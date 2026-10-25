import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/transport.dart';
import 'package:portly/state/session.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'TCP server separates two clients and preserves explicit targets',
    () async {
      final port = await freePort();
      final server = await openTransport(
        ConnectionConfig(
          kind: ConnectionKind.tcpServer,
          bindAddress: '127.0.0.1',
          networkPort: port,
        ),
      );
      final a = await Socket.connect('127.0.0.1', port),
          b = await Socket.connect('127.0.0.1', port);
      final aBytes = <int>[], bBytes = <int>[];
      a.listen(aBytes.addAll);
      b.listen(bBytes.addAll);
      await until(() => server.peers.length == 2);
      final target = server.peers.firstWhere(
        (p) => p.endpoint.endsWith(':${a.port}'),
      );
      await server.send(Uint8List.fromList([1, 2, 3]), target: target.id);
      await until(() => aBytes.length == 3);
      expect(bBytes, isEmpty);
      await server.disconnectPeer(target.id);
      expect(
        () => server.send(Uint8List.fromList([4]), target: target.id),
        throwsStateError,
      );
      a.destroy();
      b.destroy();
      await server.close();
    },
  );
  test('TCP client loopback actual bytes and EOF', () async {
    final echo = await ServerSocket.bind('127.0.0.1', 0);
    final accept = echo.listen((socket) => socket.listen(socket.add));
    final client = await openTransport(
      ConnectionConfig(
        kind: ConnectionKind.tcpClient,
        host: '127.0.0.1',
        networkPort: echo.port,
      ),
    );
    final received = client.events.firstWhere((e) => e.bytes.isNotEmpty);
    await client.send(Uint8List.fromList([0, 255, 1, 3]));
    expect((await received.timeout(const Duration(seconds: 3))).bytes, [
      0,
      255,
      1,
      3,
    ]);
    await client.close();
    await accept.cancel();
    await echo.close();
  });
  test('UDP preserves datagram boundaries and source endpoints', () async {
    final bound = await RawDatagramSocket.bind('127.0.0.1', 0);
    final port = bound.port;
    bound.close();
    final transport = await openTransport(
      ConnectionConfig(
        kind: ConnectionKind.udp,
        bindAddress: '127.0.0.1',
        networkPort: port,
      ),
    );
    RawDatagramSocket? remote;
    StreamSubscription<TransportEvent>? sub;
    StreamSubscription<RawSocketEvent>? rsub;
    Completer<void>? writable;
    final reply = Completer<List<int>>();
    final replyFuture = reply.future;
    unawaited(replyFuture.then<void>((_) {}, onError: (Object _) {}));
    try {
      remote = await RawDatagramSocket.bind('127.0.0.1', 0);
      final socket = remote;
      socket.writeEventsEnabled = false;
      rsub = socket.listen(
        (event) {
          if (event == RawSocketEvent.write) {
            socket.writeEventsEnabled = false;
            if (writable != null && !writable!.isCompleted) {
              writable!.complete();
            }
          } else if (event == RawSocketEvent.read) {
            Datagram? data;
            while ((data = socket.receive()) != null) {
              if (!reply.isCompleted) reply.complete(data!.data);
            }
          }
        },
        onError: (Object error) {
          if (writable != null && !writable!.isCompleted) {
            writable!.completeError(error);
          }
          if (!reply.isCompleted) reply.completeError(error);
        },
      );
      Future<void> sendRemote(List<int> bytes) async {
        final watch = Stopwatch()..start();
        while (true) {
          final count = socket.send(bytes, InternetAddress.loopbackIPv4, port);
          if (count == bytes.length) return;
          if (count != 0) {
            throw StateError('Remote UDP short write $count/${bytes.length}');
          }
          final left = const Duration(seconds: 3) - watch.elapsed;
          if (left <= Duration.zero) {
            throw TimeoutException('Remote UDP would block');
          }
          final ready = Completer<void>();
          writable = ready;
          try {
            socket.writeEventsEnabled = true;
            await ready.future.timeout(left);
          } finally {
            socket.writeEventsEnabled = false;
            if (identical(writable, ready)) writable = null;
          }
        }
      }

      final messages = <TransportEvent>[];
      sub = transport.events.listen((e) {
        if (e.bytes.isNotEmpty) messages.add(e);
      });
      await sendRemote([1, 2]);
      await sendRemote([3]);
      await until(() => messages.length == 2);
      expect(messages.map((m) => m.bytes.toList()), [
        [1, 2],
        [3],
      ]);
      expect(messages.first.endpoint, '127.0.0.1:${socket.port}');
      await transport.send(
        Uint8List.fromList([4, 5]),
        target: messages.first.endpoint,
      );
      expect(await replyFuture.timeout(const Duration(seconds: 3)), [4, 5]);
    } finally {
      await sub?.cancel();
      await rsub?.cancel();
      remote?.close();
      await transport.close();
    }
  });
  test('Session drafts are immutable after queued submission, disconnect stops loop', () async {
    final received = <int>[];
    final server = await ServerSocket.bind('127.0.0.1', 0);
    final clients = <Socket>[];
    final accept = server.listen((socket) {
      clients.add(socket);
      socket.listen(received.addAll);
    });
    final session = Session(
      config: ConnectionConfig(
        kind: ConnectionKind.tcpClient,
        host: '127.0.0.1',
        networkPort: server.port,
      ),
    );
    await session.connect();
    expect(session.connected, true);
    final draft = Draft(body: '01 02');
    final pending = session.send(draft);
    draft.body = 'FF';
    await pending;
    await until(() => received.length == 2);
    expect(received, [1, 2]);
    session.waitResponse = false;
    session.periodMs = 25;
    final run = session.execute([
      SavedCommand(
        name: 'loop',
        draft: Draft(body: '03'),
      ),
    ], repeat: true);
    await until(() => received.length >= 3);
    await session.disconnect();
    final count = received.length;
    await run;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(received.length, count);
    session.dispose();
    for (final c in clients) {
      c.destroy();
    }
    await accept.cancel();
    await server.close();
  });
}
