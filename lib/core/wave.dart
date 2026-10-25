import 'dart:collection';

import 'bytes.dart';
import 'models.dart';
import 'modbus.dart';

const waveColors = [
  0xFF3769FF,
  0xFF0BAA83,
  0xFFF2994A,
  0xFFB46CE5,
  0xFFE26083,
  0xFF24A6C8,
  0xFF97942B,
  0xFF7E8AAB,
];

class WaveMapping {
  String id, name, unit, mode, delimiter, type, order, endpoint, prefix;
  int field,
      offset,
      frameLength,
      station,
      function,
      registerAddress,
      color,
      gapMs;
  double scale, bias;
  bool enabled, visible;
  WaveMapping({
    String? id,
    this.name = '通道 1',
    this.unit = '',
    this.mode = '文本字段',
    this.delimiter = ',',
    this.field = 0,
    this.offset = 0,
    this.frameLength = 0,
    this.type = 'uint16',
    this.order = 'BE',
    this.scale = 1,
    this.bias = 0,
    this.endpoint = '',
    this.prefix = '',
    this.station = 1,
    this.function = 3,
    this.registerAddress = 0,
    this.color = 0xFF3769FF,
    this.gapMs = 5000,
    this.enabled = true,
    this.visible = true,
  }) : id = id ?? newId();
  void validate() {
    if (!['文本字段', '固定字节偏移', 'Modbus 寄存器'].contains(mode) ||
        ![
          'int16',
          'uint16',
          'int32',
          'uint32',
          'float32',
          'float64',
        ].contains(type) ||
        !['BE', 'LE', 'SWAP_BYTES', 'SWAP_WORDS'].contains(order) ||
        ![3, 4].contains(function)) {
      throw const FormatException('不支持的数值映射参数');
    }
    if (name.trim().isEmpty) throw const FormatException('请输入通道名称');
    if (!scale.isFinite || !bias.isFinite) {
      throw const FormatException('比例和偏移必须为有限数值');
    }
    if (field < 0 || offset < 0 || frameLength < 0 || frameLength > 65536) {
      throw const FormatException('字段、偏移和帧长超出范围');
    }
    if (mode == '文本字段' && delimiter.isEmpty) {
      throw const FormatException('分隔符不能为空');
    }
    if (mode == '固定字节偏移' && (frameLength < offset + typeSize(type))) {
      throw const FormatException('帧长必须覆盖完整数值字段');
    }
    if (station < 1 ||
        station > 247 ||
        registerAddress < 0 ||
        registerAddress > 65535) {
      throw const FormatException('站号或寄存器地址超出范围');
    }
    if (gapMs < 0 || gapMs > 86400000) {
      throw const FormatException('超时范围必须为 0–86400000 ms');
    }
    if (prefix.isNotEmpty) parseHex(prefix);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'unit': unit,
    'mode': mode,
    'delimiter': delimiter,
    'field': field,
    'offset': offset,
    'frameLength': frameLength,
    'type': type,
    'order': order,
    'scale': scale,
    'bias': bias,
    'endpoint': endpoint,
    'prefix': prefix,
    'station': station,
    'function': function,
    'registerAddress': registerAddress,
    'color': color,
    'enabled': enabled,
    'visible': visible,
    'gapMs': gapMs,
  };
  factory WaveMapping.fromJson(Map<String, dynamic> j) => WaveMapping(
    id: j['id'],
    name: j['name'] ?? '通道',
    unit: j['unit'] ?? '',
    mode: j['mode'] ?? '文本字段',
    delimiter: j['delimiter'] ?? ',',
    field: j['field'] ?? 0,
    offset: j['offset'] ?? 0,
    frameLength: j['frameLength'] ?? 0,
    type: j['type'] ?? 'uint16',
    order: j['order'] ?? 'BE',
    scale: (j['scale'] ?? 1).toDouble(),
    bias: (j['bias'] ?? 0).toDouble(),
    endpoint: j['endpoint'] ?? '',
    prefix: j['prefix'] ?? '',
    station: j['station'] ?? 1,
    function: j['function'] ?? 3,
    registerAddress: j['registerAddress'] ?? 0,
    color: j['color'] ?? waveColors.first,
    enabled: j['enabled'] ?? true,
    visible: j['visible'] ?? true,
    gapMs: j['gapMs'] ?? 5000,
  );
  WaveMapping copy() => WaveMapping.fromJson(toJson());
}

