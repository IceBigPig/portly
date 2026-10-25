import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:portly/core/models.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';

Map<String, dynamic> _clone(Map<String, dynamic> j) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(j)));
LibrarySnapshot _snapshot(Map<String, dynamic>? j) => LibrarySnapshot.capture(
  groups: Map<String, String>.from(j?['groups'] ?? {'default': '默认分组'}),
  commands: (j?['commands'] as List? ?? [])
      .map((c) => SavedCommand.fromJson(Map<String, dynamic>.from(c)))
      .toList(),
  groupMetadata: {
    for (final e in (j?['groupMetadata'] as Map? ?? {}).entries)
      e.key as String: Map<String, dynamic>.from(e.value),
  },
);

class _GateStorage extends AppStorage {
  Map<String, dynamic>? state;
  int writes = 0, commits = 0, backups = 0;
  Completer<void>? saveGate, commitGate;
  bool failBackup = false, failCommit = false;
  @override
  Future<Map<String, dynamic>?> open({String? path}) async =>
      state == null ? null : _clone(state!);
  @override
  Future<void> save(Map<String, dynamic> data) async {
    writes++;
    final next = _clone(data);
    await saveGate?.future;
    state = next;
  }

  @override
  Future<String> commitLibraryImport({
    required String expectedFingerprint,
    required Map<String, dynamic> state,
  }) async {
    commits++;
    final next = _clone(state);
    await commitGate?.future;
    if (_snapshot(this.state).fingerprint != expectedFingerprint) {
      throw StateError('命令库已改变');
    }
    if (failBackup) throw StateError('备份失败');
    backups++;
    if (failCommit) throw StateError('提交失败');
    this.state = next;
    return '/tmp/import-test.backup';
  }

  @override
  void close() {}
}

String _library({String id = 'incoming', String group = 'default'}) =>
    jsonEncode({
      'format': commandLibraryFormat,
      'schemaVersion': 1,
      'groups': [
        {
          'id': group,
          'name': group == 'default' ? '默认分组' : '传感器',
          'sortOrder': 4,
          'createdAt': '2026-10-25T00:00:00Z',
        },
      ],
      'commands': [
        SavedCommand(
          id: id,
          groupId: group,
          name: '参数读取',
          revision: 7,
          draft: Draft(body: '{{unit}} 03 00 00 00 02', crc: true),
          parameters: const [
            CommandParameter(
              name: 'unit',
              type: 'uint8',
              defaultValue: '1',
              min: 1,
              max: 247,
            ),
          ],
          responseRule: const ResponseRule(
            kind: 'modbus_rtu',
            unitId: 1,
            functionCode: 3,
            registerCount: 2,
          ),
          tags: ['读取'],
        ).toJson(),
      ],
    });
