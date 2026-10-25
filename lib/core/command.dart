import 'dart:typed_data';

import 'bytes.dart';
import 'modbus.dart';

/// Deliberately limited substitutions. Command libraries never execute code.
class CommandParameter {
  static const allowedTypes = [
    'uint8',
    'int8',
    'uint16',
    'int16',
    'uint32',
    'int32',
    'hex',
    'text',
  ];
  final String name, type, defaultValue, byteOrder;
  final int? min, max;
  const CommandParameter({
    required this.name,
    this.type = 'uint16',
    this.defaultValue = '0',
    this.min,
    this.max,
    this.byteOrder = 'BE',
  });

  bool get numeric => type != 'hex' && type != 'text';
  int get width => int.parse(type.replaceAll(RegExp('[^0-9]'), ''));
  BigInt get lower =>
      type.startsWith('uint') ? BigInt.zero : -(BigInt.one << (width - 1));
  BigInt get upper =>
      (BigInt.one << (type.startsWith('uint') ? width : width - 1)) -
      BigInt.one;

  void validate() {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(name)) {
      throw const FormatException('参数名称须以字母或下划线开头，仅含字母、数字和下划线');
    }
    if (!allowedTypes.contains(type) || !['BE', 'LE'].contains(byteOrder)) {
      throw const FormatException('参数类型或字节序无效');
    }
    if (!numeric && (min != null || max != null)) {
      throw FormatException('参数 $name 的范围仅适用于整数');
    }
    if (numeric &&
        ((min != null && BigInt.from(min!) < lower) ||
            (max != null && BigInt.from(max!) > upper) ||
            (min != null && max != null && min! > max!))) {
      throw FormatException('参数 $name 的范围无效');
    }
    substitute(defaultValue, asText: false, encoding: 'UTF-8');
  }

  String substitute(
    String value, {
    required bool asText,
    required String encoding,
  }) {
    if (value.length > 4096) throw FormatException('参数 $name 超过 4096 字符');
    if (type == 'hex') return hex(parseHex(value));
    if (type == 'text') {
      return asText ? value : hex(encodeText(value, encoding));
    }
    var input = value.trim();
    final negative = input.startsWith('-');
    var digits = negative ? input.substring(1) : input;
    final radix = digits.startsWith('0x') || digits.startsWith('0X') ? 16 : 10;
    if (radix == 16) digits = digits.substring(2);
    final parsed = BigInt.tryParse(
      '${negative ? '-' : ''}$digits',
      radix: radix,
    );
    if (parsed == null ||
        parsed < lower ||
        parsed > upper ||
        (min != null && parsed < BigInt.from(min!)) ||
        (max != null && parsed > BigInt.from(max!))) {
      throw FormatException('参数 $name 超出范围 ${min ?? lower} … ${max ?? upper}');
    }
    if (asText) return parsed.toString();
    final bits = parsed.toUnsigned(width);
    final bytes = List.generate(
      width ~/ 8,
      (i) => ((bits >> (width - (i + 1) * 8)) & BigInt.from(255)).toInt(),
    );
    return hex(byteOrder == 'LE' ? bytes.reversed : bytes);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'defaultValue': defaultValue,
    'byteOrder': byteOrder,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
  };
  factory CommandParameter.fromJson(Map<String, dynamic> j) {
    _keys(j, {'name', 'type', 'defaultValue', 'min', 'max', 'byteOrder'}, '参数');
    if (j['name'] is! String ||
        (j['type'] != null && j['type'] is! String) ||
        (j['defaultValue'] != null &&
            j['defaultValue'] is! String &&
            j['defaultValue'] is! int) ||
        (j['min'] != null && j['min'] is! int) ||
        (j['max'] != null && j['max'] is! int)) {
      throw const FormatException('参数字段类型无效');
    }
    final parameter = CommandParameter(
      name: j['name'],
      type: j['type'] ?? 'uint16',
      defaultValue: (j['defaultValue'] ?? '0').toString(),
      min: j['min'],
      max: j['max'],
      byteOrder: j['byteOrder'] ?? 'BE',
    );
    parameter.validate();
    return parameter;
  }
}

