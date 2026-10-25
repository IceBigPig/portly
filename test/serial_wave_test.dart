import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/bytes.dart';
import 'package:portly/core/models.dart';
import 'package:portly/core/wave.dart';
import 'package:portly/platform/transport.dart';
import 'package:portly/state/session.dart';

class FakeSerial implements Transport, SerialControl {
  final controller = StreamController<TransportEvent>.broadcast(sync: true);
  final sent = <List<int>>[];
  bool closed = false, failControl = false;
  Completer<void>? writeGate;
  @override
  SerialStatus serialStatus = const SerialStatus(
    dtr: true,
    rts: false,
    cts: true,
  );
  @override
  Stream<TransportEvent> get events => controller.stream;
  @override
  List<Peer> get peers => [];
  @override
  String get localEndpoint => '/dev/one';
  @override
  Future<void> send(Uint8List bytes, {String? target}) async {
    await writeGate?.future;
    if (closed) throw StateError('closed');
    sent.add(bytes.toList());
  }

  @override
  Future<void> disconnectPeer(String id) async {}
  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }

  @override
  Future<void> setControlLines({bool? dtr, bool? rts}) async {
    if (failControl) throw UnsupportedError('driver');
    serialStatus = SerialStatus(
      dtr: dtr ?? serialStatus.dtr,
      rts: rts ?? serialStatus.rts,
      cts: true,
    );
  }

  void receive(String text) => controller.add(
    TransportEvent(bytes: utf8.encode(text), endpoint: '/dev/one'),
  );
  void unplug() =>
      controller.add(TransportEvent(closed: true, message: 'removed'));
}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
    'Reconnect locks device identity, cancels old tasks and does not replay',
    () async {
      final transports = <FakeSerial>[];
      var ports = [PortInfo('/dev/one', 'USB', identity: 'usb:123')];
      final s = Session(
        config: ConnectionConfig(
          port: '/dev/one',
          autoReconnect: true,
          reconnectIntervalMs: 100,
        ),
        ports: () => ports,
        opener: (_) async {
          final t = FakeSerial();
          transports.add(t);
          return t;
        },
      );
      s.waveform.upsert(WaveMapping());
      await s.connect();
      transports.first.receive('12\n');
      await s.send(Draft(body: 'AA'));
      s.waitResponse = false;
      s.periodMs = 500;
      final task = s.execute([
        SavedCommand(
          name: 'loop',
          draft: Draft(body: 'BB'),
        ),
      ], repeat: true);
      await waitFor(() => transports.first.sent.length == 2);
      transports.first.unplug();
      ports = [PortInfo('/dev/other', 'Same name', identity: 'usb:other')];
      await Future<void>.delayed(const Duration(milliseconds: 140));
      expect(transports.length, 1);
      expect(s.running, false);
      expect(s.reconnecting, true);
      ports = [PortInfo('/dev/new', 'USB', identity: 'usb:123')];
      await waitFor(() => transports.length == 2 && s.connected);
      await task;
      expect(s.config.port, '/dev/new');
      expect(transports.last.sent, isEmpty);
      expect(s.waveform.channels.single.samples.last.value, isNull);
      await s.disconnect();
      s.dispose();
    },
  );
  test(
    'Manual disconnect cancels reconnect and ambiguous devices stop at limit',
    () async {
      final first = FakeSerial();
      var opens = 0;
      var ports = [PortInfo('/dev/one', 'USB', identity: 'unique')];
      final s = Session(
        config: ConnectionConfig(
          port: '/dev/one',
          autoReconnect: true,
          reconnectIntervalMs: 100,
          reconnectMaxAttempts: 2,
        ),
        ports: () => ports,
        opener: (_) async {
          opens++;
          return first;
        },
      );
      await s.connect();
      first.unplug();
      await waitFor(() => s.reconnecting);
      await s.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(opens, 1);
      expect(s.reconnecting, false);
      s.dispose();
      final t = FakeSerial();
      final second = Session(
        config: ConnectionConfig(
          port: '/dev/one',
          autoReconnect: true,
          reconnectIntervalMs: 100,
          reconnectMaxAttempts: 2,
        ),
        ports: () => ports,
        opener: (_) async => t,
      );
      await second.connect();
      t.unplug();
      ports = [
        PortInfo('/dev/a', 'USB', identity: 'unique'),
        PortInfo('/dev/b', 'USB', identity: 'unique'),
      ];
      await waitFor(() => second.reconnectAttempt == 2 && !second.reconnecting);
      expect(second.connected, false);
      expect(second.state, '重连次数已用完');
      second.dispose();
    },
  );
  test('No unique device identity requires explicit reopen, initial failures never auto start', () async {
    final t = FakeSerial();
    final s = Session(
      config: ConnectionConfig(port: '/dev/one', autoReconnect: true),
      ports: () => [PortInfo('/dev/one', 'USB')],
      opener: (_) async => t,
    );
    await s.connect();
    t.unplug();
    await waitFor(() => !s.reconnecting && !s.connected);
    expect(s.error, contains('唯一标识'));
    s.dispose();
    final failed = Session(
      config: ConnectionConfig(autoReconnect: true),
      opener: (_) async => throw StateError('open'),
    );
    await failed.connect();
    expect(failed.reconnecting, false);
    failed.dispose();
  });
  test(
    'Cancel during open closes late handle and never attaches a listener',
    () async {
      final opened = Completer<Transport>(), t = FakeSerial();
      var attempted = false;
      final s = Session(
        config: ConnectionConfig(),
        ports: () => [],
        opener: (_) {
          attempted = true;
          return opened.future;
        },
      );
      final connect = s.connect();
      await waitFor(() => attempted);
      await s.disconnect();
      opened.complete(t);
      await connect;
      expect(t.closed, true);
      expect(s.connected, false);
      s.dispose();
    },
  );
  test('DTR/RTS update only on success, hardware flow blocks RTS', () async {
    final t = FakeSerial();
    final s = Session(
      config: ConnectionConfig(flowControl: 'RTS/CTS'),
      opener: (_) async => t,
    );
    await s.connect();
    await s.setControlLines(dtr: false);
    expect(s.serialStatus.dtr, false);
    expect(s.config.dtr, false);
    await s.setControlLines(rts: true);
    expect(s.controlError, contains('硬件流控'));
    expect(s.config.rts, isNull);
    t.failControl = true;
    await s.setControlLines(dtr: true);
    expect(s.config.dtr, false);
    expect(s.controlError, contains('失败'));
    expect(s.serialStatus.dsr, isNull);
    await s.disconnect();
    s.dispose();
  });
  test('File send streams raw bytes in blocks, no CRC or encoding, cancellation stops next blocks', () async {
    final t = FakeSerial();
    final session = Session(config: ConnectionConfig(), opener: (_) async => t);
    await session.connect();
    await session.sendFile(
      Stream.value([0, 1, 255, 10, 13, 128, 9]),
      length: 7,
      name: 'raw.bin',
      chunkSize: 3,
      delayMs: 0,
    );
    expect(t.sent, [
      [0, 1, 255],
      [10, 13, 128],
      [9],
    ]);
    expect(session.fileSent, 7);
    final send = session.sendFile(
      Stream.value(List.generate(100, (i) => i)),
      length: 100,
      name: 'cancel.bin',
      chunkSize: 4,
      delayMs: 50,
    );
    await waitFor(() => session.fileSent == 4);
    session.stop();
    await send;
    expect(session.fileSent, 4);
    expect(session.running, false);
    await session.disconnect();
    session.dispose();
  });
  test('8 channels parse split text independently; hidden keeps collecting, disabled does not', () {
    final engine = WaveEngine();
    for (var i = 0; i < 8; i++) {
      engine.upsert(WaveMapping(name: 'C$i', field: i));
    }
    expect(() => engine.upsert(WaveMapping()), throwsStateError);
    engine.receive(LogEntry('RX', utf8.encode('1,2,3,4,'), endpoint: 'a'));
    expect(engine.channels.first.samples, isEmpty);
    engine.receive(LogEntry('RX', utf8.encode('5,6,7,8\n'), endpoint: 'a'));
    expect(engine.channels.map((c) => c.samples.single.value), [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]);
    engine.channels.first.mapping.visible = false;
    engine.channels[1].mapping.enabled = false;
    engine.receive(
      LogEntry('RX', utf8.encode('9,8,7,6,5,4,3,2\n'), endpoint: 'a'),
    );
    expect(engine.channels.first.samples.length, 2);
    expect(engine.channels[1].samples.length, 1);
    engine.receive(LogEntry('RX', utf8.encode('NaN,x\n'), endpoint: 'a'));
    expect(engine.channels.first.samples.last.value, isNull);
    expect(engine.channels.last.samples.last.error, contains('越界'));
    expect(engine.exportCsv(), contains('非有限数值'));
  });
  test('Fixed frames reassemble, apply endian/scale, preserve gaps and bounded original CSV', () {
    final engine = WaveEngine(sampleLimit: 3);
    engine.upsert(
      WaveMapping(
        mode: '固定字节偏移',
        frameLength: 4,
        offset: 2,
        type: 'uint16',
        order: 'LE',
        prefix: 'AA BB',
        scale: .1,
        bias: -1,
      ),
    );
    engine.receive(LogEntry('RX', [0, 0xAA, 0xBB, 0x64], endpoint: 'a'));
    engine.receive(LogEntry('RX', [0, 0xAA, 0xBB, 0xC8, 0], endpoint: 'a'));
    expect(engine.channels.single.samples.map((p) => p.value), [9, 19]);
    engine.receive(
      LogEntry('RX', [0xAA, 0xBB, 0], endpoint: 'a'),
      datagram: true,
    );
    expect(engine.channels.single.samples.last.value, isNull);
    engine.boundary();
    engine.receive(LogEntry('RX', [0xAA, 0xBB, 1, 0], endpoint: 'a'));
    expect(engine.channels.single.samples.length, 3);
    expect(engine.channels.single.dropped, 1);
    expect(engine.exportCsv().split('\n').length, 4);
  });
  test('Modbus needs matched station/function/request register range and uses complete frames', () {
    final engine = WaveEngine();
    engine.upsert(
      WaveMapping(
        mode: 'Modbus 寄存器',
        station: 1,
        function: 3,
        registerAddress: 0x11,
        scale: .1,
      ),
    );
    final response = withCrc([1, 3, 4, 0, 100, 0, 200]);
    final entry = LogEntry('RX', response, endpoint: 'serial');
    engine.receive(entry, rtuFrame: response);
    expect(engine.channels.single.samples.last.error, contains('请求'));
    engine.recordRequest(withCrc([1, 3, 0, 0x10, 0, 2]), 'serial');
    engine.receive(entry, rtuFrame: response);
    expect(engine.channels.single.samples.last.value, 20);
    engine.receive(
      LogEntry('RX', withCrc([2, 3, 2, 0, 50]), endpoint: 'serial'),
      rtuFrame: withCrc([2, 3, 2, 0, 50]),
    );
    expect(engine.channels.single.samples.length, 2);
    engine.boundary();
    engine.receive(entry, rtuFrame: response);
    expect(engine.channels.single.samples.last.value, isNull);
  });
  test(
    'Timeout creates one gap and no zero; valid values resume a new segment',
    () {
      final engine = WaveEngine();
      engine.upsert(WaveMapping(gapMs: 1000));
      final entry = LogEntry('RX', utf8.encode('12\n'));
      engine.receive(entry);
      expect(engine.expire(entry.time.add(const Duration(seconds: 2))), true);
      expect(engine.channels.single.samples.last.value, isNull);
      expect(engine.expire(entry.time.add(const Duration(seconds: 3))), false);
      engine.receive(LogEntry('RX', utf8.encode('13\n')));
      expect(engine.channels.single.samples.map((p) => p.value), [
        12,
        null,
        13,
      ]);
    },
  );
  test('Mappings and serial settings restore without connection, loops or cached samples', () {
    final s = Session(
      config: ConnectionConfig(
        baud: 12345,
        dtr: true,
        rts: false,
        autoReconnect: true,
      ),
    );
    s.waveform.upsert(
      WaveMapping(
        name: '温度',
        field: 1,
        unit: '°C',
        color: waveColors[2],
        scale: .1,
      ),
    );
    s.waveform.receive(LogEntry('RX', utf8.encode('0,123\n')));
    final restored = Session.fromJson(s.toJson());
    expect(restored.config.baud, 12345);
    expect(restored.config.autoReconnect, true);
    expect(restored.config.dtr, true);
    expect(restored.config.rts, false);
    expect(restored.waveform.channels.single.mapping.unit, '°C');
    expect(restored.waveform.channels.single.samples, isEmpty);
    expect(restored.connected, false);
    expect(restored.reconnecting, false);
    expect(restored.loop, false);
    s.dispose();
    restored.dispose();
  });
}