class WaveSample {
  final DateTime time;
  final double? value;
  final String logId, error;
  const WaveSample(this.time, this.value, this.logId, {this.error = ''});
}

class WaveChannel {
  WaveMapping mapping;
  final samples = ListQueue<WaveSample>();
  int dropped = 0;
  String lastError = '';
  final _tails = <String, List<int>>{};
  WaveChannel(this.mapping);
  void append(WaveSample sample, int limit) {
    samples.add(sample);
    lastError = sample.error;
    while (samples.length > limit) {
      samples.removeFirst();
      dropped++;
    }
  }

  void resetStream() => _tails.clear();
  void clear() {
    samples.clear();
    dropped = 0;
    lastError = '';
    resetStream();
  }
}

/// Maps raw receive records; display state never controls acquisition.
class WaveEngine {
  final channels = <WaveChannel>[];
  final int sampleLimit;
  final _requests = <String, List<int>>{};
  WaveEngine({this.sampleLimit = 100000});
  void upsert(WaveMapping mapping) {
    mapping.validate();
    final index = channels.indexWhere((c) => c.mapping.id == mapping.id);
    if (index < 0) {
      if (channels.length >= 8) throw StateError('最多添加 8 个通道');
      channels.add(WaveChannel(mapping.copy()));
    } else {
      channels[index].mapping = mapping.copy();
      // Changed interpretation starts a new sample series.
      channels[index].clear();
    }
  }

  void recordRequest(List<int> bytes, String endpoint) {
    try {
      parseRtu(bytes);
      if ([3, 4].contains(bytes[1])) {
        if (_requests.length >= 256) _requests.remove(_requests.keys.first);
        _requests['$endpoint:${bytes[0]}:${bytes[1]}'] = List.of(bytes);
      }
    } catch (_) {}
  }

  void boundary({DateTime? time}) {
    _requests.clear();
    for (final c in channels) {
      c.resetStream();
      if (c.samples.isNotEmpty && c.samples.last.value != null) {
        c.append(
          WaveSample(time ?? DateTime.now(), null, '', error: '连接中断'),
          sampleLimit,
        );
      }
    }
  }

  bool expire(DateTime now) {
    var changed = false;
    for (final c in channels) {
      if (!c.mapping.enabled || c.mapping.gapMs <= 0 || c.samples.isEmpty) {
        continue;
      }
      final last = c.samples.last;
      if (last.value != null &&
          now.difference(last.time).inMilliseconds >= c.mapping.gapMs) {
        c.append(
          WaveSample(
            last.time.add(Duration(milliseconds: c.mapping.gapMs)),
            null,
            '',
            error: '采样超时',
          ),
          sampleLimit,
        );
        changed = true;
      }
    }
    return changed;
  }

