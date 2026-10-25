import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// SP_DEVINFO_DATA: DWORD, GUID[16], DWORD, ULONG_PTR. Its Win64 size is 32
/// bytes on both x64 and ARM64; a pointer-sized Reserved field is essential.
final class WindowsSerialDeviceInfo extends Struct {
  @Uint32()
  external int cbSize;
  @Array(16)
  external Array<Uint8> classGuid;
  @Uint32()
  external int devInst;
  @UintPtr()
  external int reserved;
}

/// Injectable Win32 boundary. Implementations return Win32 error codes for
/// queries/enumeration (zero means success), never an ANSI-decoded string.
abstract interface class WindowsSerialMetadataApi {
  Pointer<Uint8> allocate(int bytes);
  void free(Pointer pointer);
  int get lastError;
  Pointer<Void> openPresentDevices();
  int nextDevice(
    Pointer<Void> set,
    int index,
    Pointer<WindowsSerialDeviceInfo> info,
  );
  void closeDevices(Pointer<Void> set);
  Pointer<Void> openDeviceKey(
    Pointer<Void> set,
    Pointer<WindowsSerialDeviceInfo> info,
  );
  void closeKey(Pointer<Void> key);
  int portName(
    Pointer<Void> key,
    Pointer<Uint32> type,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Uint32> required,
  );
  int property(
    Pointer<Void> set,
    Pointer<WindowsSerialDeviceInfo> info,
    int property,
    Pointer<Uint32> type,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Uint32> required,
  );
  int formatMessage(int error, Pointer<Uint16> buffer, int codeUnits);
}

const _success = 0,
    _insufficientBuffer = 122,
    _moreData = 234,
    _noMoreItems = 259;
const _regSz = 1, _friendlyName = 12, _deviceDescription = 0;
const _maxPropertyBytes = 65536;

bool _invalidHandle(Pointer<Void> value) =>
    value.address == 0 || value.address == -1;

/// Decode only the returned UTF-16LE bytes. Registry REG_SZ values need not be
/// NUL-terminated; never scan beyond the reported native buffer length.
String decodeWindowsMetadataUtf16(Uint8List bytes) {
  if (bytes.length.isOdd) throw const FormatException('Odd UTF-16 byte count');
  final data = ByteData.sublistView(bytes);
  final units = <int>[];
  for (var i = 0; i < bytes.length; i += 2) {
    final unit = data.getUint16(i, Endian.little);
    if (unit == 0) break;
    units.add(unit);
  }
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        throw const FormatException('Unpaired UTF-16 surrogate');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Unpaired UTF-16 surrogate');
    }
  }
  return String.fromCharCodes(units);
}

typedef _PropertyQuery = int Function(
  Pointer<Uint32> type,
  Pointer<Uint8> data,
  int capacity,
  Pointer<Uint32> required,
);

String? _readString(WindowsSerialMetadataApi api, _PropertyQuery query) {
  final counters = api.allocate(8);
  try {
    final type = counters.cast<Uint32>(),
        required = (counters + 4).cast<Uint32>();
    var result = query(type, nullptr, 0, required);
    if (result != _success &&
        result != _insufficientBuffer &&
        result != _moreData) {
      return null;
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final capacity = required.value;
      if (capacity < 2 || capacity > _maxPropertyBytes || capacity.isOdd) {
        return null;
      }
      final buffer = api.allocate(capacity);
      try {
        required.value = capacity;
        result = query(type, buffer, capacity, required);
        if (result == _insufficientBuffer || result == _moreData) continue;
        if (result != _success ||
            type.value != _regSz ||
            required.value > capacity) {
          return null;
        }
        try {
          final value = decodeWindowsMetadataUtf16(
            buffer.asTypedList(required.value),
          ).trim();
          return value.isEmpty ? null : value;
        } on FormatException {
          return null;
        }
      } finally {
        api.free(buffer);
      }
    }
    return null;
  } finally {
    api.free(counters);
  }
}

