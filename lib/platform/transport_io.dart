import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../core/models.dart';
import 'transport_base.dart';

List<PortInfo> enumeratePorts() => SerialPort.availablePorts.map((path) {
  final p = SerialPort(path);
  try {
    final serial = p.serialNumber?.trim() ?? '';
    final bluetooth = p.macAddress?.trim() ?? '';
    final identity = serial.isNotEmpty
        ? 'usb:${p.vendorId}:${p.productId}:$serial'
        : bluetooth.isNotEmpty
        ? 'bt:$bluetooth'
        : '';
    return PortInfo(path, p.description ?? path, identity: identity);
  } finally {
    p.dispose();
  }
}).toList();

Future<List<PortInfo>> enumeratePortsAsync() => Isolate.run(enumeratePorts);

Future<Transport> openTransport(ConnectionConfig config) async {
  final transport = IoTransport(config.copy());
  try {
    await transport.open();
    return transport;
  } catch (_) {
    await transport.close();
    rethrow;
  }
}

class IoTransport implements Transport, SerialControl, DatagramTargetResolver {
  final ConnectionConfig config;
  final _events = StreamController<TransportEvent>.broadcast();
  final _clients = <String, Socket>{};
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Socket? _socket;
  ServerSocket? _server;
  RawDatagramSocket? _udp;
  SerialPort? _serial;
  Timer? _serialReadTimer;
  bool _closed = false;
  Timer? _serialMonitor;
  SerialStatus _serialStatus = const SerialStatus();
  @override
  SerialStatus get serialStatus => _serialStatus;
  @override
  String localEndpoint = '';
  IoTransport(this.config);
  @override
  Stream<TransportEvent> get events => _events.stream;
  @override
  List<Peer> get peers => _clients.entries
      .map(
        (e) => Peer(
          e.key,
          '${e.value.remoteAddress.address}:${e.value.remotePort}',
        ),
      )
      .toList();
  void emit(TransportEvent event) {
    if (!_closed) _events.add(event);
  }

  void error(Object error) =>
      emit(TransportEvent(message: error.toString(), closed: true));
  void checkPort(int port) {
    if (port < 1 || port > 65535) throw const FormatException('端口必须为 1–65535');
  }

