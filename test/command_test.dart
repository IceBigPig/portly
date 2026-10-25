import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/bytes.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/transport.dart';
import 'package:portly/state/session.dart';

class CommandTransport implements Transport {
  final controller = StreamController<TransportEvent>.broadcast(sync: true);
  final writes = <List<int>>[];
  void Function(List<int>)? onWrite;
  Completer<void>? gate;
  bool closed = false;
  @override
  Stream<TransportEvent> get events => controller.stream;
  @override
  List<Peer> get peers => [
    Peer('one', '127.0.0.1:1001'),
    Peer('two', '127.0.0.1:1002'),
  ];
  @override
  String get localEndpoint => 'test';
  @override
  Future<void> send(Uint8List bytes, {String? target}) async {
    await gate?.future;
    if (closed) throw StateError('closed');
    writes.add(bytes.toList());
    onWrite?.call(bytes);
  }

  void receive(List<int> bytes, {String endpoint = ''}) =>
      controller.add(TransportEvent(bytes: bytes, endpoint: endpoint));
  @override
  Future<void> disconnectPeer(String id) async {}
  @override
  Future<void> close() async {
    closed = true;
    await controller.close();
  }
}

class ResolvedCommandTransport extends CommandTransport
    implements DatagramTargetResolver {
  int resolves = 0;
  final targets = <String?>[];
  @override
  Future<String> resolveDatagramTarget(String target) async {
    resolves++;
    return '127.0.0.1:1001';
  }

  @override
  Future<void> send(Uint8List bytes, {String? target}) async {
    targets.add(target);
    await super.send(bytes, target: target);
  }
}

Future<void> until(bool Function() predicate) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<Session> sessionFor(
  CommandTransport transport, {
  ConnectionKind kind = ConnectionKind.tcpClient,
}) async {
  final session = Session(
    config: ConnectionConfig(
      kind: kind,
      host: '127.0.0.1',
      targetHost: '127.0.0.1',
      targetPort: 1001,
    ),
    opener: (_) async => transport,
  );
  await session.connect();
  return session;
}

SavedCommand textCommand(
  String name, {
  String expected = 'OK',
  int timeout = 1000,
}) => SavedCommand(
  name: name,
  draft: Draft(body: 'GO', text: true),
  timeoutMs: timeout,
  stepDelayMs: 10,
  responseRule: ResponseRule(
    kind: 'text_exact',
    framing: 'delimiter',
    text: expected,
    delimiterHex: '0D 0A',
  ),
);