  void receive(LogEntry entry, {bool datagram = false, List<int>? rtuFrame}) {
    for (final c in channels) {
      final m = c.mapping;
      if (!m.enabled ||
          (m.endpoint.isNotEmpty && m.endpoint != entry.endpoint)) {
        continue;
      }
      if ((m.mode == 'Modbus 寄存器') != (rtuFrame != null)) continue;
      if (m.mode == 'Modbus 寄存器') {
        final bytes = rtuFrame!;
        if (bytes[0] != m.station || (bytes[1] & 0x7F) != m.function) continue;
        _extract(c, entry, bytes);
        continue;
      }
      final tail = c._tails.putIfAbsent(entry.endpoint, () => <int>[]);
      if (c._tails.length > 32) c._tails.remove(c._tails.keys.first);
      tail.addAll(entry.bytes);
      if (tail.length > 65536) {
        tail.clear();
        _invalid(c, entry, '报文超过 64 KiB');
        continue;
      }
      if (datagram) {
        _extract(c, entry, List.of(tail));
        tail.clear();
      } else if (m.mode == '文本字段') {
        int end;
        while ((end = tail.indexOf(10)) >= 0) {
          final bytes = tail.sublist(0, end);
          tail.removeRange(0, end + 1);
          _extract(c, entry, bytes);
        }
      } else {
        final length = m.frameLength;
        if (length < 1) {
          _invalid(c, entry, '请设置固定帧长');
          tail.clear();
          continue;
        }
        final prefix = m.prefix.isEmpty ? <int>[] : parseHex(m.prefix);
        while (tail.length >= length) {
          if (!_starts(tail, prefix)) {
            tail.removeAt(0);
            continue;
          }
          final bytes = tail.sublist(0, length);
          tail.removeRange(0, length);
          _extract(c, entry, bytes);
        }
      }
    }
  }

  bool _starts(List<int> bytes, List<int> prefix) =>
      bytes.length >= prefix.length &&
      List.generate(
        prefix.length,
        (i) => bytes[i] == prefix[i],
      ).every((v) => v);
  void _extract(WaveChannel c, LogEntry entry, List<int> bytes) {
    final m = c.mapping;
    try {
      if (m.prefix.isNotEmpty && !_starts(bytes, parseHex(m.prefix))) return;
      double raw;
      if (m.mode == '文本字段') {
        final fields = decodeText(bytes, 'UTF-8').trim().split(m.delimiter);
        if (m.field >= fields.length) throw const FormatException('文本字段越界');
        raw = double.parse(fields[m.field].trim());
      } else {
        var offset = m.offset;
        var end = bytes.length;
        if (m.mode == 'Modbus 寄存器') {
          parseRtu(bytes, response: true);
          if (bytes[1] & 0x80 != 0) throw FormatException('设备异常 ${bytes[2]}');
          final request =
              _requests['${entry.endpoint}:${m.station}:${m.function}'] ??
              _requests[':${m.station}:${m.function}'];
          if (request == null || !matchesResponse(request, bytes)) {
            throw const FormatException('缺少匹配的读取请求');
          }
          final start = request[2] * 256 + request[3];
          offset = 3 + (m.registerAddress - start) * 2;
          end = 3 + bytes[2];
          if (offset < 3) throw const FormatException('寄存器不在响应范围');
        }
        final size = typeSize(m.type);
        if (offset < 0 || offset + size > end) {
          throw const FormatException('数值字段越界');
        }
        raw = double.parse(
          decodeNumber(bytes.sublist(offset, offset + size), m.type, m.order),
        );
      }
      final value = raw * m.scale + m.bias;
      if (!value.isFinite) throw const FormatException('非有限数值');
      c.append(WaveSample(entry.time, value, entry.id), sampleLimit);
    } catch (e) {
      _invalid(c, entry, e.toString().replaceFirst('FormatException: ', ''));
    }
  }

  void _invalid(WaveChannel c, LogEntry entry, String reason) => c.append(
    WaveSample(entry.time, null, entry.id, error: reason),
    sampleLimit,
  );
  String exportCsv() {
    String quote(String s) => '"${s.replaceAll('"', '""')}"';
    return [
      'channel,unit,time_utc,value,error,log_id',
      for (final c in channels)
        for (final p in c.samples)
          [
            quote(c.mapping.name),
            quote(c.mapping.unit),
            p.time.toUtc().toIso8601String(),
            p.value?.toString() ?? '',
            quote(p.error),
            p.logId,
          ].join(','),
    ].join('\n');
  }
}
