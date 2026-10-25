import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:portly/platform/storage_io.dart';

String _dartExecutable() {
  final config = File('.dart_tool/package_config.json').absolute;
  final packages = jsonDecode(config.readAsStringSync())['packages'] as List;
  final flutter = packages.singleWhere((p) => p['name'] == 'flutter');
  final root = config.uri.resolve(flutter['rootUri'] as String);
  final sdk = Directory.fromUri(root).parent.parent;
  return '${sdk.path}/bin/cache/dart-sdk/bin/dart${Platform.isWindows ? '.exe' : ''}';
}

Future<ProcessResult> _probe(String path) => Process.run(_dartExecutable(), [
  'test/helpers/storage_owner_probe.dart',
  path,
]);
Future<Process> _hold(String path) async {
  final child = await Process.start(_dartExecutable(), [
    'test/helpers/storage_owner_probe.dart',
    path,
    'hold',
  ]);
  final first = await child.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 10));
  expect(first, 'HELD');
  return child;
}

Future<void> _release(Process child) async {
  child.stdin.writeln('release');
  await child.stdin.close();
  expect(await child.exitCode.timeout(const Duration(seconds: 5)), 0);
}

void main() {
  test('A second primary repository in the same process is rejected before database writes', () async {
    final temp = await Directory.systemTemp.createTemp('portly-owner-'),
        path = '${temp.path}/app.sqlite';
    final first = AppStorage(), second = AppStorage();
    await first.open(path: path);
    await first.save({'marker': 'keep'});
    await expectLater(
      second.open(path: path),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('当前进程')),
      ),
    );
    final db = sqlite3.open(path);
    expect(
      jsonDecode(
        db.select('SELECT json FROM app_state').single['json'],
      )['marker'],
      'keep',
    );
    db.close();
    expect((await _probe(path)).exitCode, 23);
    first.close();
    await first.closed;
    await temp.delete(recursive: true);
  });
  test('Closing drains pending history and an immediate reopen waits for the owner release', () async {
    final temp = await Directory.systemTemp.createTemp('portly-owner-'),
        path = '${temp.path}/app.sqlite';
    final first = AppStorage();
    await first.open(path: path);
    await first.save({'marker': 'restored'});
    for (var i = 0; i < 100; i++) {
      first.recordHistory(
        HistoryRecord(
          id: 'h$i',
          kind: 'send',
          sessionId: 's',
          runtimeId: 'r',
          status: 'submitted',
          finalBytes: [i],
        ),
      );
    }
    first.close();
    final next = AppStorage();
    expect((await next.open(path: path))!['marker'], 'restored');
    expect((await next.queryHistory()).count, 100);
    expect((await _probe(path)).exitCode, 23);
    next.close();
    await next.closed;
    expect((await _probe(path)).exitCode, 0);
    await temp.delete(recursive: true);
  });
  test('The same repository can reopen only after its asynchronous close completes', () async {
    final temp = await Directory.systemTemp.createTemp('portly-owner-'),
        path = '${temp.path}/app.sqlite';
    final store = AppStorage();
    await store.open(path: path);
    await store.save({'marker': 'keep'});
    await expectLater(store.open(path: path), throwsStateError);
    store.close();
    expect((await store.open(path: path))!['marker'], 'keep');
    store.close();
    await store.closed;
    await temp.delete(recursive: true);
  });
  test(
    'Worker owner lock rejects a second real OS process and releases on close',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-owner-'),
          path = '${temp.path}/app.sqlite';
      final storage = AppStorage();
      await storage.open(path: path);
      final blocked = await _probe(path);
      expect(blocked.exitCode, 23);
      expect(blocked.stdout, 'BUSY\n');
      storage.close();
      await storage.closed;
      expect((await _probe(path)).exitCode, 0);
      await temp.delete(recursive: true);
    },
  );
  test('A real second process owner prevents initialization without modifying the database', () async {
    final temp = await Directory.systemTemp.createTemp('portly-owner-'),
        path = '${temp.path}/app.sqlite';
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE sentinel(value TEXT)');
    db.execute("INSERT INTO sentinel VALUES('keep')");
    db.execute('PRAGMA user_version=1');
    db.close();
    final before = File(path).readAsBytesSync();
    final child = await _hold(path);
    try {
      await expectLater(
        AppStorage().open(path: path),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('另一个 Portly 进程'),
          ),
        ),
      );
      expect(File(path).readAsBytesSync(), before);
      expect(File('$path.migration-v1.backup').existsSync(), false);
    } finally {
      await _release(child);
    }
    final reopened = AppStorage();
    await reopened.open(path: path);
    reopened.close();
    await reopened.closed;
    await temp.delete(recursive: true);
  });
  test(
    'Initialization failure releases both the process registry and the OS lock',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-owner-'),
          path = '${temp.path}/app.sqlite';
      final db = sqlite3.open(path);
      db.execute('PRAGMA user_version=99');
      db.close();
      await expectLater(AppStorage().open(path: path), throwsStateError);
      expect((await _probe(path)).exitCode, 0);
      final old = sqlite3.open(path);
      old.execute('PRAGMA user_version=1');
      old.close();
      final storage = AppStorage();
      await storage.open(path: path);
      storage.close();
      await storage.closed;
      await temp.delete(recursive: true);
    },
  );
  test(
    'Canonical parent aliases cannot bypass the same-process repository owner',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-owner-'),
          path = '${temp.path}/app.sqlite';
      final alias = Link('${temp.path}/alias');
      await alias.create(temp.path);
      final first = AppStorage();
      await first.open(path: path);
      await expectLater(
        AppStorage().open(path: '${alias.path}/app.sqlite'),
        throwsStateError,
      );
      first.close();
      await first.closed;
      await temp.delete(recursive: true);
    },
  );
  test('Database, lock, WAL and backup symlinks are rejected without following them', () async {
    for (final suffix in [
      '',
      '.owner.lock',
      '-wal',
      '-shm',
      '-journal',
      '.backup',
      '.migration-v1.backup',
      '.import-123.backup',
    ]) {
      final temp = await Directory.systemTemp.createTemp('portly-owner-'),
          path = '${temp.path}/app.sqlite';
      final outside = File('${temp.path}/external');
      await outside.writeAsString('keep');
      await Link('$path$suffix').create(outside.path);
      await expectLater(AppStorage().open(path: path), throwsStateError);
      expect(await outside.readAsString(), 'keep');
      await Link('$path$suffix').delete();
      final storage = AppStorage();
      await storage.open(path: path);
      storage.close();
      await storage.closed;
      await temp.delete(recursive: true);
    }
  });
}