String substituteParameters(
  String template,
  List<CommandParameter> parameters,
  Map<String, String> values, {
  required bool text,
  required String encoding,
}) {
  if (parameters.length > 64 || template.length > 1048576) {
    throw const FormatException('命令模板或参数数量超出限制');
  }
  final definitions = <String, CommandParameter>{};
  for (final parameter in parameters) {
    parameter.validate();
    if (definitions.containsKey(parameter.name)) {
      throw FormatException('参数 ${parameter.name} 重复');
    }
    definitions[parameter.name] = parameter;
  }
  for (final name in values.keys) {
    if (!definitions.containsKey(name)) throw FormatException('未知参数 $name');
  }
  final buffer = StringBuffer();
  var size = 0, position = 0;
  void append(String fragment) {
    size += fragment.length;
    if (size > 1048576) throw const FormatException('代入参数后的命令超过 1 MiB');
    buffer.write(fragment);
  }

  for (final match in RegExp(r'\{\{([^{}]*)\}\}').allMatches(template)) {
    append(template.substring(position, match.start));
    final name = match[1]!.trim();
    final parameter = definitions[name];
    if (parameter == null) throw FormatException('未定义参数 $name');
    final value = parameter.substitute(
      values[name] ?? parameter.defaultValue,
      asText: text,
      encoding: encoding,
    );
    append(text ? value : ' $value ');
    position = match.end;
  }
  append(template.substring(position));
  final result = buffer.toString();
  if (result.contains('{{') || result.contains('}}')) {
    throw const FormatException('参数占位符不完整');
  }
  return result;
}

class ResponseRule {
  static const allowedKinds = [
    'none',
    'modbus_rtu',
    'bytes_exact',
    'bytes_prefix',
    'bytes_masked',
    'text_exact',
    'text_contains',
  ];
  static const allowedFramings = ['rtu', 'fixed', 'delimiter', 'datagram'];
  final String kind, framing, patternHex, maskHex, text, encoding, delimiterHex;
  final int length, offset;
  final int? unitId, functionCode, registerCount;
  final bool allowException;
  const ResponseRule({
    this.kind = 'modbus_rtu',
    this.framing = 'rtu',
    this.patternHex = '',
    this.maskHex = '',
    this.text = '',
    this.encoding = 'UTF-8',
    this.length = 0,
    this.delimiterHex = '0A',
    this.offset = 0,
    this.unitId,
    this.functionCode,
    this.registerCount,
    this.allowException = true,
  });
  void validate() {
    if (!allowedKinds.contains(kind) || !allowedFramings.contains(framing)) {
      throw const FormatException('不支持的响应规则或分帧方式');
    }
    if (kind == 'none') return;
    if (length < 0 || length > 65536 || offset < 0 || offset > 65535) {
      throw const FormatException('响应长度或偏移超出范围');
    }
    if (kind == 'modbus_rtu') {
      if (framing != 'rtu' ||
          (unitId != null && (unitId! < 0 || unitId! > 247)) ||
          (functionCode != null &&
              ![1, 2, 3, 4, 5, 6, 15, 16].contains(functionCode)) ||
          (registerCount != null &&
              (registerCount! < 1 || registerCount! > 2000))) {
        throw const FormatException('Modbus 响应规则无效');
      }
      return;
    }
    if (framing == 'rtu') throw const FormatException('请选择固定长度、分隔符或数据报分帧');
    if (framing == 'fixed' && length < 1) {
      throw const FormatException('固定帧长度须大于零');
    }
    if (framing == 'delimiter') {
      final delimiter = parseHex(delimiterHex);
      if (delimiter.isEmpty || delimiter.length > 32) {
        throw const FormatException('响应分隔符须为 1–32 字节');
      }
    }
    if (kind.startsWith('bytes_')) {
      final pattern = parseHex(patternHex);
      if (pattern.isEmpty || pattern.length > 65536) {
        throw const FormatException('请输入响应字节');
      }
      if (framing == 'fixed' && offset + pattern.length > length) {
        throw const FormatException('匹配字节超出固定帧长度');
      }
      if (kind == 'bytes_exact' &&
          (offset != 0 || (framing == 'fixed' && pattern.length != length))) {
        throw const FormatException('完整字节匹配必须覆盖整帧');
      }
      if (kind == 'bytes_masked') {
        final mask = parseHex(maskHex);
        if (mask.length != pattern.length || mask.every((b) => b == 0)) {
          throw const FormatException('掩码须与匹配字节等长，且至少有一个有效位');
        }
      }
    } else {
      if (text.isEmpty ||
          text.length > 65536 ||
          !['UTF-8', 'ASCII', 'UTF-16LE', 'UTF-16BE'].contains(encoding)) {
        throw const FormatException('响应文本或编码无效');
      }
      encodeText(text, encoding);
    }
  }

