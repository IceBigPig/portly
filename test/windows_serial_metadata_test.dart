import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/platform/windows_serial_metadata.dart';

Uint8List _utf16(String value, {bool terminate = true}) {
  final bytes = Uint8List((value.codeUnits.length + (terminate ? 1 : 0)) * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < value.codeUnits.length; i++) {
    data.setUint16(i * 2, value.codeUnits[i], Endian.little);
  }
  return bytes;
}

/// Real native memory keeps pointer/struct/buffer bounds tests meaningful on
/// both Windows and macOS, without depending on the ffi pub package.
class _Memory {
  late final Pointer<Uint8> Function(int) _allocate;
  late final void Function(Pointer) _free;
  final live = <int, int>{};
  int allocated = 0, freed = 0;

  _Memory() {
    if (Platform.isWindows) {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final heap = kernel
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'GetProcessHeap',
          )();
      final allocate = kernel
          .lookupFunction<
            Pointer<Uint8> Function(Pointer<Void>, Uint32, UintPtr),
            Pointer<Uint8> Function(Pointer<Void>, int, int)
          >('HeapAlloc');
      final free = kernel
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
            int Function(Pointer<Void>, int, Pointer<Void>)
          >('HeapFree');
      _allocate = (bytes) => allocate(heap, 8, bytes);
      _free = (pointer) => free(heap, 0, pointer.cast<Void>());
    } else {
      final library = DynamicLibrary.process();
      final allocate = library
          .lookupFunction<
            Pointer<Uint8> Function(UintPtr),
            Pointer<Uint8> Function(int)
          >('malloc');
      final free = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('free');
      _allocate = allocate;
      _free = (pointer) => free(pointer.cast<Void>());
    }
  }

  Pointer<Uint8> allocate(int bytes) {
    final pointer = _allocate(bytes);
    expect(pointer, isNot(nullptr));
    pointer.asTypedList(bytes).fillRange(0, bytes, 0);
    live[pointer.address] = bytes;
    allocated++;
    return pointer;
  }

  void free(Pointer pointer) {
    expect(
      live.remove(pointer.address),
      isNotNull,
      reason: 'free each allocation exactly once',
    );
    _free(pointer);
    freed++;
  }

  void expectClosed() {
    expect(live, isEmpty);
    expect(freed, allocated);
  }
}

class _Device {
  final String port;
  final String? friendly, description;
  const _Device(this.port, {this.friendly, this.description});
}

class _Api implements WindowsSerialMetadataApi {
  final memory = _Memory();
  final List<_Device> devices;
  final openedKeys = <int>[], closedKeys = <int>[];
  final reads = <String, int>{};
  final properties = <String, Uint8List>{};
  int closedSets = 0;
  bool failOpen = false, failKey = false, throwProperty = false;
  int? enumerationError;
  int valueType = 1;
  String? growProperty;
  bool terminate = true;
  String? message = '访问被拒绝。\r\n';
  @override
  int lastError = 0;
  _Api(this.devices);
  @override
  Pointer<Uint8> allocate(int bytes) => memory.allocate(bytes);
  @override
  void free(Pointer pointer) => memory.free(pointer);
  @override
  Pointer<Void> openPresentDevices() {
    lastError = 5;
    return Pointer.fromAddress(failOpen ? -1 : 1234);
  }

  @override
  int nextDevice(
    Pointer<Void> set,
    int index,
    Pointer<WindowsSerialDeviceInfo> info,
  ) {
    expect(info.ref.cbSize, sizeOf<WindowsSerialDeviceInfo>());
    if (enumerationError != null) return enumerationError!;
    if (index >= devices.length) return 259;
    info.ref.devInst = index;
    return 0;
  }

  @override
  void closeDevices(Pointer<Void> set) => closedSets++;
  @override
  Pointer<Void> openDeviceKey(
    Pointer<Void> set,
    Pointer<WindowsSerialDeviceInfo> info,
  ) {
    if (failKey) return Pointer.fromAddress(-1);
    final address = 10000 + info.ref.devInst;
    openedKeys.add(address);
    return Pointer.fromAddress(address);
  }

  @override
  void closeKey(Pointer<Void> key) => closedKeys.add(key.address);

