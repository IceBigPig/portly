import 'dart:convert';
import 'dart:typed_data';

Uint8List parseHex(String input) {
  final out = <int>[];
  final tokens = RegExp(r'\S+').allMatches(input);
  for (final token in tokens) {
    var text = token.group(0)!;
    final prefixed = text.startsWith('0x') || text.startsWith('0X');
    if (prefixed) text = text.substring(2);
    if (text.isEmpty || text.length.isOdd || (prefixed && text.length != 2)) {
      throw FormatException('第 ${token.start + 1} 位：请输入完整的两位 HEX 字节');
    }
    for (var i = 0; i < text.length; i += 2) {
      final value = int.tryParse(text.substring(i, i + 2), radix: 16);
      if (value == null) {
        throw FormatException('第 ${token.start + i + 1} 位：无效 HEX');
      }
      out.add(value);
    }
  }
  return Uint8List.fromList(out);
}

String hex(Iterable<int> bytes) => bytes
    .map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');

Uint8List encodeText(String text, String encoding) {
  if (encoding == 'ASCII') {
    if (text.codeUnits.any((c) => c > 127)) {
      throw const FormatException('ASCII 不能编码非 ASCII 字符');
    }
    return Uint8List.fromList(ascii.encode(text));
  }
  if (encoding.startsWith('UTF-16')) {
    final data = ByteData(text.length * 2);
    for (var i = 0; i < text.length; i++) {
      data.setUint16(
        i * 2,
        text.codeUnitAt(i),
        encoding == 'UTF-16LE' ? Endian.little : Endian.big,
      );
    }
    // Reject isolated surrogates rather than producing ill-formed Unicode.
    decodeText(data.buffer.asUint8List(), encoding);
    return data.buffer.asUint8List();
  }
  return Uint8List.fromList(utf8.encode(text));
}