  Map<String, dynamic> toJson() => kind == 'none'
      ? {'type': kind}
      : {
          'type': kind,
          'framing': framing,
          if (kind == 'modbus_rtu') ...{
            if (unitId != null) 'unitId': unitId,
            if (functionCode != null) 'functionCode': functionCode,
            if (registerCount != null) 'registerCount': registerCount,
            'allowException': allowException,
          } else ...{
            'length': length,
            'delimiterHex': delimiterHex,
            'offset': offset,
            if (kind.startsWith('bytes_')) 'patternHex': patternHex,
            if (kind == 'bytes_masked') 'maskHex': maskHex,
            if (kind.startsWith('text_')) ...{
              'text': text,
              'encoding': encoding,
            },
          },
        };
  factory ResponseRule.fromJson(Map<String, dynamic> j) {
    _keys(j, {
      'type',
      'framing',
      'patternHex',
      'maskHex',
      'text',
      'encoding',
      'length',
      'delimiterHex',
      'offset',
      'unitId',
      'functionCode',
      'registerCount',
      'allowException',
    }, '响应规则');
    for (final field in [
      'type',
      'framing',
      'patternHex',
      'maskHex',
      'text',
      'encoding',
      'delimiterHex',
    ]) {
      if (j[field] != null && j[field] is! String) {
        throw FormatException('响应规则 $field 类型无效');
      }
    }
    for (final field in [
      'length',
      'offset',
      'unitId',
      'functionCode',
      'registerCount',
    ]) {
      if (j[field] != null && j[field] is! int) {
        throw FormatException('响应规则 $field 类型无效');
      }
    }
    if (j['allowException'] != null && j['allowException'] is! bool) {
      throw const FormatException('allowException 必须为布尔值');
    }
    final rule = ResponseRule(
      kind: j['type'] ?? 'modbus_rtu',
      framing:
          j['framing'] ??
          (j['type'] == 'modbus_rtu' || j['type'] == null
              ? 'rtu'
              : 'delimiter'),
      patternHex: j['patternHex'] ?? '',
      maskHex: j['maskHex'] ?? '',
      text: j['text'] ?? '',
      encoding: j['encoding'] ?? 'UTF-8',
      length: j['length'] ?? 0,
      delimiterHex: j['delimiterHex'] ?? '0A',
      offset: j['offset'] ?? 0,
      unitId: j['unitId'],
      functionCode: j['functionCode'],
      registerCount: j['registerCount'],
      allowException: j['allowException'] ?? true,
    );
    rule.validate();
    return rule;
  }
}

void _keys(Map<String, dynamic> j, Set<String> allowed, String name) {
  for (final key in j.keys) {
    if (!allowed.contains(key)) throw FormatException('$name 包含未支持的字段 $key');
  }
}

class ResponseMatch {
  final Uint8List bytes;
  final int? exceptionCode;
  ResponseMatch(List<int> bytes, {this.exceptionCode})
    : bytes = Uint8List.fromList(bytes);
}

/// One instance per submitted request, never shared across steps or endpoints.
/// Stream callbacks are transport chunks, never implicit message boundaries.
class ResponseMatcher {
  final ResponseRule rule;
  final Uint8List request;
  late final Uint8List _pattern, _mask, _delimiter;
  final _buffer = <int>[];
  int _delimiterSearchStart = 0;
  static const maxBytes = 65536;
  ResponseMatcher(this.rule, List<int> request)
    : request = Uint8List.fromList(request) {
    rule.validate();
    _pattern = rule.kind.startsWith('bytes_')
        ? parseHex(rule.patternHex)
        : Uint8List(0);
    _mask = rule.kind == 'bytes_masked' ? parseHex(rule.maskHex) : Uint8List(0);
    _delimiter = rule.framing == 'delimiter'
        ? parseHex(rule.delimiterHex)
        : Uint8List(0);
    if (rule.kind == 'modbus_rtu') {
      parseRtu(request);
      if (request.length < 8 ||
          request[0] > 247 ||
          ![1, 2, 3, 4, 5, 6, 15, 16].contains(request[1]) ||
          (rule.unitId != null && rule.unitId != request[0]) ||
          (rule.functionCode != null && rule.functionCode != request[1]) ||
          (rule.registerCount != null &&
              rule.registerCount != (request[4] * 256 + request[5]))) {
        throw const FormatException('响应规则与最终请求不一致');
      }
      if (request[0] == 0 && request[1] <= 4) {
        throw const FormatException('Modbus 广播地址不支持读取');
      }
    }
  }