  int query(
    String key,
    String? text,
    Pointer<Uint32> type,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Uint32> required,
  ) {
    final count = reads.update(key, (n) => n + 1, ifAbsent: () => 1);
    final bytes =
        properties[key] ??
        (text == null ? null : _utf16(text, terminate: terminate));
    if (bytes == null) return 2;
    if (buffer == nullptr) {
      // SetupDi may only populate RequiredSize when reporting insufficient
      // buffer; require a successful read before trusting PropertyRegDataType.
      required.value = growProperty == key ? 8 : bytes.length;
      return 122;
    }
    if (growProperty == key && count == 2) {
      required.value = bytes.length;
      return 234;
    }
    type.value = valueType;
    required.value = bytes.length;
    if (capacity < bytes.length) return 122;
    buffer.asTypedList(capacity).setAll(0, bytes);
    return 0;
  }

  @override
  int portName(
    Pointer<Void> key,
    Pointer<Uint32> type,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Uint32> required,
  ) {
    final index = key.address - 10000;
    return query(
      '$index.port',
      devices[index].port,
      type,
      buffer,
      capacity,
      required,
    );
  }

  @override
  int property(
    Pointer<Void> set,
    Pointer<WindowsSerialDeviceInfo> info,
    int property,
    Pointer<Uint32> type,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Uint32> required,
  ) {
    if (throwProperty) throw StateError('device removed');
    final index = info.ref.devInst;
    return query(
      '$index.$property',
      property == 12 ? devices[index].friendly : devices[index].description,
      type,
      buffer,
      capacity,
      required,
    );
  }

  @override
  int formatMessage(int error, Pointer<Uint16> buffer, int codeUnits) {
    if (message == null) {
      lastError = 317;
      return 0;
    }
    if (message!.codeUnits.length >= codeUnits) {
      lastError = 122;
      return 0;
    }
    buffer.asTypedList(codeUnits).setAll(0, message!.codeUnits);
    return message!.codeUnits.length;
  }

  void expectClosed() {
    memory.expectClosed();
    expect(closedKeys, openedKeys);
    expect(closedSets, failOpen ? 0 : 1);
  }
}