String decodeText(List<int> bytes, String encoding, {bool preview = false}) {
  if (encoding == 'ASCII') return ascii.decode(bytes, allowInvalid: preview);
  if (!encoding.startsWith('UTF-16')) {
    return utf8.decode(bytes, allowMalformed: preview);
  }
  if (bytes.length.isOdd) {
    if (preview) {
      return '${decodeText(bytes.sublist(0, bytes.length - 1), encoding, preview: true)}�';
    }
    throw const FormatException('UTF-16 需要偶数字节');
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final codes = <int>[];
  for (var i = 0; i < bytes.length; i += 2) {
    codes.add(
      data.getUint16(i, encoding == 'UTF-16LE' ? Endian.little : Endian.big),
    );
  }
  for (var i = 0; i < codes.length; i++) {
    final c = codes[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (++i >= codes.length || codes[i] < 0xDC00 || codes[i] > 0xDFFF) {
        if (preview) {
          codes[i - 1] = 0xFFFD;
          i--;
        } else {
          throw const FormatException('UTF-16 代理对不完整');
        }
      }
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      if (preview) {
        codes[i] = 0xFFFD;
      } else {
        throw const FormatException('UTF-16 低代理项缺少高代理项');
      }
    }
  }
  return String.fromCharCodes(codes);
}

int crc16(List<int> bytes) {
  var crc = 0xFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc;
}

Uint8List withCrc(List<int> bytes) {
  final crc = crc16(bytes);
  return Uint8List.fromList([...bytes, crc & 255, crc >> 8]);
}

bool validCrc(List<int> bytes) => bytes.length >= 4 && crc16(bytes) == 0;
int sum8(List<int> bytes) => bytes.fold(0, (s, b) => s + b) & 255;
int xor8(List<int> bytes) => bytes.fold(0, (s, b) => s ^ b);
int lrc(List<int> bytes) => (-sum8(bytes)) & 255;

Uint8List buildBytes({
  required String body,
  bool text = false,
  String encoding = 'UTF-8',
  String suffix = '',
  bool crc = false,
}) {
  if (body.trim().isEmpty) throw const FormatException('请输入发送内容');
  if (crc && (text || suffix.isNotEmpty)) {
    throw const FormatException('自动 RTU CRC 仅适用于无文本尾缀的 HEX 主体');
  }
  final data = text ? encodeText(body, encoding) : parseHex(body);
  final bytes = [...data, if (text) ...parseHex(suffix)];
  return crc ? withCrc(bytes) : Uint8List.fromList(bytes);
}

class RadixResult {
  final BigInt value, bits;
  final int width;
  RadixResult(this.value, this.bits, this.width);
  BigInt get signed => bits.toSigned(width);
  List<int> get be => List.generate(
    width ~/ 8,
    (i) => ((bits >> ((width ~/ 8 - 1 - i) * 8)) & BigInt.from(255)).toInt(),
  );
  String pattern(int radix) => bits
      .toRadixString(radix)
      .toUpperCase()
      .padLeft(
        radix == 2
            ? width
            : radix == 8
            ? (width / 3).ceil()
            : width ~/ 4,
        '0',
      );
}

RadixResult convertRadix(
  String input, {
  int radix = 10,
  int width = 32,
  bool signed = false,
  bool bitPattern = false,
}) {
  var text = input.trim();
  final prefix = RegExp(r'^(-?)(0[xXbBoO])').firstMatch(text);
  if (prefix != null) {
    final expected = {
      'x': 16,
      'b': 2,
      'o': 8,
    }[prefix.group(2)!.substring(1).toLowerCase()];
    if (expected != radix) throw const FormatException('输入前缀与所选进制不一致');
    text = '${prefix.group(1)}${text.substring(prefix.end)}';
  }
  final value = BigInt.tryParse(text, radix: radix);
  if (value == null) throw const FormatException('数值为空或包含当前进制不支持的字符');
  final min = signed && !bitPattern
      ? -(BigInt.one << (width - 1))
      : BigInt.zero;
  final max =
      (BigInt.one << (signed && !bitPattern ? width - 1 : width)) - BigInt.one;
  if (value < min || value > max) {
    throw FormatException(
      '超出 ${signed && !bitPattern ? '有符号' : '无符号'} $width 位范围：$min … $max',
    );
  }
  final bits = value.toUnsigned(width);
  return RadixResult(
    bitPattern && signed ? bits.toSigned(width) : value,
    bits,
    width,
  );
}

List<int> reorder(List<int> bytes, String order) {
  if (order == 'LE') return bytes.reversed.toList();
  if (order == 'SWAP_BYTES') {
    return List.generate(bytes.length, (i) => bytes[i ^ 1]);
  }
  if (order == 'SWAP_WORDS') {
    return [
      for (var i = bytes.length - 2; i >= 0; i -= 2) ...[
        bytes[i],
        bytes[i + 1],
      ],
    ];
  }
  return List.of(bytes);
}

int typeSize(String type) => type.endsWith('16')
    ? 2
    : type.endsWith('32')
    ? 4
    : 8;
String decodeNumber(List<int> input, String type, String order) {
  final size = typeSize(type);
  if (input.length != size) {
    throw FormatException('$type 必须为 $size 字节，实际 ${input.length} 字节');
  }
  final bytes = reorder(input, order);
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  if (type == 'float32') return data.getFloat32(0).toString();
  if (type == 'float64') return data.getFloat64(0).toString();
  var n = BigInt.zero;
  for (final b in bytes) {
    n = (n << 8) | BigInt.from(b);
  }
  return (type.startsWith('int') ? n.toSigned(size * 8) : n).toString();
}

List<int> encodeNumber(String input, String type, String order) {
  final size = typeSize(type);
  if (type.startsWith('float')) {
    final value = double.tryParse(input);
    if (value == null) throw const FormatException('无效浮点数');
    final data = ByteData(size);
    if (size == 4) {
      data.setFloat32(0, value);
    } else {
      data.setFloat64(0, value);
    }
    return reorder(data.buffer.asUint8List(), order);
  }
  return reorder(
    convertRadix(input, width: size * 8, signed: type.startsWith('int')).be,
    order,
  );
}

int floorSeconds(int milliseconds) =>
    (BigInt.from(milliseconds) ~/ BigInt.from(1000) -
            (milliseconds < 0 && milliseconds % 1000 != 0
                ? BigInt.one
                : BigInt.zero))
        .toInt();

int parseTimestamp(String text, bool seconds) {
  if (!seconds) return int.parse(text.trim());
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d{1,3}))?$').firstMatch(text.trim());
  if (match == null) throw const FormatException('秒支持最多三位小数；毫秒必须为整数');
  return (match.group(1) == '-' ? -1 : 1) *
      (int.parse(match.group(2)!) * 1000 +
          int.parse((match.group(3) ?? '').padRight(3, '0')));
}
