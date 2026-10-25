import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage_io.dart';

void main() {
  test('archive worker records canonical bytes, Unicode offsets and indexed HEX/text with pagination', () async {
    final temp = await Directory.systemTemp.createTemp('portly-archive-');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(directory: temp.path),
      sessionId: 'serial-01',
      sessionName: '串口一',
      runtimeId: 'runtime-a',
    );
    final entries = [
      LogEntry(
        'RX',
        utf8.encode('温度=23.5 ℃\n'),
        endpoint: '设备',
        time: DateTime.utc(2026, 10, 25, 1),
      ),
      LogEntry('TX', [
        0x01,
        0x03,
        0x00,
        0xff,
      ], time: DateTime.utc(2026, 10, 25, 2)),
      LogEntry(
        'RX',
        utf8.encode('temperature=24.0\n'),
        time: DateTime.utc(2026, 10, 25, 3),
      ),
      LogEntry('RX', [0x11, 0x10, 0x31], time: DateTime.utc(2026, 10, 25, 4)),
    ];
    for (final entry in entries) {
      recorder.writeEntry(entry);
    }
    await recorder.stop();
    expect(errors, isEmpty);
    final files = await archive.listFiles(temp.path);
    expect(files.single.records, 4);
    final all = await archive.search(
      LogSearchQuery(directory: temp.path, limit: 2),
    );
    expect(all.hits.length, 2);
    expect(all.nextCursor, isNotEmpty);
    final next = await archive.search(
      LogSearchQuery(directory: temp.path, limit: 2, cursor: all.nextCursor),
    );
    expect(next.hits.map((h) => h.recordId), entries.skip(2).map((e) => e.id));
    final record = await archive.readRecord(all.hits[1]);
    expect(record['hex'], '01 03 00 FF');
    expect(record['sessionId'], 'serial-01');
    expect(record['runtimeId'], 'runtime-a');
    expect(
      all.hits[1].offset,
      utf8
          .encode('${jsonEncode(await archive.readRecord(all.hits.first))}\n')
          .length,
    );
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '温度')))
          .hits
          .single
          .recordId,
      entries.first.id,
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'TEMPERATURE'),
      )).hits.single.recordId,
      entries[2].id,
    );
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '度')))
          .hits
          .single
          .recordId,
      entries.first.id,
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: '03 00', hex: true),
      )).hits.single.recordId,
      entries[1].id,
    );
    // A nibble-aligned hit must not count as a byte-aligned match.
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: '10 03', hex: true),
      )).hits,
      isEmpty,
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'FF', hex: true),
      )).hits.single.recordId,
      entries[1].id,
    );
    final filtered = await archive.search(
      LogSearchQuery(
        directory: temp.path,
        direction: 'RX',
        sessionId: 'serial-01',
        from: DateTime.utc(2026, 10, 25, 2, 30),
        to: DateTime.utc(2026, 10, 25, 3, 30),
      ),
    );
    expect(filtered.hits.single.recordId, entries[2].id);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test(
    'rotation stops at file count by default and drains accepted records',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-rotation-');
      final recorder = LogRecorder(),
          archive = LogArchive(),
          errors = <String>[];
      await recorder.start(
        errors.add,
        options: LogRecordingOptions(
          directory: temp.path,
          fileLimitBytes: 700,
          maxFiles: 2,
        ),
      );
      for (var i = 0; i < 6; i++) {
        recorder.writeEntry(LogEntry('RX', List.filled(16, i)));
      }
      await recorder.stop();
      final files = await archive.listFiles(temp.path);
      expect(files.length, 2);
      expect(files.every((f) => f.bytes <= 700), true);
      expect(files.fold<int>(0, (sum, f) => sum + f.records), 2);
      expect(errors.single, contains('数量上限'));
      expect(recorder.active, false);
      expect(recorder.status.queued, 0);
      await archive.close();
      await temp.delete(recursive: true);
    },
  );

  test('overwrite removes only owned closed files, preserves unrelated files and maintains search index', () async {
    final temp = await Directory.systemTemp.createTemp('portly-overwrite-');
    final arbitrary = File('${temp.path}/other.ndjson')
      ..writeAsStringSync('do not delete');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(
        directory: temp.path,
        fileLimitBytes: 500,
        maxFiles: 2,
        overwriteOldest: true,
      ),
    );
    final entries = List.generate(6, (i) => LogEntry('RX', [i]));
    for (final e in entries) {
      recorder.writeEntry(e);
    }
    await recorder.stop();
    expect(errors, isEmpty);
    expect(arbitrary.readAsStringSync(), 'do not delete');
    expect((await archive.listFiles(temp.path)).length, 2);
    final hits = (await archive.search(LogSearchQuery(directory: temp.path)))
        .hits;
    expect(hits.map((h) => h.recordId), entries.skip(4).map((e) => e.id));
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: '00', hex: true),
      )).hits,
      isEmpty,
    );
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('missing and truncated files are visible and index rebuild preserves complete records', () async {
    final temp = await Directory.systemTemp.createTemp('portly-recovery-');
    final recorder = LogRecorder(), archive = LogArchive();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path, fileLimitBytes: 900),
    );
    for (var i = 0; i < 4; i++) {
      recorder.writeEntry(LogEntry('RX', [i]));
    }
    await recorder.stop();
    var files = await archive.listFiles(temp.path);
    expect(files.length, 2);
    final first = File(files.first.path), second = File(files.last.path);
    first.deleteSync();
    final bytes = second.readAsBytesSync();
    second.writeAsBytesSync(bytes.sublist(0, bytes.length - 3));
    final warnings = await archive.rebuild(temp.path);
    expect(warnings.any((w) => w.contains('缺失')), true);
    expect(warnings.any((w) => w.contains('截断')), true);
    files = await archive.listFiles(temp.path);
    expect(files.first.state, 'missing');
    expect(files.last.state, 'truncated');
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path))).hits.length,
      1,
    );
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('one background directory serializes multiple sessions and keeps runtime identities', () async {
    final temp = await Directory.systemTemp.createTemp('portly-shared-');
    final a = LogRecorder(), b = LogRecorder(), archive = LogArchive();
    final options = LogRecordingOptions(directory: temp.path);
    await Future.wait([
      a.start(
        (e) => fail(e),
        options: options,
        sessionId: 'a',
        runtimeId: 'a1',
      ),
      b.start(
        (e) => fail(e),
        options: options,
        sessionId: 'b',
        runtimeId: 'b1',
      ),
    ]);
    a.writeEntry(LogEntry('TX', [1]), runtimeId: 'a2');
    b.writeEntry(LogEntry('RX', [2]));
    await a.stop();
    b.writeEntry(LogEntry('RX', [3]));
    await b.stop();
    final all = await archive.search(LogSearchQuery(directory: temp.path));
    expect(all.hits.length, 3);
    expect(all.hits.where((h) => h.sessionId == 'a').single.runtimeId, 'a2');
    expect(all.hits.where((h) => h.sessionId == 'b').length, 2);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('queue overflow reports failure without clearing already accepted records; cancel is generation-safe', () async {
    final temp = await Directory.systemTemp.createTemp('portly-bound-');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(directory: temp.path, maxQueueRecords: 2),
    );
    recorder.writeEntry(LogEntry('RX', [1]));
    recorder.writeEntry(LogEntry('RX', [2]));
    recorder.writeEntry(LogEntry('RX', [3]));
    await recorder.stop();
    expect(errors.single, contains('队列已满'));
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path))).hits.length,
      2,
    );
    final searching = archive.search(LogSearchQuery(directory: temp.path));
    archive.cancel();
    expect((await searching).cancelled, true);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('single oversized record is rejected and disk budget includes index sidecars', () async {
    final temp = await Directory.systemTemp.createTemp('portly-quota-');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(
        directory: temp.path,
        fileLimitBytes: 400,
        maxTotalBytes: 256 * 1024,
      ),
    );
    recorder.writeEntry(LogEntry('RX', List.filled(200, 255)));
    await recorder.stop();
    expect(errors.single, contains('超过单文件限制'));
    expect((await archive.listFiles(temp.path)), isEmpty);
    final used = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .fold<int>(0, (sum, f) => sum + f.lengthSync());
    expect(used, lessThanOrEqualTo(256 * 1024));
    await archive.close();
    await temp.delete(recursive: true);
  });
  test('disk cap stops before exceeding actual managed usage, including the index and rollback budget', () async {
    final temp = await Directory.systemTemp.createTemp('portly-disk-cap-');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    const cap = 256 * 1024;
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(
        directory: temp.path,
        maxTotalBytes: cap,
        maxFiles: 100,
        fileLimitBytes: 1024 * 1024,
      ),
    );
    for (var i = 0; i < 500; i++) {
      recorder.writeEntry(
        LogEntry('RX', List.generate(100, (j) => (i + j) % 256)),
      );
    }
    await recorder.stop();
    expect(errors.single, contains('占用限制'));
    final usage = await archive.usage(temp.path);
    expect(usage['totalBytes'], lessThanOrEqualTo(cap));
    expect(usage['indexBytes'], greaterThan(0));
    expect(usage['logBytes'], greaterThan(0));
    final records = (await archive.search(
      LogSearchQuery(directory: temp.path, limit: 500),
    )).hits;
    expect(records.length, lessThan(500));
    final rawFiles = (await archive.listFiles(temp.path))
        .where((f) => f.bytes > 0)
        .toList();
    expect(rawFiles, isNotEmpty);
    final rawBefore = File(rawFiles.first.path).readAsBytesSync();
    final repaired = await archive.rebuild(
      temp.path,
      options: LogRecordingOptions(
        directory: temp.path,
        maxTotalBytes: 4 * 1024 * 1024,
      ),
    );
    expect(repaired.where((w) => w.contains('占用限制')), isEmpty);
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path))).hits,
      isNotEmpty,
    );
    expect(File(rawFiles.first.path).readAsBytesSync(), rawBefore);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('a damaged index is rebuilt from original files and a future index schema is preserved', () async {
    final temp = await Directory.systemTemp.createTemp('portly-index-repair-');
    final recorder = LogRecorder();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path),
    );
    recorder.writeEntry(LogEntry('RX', utf8.encode('恢复索引')));
    await recorder.stop();
    final indexFile = File('${temp.path}/.portly-index.sqlite');
    indexFile.writeAsStringSync('broken database', flush: true);
    final archive = LogArchive();
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '恢复')))
          .hits
          .length,
      1,
    );
    expect(
      Directory(temp.path).listSync().any((f) => f.path.contains('.corrupt-')),
      true,
    );
    await archive.close();
    final db = sqlite3.open(indexFile.path);
    db.execute('PRAGMA user_version=99');
    db.close();
    final future = LogArchive();
    await expectLater(future.listFiles(temp.path), throwsStateError);
    final verify = sqlite3.open(indexFile.path);
    expect(verify.select('PRAGMA user_version').first.values.first, 99);
    verify.close();
    await future.close();
    await temp.delete(recursive: true);
  });

  test('overwriting cannot delete a managed-name file replaced with foreign contents', () async {
    final temp = await Directory.systemTemp.createTemp('portly-owned-only-');
    final recorder = LogRecorder(), archive = LogArchive();
    final options = LogRecordingOptions(
      directory: temp.path,
      fileLimitBytes: 500,
      maxFiles: 1,
      overwriteOldest: true,
    );
    await recorder.start((e) => fail(e), options: options);
    recorder.writeEntry(LogEntry('RX', [1]));
    await recorder.stop();
    final files = await archive.listFiles(temp.path);
    final foreign = File(files.single.path)
      ..writeAsStringSync('foreign contents\n');
    await archive.close();
    final retry = LogRecorder(), errors = <String>[];
    await retry.start(errors.add, options: options);
    retry.writeEntry(LogEntry('RX', [2]));
    await retry.stop();
    expect(errors.single, contains('归属校验失败'));
    expect(foreign.readAsStringSync(), 'foreign contents\n');
    await temp.delete(recursive: true);
  });

  test('bounded batch capture leaves the UI isolate responsive during indexed write/search', () async {
    final temp = await Directory.systemTemp.createTemp('portly-index-load-');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(directory: temp.path),
      sessionId: 'load',
    );
    var uiTurns = 0;
    final ticker = Stream.periodic(const Duration(milliseconds: 1))
        .listen((_) => uiTurns++);
    for (var i = 0; i < 2000; i++) {
      recorder.writeEntry(
        LogEntry(i.isEven ? 'RX' : 'TX', utf8.encode('packet=$i 温度=23.50\n')),
      );
    }
    await recorder.stop();
    ticker.cancel();
    expect(errors, isEmpty);
    expect(uiTurns, greaterThan(2));
    final page = await archive.search(
      LogSearchQuery(
        directory: temp.path,
        query: '温度',
        direction: 'RX',
        limit: 500,
      ),
    );
    expect(page.hits.length, 500);
    expect(page.nextCursor, isNotEmpty);
    final second = await archive.search(
      LogSearchQuery(
        directory: temp.path,
        query: '温度',
        direction: 'RX',
        limit: 500,
        cursor: page.nextCursor,
      ),
    );
    expect(second.hits.length, 500);
    expect(second.nextCursor, isEmpty);
    await archive.close();
    await temp.delete(recursive: true);
  });
  test('active recording refuses rebuild, continues rotation and permits maintenance after drain', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-active-maintenance-',
    );
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(
        directory: temp.path,
        fileLimitBytes: 500,
        maxFiles: 2,
        overwriteOldest: true,
      ),
    );
    recorder.writeEntry(LogEntry('RX', [0]));
    await expectLater(archive.rebuild(temp.path), throwsStateError);
    final last = LogEntry('RX', [9]);
    for (var i = 1; i < 9; i++) {
      recorder.writeEntry(LogEntry('RX', [i]));
    }
    recorder.writeEntry(last);
    await recorder.stop();
    expect(errors, isEmpty);
    await archive.rebuild(temp.path);
    final results = await archive.search(LogSearchQuery(directory: temp.path));
    expect(results.hits.length, 2);
    expect(results.hits.last.recordId, last.id);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test(
    'directory aliases and close/reopen races cannot create two writers',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'portly-directory-alias-',
      );
      final link = Link('${temp.path}-alias');
      await link.create(temp.path);
      final a = LogRecorder(), b = LogRecorder(), errors = <String>[];
      await Future.wait([
        a.start(
          errors.add,
          options: LogRecordingOptions(directory: temp.path),
          sessionId: 'a',
        ),
        b.start(
          errors.add,
          options: LogRecordingOptions(directory: link.path),
          sessionId: 'b',
        ),
      ]);
      a.writeEntry(LogEntry('RX', [1]));
      b.writeEntry(LogEntry('RX', [2]));
      await Future.wait([a.stop(), b.stop()]);
      final c = LogRecorder();
      await c.start(
        errors.add,
        options: LogRecordingOptions(directory: temp.path),
      );
      c.writeEntry(LogEntry('RX', [3]));
      await c.stop();
      expect(errors, isEmpty);
      final archive = LogArchive();
      expect(
        (await archive.search(LogSearchQuery(directory: temp.path)))
            .hits
            .length,
        3,
      );
      await archive.close();
      await link.delete();
      await temp.delete(recursive: true);
    },
  );
  test(
    'simultaneous starts coalesce and stop fences a pending start',
    () async {
      final temp = await Directory.systemTemp.createTemp('portly-start-stop-');
      final recorder = LogRecorder(), errors = <String>[];
      final options = LogRecordingOptions(directory: temp.path);
      final starting = recorder.start(errors.add, options: options);
      final same = recorder.start(errors.add, options: options);
      expect(identical(starting, same), true);
      await recorder.stop();
      await starting;
      expect(recorder.active, false);
      await recorder.start(errors.add, options: options);
      expect(recorder.active, true);
      recorder.writeEntry(LogEntry('RX', [1]));
      await recorder.stop();
      expect(errors, isEmpty);
      final archive = LogArchive();
      expect(
        (await archive.search(LogSearchQuery(directory: temp.path)))
            .hits
            .length,
        1,
      );
      await archive.close();
      await temp.delete(recursive: true);
    },
  );

  test(
    'reserved index and temporary manifest symlinks never mutate foreign files',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'portly-metadata-link-',
      );
      final foreign = File('${temp.path}/foreign')
        ..writeAsStringSync('keep me');
      for (final name in [
        '.portly-index.sqlite',
        '.portly-archive.json.tmp',
        '.portly-archive.lock',
      ]) {
        final link = Link('${temp.path}/$name');
        await link.create(foreign.path);
        final archive = LogArchive();
        await expectLater(archive.listFiles(temp.path), throwsStateError);
        await archive.close();
        expect(foreign.readAsStringSync(), 'keep me');
        await link.delete();
      }
      await temp.delete(recursive: true);
    },
  );

  test('closing a broad in-flight search resolves cancellation before shutting the worker down', () async {
    final temp = await Directory.systemTemp.createTemp('portly-search-close-');
    final recorder = LogRecorder();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path),
    );
    for (var i = 0; i < 2000; i++) {
      recorder.writeEntry(LogEntry('RX', utf8.encode('common $i')));
    }
    await recorder.stop();
    final archive = LogArchive();
    await archive.listFiles(temp.path);
    final searching = archive.search(
      LogSearchQuery(directory: temp.path, query: 'common', limit: 500),
    );
    await Future<void>.delayed(Duration.zero);
    await archive.close().timeout(const Duration(seconds: 5));
    final page = await searching.timeout(const Duration(seconds: 5));
    expect(page.cancelled, true);
    await temp.delete(recursive: true);
  });

  test('corrupt-index recovery respects quota and can retry with an explicitly increased limit', () async {
    final temp = await Directory.systemTemp.createTemp('portly-repair-quota-');
    final recorder = LogRecorder();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path),
    );
    recorder.writeEntry(LogEntry('RX', utf8.encode('original packet')));
    await recorder.stop();
    final manifest = File('${temp.path}/.portly-archive.json');
    final data =
        jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
    (data['options'] as Map)['maxTotalBytes'] = 256 * 1024;
    manifest.writeAsStringSync(jsonEncode(data));
    final originals = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.ndjson'))
        .toList();
    final saved = originals.single.readAsBytesSync();
    File('${temp.path}/.portly-index.sqlite')
        .writeAsBytesSync(List.filled(180 * 1024, 0));
    final archive = LogArchive();
    await expectLater(archive.listFiles(temp.path), throwsStateError);
    final used = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .fold<int>(0, (n, f) => n + f.lengthSync());
    expect(used, lessThanOrEqualTo(256 * 1024));
    expect(originals.single.readAsBytesSync(), saved);
    await archive.rebuild(
      temp.path,
      options: LogRecordingOptions(
        directory: temp.path,
        maxTotalBytes: 4 * 1024 * 1024,
      ),
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'original'),
      )).hits.length,
      1,
    );
    expect(originals.single.readAsBytesSync(), saved);
    await archive.close();
    await temp.delete(recursive: true);
  });
}