  ResponseMatch? add(List<int> chunk, {bool datagram = false}) {
    if (rule.kind == 'none') return null;
    if (chunk.length > maxBytes || _buffer.length + chunk.length > maxBytes) {
      _buffer.clear();
      _delimiterSearchStart = 0;
      throw const FormatException('响应分帧缓存超过 64 KiB');
    }
    // UDP packet boundaries must never be joined with the next packet.
    if (datagram || rule.framing == 'datagram') {
      if (!datagram) throw const FormatException('数据报分帧仅适用于 UDP');
      if (rule.kind == 'modbus_rtu') return _match(chunk);
      if (rule.framing == 'fixed' && chunk.length != rule.length) return null;
      if (rule.framing == 'delimiter') {
        if (!_endsWith(chunk, _delimiter)) return null;
        return _match(chunk.sublist(0, chunk.length - _delimiter.length));
      }
      return _match(chunk);
    }
    _buffer.addAll(chunk);
    if (rule.framing == 'rtu') return _rtu();
    var consumed = 0;
    while (consumed < _buffer.length) {
      int end, next;
      if (rule.framing == 'fixed') {
        if (_buffer.length - consumed < rule.length) break;
        end = next = consumed + rule.length;
      } else {
        end = _findDelimiter(
          _buffer,
          _delimiter,
          consumed > _delimiterSearchStart ? consumed : _delimiterSearchStart,
        );
        if (end < 0) {
          _delimiterSearchStart = (_buffer.length - _delimiter.length + 1)
              .clamp(consumed, _buffer.length);
          break;
        }
        next = end + _delimiter.length;
      }
      final matched = _match(_buffer.sublist(consumed, end));
      consumed = next;
      if (matched != null) {
        _buffer.removeRange(0, consumed);
        _delimiterSearchStart = 0;
        return matched;
      }
    }
    if (consumed > 0) {
      _buffer.removeRange(0, consumed);
      _delimiterSearchStart = (_delimiterSearchStart - consumed).clamp(
        0,
        _buffer.length,
      );
    }
    return null;
  }

  ResponseMatch? _rtu() {
    int? retain;
    for (var start = 0; start + 4 < _buffer.length; start++) {
      final f = _buffer[start + 1];
      final size = f & 0x80 != 0
          ? 5
          : f >= 1 && f <= 4
          ? 5 + _buffer[start + 2]
          : [5, 6, 15, 16].contains(f)
          ? 8
          : 0;
      if (size < 5 || size > 260) continue;
      if (start + size > _buffer.length) {
        retain ??= start;
        continue;
      }
      final frame = _buffer.sublist(start, start + size);
      if (!validCrc(frame)) continue;
      final matched = _match(frame);
      if (matched != null) {
        _buffer.removeRange(0, start + size);
        return matched;
      }
      start += size - 1;
    }
    final keep = retain ?? (_buffer.length - 4).clamp(0, _buffer.length);
    if (keep > 0) _buffer.removeRange(0, keep);
    return null;
  }

  ResponseMatch? _match(List<int> frame) {
    if (rule.kind == 'modbus_rtu') {
      if (!matchesResponse(request, frame)) return null;
      return ResponseMatch(
        frame,
        exceptionCode: frame[1] & 0x80 != 0 ? frame[2] : null,
      );
    }
    if (rule.kind.startsWith('text_')) {
      try {
        final value = decodeText(frame, rule.encoding);
        final matches = rule.kind == 'text_exact'
            ? value == rule.text
            : value.contains(rule.text);
        return matches ? ResponseMatch(frame) : null;
      } on FormatException {
        return null;
      }
    }
    if (frame.length < rule.offset + _pattern.length ||
        (rule.kind == 'bytes_exact' && frame.length != _pattern.length)) {
      return null;
    }
    for (var i = 0; i < _pattern.length; i++) {
      final mask = rule.kind == 'bytes_masked' ? _mask[i] : 255;
      if ((frame[i + rule.offset] & mask) != (_pattern[i] & mask)) return null;
    }
    return ResponseMatch(frame);
  }
}

bool _endsWith(List<int> data, List<int> end) =>
    data.length >= end.length &&
    List.generate(
      end.length,
      (i) => data[data.length - end.length + i] == end[i],
    ).every((x) => x);
int _findDelimiter(List<int> data, List<int> delimiter, int start) {
  for (var i = start; i <= data.length - delimiter.length; i++) {
    var match = true;
    for (var j = 0; j < delimiter.length; j++) {
      if (data[i + j] != delimiter[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}