Future<void> _until(bool Function() test) async {
  for (var i = 0; i < 1000; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw TimeoutException('condition');
}

Future<void> _cleanup(AppModel model, Directory temp) async {
  model.dispose();
  await Future<void>.delayed(const Duration(milliseconds: 30));
  await temp.delete(recursive: true);
}

void main() {
  test('Editing a library after preview rejects stale plan without a storage commit', () async {
    final store = _GateStorage();
    final app = AppModel(storage: store);
    await app.initialize();
    final plan = (await app.previewLibraryImport(_library())).buildPlan();
    app.commands.add(
      SavedCommand(
        name: '本地编辑',
        draft: Draft(body: 'AA'),
      ),
    );
    await expectLater(app.applyLibraryImport(plan), throwsStateError);
    expect(store.commits, 0);
    expect(store.writes, 0);
    expect(app.commands.single.name, '本地编辑');
    app.dispose();
  });
  test(
    'Import waits for an in-flight configuration save before committing',
    () async {
      final store = _GateStorage();
      final model = AppModel(storage: store);
      await model.initialize();
      model.current.draft.body = 'AA';
      model.saveSoon();
      store.saveGate = Completer<void>();
      final save = model.save();
      await _until(() => store.writes == 1);
      final plan = (await model.previewLibraryImport(_library())).buildPlan();
      var finished = false;
      final imported = model.applyLibraryImport(plan).then((_) {
        finished = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(finished, false);
      expect(store.commits, 0);
      store.saveGate!.complete();
      await save;
      await imported;
      expect(store.commits, 1);
      expect(model.commands.single.id, 'incoming');
      expect((store.state!['sessions'] as List).single['draft']['body'], 'AA');
      model.dispose();
    },
  );
  test('Session selection is synchronous during an import transaction and later saves preserve the imported library', () async {
    final store = _GateStorage();
    final app = AppModel(storage: store);
    await app.initialize();
    final first = app.current, second = app.newSession(ConnectionKind.serial);
    await app.flushPendingSave();
    final plan = (await app.previewLibraryImport(_library())).buildPlan();
    store.commitGate = Completer<void>();
    final importing = app.applyLibraryImport(plan);
    await _until(() => store.commits == 1);
    expect(app.libraryImporting, true);
    final watch = Stopwatch()..start();
    app.selectSession(first.id);
    expect(app.current.id, first.id);
    app.selectSession(second.id);
    expect(app.current.id, second.id);
    expect(watch.elapsedMilliseconds, lessThan(20));
    first.draft.body = 'DE AD';
    app.changed();
    var flushed = false;
    final save = app.flushPendingSave().then((v) {
      flushed = true;
      return v;
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(flushed, false);
    store.commitGate!.complete();
    await importing;
    expect(await save, true);
    expect(app.commands.single.id, 'incoming');
    expect((store.state!['commands'] as List).single['id'], 'incoming');
    expect(
      (store.state!['sessions'] as List).firstWhere(
        (s) => s['id'] == first.id,
      )['draft']['body'],
      'DE AD',
    );
    app.dispose();
  });
  test(
    'Backup or commit failure leaves the in-memory command library unchanged',
    () async {
      for (final fail in ['backup', 'commit']) {
        final store = _GateStorage();
        final app = AppModel(storage: store);
        await app.initialize();
        app.commands.add(
          SavedCommand(
            id: 'local',
            name: '保留',
            draft: Draft(body: 'AA'),
          ),
        );
        app.changed();
        await app.flushPendingSave();
        final old = app.librarySnapshot.fingerprint,
            plan = (await app.previewLibraryImport(_library())).buildPlan();
        store.failBackup = fail == 'backup';
        store.failCommit = fail == 'commit';
        await expectLater(app.applyLibraryImport(plan), throwsStateError);
        expect(app.librarySnapshot.fingerprint, old);
        expect(_snapshot(store.state).fingerprint, old);
        expect(app.storageError, isNotEmpty);
        expect(app.libraryImporting, false);
        app.dispose();
      }
    },
  );
  test('Default empty library imports atomically and advanced commands/group metadata survive restart', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-import-integration-',
    );
    final path = '${temp.path}/app.sqlite';
    final app = AppModel();
    await app.initialize(storagePath: path);
    final preview = await app.previewLibraryImport(_library(group: 'sensors'));
    expect(preview.valid, true);
    final backup = await app.applyLibraryImport(preview.buildPlan());
    expect(File(backup).existsSync(), true);
    expect(app.commands.single.revision, 7);
    final before = app.librarySnapshot.fingerprint;
    app.dispose();
    final restored = AppModel();
    await restored.initialize(storagePath: path);
    expect(restored.librarySnapshot.fingerprint, before);
    expect(
      restored.groupMetadata['sensors']!['createdAt'],
      '2026-10-25T00:00:00Z',
    );
    expect(restored.commands.single.parameters.single.defaultValue, '1');
    expect(restored.commands.single.responseRule!.registerCount, 2);
    expect(restored.current.connected, false);
    await _cleanup(restored, temp);
  });
  test('An external database library change fails CAS without overwriting data or memory', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-import-integration-',
    );
    final path = '${temp.path}/app.sqlite';
    final app = AppModel();
    await app.initialize(storagePath: path);
    await app.save();
    final old = app.librarySnapshot.fingerprint,
        plan = (await app.previewLibraryImport(_library())).buildPlan();
    final external = app.snapshot();
    external['commands'] = [
      SavedCommand(
        id: 'external',
        name: '外部更新',
        draft: Draft(body: 'BB'),
      ).toJson(),
    ];
    final db = sqlite3.open(path);
    db.execute('UPDATE app_state SET json=? WHERE id=1', [
      jsonEncode(external),
    ]);
    db.close();
    await expectLater(app.applyLibraryImport(plan), throwsStateError);
    expect(app.librarySnapshot.fingerprint, old);
    final check = sqlite3.open(path);
    expect(
      (jsonDecode(
                check.select('SELECT json FROM app_state').single['json'],
              )['commands']
              as List)
          .single['id'],
      'external',
    );
    check.close();
    await _cleanup(app, temp);
  });
  test('A real SQLite transaction failure retains memory/library and the import backup', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-import-integration-',
    );
    final path = '${temp.path}/app.sqlite';
    final app = AppModel();
    await app.initialize(storagePath: path);
    await app.save();
    final old = app.librarySnapshot.fingerprint,
        plan = (await app.previewLibraryImport(_library())).buildPlan();
    final db = sqlite3.open(path);
    db.execute(
      "CREATE TRIGGER fail_library BEFORE INSERT ON app_state BEGIN SELECT RAISE(ABORT,'test-full-disk'); END",
    );
    db.close();
    await expectLater(app.applyLibraryImport(plan), throwsStateError);
    expect(app.librarySnapshot.fingerprint, old);
    expect(app.commands, isEmpty);
    expect(app.storageError, contains('test-full-disk'));
    expect(
      temp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.import-'))
          .length,
      1,
    );
    await _cleanup(app, temp);
  });
  test(
    'History is separate from snapshots and clearing it never deletes commands',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'portly-import-integration-',
      );
      final app = AppModel();
      await app.initialize(storagePath: '${temp.path}/app.sqlite');
      app.commands.add(
        SavedCommand(
          name: '保留',
          draft: Draft(body: 'AA'),
        ),
      );
      app.changed();
      await app.flushPendingSave();
      app.storage.recordHistory(
        HistoryRecord(
          kind: 'send',
          sessionId: app.current.id,
          runtimeId: app.current.runtimeId,
          finalBytes: [170],
          draft: Draft(body: 'AA'),
          status: 'submitted',
        ),
      );
      await app.storage.flushHistory();
      final state = app.snapshot();
      expect(state.containsKey('history'), false);
      expect(state.containsKey('send_history'), false);
      expect((state['sessions'] as List).single.containsKey('history'), false);
      expect((await app.storage.queryHistory()).count, 1);
      await app.storage.clearHistory();
      expect((await app.storage.queryHistory()).count, 0);
      expect(app.commands.single.name, '保留');
      await _cleanup(app, temp);
    },
  );
}
