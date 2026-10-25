import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';

class _GatedStorage extends AppStorage {
  int writes = 0;
  final snapshots = <Map<String, dynamic>>[];
  bool fail = false, block = false;
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    writes++;
    snapshots.add(data);
    if (block) {
      gate = Completer<void>();
      await gate!.future;
    }
    if (fail) throw StateError('磁盘写入失败');
  }

  @override
  void close() {}
}

Future<void> _shutdown(AppModel model) async {
  await model.shutdown();
  model.dispose();
  await model.storage.closed;
  expect(model.storage.closeError, isEmpty);
}

Future<void> _close(AppStorage storage) async {
  storage.close();
  await storage.closed;
  expect(storage.closeError, isEmpty);
}

void main() {
  test(
    'Log limits restore from SQLite and capture never restarts automatically',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'portly-log-persistence',
      );
      final path = '${temp.path}/app.sqlite';
      final logDirectory = '${temp.path}/capture';
      final first = AppModel();
      await first.initialize(storagePath: path);
      first.logOptions = LogRecordingOptions(
        directory: logDirectory,
        baseName: 'capture',
        fileLimitBytes: 1024 * 1024,
        maxFiles: 3,
        maxTotalBytes: 8 * 1024 * 1024,
        overwriteOldest: true,
      );
      final errors = <String>[];
      await first.current.recorder.start(
        errors.add,
        options: first.logOptions,
        sessionId: first.current.id,
        sessionName: first.current.config.name,
        runtimeId: first.current.runtimeId,
      );
      expect(first.current.recorder.active, isTrue);
      first.current.addLog(LogEntry('RX', [65, 66]));
      await first.save();
      await first.current.recorder.stop();
      await _shutdown(first);
      final before = Directory(logDirectory)
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.ndjson'))
          .length;
      expect(before, greaterThan(0));
      final second = AppModel();
      await second.initialize(storagePath: path);
      expect(second.logOptions.directory, logDirectory);
      expect(second.logOptions.baseName, 'capture');
      expect(second.logOptions.fileLimitBytes, 1024 * 1024);
      expect(second.logOptions.maxFiles, 3);
      expect(second.logOptions.maxTotalBytes, 8 * 1024 * 1024);
      expect(second.logOptions.overwriteOldest, isTrue);
      expect(second.current.recorder.active, isFalse);
      expect(second.current.connected, isFalse);
      expect(second.current.logs, isEmpty);
      expect(
        Directory(logDirectory)
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.ndjson'))
            .length,
        before,
      );
      expect(errors, isEmpty);
      await _shutdown(second);
      await temp.delete(recursive: true);
    },
  );

  test('Flush with no edits does not write; concurrent flush awaits one pending write and switching is immediate', () async {
    final store = _GatedStorage();
    final model = AppModel(storage: store);
    await model.initialize();
    expect(
      await model.flushPendingSave().timeout(const Duration(milliseconds: 100)),
      isTrue,
    );
    expect(store.writes, 0);
    final first = model.current,
        second = model.newSession(ConnectionKind.serial);
    await model.flushPendingSave();
    final baseline = store.writes;
    model.selectSession(first.id);
    first.draft.body = '01';
    model.saveSoon();
    store.block = true;
    var completeA = false, completeB = false;
    final a = model.flushPendingSave().then((value) {
      completeA = true;
      return value;
    });
    final b = model.flushPendingSave().then((value) {
      completeB = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, baseline + 1);
    expect(completeA, isFalse);
    expect(completeB, isFalse);
    model.selectSession(second.id);
    expect(model.current.id, second.id);
    model.selectSession(first.id);
    expect(model.current.id, first.id);
    expect(completeA, isFalse);
    expect(store.writes, baseline + 1);
    store.gate!.complete();
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(store.writes, baseline + 1);
    model.dispose();
  });

  test(
    'A failed pending-save flush reports failure until retry succeeds',
    () async {
      final store = _GatedStorage()..fail = true;
      final model = AppModel(storage: store);
      await model.initialize();
      model.current.draft.body = '01';
      model.saveSoon();
      expect(await model.flushPendingSave(), isFalse);
      expect(store.writes, 1);
      expect(model.storageError, contains('磁盘写入失败'));
      store.fail = false;
      expect(await model.flushPendingSave(), isTrue);
      expect(store.writes, 2);
      expect(model.storageError, isEmpty);
      model.dispose();
    },
  );

  test(
    'Flush waits for edits made while the first background write is pending',
    () async {
      final store = _GatedStorage()..block = true;
      final model = AppModel(storage: store);
      await model.initialize();
      model.current.draft.body = '01';
      model.saveSoon();
      var completedA = false, completedB = false;
      final a = model.flushPendingSave().then((value) {
        completedA = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 1);
      model.current.draft.body = '02';
      model.saveSoon();
      final b = model.flushPendingSave().then((value) {
        completedB = true;
        return value;
      });
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 1);
      store.gate!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, 2);
      expect(completedA, isFalse);
      expect(completedB, isFalse);
      expect(
        ((store.snapshots[1]['sessions'] as List).single['draft']
            as Map)['body'],
        '02',
      );
      store.gate!.complete();
      expect(await a, isTrue);
      expect(await b, isTrue);
      expect(store.writes, 2);
      model.dispose();
    },
  );

  test('Concurrent flush waiters return false after one failed background write without retrying', () async {
    final store = _GatedStorage()
      ..block = true
      ..fail = true;
    final model = AppModel(storage: store);
    await model.initialize();
    model.current.draft.body = '01';
    model.saveSoon();
    final background = model.save();
    final a = model.flushPendingSave(), b = model.flushPendingSave();
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, 1);
    store.gate!.complete();
    await background;
    expect(await a, isFalse);
    expect(await b, isFalse);
    expect(store.writes, 1);
    expect(model.storageError, contains('磁盘写入失败'));
    model.dispose();
  });

  test(
    'SQLite restores drafts, library and profiles, never a running connection',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-test');
      final path = '${temp.path}/app.sqlite';
      final first = AppModel();
      await first.initialize(storagePath: path);
      first.current.draft = Draft(body: '01 03 00 00 00 02', crc: true);
      first.commands.add(
        SavedCommand(name: '设备读取', draft: first.current.draft.copy()),
      );
      first.profiles.add(
        ConnectionConfig(name: '测试服务器', kind: ConnectionKind.tcpServer),
      );
      await first.save();
      await _shutdown(first);
      final second = AppModel();
      await second.initialize(storagePath: path);
      expect(second.current.draft.crc, true);
      expect(second.commands.length, 1);
      expect(second.profiles.single.name, '测试服务器');
      expect(second.current.connected, false);
      expect(second.current.running, false);
      expect(second.current.loop, false);
      await _shutdown(second);
      await temp.delete(recursive: true);
    },
  );
  test(
    'Import validates complete batch, skips UUID conflicts, roundtrips bytes',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-import');
      final model = AppModel();
      await model.initialize(storagePath: '${temp.path}/app.sqlite');
      model.commands.add(
        SavedCommand(
          name: '设备读取',
          draft: Draft(body: '01 03 00 00 00 02', crc: true),
        ),
      );
      final library = model.exportLibrary(), count = model.commands.length;
      expect(model.validateImport(library).conflicts, count);
      expect(await model.importLibrary(library), 0);
      expect(
        () => model.validateImport(library.replaceFirst('01 03', '01 0Z')),
        throwsFormatException,
      );
      expect(model.commands.length, count);
      expect(
        Directory(temp.path)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.import-')),
        isEmpty,
      );
      await _shutdown(model);
      await temp.delete(recursive: true);
    },
  );
  test(
    'Future database schema is rejected without clearing existing data',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-corrupt');
      final store = AppStorage();
      await store.open(path: '${temp.path}/app.sqlite');
      await store.save({'schemaVersion': 99});
      await _close(store);
      final app = AppModel();
      await app.initialize(storagePath: '${temp.path}/app.sqlite');
      expect(app.storageError, isNotEmpty);
      await app.save();
      // The intentionally unsupported app snapshot must not be saved by a
      // normal shutdown. Dispose still starts the async database close; wait
      // for its actual completion before reopening or deleting files.
      app.dispose();
      await app.storage.closed;
      expect(app.storage.closeError, isEmpty);
      final read = AppStorage();
      expect(
        (await read.open(path: '${temp.path}/app.sqlite'))!['schemaVersion'],
        99,
      );
      await _close(read);
      await temp.delete(recursive: true);
    },
  );
  test('Migration removes generated sessions and untouched examples, preserves user work', () async {
    final temp = await Directory.systemTemp.createTemp('portly-cleanup');
    final path = '${temp.path}/app.sqlite';
    final old = AppModel();
    await old.initialize(storagePath: path);
    old.groups['default'] = '示例命令';
    old.newSession(ConnectionKind.serial, name: '离线演示');
    final actual = old.newSession(ConnectionKind.serial, name: '离线演示');
    actual.config.port = '/dev/cu.user-device';
    old.commands.add(
      SavedCommand(
        name: '读取温湿度',
        draft: Draft(body: '01 03 00 00 00 02', crc: true),
      ),
    );
    old.commands.add(
      SavedCommand(
        name: '读取设备状态',
        draft: Draft(body: '01 03 00 10 00 02', crc: true),
        revision: 2,
      ),
    );
    old.commands.add(
      SavedCommand(
        name: '自定义命令',
        draft: Draft(body: 'FF'),
      ),
    );
    await old.save();
    await _shutdown(old);
    final restored = AppModel();
    await restored.initialize(storagePath: path);
    expect(restored.sessions.length, 2);
    expect(
      restored.sessions.any((s) => s.config.port == '/dev/cu.user-device'),
      true,
    );
    expect(restored.commands.map((c) => c.name), ['读取设备状态', '自定义命令']);
    expect(restored.groups['default'], '默认分组');
    await _shutdown(restored);
    final check = AppStorage();
    final persisted = await check.open(path: path);
    expect((persisted!['sessions'] as List).length, 2);
    await _close(check);
    await temp.delete(recursive: true);
  });
}
