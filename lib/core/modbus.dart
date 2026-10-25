import 'dart:typed_data';

import 'bytes.dart';

Uint8List modbusRequest(
  int unit,
  int function,
  int address,
  int value, {
  List<int>? values,
}) {
  if (unit < 0 || unit > 247) throw const FormatException('站址应为 0–247');
  if (address < 0 || address > 65535) {
    throw const FormatException('PDU 地址应为 0–65535');
  }
  if (![1, 2, 3, 4, 5, 6, 15, 16].contains(function)) {
    throw const FormatException('不支持的功能码');
  }
  if (unit == 0 && function <= 4) throw const FormatException('广播地址 0 仅适用于写请求');
  final max = function <= 2
      ? 2000
      : function <= 4
      ? 125
      : function == 15
      ? 1968
      : function == 16
      ? 123
      : 65535;
  if (value < (function == 5 || function == 6 ? 0 : 1) || value > max) {
    throw FormatException('数量或值超出范围，上限 $max');
  }
  if (function == 5 && value != 0 && value != 0xFF00) {
    throw const FormatException('写单线圈值仅允许 0 或 65280（FF00）');
  }
  if ([1, 2, 3, 4, 15, 16].contains(function) && address + value > 65536) {
    throw const FormatException('地址范围超出 65535');
  }
  final body = <int>[
    unit,
    function,
    address >> 8,
    address & 255,
    value >> 8,
    value & 255,
  ];
  if (function == 15 || function == 16) {
    if (values == null || values.length != value) {
      throw const FormatException('写入值列表长度必须与数量一致');
    }
    if (function == 16) {
      if (values.any((v) => v < 0 || v > 65535)) {
        throw const FormatException('寄存器值应为 0–65535');
      }
      body.add(value * 2);
      for (final v in values) {
        body.addAll([v >> 8, v & 255]);
      }
    } else {
      if (values.any((v) => v != 0 && v != 1)) {
        throw const FormatException('线圈值应为 0 或 1');
      }
      final packed = List.filled((value / 8).ceil(), 0);
      for (var i = 0; i < values.length; i++) {
        packed[i ~/ 8] |= values[i] << (i % 8);
      }
      body.addAll([packed.length, ...packed]);
    }
  }
  return withCrc(body);
}

Map<String, String> parseRtu(List<int> data, {bool response = false}) {
  if (data.length < 4) throw const FormatException('完整 RTU 帧至少 4 字节');
  if (!validCrc(data)) throw const FormatException('CRC 不匹配，原报文已保留');
  final f = data[1];
  final result = <String, String>{
    '站址': '${data[0]}',
    '功能码': '0x${f.toRadixString(16).padLeft(2, '0').toUpperCase()}',
    'CRC': '通过',
    '角色': response ? '响应' : '请求',
  };
  if (f & 0x80 != 0) {
    if (data.length != 5) throw const FormatException('异常响应必须为 5 字节');
    return {...result, '设备异常码': '${data[2]}'};
  }
  if (![1, 2, 3, 4, 5, 6, 15, 16].contains(f)) {
    return {...result, '说明': '未支持的功能码，保留原文'};
  }
  if (response && f <= 4) {
    if (data.length != data[2] + 5 || ((f == 3 || f == 4) && data[2].isOdd)) {
      throw const FormatException('响应字节数与长度不一致');
    }
    return {
      ...result,
      '字节数': '${data[2]}',
      '起始寄存器': '未知（响应未携带）',
      '数据': f >= 3
          ? [
              for (var i = 3; i < data.length - 2; i += 2)
                (data[i] << 8) | data[i + 1],
            ].join('，')
          : hex(data.sublist(3, data.length - 2)),
    };
  }
  if (data.length < 8) throw const FormatException('请求或写响应长度不足');
  final address = (data[2] << 8) | data[3], value = (data[4] << 8) | data[5];
  if (!response && (f == 15 || f == 16)) {
    final expected = f == 16 ? value * 2 : (value / 8).ceil();
    if (data[6] != expected || data.length != 9 + expected) {
      throw const FormatException('多写请求数量、字节数或长度不一致');
    }
  } else if (data.length != 8) {
    throw const FormatException('该请求或写响应必须恰好为 8 字节');
  }
  if (f == 5 && value != 0 && value != 0xFF00) {
    throw const FormatException('非法写线圈值');
  }
  if (!response && f <= 4 && (value < 1 || value > (f <= 2 ? 2000 : 125))) {
    throw const FormatException('读取数量越界');
  }
  return {
    ...result,
    'PDU 地址（0 起始）': '$address',
    f == 5 || f == 6 ? '写入值' : '数量': '$value',
  };
}

// A stream callback is never a protocol boundary. Retain incomplete tails.
class RtuFramer {
  final _buffer = <int>[];
  final int maxBytes;
  RtuFramer({this.maxBytes = 65536});
  List<Uint8List> add(List<int> chunk) {
    _buffer.addAll(chunk);
    if (_buffer.length > maxBytes) {
      _buffer.clear();
      throw const FormatException('未完成帧缓存超过 64 KiB');
    }
    final frames = <Uint8List>[];
    while (_buffer.length >= 5) {
      final f = _buffer[1];
      final length = f & 0x80 != 0
          ? 5
          : f >= 1 && f <= 4
          ? 5 + _buffer[2]
          : [5, 6, 15, 16].contains(f)
          ? 8
          : 0;
      if (length == 0 || length > 260) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < length) break;
      final candidate = Uint8List.fromList(_buffer.sublist(0, length));
      if (validCrc(candidate)) {
        frames.add(candidate);
        _buffer.removeRange(0, length);
      } else {
        _buffer.removeAt(0);
      }
    }
    return frames;
  }
}

bool matchesResponse(List<int> request, List<int> response) {
  if (request.length < 8 ||
      response.length < 5 ||
      request[0] == 0 ||
      !validCrc(response) ||
      request[0] != response[0]) {
    return false;
  }
  final f = request[1];
  if (response[1] == (f | 0x80)) return response.length == 5;
  if (response[1] != f) return false;
  try {
    parseRtu(response, response: true);
  } catch (_) {
    return false;
  }
  if (f <= 4) {
    final count = request[4] * 256 + request[5];
    return response[2] == (f <= 2 ? (count / 8).ceil() : count * 2);
  }
  return List.generate(
    4,
    (i) => request[i + 2] == response[i + 2],
  ).every((x) => x);
}

({String output, String status}) nmea(
  String input, {
  bool verify = false,
  String start = r'$',
  bool crlf = false,
}) {
  var body = input.trim();
  if (body.startsWith(r'$') || body.startsWith('!')) {
    start = body[0];
    body = body.substring(1);
  }
  final split = body.split('*');
  if (split.length > 2) throw const FormatException('语句含多个星号');
  final checksum = xor8(encodeText(split[0], 'ASCII'))
      .toRadixString(16)
      .padLeft(2, '0')
      .toUpperCase();
  var status = '已生成';
  if (verify) {
    if (split.length == 1) {
      status = '缺少校验';
    } else if (!RegExp(r'^[0-9A-Fa-f]{2}$').hasMatch(split[1])) {
      throw const FormatException('校验必须为两位 HEX');
    } else {
      status = split[1].toUpperCase() == checksum
          ? '校验通过'
          : '校验失败，应为 $checksum';
    }
  }
  return (
    output: verify
        ? '$start$body${crlf ? '\r\n' : ''}'
        : '$start${split[0]}*$checksum${crlf ? '\r\n' : ''}',
    status: status,
  );
}
