import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/transport_io.dart';
import 'package:portly/state/session.dart';

class _Socket extends Stream<RawSocketEvent> implements RawDatagramSocket {
  final controller = StreamController<RawSocketEvent>();
  final counts = <int>[];
  final attempts = <List<int>>[], submitted = <List<int>>[];
  bool closed = false;
  @override
  bool broadcastEnabled = false;
  @override
  bool writeEventsEnabled = false;
  @override
  InternetAddress get address => InternetAddress.loopbackIPv4;
  @override
  int get port => 40001;
  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => controller.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  int send(List<int> data, InternetAddress address, int port) {
    if (closed) throw StateError('socket closed');
    attempts.add(List.of(data));
    final count = counts.isEmpty ? data.length : counts.removeAt(0);
    if (count == data.length) submitted.add(List.of(data));
    return count;
  }

  void writable() {
    if (!closed) controller.add(RawSocketEvent.write);
  }

  void fail() {
    if (!closed) {
      controller.addError(const SocketException('injected UDP error'));
    }
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(controller.close());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResolvingTransport extends IoTransport {
  final resolution = Completer<String>();
  final started = Completer<void>();
  _ResolvingTransport(_Socket socket)
    : super(
        ConnectionConfig(kind: ConnectionKind.udp, networkPort: 40001),
        datagramBinder: (_, _) async => socket,
      );
  @override
  Future<String> resolveDatagramTarget(String target) {
    if (!started.isCompleted) started.complete();
    return resolution.future;
  }
}

Future<void> until(bool Function() check) async {
  final watch = Stopwatch()..start();
  while (!check()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw TimeoutException('UDP condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<IoTransport> _transport(_Socket socket, {int timeout = 1000}) async {
  final value = IoTransport(
    ConnectionConfig(
      kind: ConnectionKind.udp,
      bindAddress: '127.0.0.1',
      networkPort: 40001,
      timeoutMs: timeout,
    ),
    datagramBinder: (_, _) async => socket,
  );
  await value.open();
  return value;
}

Future<void> settle() async =>
    Future<void>.delayed(const Duration(milliseconds: 10));
void main() {
  test('zero waits for each one-shot writable, retries immutable whole datagram and never replays success', () async {
    final socket = _Socket()..counts.addAll([0, 0, 2]);
    final io = await _transport(socket);
    try {
      final input = Uint8List.fromList([1, 2]);
      final sending = io.send(input, target: '127.0.0.1:40002');
      input[0] = 9;
      await until(() => socket.attempts.length == 1);
      expect(socket.writeEventsEnabled, true);
      expect(socket.attempts.single, [1, 2]);
      expect(socket.submitted, isEmpty);
      await settle();
      expect(socket.attempts.length, 1);
      socket.writable();
      await until(() => socket.attempts.length == 2);
      expect(socket.writeEventsEnabled, true);
      expect(socket.submitted, isEmpty);
      socket.writable();
      await sending;
      expect(socket.attempts, [
        [1, 2],
        [1, 2],
        [1, 2],
      ]);
      expect(socket.submitted, [
        [1, 2],
      ]);
      expect(socket.writeEventsEnabled, false);
      socket.writable();
      await settle();
      expect(socket.attempts.length, 3);
    } finally {
      await io.close();
    }
  });
  test('nonzero short datagram fails without retrying any suffix', () async {
    final socket = _Socket()..counts.add(1);
    final io = await _transport(socket);
    try {
      await expectLater(
        io.send(Uint8List.fromList([1, 2]), target: '127.0.0.1:40002'),
        throwsStateError,
      );
      socket.writable();
      await settle();
      expect(socket.attempts, [
        [1, 2],
      ]);
      expect(socket.submitted, isEmpty);
    } finally {
      await io.close();
    }
  });
  test(
    'would-block timeout does not submit after a later writable event',
    () async {
      final socket = _Socket()..counts.add(0);
      final io = await _transport(socket, timeout: 20);
      try {
        await expectLater(
          io.send(Uint8List.fromList([1]), target: '127.0.0.1:40002'),
          throwsA(isA<TimeoutException>()),
        );
        expect(socket.writeEventsEnabled, false);
        socket.writable();
        await settle();
        expect(socket.attempts.length, 1);
        expect(socket.submitted, isEmpty);
      } finally {
        await io.close();
      }
    },
  );
  for (final failure in [false, true]) {
    test(
      '${failure ? 'socket error' : 'close'} wakes blocked send and rejects queued datagrams',
      () async {
        final socket = _Socket()..counts.add(0);
        final io = await _transport(socket);
        try {
          var settled = 0;
          final first = expectLater(
            io.send(Uint8List.fromList([1]), target: '127.0.0.1:40002'),
            throwsA(anyOf(isA<Exception>(), isA<StateError>())),
          ).then((_) => settled++);
          final second = expectLater(
            io.send(Uint8List.fromList([2]), target: '127.0.0.1:40002'),
            throwsA(anyOf(isA<Exception>(), isA<StateError>())),
          ).then((_) => settled++);
          await until(() => socket.attempts.length == 1);
          if (failure) {
            socket.fail();
          } else {
            final closing = io.close();
            expect(identical(closing, io.close()), true);
            await closing;
            expect(settled, 2);
          }
          await Future.wait([first, second]);
          socket.writable();
          await settle();
          expect(socket.attempts.length, 1);
          expect(socket.submitted, isEmpty);
        } finally {
          await io.close();
        }
      },
    );
  }
  test('cancel rejects pending generation, keeps socket open and allows only a new explicit send', () async {
    final socket = _Socket()..counts.add(0);
    final io = await _transport(socket);
    try {
      final first = expectLater(
        io.send(Uint8List.fromList([1]), target: '127.0.0.1:40002'),
        throwsStateError,
      );
      final queued = expectLater(
        io.send(Uint8List.fromList([2]), target: '127.0.0.1:40002'),
        throwsStateError,
      );
      await until(() => socket.attempts.length == 1);
      io.cancelPendingWrites();
      socket.writable();
      await Future.wait([first, queued]);
      await settle();
      expect(socket.submitted, isEmpty);
      expect(socket.closed, false);
      await io.send(Uint8List.fromList([3]), target: '127.0.0.1:40002');
      expect(socket.submitted, [
        [3],
      ]);
    } finally {
      await io.close();
    }
  });
  test('Session.stop cancels a would-block datagram before an eventual writable notification', () async {
    final socket = _Socket()..counts.add(0);
    final io = await _transport(socket);
    final config = ConnectionConfig(
      kind: ConnectionKind.udp,
      bindAddress: '127.0.0.1',
      networkPort: 40001,
      targetHost: '127.0.0.1',
      targetPort: 40002,
    );
    final session = Session(config: config, opener: (_) async => io);
    try {
      await session.connect();
      session.waitResponse = false;
      final run = session.execute([
        SavedCommand(
          name: 'blocked',
          draft: Draft(body: '01'),
        ),
      ]);
      await until(() => socket.attempts.length == 1);
      session.stop();
      socket.writable();
      await run;
      await settle();
      expect(socket.submitted, isEmpty);
      expect(session.tx, 0);
      expect(session.running, false);
    } finally {
      await session.disconnect();
      session.dispose();
    }
  });
  test('UDP admission is bounded at 1000 queued writes and cancellation releases the queue', () async {
    final socket = _Socket()..counts.add(0);
    final io = await _transport(socket);
    try {
      final pending = <Future<void>>[];
      for (var i = 0; i < 1000; i++) {
        pending.add(
          expectLater(
            io.send(Uint8List.fromList([i & 255]), target: '127.0.0.1:40002'),
            throwsStateError,
          ),
        );
      }
      await expectLater(
        io.send(Uint8List.fromList([1]), target: '127.0.0.1:40002'),
        throwsStateError,
      );
      await until(() => socket.attempts.length == 1);
      io.cancelPendingWrites();
      await Future.wait(pending);
      expect(socket.submitted, isEmpty);
      await io.send(Uint8List.fromList([7]), target: '127.0.0.1:40002');
      expect(socket.submitted, [
        [7],
      ]);
    } finally {
      await io.close();
    }
  });
  test('close cancels DNS resolution and a later answer cannot send', () async {
    final socket = _Socket();
    // Use the same observable socket passed to the resolver transport.
    final value = _ResolvingTransport(socket);
    await value.open();
    try {
      final sending = expectLater(
        value.send(Uint8List.fromList([1]), target: 'delayed.invalid:40002'),
        throwsStateError,
      );
      await value.started.future;
      await value.close();
      await sending;
      value.resolution.complete('127.0.0.1:40002');
      await settle();
      expect(socket.attempts, isEmpty);
    } finally {
      await value.close();
    }
  });

  test('UDP admission is also bounded by retained payload bytes', () async {
    final socket = _Socket()..counts.add(0);
    final value = await _transport(socket);
    try {
      final pending = <Future<void>>[];
      for (var i = 0; i < 128; i++) {
        pending.add(
          expectLater(
            value.send(Uint8List(65507), target: '127.0.0.1:40002'),
            throwsStateError,
          ),
        );
      }
      await expectLater(
        value.send(Uint8List(65507), target: '127.0.0.1:40002'),
        throwsStateError,
      );
      await until(() => socket.attempts.length == 1);
      value.cancelPendingWrites();
      await Future.wait(pending);
      expect(socket.submitted, isEmpty);
    } finally {
      await value.close();
    }
  });
}