  Future<void> open() async {
    switch (config.kind) {
      case ConnectionKind.serial:
        if (config.port.isEmpty) throw const FormatException('请选择串口设备');
        if (config.autoReconnect &&
            (config.reconnectIntervalMs < 100 ||
                config.reconnectIntervalMs > 3600000 ||
                config.reconnectMaxAttempts < 1 ||
                config.reconnectMaxAttempts > 1000)) {
          throw const FormatException('重连间隔为 100–3600000 ms，次数为 1–1000');
        }

        if (config.baud < 1 || config.baud > 2147483647) {
          throw const FormatException('波特率必须为 1–2147483647 的整数');
        }
        final port = SerialPort(config.port);
        _serial = port;
        if (!port.openReadWrite()) {
          throw StateError('无法打开 ${config.port}：${SerialPort.lastError}');
        }
        final settings = SerialPortConfig()
          ..baudRate = config.baud
          ..bits = config.dataBits
          ..stopBits = config.stopBits
          ..parity = {
            'None': SerialPortParity.none,
            'Even': SerialPortParity.even,
            'Odd': SerialPortParity.odd,
          }[config.parity]!;
        settings.setFlowControl(
          config.flowControl == 'RTS/CTS'
              ? SerialPortFlowControl.rtsCts
              : config.flowControl == 'XON/XOFF'
              ? SerialPortFlowControl.xonXoff
              : SerialPortFlowControl.none,
        );
        if (config.dtr != null) {
          settings.dtr = config.dtr! ? SerialPortDtr.on : SerialPortDtr.off;
        }
        if (config.rts != null && config.flowControl != 'RTS/CTS') {
          settings.rts = config.rts! ? SerialPortRts.on : SerialPortRts.off;
        }
        // SerialPort owns an assigned config and disposes it on replacement/close.
        port.config = settings;
        _serialStatus = SerialStatus(
          dtr: settings.dtr == 0
              ? false
              : settings.dtr == 1
              ? true
              : null,
          rts: settings.rts == 0
              ? false
              : settings.rts == 1
              ? true
              : null,
        );
        localEndpoint = config.port;
        // Keep all access to this native handle on one isolate. The package
        // reader kills an isolate that still shares the port pointer on close.
        _serialReadTimer = Timer.periodic(const Duration(milliseconds: 16), (
          _,
        ) {
          if (_closed) return;
          try {
            final available = port.bytesAvailable;
            if (available < 0) {
              throw StateError('串口读取失败：${SerialPort.lastError}');
            }
            if (available > 0) {
              emit(
                TransportEvent(
                  bytes: port.read(available.clamp(1, 65536)),
                  endpoint: config.port,
                ),
              );
            }
          } catch (e) {
            _serialReadTimer?.cancel();
            error(e);
          }
        });
        _pollSerial();
        _serialMonitor = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => _pollSerial(),
        );
      case ConnectionKind.tcpClient:
        checkPort(config.networkPort);
        if (config.host.trim().isEmpty) throw const FormatException('请输入服务器地址');
        _socket = await Socket.connect(
          config.host.trim(),
          config.networkPort,
          timeout: Duration(milliseconds: config.timeoutMs),
        );
        localEndpoint = '${_socket!.address.address}:${_socket!.port}';
        _subscriptions.add(
          _socket!.listen(
            (data) => emit(
              TransportEvent(
                bytes: data,
                endpoint:
                    '${_socket!.remoteAddress.address}:${_socket!.remotePort}',
              ),
            ),
            onError: error,
            onDone: () =>
                emit(TransportEvent(message: '远端已关闭连接', closed: true)),
          ),
        );
      case ConnectionKind.tcpServer:
        checkPort(config.networkPort);
        _server = await ServerSocket.bind(
          config.bindAddress,
          config.networkPort,
          shared: false,
        );
        localEndpoint = '${_server!.address.address}:${_server!.port}';
        _subscriptions.add(
          _server!.listen((client) {
            if (_closed) {
              client.destroy();
              return;
            }
            final id = newId();
            _clients[id] = client;
            final endpoint =
                '${client.remoteAddress.address}:${client.remotePort}';
            emit(TransportEvent(message: '客户端接入：$endpoint'));
            _subscriptions.add(
              client.listen(
                (data) => emit(TransportEvent(bytes: data, endpoint: id)),
                onError: (Object e) =>
                    emit(TransportEvent(message: '$endpoint：$e')),
                onDone: () {
                  _clients.remove(id);
                  emit(TransportEvent(message: '客户端离线：$endpoint'));
                },
              ),
            );
          }, onError: error),
        );
      case ConnectionKind.udp:
        checkPort(config.networkPort);
        _udp = await RawDatagramSocket.bind(
          config.bindAddress,
          config.networkPort,
        );
        _udp!.broadcastEnabled = config.broadcast;
        localEndpoint = '${_udp!.address.address}:${_udp!.port}';
        _subscriptions.add(
          _udp!.listen((event) {
            if (event == RawSocketEvent.read) {
              Datagram? data;
              while ((data = _udp!.receive()) != null) {
                emit(
                  TransportEvent(
                    bytes: data!.data,
                    endpoint: '${data.address.address}:${data.port}',
                  ),
                );
              }
            } else if (event == RawSocketEvent.closed) {
              emit(TransportEvent(message: 'UDP 已关闭', closed: true));
            }
          }, onError: error),
        );
    }
  }

  void _pollSerial() {
    if (_closed || _serial == null) return;
    try {
      if (!SerialPort.availablePorts.contains(config.port)) {
        emit(TransportEvent(message: '串口设备已移除', closed: true));
        _serialMonitor?.cancel();
        return;
      }
    } catch (_) {
      /* Enumeration errors are not evidence of removal. */
    }
    bool? cts, dsr;
    String issue = '';
    try {
      final signals = _serial!.signals;
      cts = signals & SerialPortSignal.cts != 0;
      dsr = signals & SerialPortSignal.dsr != 0;
    } catch (_) {
      issue = 'CTS / DSR 不可用';
    }
    _serialStatus = SerialStatus(
      dtr: _serialStatus.dtr,
      rts: _serialStatus.rts,
      cts: cts,
      dsr: dsr,
      error: issue,
    );
    emit(TransportEvent(serialStatus: _serialStatus));
  }

  @override
  Future<void> setControlLines({bool? dtr, bool? rts}) async {
    if (_closed || _serial == null) throw StateError('串口未连接');
    if (rts != null && config.flowControl == 'RTS/CTS') {
      throw StateError('RTS 由硬件流控管理');
    }
    final settings = SerialPortConfig();
    if (dtr != null) settings.dtr = dtr ? SerialPortDtr.on : SerialPortDtr.off;
    if (rts != null) settings.rts = rts ? SerialPortRts.on : SerialPortRts.off;
    _serial!.config = settings;
    _serialStatus = SerialStatus(
      dtr: dtr ?? _serialStatus.dtr,
      rts: rts ?? _serialStatus.rts,
      cts: _serialStatus.cts,
      dsr: _serialStatus.dsr,
      error: _serialStatus.error,
    );
    emit(TransportEvent(serialStatus: _serialStatus));
  }

  @override
  Future<String> resolveDatagramTarget(String target) async {
    if (_closed || _udp == null) throw StateError('UDP 连接未就绪');
    final split = target.lastIndexOf(':');
    if (split < 1) throw const FormatException('请设置 UDP 目标地址与端口');
    var host = target.substring(0, split);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final port = int.tryParse(target.substring(split + 1));
    if (port == null) throw const FormatException('UDP 目标端口无效');
    checkPort(port);
    final family = _udp!.address.type;
    final numeric = InternetAddress.tryParse(host);
    final addresses = numeric != null
        ? [numeric]
        : await InternetAddress.lookup(host, type: family);
    if (_closed || _udp == null) throw StateError('UDP 连接已关闭');
    final address = addresses.where((a) => a.type == family).firstOrNull;
    if (address == null) throw const FormatException('UDP 目标地址与本地绑定的 IP 版本不一致');
    return '${address.address}:$port';
  }

  @override
  Future<void> send(Uint8List bytes, {String? target}) async {
    if (_closed) throw StateError('连接已关闭');
    switch (config.kind) {
      case ConnectionKind.serial:
        var offset = 0;
        while (offset < bytes.length) {
          if (_closed) throw StateError('连接已关闭');
          final count = _serial!.write(
            Uint8List.sublistView(bytes, offset),
            timeout: 10,
          );
          if (count <= 0) throw StateError('串口写入失败：${SerialPort.lastError}');
          offset += count;
          if (offset < bytes.length) await Future<void>.delayed(Duration.zero);
        }
      case ConnectionKind.tcpClient:
        _socket!.add(bytes);
        await _socket!.flush();
      case ConnectionKind.tcpServer:
        final client = _clients[target];
        if (client == null) throw StateError('所选客户端已失效');
        client.add(bytes);
        await client.flush();
      case ConnectionKind.udp:
        final resolved = await resolveDatagramTarget(target ?? '');
        final split = resolved.lastIndexOf(':');
        final address = InternetAddress(resolved.substring(0, split)),
            port = int.parse(resolved.substring(split + 1));
        if (_closed) throw StateError('连接已关闭');
        if (_udp!.send(bytes, address, port) != bytes.length) {
          throw StateError('UDP 未能提交完整数据报');
        }
    }
  }

  @override
  Future<void> disconnectPeer(String id) async {
    _clients.remove(id)?.destroy();
    emit(TransportEvent(message: '已断开客户端'));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _serialMonitor?.cancel();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _serialReadTimer?.cancel();
    if (_serial != null) {
      _serial!.close();
      _serial!.dispose();
    }
    _socket?.destroy();
    await _server?.close();
    for (final client in _clients.values) {
      client.destroy();
    }
    _clients.clear();
    _udp?.close();
    await _events.close();
  }
}