void main() {
  test('Win64 device structure is 32 bytes and preserves pointer width', () {
    expect(sizeOf<WindowsSerialDeviceInfo>(), sizeOf<IntPtr>() == 8 ? 32 : 28);
    final memory = _Memory();
    final pointer = memory.allocate(sizeOf<WindowsSerialDeviceInfo>());
    pointer.cast<WindowsSerialDeviceInfo>().ref.reserved = 0x123456789;
    if (sizeOf<IntPtr>() == 8) {
      expect(pointer.cast<WindowsSerialDeviceInfo>().ref.reserved, 0x123456789);
    }
    memory.free(pointer);
    memory.expectClosed();
  });
  test('UTF16 metadata preserves Chinese, Cyrillic, Japanese, supplementary characters and no-NUL values', () {
    for (final name in ['USB 串口设备（COM12）', 'Порт связи', '通信ポート 🔌 𠮷']) {
      expect(decodeWindowsMetadataUtf16(_utf16(name)), name);
      expect(decodeWindowsMetadataUtf16(_utf16(name, terminate: false)), name);
    }
    expect(decodeWindowsMetadataUtf16(_utf16('串口\u0000unused')), '串口');
  });
  test('Invalid UTF16 is rejected without guessing an ANSI codepage', () {
    expect(
      () => decodeWindowsMetadataUtf16(Uint8List.fromList([0x2d])),
      throwsFormatException,
    );
    expect(
      () => decodeWindowsMetadataUtf16(Uint8List.fromList([0x00, 0xd8])),
      throwsFormatException,
    );
    expect(
      () => decodeWindowsMetadataUtf16(Uint8List.fromList([0x00, 0xdc])),
      throwsFormatException,
    );
  });
  test(
    'Metadata query preserves long Unicode names and canonical COM paths',
    () {
      final name = '串口连接器 🔌 ${'设备' * 200}';
      final api = _Api([
        _Device('com123', friendly: name),
        const _Device('LPT1', friendly: '打印机'),
      ]);
      expect(readWindowsSerialDescriptions(api: api), {'COM123': name});
      api.expectClosed();
    },
  );
  test(
    'Missing friendly name uses Unicode device description then COM only',
    () {
      final api = _Api([
        const _Device('COM1', description: '蓝牙链接'),
        const _Device('COM2'),
        const _Device('COM3', friendly: '', description: '虚拟串口'),
      ]);
      expect(readWindowsSerialDescriptions(api: api), {
        'COM1': '蓝牙链接',
        'COM2': 'COM2',
        'COM3': '虚拟串口',
      });
      api.expectClosed();
    },
  );
  test('Size probing, non-terminated REG_SZ and property growth are bounded and freed', () {
    final api = _Api([_Device('COM5', friendly: '长串口名称' * 100)])
      ..terminate = false
      ..growProperty = '0.12';
    expect(readWindowsSerialDescriptions(api: api)['COM5'], '长串口名称' * 100);
    expect(api.reads['0.12'], 3);
    api.expectClosed();
  });
  test('Malformed, wrong-type and excessive properties do not corrupt other devices', () {
    final api = _Api([
      const _Device('COM1', description: '安全回退'),
      const _Device('COM2', friendly: '正常端口'),
    ]);
    api.properties['0.12'] = Uint8List.fromList([0x00, 0xd8, 0, 0]);
    expect(readWindowsSerialDescriptions(api: api), {
      'COM1': '安全回退',
      'COM2': '正常端口',
    });
    api.expectClosed();
    final excessive = _Api([_Device('COM1', friendly: '名' * 40000)]);
    expect(readWindowsSerialDescriptions(api: excessive), {'COM1': 'COM1'});
    excessive.expectClosed();
    final wrongType = _Api([const _Device('COM1', friendly: 'not a string')])
      ..valueType = 7;
    expect(readWindowsSerialDescriptions(api: wrongType), isEmpty);
    wrongType.expectClosed();
  });
  test('Enumeration failure and field exceptions close handles and every native allocation', () {
    final enumeration = _Api([])..enumerationError = 5;
    expect(
      () => readWindowsSerialDescriptions(api: enumeration),
      throwsStateError,
    );
    enumeration.expectClosed();
    final property = _Api([const _Device('COM7', friendly: '设备')])
      ..throwProperty = true;
    expect(
      () => readWindowsSerialDescriptions(api: property),
      throwsStateError,
    );
    property.expectClosed();
    final open = _Api([])..failOpen = true;
    expect(() => readWindowsSerialDescriptions(api: open), throwsStateError);
    open.expectClosed();
  });
  test('Inaccessible device keys do not abort enumeration and no invalid handle is closed', () {
    final api = _Api([const _Device('COM1')])..failKey = true;
    expect(readWindowsSerialDescriptions(api: api), isEmpty);
    api.expectClosed();
  });
  test('Windows system messages use UTF16 and unknown codes keep numeric fallback available', () {
    final api = _Api([]);
    expect(windowsSystemMessage(5, api: api), '访问被拒绝。');
    api.memory.expectClosed();
    api.message = null;
    expect(windowsSystemMessage(999999, api: api), isNull);
    api.memory.expectClosed();
    expect(windowsSystemMessage(-1, api: api), isNull);
    expect(windowsSystemMessage(0, api: api), isNull);
  });
  test('System message buffer growth remains bounded and frees unsuccessful buffers', () {
    final api = _Api([])..message = '错误说明' * 200;
    expect(windowsSystemMessage(5, api: api), '错误说明' * 200);
    expect(api.memory.allocated, greaterThan(1));
    api.memory.expectClosed();
    api.message = '错' * 40000;
    expect(windowsSystemMessage(5, api: api), isNull);
    api.memory.expectClosed();
  });
  test('Non-Windows production calls do not load any Windows DLL', () {
    if (!Platform.isWindows) {
      expect(readWindowsSerialDescriptions(), isEmpty);
      expect(windowsSystemMessage(5), isNull);
    }
  });
  test('Real Windows Unicode API smoke enumerates metadata without opening a serial port', () {
    final ports = readWindowsSerialDescriptions();
    expect(
      ports.keys.every((path) => RegExp(r'^COM[1-9][0-9]*$').hasMatch(path)),
      isTrue,
    );
    expect(windowsSystemMessage(5), isNotEmpty);
    expect(windowsSystemMessage(5), isNot(contains('\ufffd')));
  }, skip: !Platform.isWindows);
}