void main() {
  test(
    'Typed parameters resolve defaults, bounds, endian and CRC exactly once',
    () {
      final command = SavedCommand(
        name: 'Read',
        draft: Draft(body: '{{unit}} 03 {{address}} {{count}}', crc: true),
        parameters: const [
          CommandParameter(
            name: 'unit',
            type: 'uint8',
            defaultValue: '1',
            min: 1,
            max: 247,
          ),
          CommandParameter(name: 'address', defaultValue: '0x10'),
          CommandParameter(name: 'count', defaultValue: '2', min: 1, max: 125),
        ],
      );
      command.validate();
      expect(command.buildBytes(), withCrc([1, 3, 0, 16, 0, 2]));
      expect(
        command.buildBytes({'unit': '2', 'count': '3'}),
        withCrc([2, 3, 0, 16, 0, 3]),
      );
      expect(command.draft.body, '{{unit}} 03 {{address}} {{count}}');
      expect(() => command.buildBytes({'count': '126'}), throwsFormatException);
      expect(() => command.buildBytes({'typo': '2'}), throwsFormatException);
      final signed = SavedCommand(
        name: 'signed',
        draft: Draft(body: '{{value}}'),
        parameters: const [
          CommandParameter(
            name: 'value',
            type: 'int16',
            defaultValue: '-2',
            byteOrder: 'LE',
          ),
        ],
      );
      expect(signed.buildBytes(), [254, 255]);
    },
  );

  test('Text and HEX parameters preserve explicit encoding and suffix', () {
    final command = SavedCommand(
      name: 'text',
      draft: Draft(
        body: 'SET {{number}} {{label}}',
        text: true,
        suffix: '0D 0A',
      ),
      parameters: const [
        CommandParameter(name: 'number', type: 'uint8', defaultValue: '0x10'),
        CommandParameter(name: 'label', type: 'text', defaultValue: '温度'),
      ],
    );
    expect(command.buildBytes(), utf8.encode('SET 16 温度\r\n'));
    final bytes = SavedCommand(
      name: 'bytes',
      draft: Draft(body: 'AA {{payload}} {{label}}'),
      parameters: const [
        CommandParameter(name: 'payload', type: 'hex', defaultValue: '00 FF'),
        CommandParameter(name: 'label', type: 'text', defaultValue: 'A'),
      ],
    );
    expect(bytes.buildBytes(), [170, 0, 255, 65]);
    expect(() => command.buildBytes({'number': '256'}), throwsFormatException);
  });

  test('Libraries roundtrip parameters and spec Modbus rule; invalid advanced fields reject', () {
    final command = SavedCommand(
      name: 'read',
      draft: Draft(body: '{{unit}} 03 00 00 00 02', crc: true),
      parameters: const [
        CommandParameter(name: 'unit', type: 'uint8', defaultValue: '1'),
      ],
      responseRule: const ResponseRule(
        unitId: 1,
        functionCode: 3,
        registerCount: 2,
      ),
      tags: ['读取'],
    );
    final restored = SavedCommand.fromJson(command.toJson());
    expect(restored.toJson(), command.toJson());
    expect(restored.buildBytes(), withCrc([1, 3, 0, 0, 0, 2]));
    expect(
      () => SavedCommand.fromJson({...command.toJson(), 'script': 'run()'}),
      throwsFormatException,
    );
    expect(
      () => ResponseRule.fromJson({'type': 'regex', 'text': '.*'}),
      throwsFormatException,
    );
    expect(
      () => ResponseRule.fromJson({'type': 'modbus_rtu', 'action': 'retry'}),
      throwsFormatException,
    );
    expect(
      () => CommandParameter.fromJson({
        'name': 'x',
        'type': 'uint8',
        'defaultValue': '256',
      }),
      throwsFormatException,
    );
    expect(
      () => SavedCommand(
        name: 'bad',
        draft: Draft(body: '{{missing}}'),
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => SavedCommand(
        name: 'bad',
        draft: Draft(body: '{{x'),
        parameters: const [CommandParameter(name: 'x')],
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => SavedCommand(
        name: 'bad',
        draft: Draft(body: '{{x}}'),
        parameters: const [
          CommandParameter(name: 'x'),
          CommandParameter(name: 'x'),
        ],
      ).validate(),
      throwsFormatException,
    );
  });

  test('Delimited text handles fragmented UTF8, coalesced unsolicited lines, and strict decoding', () {
    final matcher = ResponseMatcher(
      const ResponseRule(
        kind: 'text_exact',
        framing: 'delimiter',
        text: '温度正常',
        delimiterHex: '0D 0A',
      ),
      [1],
    );
    final bytes = utf8.encode('温度正常\r\n');
    expect(
      matcher.add([...utf8.encode('noise\r\n'), ...bytes.take(2)]),
      isNull,
    );
    expect(matcher.add(bytes.sublist(2, bytes.length - 1)), isNull);
    expect(
      matcher.add([10, ...utf8.encode('next\r\n')])!.bytes,
      utf8.encode('温度正常'),
    );
    final bad = ResponseMatcher(
      const ResponseRule(
        kind: 'text_contains',
        framing: 'delimiter',
        text: 'OK',
      ),
      [1],
    );
    expect(bad.add([255, 79, 75, 10]), isNull);
    expect(bad.add(utf8.encode('result:OK\n')), isNotNull);
  });

  test(
    'Fixed frames, prefixes and masks cannot match across message boundaries',
    () {
      final exact = ResponseMatcher(
        const ResponseRule(
          kind: 'bytes_exact',
          framing: 'fixed',
          length: 2,
          patternHex: 'AA BB',
        ),
        [1],
      );
      expect(exact.add([0, 170]), isNull);
      expect(
        exact.add([187, 0]),
        isNull,
      ); // AA and BB belonged to separate frames.
      expect(exact.add([170]), isNull);
      expect(exact.add([187])!.bytes, [170, 187]);
      final masked = ResponseMatcher(
        const ResponseRule(
          kind: 'bytes_masked',
          framing: 'fixed',
          length: 4,
          offset: 1,
          patternHex: 'A0 05',
          maskHex: 'F0 FF',
        ),
        [1],
      );
      expect(masked.add([0, 171, 5, 1]), isNotNull);
      final prefix = ResponseMatcher(
        const ResponseRule(
          kind: 'bytes_prefix',
          framing: 'delimiter',
          delimiterHex: '0A',
          patternHex: 'AA BB',
        ),
        [1],
      );
      expect(prefix.add([170, 187, 204, 10]), isNotNull);
      expect(
        () => ResponseRule(
          kind: 'bytes_masked',
          framing: 'fixed',
          length: 2,
          patternHex: 'AA',
          maskHex: '00',
        ).validate(),
        throwsFormatException,
      );
    },
  );

  test('UDP boundaries are retained and bounded stream tails reject excessive data', () {
    final matcher = ResponseMatcher(
      const ResponseRule(
        kind: 'bytes_exact',
        framing: 'datagram',
        patternHex: '01 02',
      ),
      [1],
    );
    expect(matcher.add([1], datagram: true), isNull);
    expect(matcher.add([2], datagram: true), isNull);
    expect(matcher.add([1, 2], datagram: true), isNotNull);
    expect(() => matcher.add([1, 2]), throwsFormatException);
    final stream = ResponseMatcher(
      const ResponseRule(kind: 'text_exact', framing: 'delimiter', text: 'OK'),
      [1],
    );
    stream.add(List.filled(65536, 1));
    expect(() => stream.add([1]), throwsFormatException);
  });

  test('Modbus matching checks CRC, unit, function, quantity, write echo and exceptions', () {
    final request = withCrc([1, 3, 0, 0, 0, 2]);
    final matcher = ResponseMatcher(
      const ResponseRule(unitId: 1, functionCode: 3, registerCount: 2),
      request,
    );
    expect(matcher.add(withCrc([2, 3, 4, 0, 1, 0, 2])), isNull);
    expect(matcher.add(withCrc([1, 3, 2, 0, 1])), isNull);
    final response = withCrc([1, 3, 4, 0, 1, 0, 2]);
    expect(matcher.add(response.sublist(0, 4)), isNull);
    expect(matcher.add(response.sublist(4))!.bytes, response);
    final exception = ResponseMatcher(const ResponseRule(), request);
    expect(exception.add(withCrc([1, 0x83, 2]))!.exceptionCode, 2);
    final write = ResponseMatcher(
      const ResponseRule(),
      withCrc([1, 6, 0, 1, 0, 2]),
    );
    expect(write.add(withCrc([1, 6, 0, 2, 0, 2])), isNull);
    expect(write.add(withCrc([1, 6, 0, 1, 0, 2])), isNotNull);
    expect(
      () => ResponseMatcher(const ResponseRule(unitId: 3), request),
      throwsFormatException,
    );
  });

  test('Explicit text rule waits even with automatic RTU disabled and ignores unsolicited old bytes', () async {
    final transport = CommandTransport();
    final session = await sessionFor(transport)
      ..waitResponse = false;
    transport.receive(utf8.encode('OK\r\n'));
    final run = session.execute([textCommand('one')]);
    await until(() => transport.writes.isNotEmpty);
    expect(session.running, true);
    transport.receive(utf8.encode('noise\r\nO'));
    expect(session.running, true);
    transport.receive(utf8.encode('K\r\n'));
    await run;
    expect(session.error, isEmpty);
    expect(session.task, '执行完成');
    await session.disconnect();
    session.dispose();
  });

  test(
    'Rules, parameters and later steps freeze before the first byte is written',
    () async {
      final transport = CommandTransport();
      final session = await sessionFor(transport);
      final values = {'value': '2'};
      final second = SavedCommand(
        name: 'two',
        draft: Draft(body: '{{value}}'),
        parameters: const [
          CommandParameter(name: 'value', type: 'uint8', defaultValue: '1'),
        ],
        responseRule: const ResponseRule(kind: 'none'),
      );
      final first = textCommand('one');
      final run = session.execute(
        [first, second],
        parameterValues: {second.id: values},
      );
      await until(() => transport.writes.length == 1);
      values['value'] = '3';
      second.draft.body = 'FF';
      first.responseRule = const ResponseRule(kind: 'none');
      session.waitResponse = false;
      expect(session.running, true);
      transport.receive(utf8.encode('OK\r\n'));
      await run;
      expect(transport.writes, [
        utf8.encode('GO'),
        [2],
      ]);
      expect(session.error, isEmpty);
      await session.disconnect();
      session.dispose();
    },
  );

  test('TCP server response source is isolated and valid exceptions stop later writes', () async {
    final transport = CommandTransport();
    final session = await sessionFor(transport, kind: ConnectionKind.tcpServer)
      ..selectedPeer = 'one';
    final run = session.execute([
      SavedCommand(
        name: 'read',
        draft: Draft(body: '01 03 00 00 00 02', crc: true),
        stepDelayMs: 10,
      ),
      SavedCommand(
        name: 'later',
        draft: Draft(body: 'AA'),
      ),
    ]);
    await until(() => transport.writes.isNotEmpty);
    transport.receive(withCrc([1, 3, 4, 0, 1, 0, 2]), endpoint: 'two');
    expect(session.running, true);
    transport.receive(withCrc([1, 0x83, 2]), endpoint: 'one');
    await run;
    expect(transport.writes.length, 1);
    expect(session.error, contains('设备异常：2'));
    await session.disconnect();
    session.dispose();
  });

  test(
    'UDP rules do not combine packets or advance on another source',
    () async {
      final transport = CommandTransport();
      final session = await sessionFor(transport, kind: ConnectionKind.udp);
      final command = SavedCommand(
        name: 'udp',
        draft: Draft(body: 'AA'),
        responseRule: const ResponseRule(
          kind: 'bytes_exact',
          framing: 'datagram',
          patternHex: '01 02',
        ),
      );
      final run = session.execute([command]);
      await until(() => transport.writes.isNotEmpty);
      transport.receive([1], endpoint: '127.0.0.1:1001');
      transport.receive([2], endpoint: '127.0.0.1:1001');
      transport.receive([1, 2], endpoint: '127.0.0.1:1002');
      expect(session.running, true);
      transport.receive([1, 2], endpoint: '127.0.0.1:1001');
      await run;
      expect(session.error, isEmpty);
      await session.disconnect();
      session.dispose();
    },
  );

  test('Timeout and stop are prompt, with no writes from subsequent commands or replay', () async {
    final transport = CommandTransport();
    final session = await sessionFor(transport);
    final timeout = session.execute([
      textCommand('timeout', timeout: 20),
      textCommand('later'),
    ]);
    await timeout;
    expect(session.error, contains('超时'));
    expect(transport.writes.length, 1);
    final stop = session.execute([textCommand('stop'), textCommand('later')]);
    await until(() => transport.writes.length == 2);
    final watch = Stopwatch()..start();
    session.stop();
    await stop;
    expect(watch.elapsedMilliseconds, lessThan(250));
    transport.receive(utf8.encode('OK\r\n'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(transport.writes.length, 2);
    await session.disconnect();
    session.dispose();
  });

  test(
    'Automatic RTU compatibility and explicit send-only broadcast never wait',
    () async {
      final transport = CommandTransport();
      final session = await sessionFor(transport);
      transport.onWrite = (_) => transport.receive(withCrc([1, 3, 2, 0, 5]));
      await session.execute([
        SavedCommand(
          name: 'old',
          draft: Draft(body: '01 03 00 00 00 01', crc: true),
        ),
      ]);
      expect(session.error, isEmpty);
      transport.onWrite = null;
      await session.execute([
        SavedCommand(
          name: 'broadcast',
          draft: Draft(body: '00 06 00 01 00 02', crc: true),
          responseRule: const ResponseRule(),
        ),
      ]);
      await session.execute([
        SavedCommand(
          name: 'send-only',
          draft: Draft(body: '01 03 00 00 00 01', crc: true),
          responseRule: const ResponseRule(kind: 'none'),
        ),
      ]);
      expect(session.task, '字节已提交');
      expect(session.error, isEmpty);
      await session.disconnect();
      session.dispose();
    },
  );
  test('Template expansion is bounded and byte-at-a-time delimiters retain their tails', () {
    final template = List.filled(400, '{{payload}}').join();
    expect(
      () => substituteParameters(
        template,
        [
          CommandParameter(
            name: 'payload',
            type: 'text',
            defaultValue: 'x' * 4096,
          ),
        ],
        {},
        text: true,
        encoding: 'UTF-8',
      ),
      throwsFormatException,
    );
    final matcher = ResponseMatcher(
      const ResponseRule(
        kind: 'text_exact',
        framing: 'delimiter',
        text: 'OK',
        delimiterHex: '0D 0A',
      ),
      [1],
    );
    for (var i = 0; i < 2000; i++) {
      expect(matcher.add([120]), isNull);
    }
    expect(matcher.add([13]), isNull);
    expect(matcher.add([10, 79]), isNull);
    expect(matcher.add([75, 13]), isNull);
    expect(matcher.add([10])!.bytes, [79, 75]);
  });

  test(
    'Coalesced unsolicited next-step reply does not advance a future request',
    () async {
      final transport = CommandTransport();
      final session = await sessionFor(transport);
      final run = session.execute([
        textCommand('one'),
        textCommand('two', expected: 'SECOND'),
      ]);
      await until(() => transport.writes.length == 1);
      transport.receive(utf8.encode('OK\r\nSECOND\r\n'));
      await until(() => transport.writes.length == 2);
      expect(session.running, true);
      transport.receive(utf8.encode('SECOND\r\n'));
      await run;
      expect(session.error, isEmpty);
      await session.disconnect();
      session.dispose();
    },
  );

  test('Failed opens keep runtime identity; each successful reopen gets a new identity', () async {
    var fail = true;
    final session = Session(
      config: ConnectionConfig(kind: ConnectionKind.tcpClient),
      opener: (_) async {
        if (fail) throw StateError('unavailable');
        return CommandTransport();
      },
    );
    final initial = session.runtimeId;
    await session.connect();
    expect(session.runtimeId, initial);
    fail = false;
    await session.connect();
    final opened = session.runtimeId;
    expect(opened, isNot(initial));
    await session.disconnect();
    expect(session.runtimeId, opened);
    await session.connect();
    expect(session.runtimeId, isNot(opened));
    await session.disconnect();
    session.dispose();
  });
  test('UDP hostname resolves once per batch and uses the same numeric endpoint for writes and replies', () async {
    final transport = ResolvedCommandTransport();
    final session = await sessionFor(transport, kind: ConnectionKind.udp);
    session.config.targetHost = 'localhost';
    transport.onWrite = (_) =>
        transport.receive([1, 2], endpoint: '127.0.0.1:1001');
    final command = SavedCommand(
      name: 'udp',
      draft: Draft(body: 'AA'),
      stepDelayMs: 10,
      responseRule: const ResponseRule(
        kind: 'bytes_exact',
        framing: 'datagram',
        patternHex: '01 02',
      ),
    );
    await session.execute([command, command, command]);
    expect(session.error, isEmpty);
    expect(transport.resolves, 1);
    expect(transport.targets, List.filled(3, '127.0.0.1:1001'));
    await session.disconnect();
    session.dispose();
  });

  for (final address in ['127.0.0.1', '::1']) {
    test(
      'UDP real localhost response matching selects bound family $address',
      () async {
        late final RawDatagramSocket remote;
        try {
          remote = await RawDatagramSocket.bind(address, 0);
        } on SocketException {
          if (address == '::1') {
            markTestSkipped('Host has no IPv6 loopback');
            return;
          }
          rethrow;
        }
        final temporary = await RawDatagramSocket.bind(address, 0);
        final localPort = temporary.port;
        temporary.close();
        final subscription = remote.listen((event) {
          if (event == RawSocketEvent.read) {
            final data = remote.receive();
            if (data != null) remote.send([1, 2], data.address, data.port);
          }
        });
        final session = Session(
          config: ConnectionConfig(
            kind: ConnectionKind.udp,
            bindAddress: address,
            networkPort: localPort,
            targetHost: 'localhost',
            targetPort: remote.port,
          ),
        );
        try {
          await session.connect();
          expect(session.connected, true, reason: session.error);
          await session.execute([
            SavedCommand(
              name: 'localhost',
              draft: Draft(body: 'AA'),
              responseRule: const ResponseRule(
                kind: 'bytes_exact',
                framing: 'datagram',
                patternHex: '01 02',
              ),
            ),
          ]);
          expect(session.error, isEmpty);
          expect(session.rx, 2);
          if (address == '127.0.0.1') {
            expect(
              () => (session.transport! as DatagramTargetResolver)
                  .resolveDatagramTarget('::1:1001'),
              throwsFormatException,
            );
          }
        } finally {
          await session.disconnect();
          session.dispose();
          await subscription.cancel();
          remote.close();
        }
      },
    );
  }
}