/// Synchronous metadata lookup intended for the existing scan worker isolate.
/// No serial device is opened, configured, read, or written by this function.
/// Non-Windows callers get an empty map without loading any Windows DLL.
Map<String, String> readWindowsSerialDescriptions({
  WindowsSerialMetadataApi? api,
}) {
  if (api == null && !Platform.isWindows) return {};
  final native = api ?? _Win32SerialMetadataApi();
  final set = native.openPresentDevices();
  if (_invalidHandle(set)) {
    throw StateError('Windows device enumeration failed (${native.lastError})');
  }
  try {
    final memory = native.allocate(sizeOf<WindowsSerialDeviceInfo>());
    try {
      final info = memory.cast<WindowsSerialDeviceInfo>();
      final descriptions = <String, String>{};
      for (var index = 0; index < 4096; index++) {
        info.ref.cbSize = sizeOf<WindowsSerialDeviceInfo>();
        final result = native.nextDevice(set, index, info);
        if (result == _noMoreItems) return descriptions;
        if (result != _success) {
          throw StateError('Windows device enumeration failed ($result)');
        }
        final key = native.openDeviceKey(set, info);
        if (_invalidHandle(key)) continue;
        String? port;
        try {
          port = _readString(
            native,
            (type, data, capacity, required) =>
                native.portName(key, type, data, capacity, required),
          );
        } finally {
          native.closeKey(key);
        }
        if (port == null ||
            !RegExp(
              r'^COM[1-9][0-9]{0,7}$',
              caseSensitive: false,
            ).hasMatch(port)) {
          continue;
        }
        final name =
            _readString(
              native,
              (type, data, capacity, required) => native.property(
                set,
                info,
                _friendlyName,
                type,
                data,
                capacity,
                required,
              ),
            ) ??
            _readString(
              native,
              (type, data, capacity, required) => native.property(
                set,
                info,
                _deviceDescription,
                type,
                data,
                capacity,
                required,
              ),
            );
        // The COM number is the safe fallback; ANSI metadata is never decoded.
        final path = port.toUpperCase();
        descriptions[path] = name ?? path;
      }
      throw StateError('Windows device enumeration exceeded its bounded limit');
    } finally {
      native.free(memory);
    }
  } finally {
    native.closeDevices(set);
  }
}

/// Native OS errors use FormatMessageW, separately from RX/TX payload encoding.
/// Unknown error codes return null so callers can retain a numeric fallback.
String? windowsSystemMessage(int errorCode, {WindowsSerialMetadataApi? api}) {
  if (errorCode <= 0 ||
      errorCode > 0xffffffff ||
      (api == null && !Platform.isWindows)) {
    return null;
  }
  final native = api ?? _Win32SerialMetadataApi();
  for (var units = 256; units <= 32768; units *= 2) {
    final buffer = native.allocate(units * 2);
    try {
      final written = native.formatMessage(
        errorCode,
        buffer.cast<Uint16>(),
        units,
      );
      if (written > 0) {
        if (written > units) return null;
        try {
          final message = decodeWindowsMetadataUtf16(
            buffer.asTypedList(written * 2),
          ).trim();
          return message.isEmpty ? null : message;
        } on FormatException {
          return null;
        }
      }
      if (native.lastError != _insufficientBuffer) return null;
    } finally {
      native.free(buffer);
    }
  }
  return null;
}

final class _Win32SerialMetadataApi implements WindowsSerialMetadataApi {
  _Win32SerialMetadataApi() {
    // Resolve GetLastError before a checked Win32 call: first-time symbol lookup
    // after that call could overwrite the thread's native error code.
    _lastError();
  }

