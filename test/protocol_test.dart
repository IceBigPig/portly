import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:portly/core/bytes.dart';
import 'package:portly/core/modbus.dart';
import 'package:portly/core/time_tools.dart';

void main() {
  setUpAll(tz.initializeTimeZones);
  group('严格 HEX / 文本', () {
    test('接受三种 HEX 语法', () {
      for (final s in [
        '010300000002',
        '01 03 00 00 00 02',
        '0x01 0x03 0x00 0x00 0x00 0x02',
      ]) {
        expect(hex(parseHex(s)), '01 03 00 00 00 02');
      }
    });
    for (final input in ['01 0', '0x001', '0x0102', 'GG', '1', '01-03']) {
      test(
        '拒绝 $input',
        () => expect(() => parseHex(input), throwsFormatException),
      );
    }
    test(
      'UTF8 中文',
      () => expect(hex(encodeText('温度', 'UTF-8')), 'E6 B8 A9 E5 BA A6'),
    );
    test(
      'ASCII / CRLF',
      () => expect(hex(encodeText('OK\r\n', 'ASCII')), '4F 4B 0D 0A'),
    );
    test('UTF16 无 BOM', () {
      expect(hex(encodeText('A', 'UTF-16LE')), '41 00');
      expect(hex(encodeText('A', 'UTF-16BE')), '00 41');
    });
    test('UTF16 代理对与错误', () {
      expect(decodeText(encodeText('😀', 'UTF-16LE'), 'UTF-16LE'), '😀');
      expect(() => decodeText([0, 0xD8], 'UTF-16LE'), throwsFormatException);
    });
    test('拒绝有损编码与截断解码', () {
      expect(() => encodeText('温', 'ASCII'), throwsFormatException);
      expect(() => decodeText([0xE6, 0xB8], 'UTF-8'), throwsFormatException);
    });
  });
  group('CRC / 单字节校验黄金向量', () {
    final body = parseHex('01 03 00 00 00 02');
    test('0BC4 / C4 0B', () {
      expect(crc16(body), 0x0BC4);
      expect(hex(withCrc(body)), '01 03 00 00 00 02 C4 0B');
    });
    test(
      '123456789',
      () => expect(crc16(encodeText('123456789', 'ASCII')), 0x4B37),
    );
    test(
      '响应 DA 4F',
      () => expect(crc16(parseHex('01 03 04 00 FA 01 2C')), 0x4FDA),
    );
    test('正确与错误完整帧', () {
      expect(validCrc(parseHex('01 03 00 00 00 02 C4 0B')), true);
      expect(validCrc(parseHex('01 03 00 00 00 03 C4 0B')), false);
      expect(crc16(parseHex('01 03 00 00 00 03')), 0xCB05);
    });
    test('构建一次 CRC', () {
      final b = buildBytes(body: hex(body), crc: true);
      expect(b.length, 8);
      expect(hex(buildBytes(body: hex(b))), hex(b));
      expect(
        () => buildBytes(body: 'A', text: true, crc: true),
        throwsFormatException,
      );
    });
    test('SUM / XOR / LRC', () {
      expect(sum8(body), 6);
      expect(xor8(body), 0);
      expect(lrc(body), 0xFA);
    });
  });
  group('BigInt 精度、边界、补码', () {
    test('65535', () {
      final r = convertRadix('65535');
      expect(r.pattern(16), '0000FFFF');
      expect(r.pattern(8), '00000177777');
      expect(hex(r.be), '00 00 FF FF');
    });
    test('signed -1', () {
      final r = convertRadix('-1', signed: true);
      expect(r.pattern(16), 'FFFFFFFF');
      expect(r.pattern(8), '37777777777');
    });
    test(
      '32 位最高位',
      () => expect(
        convertRadix(
          '80000000',
          radix: 16,
          signed: true,
          bitPattern: true,
        ).value.toString(),
        '-2147483648',
      ),
    );
    test('64 位全部1', () {
      final r = convertRadix(
        'FFFFFFFFFFFFFFFF',
        radix: 16,
        width: 64,
        bitPattern: true,
      );
      expect(r.signed.toString(), '-1');
      expect(r.bits.toString(), '18446744073709551615');
    });
    test('超 2^53 保持精确', () {
      final r = convertRadix('9007199254740993', width: 64);
      expect(r.pattern(16), '0020000000000001');
      expect(r.value.toRadixString(8), '400000000000000001');
    });
    for (final input in ['2147483648', '-2147483649']) {
      test(
        'signed32 拒绝 $input',
        () => expect(
          () => convertRadix(input, signed: true),
          throwsFormatException,
        ),
      );
    }
    test(
      'signed64 溢出',
      () => expect(
        () => convertRadix('9223372036854775808', signed: true, width: 64),
        throwsFormatException,
      ),
    );
    test(
      '位模式超宽',
      () => expect(
        () => convertRadix('1FFFFFFFF', radix: 16, bitPattern: true),
        throwsFormatException,
      ),
    );
    test('非法进制与前缀', () {
      expect(() => convertRadix('128', radix: 8), throwsFormatException);
      expect(() => convertRadix('102', radix: 2), throwsFormatException);
      expect(() => convertRadix('0x10'), throwsFormatException);
    });
  });
  group('IEEE754 字节排列', () {
    for (final e in {
      'BE': '41 45 70 A4',
      'SWAP_WORDS': '70 A4 41 45',
      'SWAP_BYTES': '45 41 A4 70',
      'LE': 'A4 70 45 41',
    }.entries) {
      test(e.key, () {
        final bytes = encodeNumber('12.34', 'float32', e.key);
        expect(hex(bytes), e.value);
        expect(decodeNumber(bytes, 'float32', e.key), '12.34000015258789');
      });
    }
    test('浮点特殊值', () {
      expect(decodeNumber(parseHex('80 00 00 00'), 'float32', 'BE'), '-0.0');
      expect(
        decodeNumber(parseHex('7F 80 00 00'), 'float32', 'BE'),
        'Infinity',
      );
      expect(decodeNumber(parseHex('7F C0 00 00'), 'float32', 'BE'), 'NaN');
    });
    test('uint64 精确读写', () {
      final b = encodeNumber('18446744073709551615', 'uint64', 'BE');
      expect(decodeNumber(b, 'uint64', 'BE'), '18446744073709551615');
    });
    test(
      '拒绝不完整数值',
      () => expect(
        () => decodeNumber([1, 2], 'float32', 'BE'),
        throwsFormatException,
      ),
    );
  });
  group('Modbus RTU 生成、结构、流分帧', () {
    final request = modbusRequest(1, 3, 0, 2),
        response = parseHex('01 03 04 00 FA 01 2C DA 4F');
    test('标准读请求', () => expect(hex(request), '01 03 00 00 00 02 C4 0B'));
    test(
      '响应字段',
      () => expect(parseRtu(response, response: true)['数据'], '250，300'),
    );
    test('异常响应也能匹配', () {
      expect(matchesResponse(request, withCrc([1, 0x83, 2])), true);
      expect(matchesResponse(request, withCrc([2, 0x83, 2])), false);
    });
    test(
      '核对读取字节数',
      () => expect(matchesResponse(request, withCrc([1, 3, 2, 0, 1])), false),
    );
    test('任意拆分、粘包得到相同帧', () {
      final framer = RtuFramer(), result = <String>[];
      final combined = [
        ...response,
        ...response,
        ...withCrc([1, 0x83, 2]),
      ];
      for (var i = 0; i < combined.length; i += 2) {
        result.addAll(
          framer
              .add(combined.sublist(i, (i + 2).clamp(0, combined.length)))
              .map(hex),
        );
      }
      expect(result, [
        hex(response),
        hex(response),
        hex(withCrc([1, 0x83, 2])),
      ]);
    });
    test(
      'CRC通过仍拒绝结构错误',
      () => expect(
        () => parseRtu(withCrc([1, 3, 4, 0, 1]), response: true),
        throwsFormatException,
      ),
    );
    test('限制数量、线圈值与广播', () {
      expect(() => modbusRequest(1, 3, 0, 126), throwsFormatException);
      expect(() => modbusRequest(1, 5, 0, 1), throwsFormatException);
      expect(() => modbusRequest(0, 3, 0, 1), throwsFormatException);
      expect(modbusRequest(0, 6, 0, 1).first, 0);
    });
    test('多寄存器与多线圈', () {
      expect(
        parseRtu(modbusRequest(1, 16, 0, 2, values: [250, 300]))['数量'],
        '2',
      );
      expect(modbusRequest(1, 15, 0, 3, values: [1, 0, 1])[7], 5);
    });
  });
  group('NMEA', () {
    const sample =
        r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47';
    test('完整 GGA 47', () => expect(nmea(sample, verify: true).status, '校验通过'));
    test('错误、缺失独立状态', () {
      expect(
        nmea(sample.replaceFirst('*47', '*46'), verify: true).status,
        contains('失败'),
      );
      expect(nmea('GPGGA,', verify: true).status, '缺少校验');
    });
    test('验证失败保留线上校验，不隐式修复', () {
      final bad = sample.replaceFirst('*47', '*46');
      expect(nmea(bad, verify: true).output, bad);
    });
    test('ASCII 边界', () => expect(() => nmea('中文'), throwsFormatException));
  });
  group('时间戳、负数与 DST', () {
    test('上海黄金值', () {
      final utc = parseZonedDate('2026-10-25T00:00:00Z', 'Asia/Shanghai');
      expect(utc.millisecondsSinceEpoch, 1792886400000);
      expect(zonedDisplay(utc, 'Asia/Shanghai'), contains('08:00:00'));
    });
    test('负数向负无穷取整', () {
      expect(floorSeconds(-1), -1);
      expect(floorSeconds(-1001), -2);
      expect(parseTimestamp('-0.001', true), -1);
      expect(parseTimestamp('1792886400.123', true), 1792886400123);
    });
    test(
      '秒不静默舍入',
      () => expect(() => parseTimestamp('1.1234', true), throwsFormatException),
    );
    test('DST不存在与歧义', () {
      expect(
        () => parseZonedDate('2026-03-08 02:30:00', 'America/New_York'),
        throwsFormatException,
      );
      expect(
        () => parseZonedDate('2026-11-01 01:30:00', 'America/New_York'),
        throwsFormatException,
      );
      final a = parseZonedDate(
            '2026-11-01 01:30:00',
            'America/New_York',
            ambiguity: 'earlier',
          ),
          b = parseZonedDate(
            '2026-11-01 01:30:00',
            'America/New_York',
            ambiguity: 'later',
          );
      expect(b.difference(a).inHours, 1);
    });
  });
}
