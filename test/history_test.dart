import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:portly/core/bytes.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/platform/transport.dart';
import 'package:portly/state/session.dart';

class _Transport implements Transport {
  final controller = StreamController<TransportEvent>.broadcast(sync: true);
  final writes = <List<int>>[];
  void Function(List<int>)? onWrite;
  Completer<void>? gate;
  bool fail = false;
  @override
  List<Peer> get peers => [];
  @override
  String get localEndpoint => 'loopback';
  @override
  Stream<TransportEvent> get events => controller.stream;
  @override
  Future<void> send(Uint8List bytes, {String? target}) async {
    await gate?.future;
    if (fail) throw StateError('write failed');
    writes.add(bytes.toList());
    onWrite?.call(bytes);
  }

  void rx(List<int> bytes) => controller.add(TransportEvent(bytes: bytes));
  @override
  Future<void> disconnectPeer(String id) async {}
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

Future<Session> _session(
  _Transport transport,
  Map<String, HistoryRecord> entries,
) async {
  final s = Session(
    config: ConnectionConfig(kind: ConnectionKind.tcpClient, name: '设备'),
    opener: (_) async => transport,
  );
  s.onHistory = (r) => entries[r.id] = r;
  await s.connect();
  return s;
}

Future<void> _until(bool Function() test) async {
  for (var i = 0; i < 1000; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw TimeoutException('condition');
}

Future<void> _close(AppStorage storage) async {
  storage.close();
  await storage.closed;
  expect(storage.closeError, isEmpty);
}

Future<void> _disposeSession(Session session) async {
  session.beginShutdown();
  await session.disconnect();
  await session.recorder.stop();
  await session.drainSends();
  session.dispose();
}

SavedCommand _command({int timeout = 30}) => SavedCommand(
  name: '读取',
  revision: 3,
  draft: Draft(body: '{{unit}} 03 00 00 00 02', crc: true),
  parameters: const [
    CommandParameter(name: 'unit', type: 'uint8', defaultValue: '1'),
  ],
  timeoutMs: timeout,
  stepDelayMs: 10,
);
HistoryRecord _record(
  int index, {
  String session = 's',
  String status = 'submitted',
  List<int> bytes = const [1, 2],
}) => HistoryRecord(
  id: 'h-${index.toString().padLeft(5, '0')}',
  kind: 'send',
  sessionId: session,
  runtimeId: 'runtime',
  name: '指令 $index',
  status: status,
  finalBytes: bytes,
  draft: Draft(body: hex(bytes)),
);

void main() {
  test(
    'Manual history freezes policy/bytes/target and RX never creates records',
    () async {
      final t = _Transport(), entries = <String, HistoryRecord>{};
      final session = await _session(t, entries);
      final input = Draft(body: '01 03 00 00 00 02', crc: true);
      final send = session.send(input, remember: true);
      input.body = 'FF';
      input.crc = false;
      await send;
      final r = entries.values.single;
      expect(r.status, 'submitted');
      expect(r.finalBytes, withCrc([1, 3, 0, 0, 0, 2]));
      expect(r.submittedBytes, 8);
      expect(r.draft!.crc, isTrue);
      expect(r.replayDraft().build(), r.finalBytes);
      expect(r.submittedLogIds.single, session.logs.last.id);
      for (var i = 0; i < 100; i++) {
        t.rx([65, 66]);
      }
      expect(entries.length, 1);
      expect(session.rx, 200);
      await _disposeSession(session);
    },
  );
  test(
    'Final-only legacy replay is raw; oversized snapshots cannot replay',
    () {
      final legacy = HistoryRecord.fromJson({
        'id': 'old',
        'kind': 'send',
        'finalBytes': '01 03 00 00 00 02 C4 0B',
      });
      final draft = legacy.replayDraft();
      expect(draft.crc, isFalse);
      expect(draft.text, isFalse);
      expect(draft.build(), [1, 3, 0, 0, 0, 2, 196, 11]);
      final large = _record(
        1,
        bytes: List.filled(HistoryRecord.maxBytes + 1, 65),
      );
      expect(large.finalBytes.length, HistoryRecord.maxBytes);
      expect(large.finalLength, HistoryRecord.maxBytes + 1);
      expect(large.canReplay, isFalse);
      expect(large.replayDraft, throwsStateError);
    },
  );
  test('Execution records resolved parameters, matched response, revision and log IDs', () async {
    final t = _Transport(), entries = <String, HistoryRecord>{};
    final s = await _session(t, entries);
    t.onWrite = (_) => t.rx(withCrc([2, 3, 4, 0, 1, 0, 2]));
    final command = _command();
    final running = s.execute(
      [command],
      parameterValues: {
        command.id: {'unit': '2'},
      },
    );
    command.revision = 4;
    command.draft.body = 'FF';
    await running;
    final step = entries.values.singleWhere((r) => r.kind == 'step');
    final task = entries.values.singleWhere((r) => r.kind == 'task');
    expect(step.status, 'response');
    expect(step.revision, 3);
    expect(step.parameters, {'unit': '2'});
    expect(step.draft!.body, contains('02'));
    expect(step.draft!.body, isNot(contains('{{')));
    expect(step.replayDraft().build(), step.finalBytes);
    expect(step.responseBytes, withCrc([2, 3, 4, 0, 1, 0, 2]));
    expect(s.logs.any((entry) => entry.id == step.responseLogId), isTrue);
    expect(task.status, 'response');
    expect(task.stepsCompleted, 1);
    expect(task.submittedBytes, 8);
    await _disposeSession(s);
  });
  test(
    'Timeout/device exception/failure/stop do not become device success',
    () async {
      for (final mode in ['timeout', 'exception', 'failure', 'stop']) {
        final t = _Transport(), entries = <String, HistoryRecord>{};
        final s = await _session(t, entries);
        if (mode == 'exception') t.onWrite = (_) => t.rx(withCrc([1, 131, 2]));
        if (mode == 'failure') t.fail = true;
        final run = s.execute([_command()]);
        if (mode == 'stop') {
          await _until(() => entries.values.any((r) => r.status == 'waiting'));
          s.stop();
        }
        await run;
        final expected = {
          'timeout': 'timeout',
          'exception': 'device_exception',
          'failure': 'failed',
          'stop': 'stopped',
        }[mode];
        expect(
          entries.values.singleWhere((r) => r.kind == 'step').status,
          expected,
        );
        expect(
          entries.values.singleWhere((r) => r.kind == 'task').status,
          expected,
        );
        await _disposeSession(s);
      }
    },
  );
  test(
    'A stopped old task cannot overwrite an immediately started task history',
    () async {
      final t = _Transport(), entries = <String, HistoryRecord>{};
      final s = await _session(t, entries);
      final first = s.execute([_command(timeout: 1000)]);
      await _until(() => entries.values.any((r) => r.status == 'waiting'));
      s.stop();
      final second = s.execute([
        SavedCommand(
          name: '另一条',
          draft: Draft(body: 'AA'),
          responseRule: const ResponseRule(kind: 'none'),
        ),
      ]);
      await Future.wait([first, second]);
      final tasks = entries.values.where((r) => r.kind == 'task').toList();
      expect(tasks.length, 2);
      expect(tasks.first.status, 'stopped');
      expect(tasks.last.status, 'submitted');
      expect(tasks.last.stepsCompleted, 1);
      expect(tasks.last.submittedBytes, 1);
      await _disposeSession(s);
    },
  );
  test('File history is one metadata entry with exact committed count, never body/chunks', () async {
    final t = _Transport(), entries = <String, HistoryRecord>{};
    final s = await _session(t, entries);
    await s.sendFile(
      Stream.value(List.filled(4096, 65)),
      length: 4096,
      name: 'firmware.bin',
      chunkSize: 256,
      delayMs: 0,
    );
    expect(t.writes.length, 16);
    final file = entries.values.single;
    expect(file.kind, 'file');
    expect(file.file['length'], 4096);
    expect(file.submittedBytes, 4096);
    expect(file.finalBytes, isEmpty);
    expect(file.draft, isNull);
    expect(file.canReplay, isFalse);
    expect(file.status, 'submitted');
    await _disposeSession(s);
  });
  test(
    'File stop retains partial accepted byte count without claiming completion',
    () async {
      final t = _Transport(), entries = <String, HistoryRecord>{};
      final s = await _session(t, entries);
      final run = s.sendFile(
        Stream.value(List.filled(4096, 65)),
        length: 4096,
        name: 'firmware.bin',
        chunkSize: 256,
        delayMs: 50,
      );
      await _until(() => s.fileSent >= 256);
      s.stop();
      await run;
      final file = entries.values.single;
      expect(file.status, 'stopped');
      expect(file.submittedBytes, 256);
      await _disposeSession(s);
    },
  );
  test('SQLite v1 migration creates backup, preserves config and recovers pending as interrupted', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-');
    final path = '${temp.path}/state.sqlite';
    final old = sqlite3.open(path);
    old.execute(
      'CREATE TABLE app_state(id INTEGER PRIMARY KEY,json TEXT NOT NULL)',
    );
    old.execute('INSERT INTO app_state VALUES(1,?)', [
      jsonEncode({'schemaVersion': 1, 'value': '保留'}),
    ]);
    old.execute('PRAGMA user_version=1');
    old.close();
    final storage = AppStorage();
    expect((await storage.open(path: path))!['value'], '保留');
    expect(File('$path.migration-v1.backup').existsSync(), isTrue);
    expect(storage.recordHistory(_record(1, status: 'waiting')), isTrue);
    await storage.flushHistory();
    await _close(storage);
    final next = AppStorage();
    await next.open(path: path);
    final page = await next.queryHistory();
    expect(page.records.single.status, 'interrupted');
    expect(page.records.single.error, isNotEmpty);
    await _close(next);
    await temp.delete(recursive: true);
  });
  test('History persists separately, pagination/clear are scoped and commands survive', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-');
    final path = '${temp.path}/state.sqlite';
    final storage = AppStorage();
    await storage.open(path: path);
    await storage.save({
      'commands': ['keep'],
    });
    for (var i = 0; i < 12; i++) {
      storage.recordHistory(_record(i, session: i.isEven ? 'a' : 'b'));
    }
    await storage.flushHistory();
    final first = await storage.queryHistory(sessionId: 'a', limit: 2);
    expect(first.count, 6);
    expect(first.records.length, 2);
    expect(first.nextCursor, isNotEmpty);
    final second = await storage.queryHistory(
      sessionId: 'a',
      before: first.nextCursor,
      limit: 2,
    );
    expect(
      second.records
          .map((r) => r.id)
          .toSet()
          .intersection(first.records.map((r) => r.id).toSet()),
      isEmpty,
    );
    await storage.clearHistory(sessionId: 'a');
    expect((await storage.queryHistory()).count, 6);
    final db = sqlite3.open(path);
    expect(
      jsonDecode(
        db.select('SELECT json FROM app_state').single['json'],
      )['commands'],
      ['keep'],
    );
    db.close();
    await _close(storage);
    await temp.delete(recursive: true);
  });
  test('Bounded ingress rejects overload visibly without blocking; global history retention is 1000', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-');
    final storage = AppStorage();
    await storage.open(path: '${temp.path}/state.sqlite');
    final errors = <String>[];
    storage.onHistoryError = errors.add;
    for (var batch = 0; batch < 6; batch++) {
      for (var i = 0; i < 200; i++) {
        expect(storage.recordHistory(_record(batch * 200 + i)), isTrue);
      }
      await storage.flushHistory();
    }
    expect((await storage.queryHistory()).count, 1000);
    for (var i = 0; i < 300; i++) {
      storage.recordHistory(_record(2000 + i));
    }
    expect(storage.historyDropped, 44);
    expect(errors, isNotEmpty);
    expect(storage.historyError, contains('队列已满'));
    await storage.flushHistory();
    await _close(storage);
    await temp.delete(recursive: true);
  });
  test(
    'Higher database versions are rejected without altering version or content',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-history-');
      final path = '${temp.path}/state.sqlite';
      final db = sqlite3.open(path);
      db.execute('CREATE TABLE sentinel(value TEXT)');
      db.execute("INSERT INTO sentinel VALUES('keep')");
      db.execute('PRAGMA user_version=99');
      db.close();
      final before = await File(path).readAsBytes();
      await expectLater(AppStorage().open(path: path), throwsStateError);
      expect(await File(path).readAsBytes(), before);
      await temp.delete(recursive: true);
    },
  );
  test('Import commit checks current fingerprint, creates consistent backup and rolls back failed transaction', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-');
    final path = '${temp.path}/state.sqlite';
    final storage = AppStorage();
    await storage.open(path: path);
    final state = {
      'schemaVersion': 1,
      'groups': {'default': '默认分组'},
      'commands': <dynamic>[],
    };
    await storage.save(state);
    final fingerprint = LibrarySnapshot.capture(
      groups: {'default': '默认分组'},
      commands: [],
    ).fingerprint;
    await expectLater(
      storage.commitLibraryImport(
        expectedFingerprint: 'stale',
        state: {'changed': true},
      ),
      throwsStateError,
    );
    final backup = await storage.commitLibraryImport(
      expectedFingerprint: fingerprint,
      state: {...state, 'marker': 'committed'},
    );
    final saved = sqlite3.open(backup);
    expect(
      jsonDecode(
        saved.select('SELECT json FROM app_state').single['json'],
      )['marker'],
      isNull,
    );
    saved.close();
    final db = sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER reject_import BEFORE INSERT ON app_state BEGIN SELECT RAISE(ABORT,'reject'); END",
    );
    db.close();
    await expectLater(
      storage.commitLibraryImport(
        expectedFingerprint: fingerprint,
        state: {...state, 'marker': 'bad'},
      ),
      throwsStateError,
    );
    final after = sqlite3.open(path);
    expect(
      jsonDecode(
        after.select('SELECT json FROM app_state').single['json'],
      )['marker'],
      'committed',
    );
    after.close();
    await _close(storage);
    await temp.delete(recursive: true);
  });
  test(
    'Failed v1 migration rolls back schema and retains original plus backup',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-history-');
      final path = '${temp.path}/state.sqlite';
      final db = sqlite3.open(path);
      db.execute(
        'CREATE TABLE app_state(id INTEGER PRIMARY KEY,json TEXT NOT NULL)',
      );
      db.execute('INSERT INTO app_state VALUES(1,?)', [
        jsonEncode({'keep': true}),
      ]);
      db.execute('CREATE TABLE send_history(wrong TEXT)');
      db.execute('PRAGMA user_version=1');
      db.close();
      await expectLater(AppStorage().open(path: path), throwsStateError);
      final after = sqlite3.open(path);
      expect(after.select('PRAGMA user_version').single.values.single, 1);
      expect(
        jsonDecode(
          after.select('SELECT json FROM app_state').single['json'],
        )['keep'],
        true,
      );
      after.close();
      expect(File('$path.migration-v1.backup').existsSync(), true);
      await temp.delete(recursive: true);
    },
  );
  test('Metadata is deeply immutable, strictly bounded and size estimates include every field', () {
    final nested = <String, dynamic>{
      'text': 'X' * 100000,
      'nested': <String, dynamic>{
        'values': <int>[1, 2],
      },
    };
    final record = HistoryRecord(
      kind: 'send',
      sessionId: 's',
      runtimeId: 'r',
      finalBytes: [1],
      draft: Draft(body: '01', suffix: '00 ' * 2000),
      targets: List.filled(100, 'T' * 100000),
      parameters: {for (var n = 0; n < 64; n++) 'p$n': 'P' * 10000},
      responseRule: nested,
      file: {'path': 'F' * 100000},
    );
    nested['text'] = 'changed';
    expect(record.metadataTruncated, true);
    expect(record.targets.length, 64);
    expect(record.targets.first.length, 512);
    expect(record.canReplay, false);
    expect(
      record.parameters.values.fold<int>(0, (n, v) => n + v.length),
      lessThanOrEqualTo(32768),
    );
    expect(
      record.estimatedBytes,
      greaterThanOrEqualTo(utf8.encode(jsonEncode(record.toJson())).length),
    );
    expect(record.estimatedBytes, lessThan(2 * 1024 * 1024));
    expect(
      () => ((record.toJson()['responseRule'] as Map)['nested'] as Map)['new'] =
          true,
      throwsUnsupportedError,
    );
  });
  test(
    'Retention keeps active task summaries ahead of older step entries',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-history-');
      final storage = AppStorage();
      await storage.open(path: '${temp.path}/state.sqlite');
      final active = HistoryRecord(
        id: 'active',
        kind: 'task',
        sessionId: 's',
        runtimeId: 'r',
        status: 'waiting',
      );
      storage.recordHistory(active);
      await storage.flushHistory();
      for (var batch = 0; batch < 6; batch++) {
        for (var i = 0; i < 200; i++) {
          storage.recordHistory(_record(batch * 200 + i));
        }
        await storage.flushHistory();
      }
      expect((await storage.queryHistory()).count, 1000);
      expect((await storage.getHistory('active'))!.pending, true);
      await _close(storage);
      await temp.delete(recursive: true);
    },
  );
  test('Large historical bodies obey the 32 MiB payload quota with bounded database growth', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-');
    final path = '${temp.path}/state.sqlite';
    final storage = AppStorage();
    await storage.open(path: path);
    final payload = List.filled(65536, 255);
    for (var i = 0; i < 130; i++) {
      expect(storage.recordHistory(_record(i, bytes: payload)), true);
      if (i.isOdd) await storage.flushHistory();
    }
    final page = await storage.queryHistory();
    expect(page.count, lessThan(130));
    expect(page.bytes, lessThanOrEqualTo(32 * 1024 * 1024));
    expect(File(path).lengthSync(), lessThan(50 * 1024 * 1024));
    expect(storage.historyError, isEmpty);
    await _close(storage);
    await temp.delete(recursive: true);
  });
  test('History storage failure remains visible after recovery and never blocks transport submission', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-');
    final path = '${temp.path}/state.sqlite';
    final storage = AppStorage();
    await storage.open(path: path);
    final db = sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER reject_history BEFORE INSERT ON send_history BEGIN SELECT RAISE(ABORT,'history disk failure'); END",
    );
    final t = _Transport(), s = await _session(t, {});
    s.onHistory = storage.recordHistory;
    await s.send(Draft(body: 'AA'));
    await storage.flushHistory();
    expect(s.tx, 1);
    expect(t.writes.single, [170]);
    expect(storage.historyError, contains('history disk failure'));
    expect(storage.historyDropped, 1);
    db.execute('DROP TRIGGER reject_history');
    await s.send(Draft(body: 'BB'));
    await storage.flushHistory();
    expect(s.tx, 2);
    expect((await storage.queryHistory()).count, 1);
    expect(storage.historyError, isNotEmpty);
    expect(storage.historyDropped, 1);
    db.close();
    await _disposeSession(s);
    await _close(storage);
    await temp.delete(recursive: true);
  });
  test('A transport completion after stop is audited without modifying the next task', () async {
    final t = _Transport(), entries = <String, HistoryRecord>{};
    final s = await _session(t, entries);
    t.gate = Completer<void>();
    final first = s.execute([
      SavedCommand(
        name: '旧任务',
        draft: Draft(body: 'AA'),
        responseRule: const ResponseRule(kind: 'none'),
      ),
    ]);
    await _until(() => entries.values.any((r) => r.kind == 'step'));
    s.stop();
    await first;
    final second = s.execute([
      SavedCommand(
        name: '新任务',
        draft: Draft(body: 'BB'),
        responseRule: const ResponseRule(kind: 'none'),
      ),
    ]);
    t.gate!.complete();
    await second;
    await Future<void>.delayed(Duration.zero);
    final steps = entries.values.where((r) => r.kind == 'step').toList();
    expect(steps.length, 2);
    expect(steps.first.status, 'stopped');
    expect(steps.first.submittedBytes, 1);
    expect(steps.last.status, 'submitted');
    expect(steps.last.submittedBytes, 1);
    expect(t.writes, [
      [170],
      [187],
    ]);
    await _disposeSession(s);
  });
  test(
    'Migration backup failure leaves the old schema and config unchanged',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-history-');
      final path = '${temp.path}/state.sqlite';
      final db = sqlite3.open(path);
      db.execute(
        'CREATE TABLE app_state(id INTEGER PRIMARY KEY,json TEXT NOT NULL)',
      );
      db.execute('INSERT INTO app_state VALUES(1,?)', [
        jsonEncode({'keep': true}),
      ]);
      db.execute('PRAGMA user_version=1');
      db.close();
      Directory('$path.migration-v1.backup').createSync();
      await expectLater(AppStorage().open(path: path), throwsStateError);
      final after = sqlite3.open(path);
      expect(after.select('PRAGMA user_version').single.values.single, 1);
      expect(
        jsonDecode(
          after.select('SELECT json FROM app_state').single['json'],
        )['keep'],
        true,
      );
      after.close();
      await temp.delete(recursive: true);
    },
  );
  test('SQLite drains 3000 execution steps and updates with bounded producer batches without losing history', () async {
    final temp = await Directory.systemTemp.createTemp('portly-history-drain-');
    final storage = AppStorage();
    await storage.open(path: '${temp.path}/state.sqlite');
    const count = 3000, batchSize = 128;
    var admitted = 0;
    // This is a drain/retention correctness test, not a 1000-steps/s benchmark.
    // Await each bounded producer batch so slow CI disks and Windows timer
    // granularity cannot turn a scheduling pause into an artificial catch-up
    // burst. The separate ingress-overload test still verifies explicit loss
    // accounting at the unchanged production queue limit.
    for (var index = 0; index < count; index++) {
      final record = HistoryRecord(
        id: 'drain-$index',
        kind: 'step',
        sessionId: 'serial-${index % 8}',
        runtimeId: 'runtime',
        taskId: 'task-${index % 8}',
        name: '读取',
        commandId: 'read',
        revision: 3,
        finalBytes: [1, 3, 0, 0, 0, 2, 196, 11],
        draft: Draft(body: '01 03 00 00 00 02', crc: true),
        responseRule: const ResponseRule().toJson(),
        timeoutMs: 1000,
        cycle: index ~/ 8 + 1,
        stepIndex: 1,
      );
      final accepted = storage.recordHistory(record);
      if (accepted) admitted++;
      expect(accepted, isTrue);
      expect(
        storage.recordHistory(
          record.update({'status': 'waiting', 'submittedBytes': 8}),
        ),
        isTrue,
      );
      expect(
        storage.recordHistory(
          record.update({
            'status': 'response',
            'submittedBytes': 8,
            'responseBytes': [1, 3, 4, 0, 1, 0, 2, 196, 11],
            'responseLogId': 'rx-$index',
            'elapsedMs': 2,
          }),
        ),
        isTrue,
      );
      if ((index + 1) % batchSize == 0) await storage.flushHistory();
    }
    await storage.flushHistory();
    expect(admitted, count);
    expect(storage.historyDropped, 0);
    expect(storage.historyError, isEmpty);
    final page = await storage.queryHistory(limit: 100);
    expect(page.count, 1000);
    expect(page.records.every((r) => r.status == 'response'), true);
    expect(page.records.every((r) => r.submittedBytes == 8), true);
    await _close(storage);
    await temp.delete(recursive: true);
  });
}