  late final _kernel = DynamicLibrary.open('kernel32.dll');
  late final _setup = DynamicLibrary.open('setupapi.dll');
  late final _registry = DynamicLibrary.open('advapi32.dll');
  late final _heap = _kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();
  late final _heapAlloc = _kernel
      .lookupFunction<
        Pointer<Uint8> Function(Pointer<Void>, Uint32, UintPtr),
        Pointer<Uint8> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  late final _heapFree = _kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  late final _lastError = _kernel
      .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
  late final _getClassDevs = _setup
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Uint16>,
          Pointer<Void>,
          Uint32,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Uint16>,
          Pointer<Void>,
          int,
        )
      >('SetupDiGetClassDevsW');
  late final _enumDevice = _setup
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<WindowsSerialDeviceInfo>),
        int Function(Pointer<Void>, int, Pointer<WindowsSerialDeviceInfo>)
      >('SetupDiEnumDeviceInfo');
  late final _destroySet = _setup
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('SetupDiDestroyDeviceInfoList');
  late final _openKey = _setup
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<WindowsSerialDeviceInfo>,
          Uint32,
          Uint32,
          Uint32,
          Uint32,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<WindowsSerialDeviceInfo>,
          int,
          int,
          int,
          int,
        )
      >('SetupDiOpenDevRegKey');
  late final _closeKey = _registry
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('RegCloseKey');
  late final _queryValue = _registry
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint16>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint16>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        )
      >('RegQueryValueExW');
  late final _getProperty = _setup
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<WindowsSerialDeviceInfo>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<WindowsSerialDeviceInfo>,
          int,
          Pointer<Uint32>,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
        )
      >('SetupDiGetDeviceRegistryPropertyW');
  late final _format = _kernel
      .lookupFunction<
        Uint32 Function(
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Uint16>,
          Uint32,
          Pointer<Void>,
        ),
        int Function(
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Uint16>,
          int,
          Pointer<Void>,
        )
      >('FormatMessageW');

  @override
  Pointer<Uint8> allocate(int bytes) {
    final pointer = _heapAlloc(_heap, 8 /* HEAP_ZERO_MEMORY */, bytes);
    if (pointer == nullptr) {
      throw StateError('Windows metadata buffer allocation failed');
    }
    return pointer;
  }

  @override
  void free(Pointer pointer) => _heapFree(_heap, 0, pointer.cast<Void>());
  @override
  int get lastError => _lastError();
  @override
  Pointer<Void> openPresentDevices() => _getClassDevs(
    nullptr,
    nullptr,
    nullptr,
    2 | 4 /* PRESENT | ALLCLASSES */,
  );
  @override
  int nextDevice(
    Pointer<Void> set,
    int index,
    Pointer<WindowsSerialDeviceInfo> info,
  ) => _enumDevice(set, index, info) != 0 ? 0 : _lastError();
  @override
  void closeDevices(Pointer<Void> set) {
    if (_destroySet(set) == 0) {
      throw StateError(
        'Windows metadata handle close failed (${_lastError()})',
      );
    }
  }

  @override
  Pointer<Void> openDeviceKey(
    Pointer<Void> set,
    Pointer<WindowsSerialDeviceInfo> info,
  ) => _openKey(
    set,
    info,
    1 /* GLOBAL */,
    0,
    1 /* DEV */,
    1 /* KEY_QUERY_VALUE */,
  );
  @override
  void closeKey(Pointer<Void> key) => _closeKey(key);
  @override
  int portName(
    Pointer<Void> key,
    Pointer<Uint32> type,
    Pointer<Uint8> buffer,
    int capacity,
    Pointer<Uint32> required,
  ) {
    final name = allocate(18).cast<Uint16>();
    try {
      name.asTypedList(9).setAll(0, 'PortName\u0000'.codeUnits);
      required.value = capacity;
      return _queryValue(key, name, nullptr, type, buffer, required);
    } finally {
      free(name);
    }
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
  ) => _getProperty(set, info, property, type, buffer, capacity, required) != 0
      ? 0
      : _lastError();
  @override
  int formatMessage(int error, Pointer<Uint16> buffer, int codeUnits) =>
      _format(
        0x1200 /* FROM_SYSTEM | IGNORE_INSERTS */,
        nullptr,
        error,
        0,
        buffer,
        codeUnits,
        nullptr,
      );
}
