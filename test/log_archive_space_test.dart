import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage_io.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('dense entropy capture bounds index growth and exact short/HEX lookup survives rotation deletion', () async {
    final temp = await Directory.systemTemp.createTemp('portly-index-space-');
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    final options = LogRecordingOptions(
      directory: temp.path,
      maxTotalBytes: 256 * 1024 * 1024,
      fileLimitBytes: 2 * 1024 * 1024,
      maxFiles: 2,
      overwriteOldest: true,
    );
    await recorder.start(
      errors.add,
      options: options,
      sessionId: 'entropy',
      runtimeId: 'run-1',
    );
    final random = Random(481516), entries = <LogEntry>[];
    for (var i = 0; i < 4000; i++) {
      final data = List.generate(128, (_) => random.nextInt(256));
      if (i == 0) {
        data.setRange(0, 4, [0xde, 0xad, 0xbe, 0xef]);
      }
      if (i == 3999) {
        data.setRange(0, 8, utf8.encode('终点OK'));
      }
      final entry = LogEntry('RX', data);
      entries.add(entry);
      recorder.writeEntry(entry);
    }
    await recorder.stop();
    expect(errors, isEmpty);
    final usage = await archive.usage(temp.path);
    // Canonical NDJSON already contains 3 characters per raw byte plus metadata.
    // Keep a generous guard below the previous observed ~56x binary footprint.
    expect(usage['totalBytes'], lessThan(4000 * 128 * 24));
    expect(usage['indexBytes'], lessThan(usage['logBytes']! * 3));
    final all = await archive.listFiles(temp.path);
    expect(all.length, 2);
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '终')))
          .hits
          .single
          .recordId,
      entries.last.id,
    );
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '终点')))
          .hits
          .single
          .recordId,
      entries.last.id,
    );
    final endHex = (await archive.search(
      LogSearchQuery(
        directory: temp.path,
        query: 'E7 BB 88 E7 82 B9',
        hex: true,
      ),
    )).hits;
    expect(endHex.single.recordId, entries.last.id);
    expect(
      (await archive.search(
        LogSearchQuery(
          directory: temp.path,
          query: '4F',
          hex: true,
          limit: 500,
        ),
      )).hits,
      isNotEmpty,
    );
    // Force enough additional real frames to rotate out the first file. Both
    // trigram and exact-token postings must lose those removed row ids.
    await recorder.start(errors.add, options: options);
    for (var i = 0; i < 6000; i++) {
      recorder.writeEntry(LogEntry('RX', List.filled(128, 0x55)));
    }
    await recorder.stop();
    expect(errors, isEmpty);
    expect((await archive.listFiles(temp.path)).length, 2);
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'DE AD BE EF', hex: true),
      )).hits,
      isEmpty,
    );
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '终点')))
          .hits,
      isEmpty,
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: '55', hex: true),
      )).hits,
      isNotEmpty,
    );
    await archive.close();
    final db = sqlite3.open('${temp.path}/.portly-index.sqlite');
    expect(db.select('PRAGMA user_version').single.values.single, 3);
    final schema =
        db
                .select(
                  "SELECT sql FROM sqlite_master WHERE name='record_tokens'",
                )
                .single['sql']
            as String;
    expect(schema, contains('detail=none'));
    expect(schema, contains("tokenize='ascii'"));
    db.close();
    await temp.delete(recursive: true);
  });

  test('position-free candidates verify order, byte alignment, Unicode and literal NUL/FTS punctuation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-index-candidates-',
    );
    final recorder = LogRecorder(), archive = LogArchive();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path),
    );
    final text = [
      LogEntry('RX', utf8.encode('abcXbcd')),
      LogEntry('RX', utf8.encode('abcd')),
      LogEntry('RX', utf8.encode('温度aX度ab')),
      LogEntry('RX', utf8.encode('温度ab')),
      LogEntry('RX', utf8.encode('a\u0000b')),
      LogEntry('RX', utf8.encode('a\u0000bcde')),
      LogEntry('RX', utf8.encode('a"b c(d)')),
      LogEntry('RX', utf8.encode('星🙂🌡️温度')),
      LogEntry('RX', [0xab, 0xc0, 0xbc, 0xd0]),
      LogEntry('RX', [0xab, 0xcd]),
    ];
    for (final entry in text) {
      recorder.writeEntry(entry);
    }
    await recorder.stop();
    for (final pair in <(String, String)>[
      ('abcd', text[1].id),
      ('温度ab', text[3].id),
      ('a\u0000bcde', text[5].id),
      ('"b c(', text[6].id),
      ('星🙂🌡', text[7].id),
    ]) {
      final page = await archive.search(
        LogSearchQuery(directory: temp.path, query: pair.$1),
      );
      expect(page.hits.single.recordId, pair.$2);
    }
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'a\u0000b'),
      )).hits.map((h) => h.recordId),
      text.sublist(4, 6).map((e) => e.id),
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'AB CD', hex: true),
      )).hits.single.recordId,
      text[9].id,
    );
    await expectLater(
      archive.search(LogSearchQuery(directory: temp.path, query: 'a' * 65537)),
      throwsStateError,
    );
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('common FTS token with sparse metadata filters crosses empty candidate batches and paginates without gaps', () async {
    final temp = await Directory.systemTemp.createTemp('portly-index-batches-');
    final noise = LogRecorder(),
        selected = LogRecorder(),
        archive = LogArchive();
    final options = LogRecordingOptions(directory: temp.path);
    await noise.start((e) => fail(e), options: options, sessionId: 'noise');
    await selected.start(
      (e) => fail(e),
      options: options,
      sessionId: 'selected',
    );
    final start = DateTime.utc(2026, 10, 25), expected = <String>[];
    for (var i = 0; i < 2048; i++) {
      final sparse = i >= 1024 && i % 97 == 0;
      final entry = LogEntry(
        i.isEven ? 'RX' : 'TX',
        utf8.encode('common packet $i'),
        time: start.add(Duration(seconds: i)),
      );
      (sparse ? selected : noise).writeEntry(entry);
      if (sparse && i.isEven && i >= 1500 && i <= 2000) expected.add(entry.id);
    }
    // The sparse writer's small final batch follows more than 15 whole noise
    // batches. Empty metadata results must not stop the common-token cursor.
    await noise.stop();
    await selected.stop();
    expect(expected.length, 3);
    final file = (await archive.listFiles(temp.path)).single.path;
    for (final body in <(String, bool)>[
      ('common', false),
      ('63', true),
      ('', false),
    ]) {
      var cursor = '';
      final actual = <String>[];
      var pages = 0;
      do {
        final page = await archive.search(
          LogSearchQuery(
            directory: temp.path,
            query: body.$1,
            hex: body.$2,
            sessionId: 'selected',
            direction: 'RX',
            filePath: file,
            from: start.add(const Duration(seconds: 1500)),
            to: start.add(const Duration(seconds: 2000)),
            limit: 2,
            cursor: cursor,
          ),
        );
        actual.addAll(page.hits.map((h) => h.recordId));
        cursor = page.nextCursor;
        pages++;
        if (pages == 1) {
          expect(page.hits.length, 2);
          expect(cursor, isNotEmpty);
        }
        expect(pages, lessThanOrEqualTo(2));
      } while (cursor.isNotEmpty);
      expect(actual, expected);
      expect(actual.toSet().length, actual.length);
    }
    final absent = await archive.search(
      LogSearchQuery(
        directory: temp.path,
        query: 'common',
        sessionId: 'not-present',
        limit: 2,
      ),
    );
    expect(absent.hits, isEmpty);
    expect(absent.nextCursor, isEmpty);
    await archive.close();
    final db = sqlite3.open('${temp.path}/.portly-index.sqlite');
    for (final query in [
      'SELECT rowid FROM record_tokens WHERE record_tokens MATCH ? AND rowid>? ORDER BY rowid LIMIT 128',
      'SELECT rowid FROM record_text_search WHERE record_text_search MATCH ? AND rowid>? ORDER BY rowid LIMIT 128',
    ]) {
      final plan = db
          .select('EXPLAIN QUERY PLAN $query', [
            query.contains('record_tokens') ? '"b63"' : '"com" AND "omm"',
            0,
          ])
          .map((r) => r['detail'])
          .join('\n');
      expect(plan, contains('VIRTUAL TABLE INDEX'));
      expect(plan.toUpperCase(), isNot(contains('TEMP')));
      expect(plan.toUpperCase(), isNot(contains('SUBQUERY')));
      expect(plan.toUpperCase(), isNot(contains('BLOOM')));
    }
    final metadataPlan = db
        .select(
          'EXPLAIN QUERY PLAN SELECT r.* FROM records r NOT INDEXED WHERE r.id IN (?,?,?) AND r.sessionId=? ORDER BY r.id LIMIT 128',
          [1, 2, 3, 'selected'],
        )
        .map((r) => r['detail'])
        .join('\n');
    expect(metadataPlan, contains('INTEGER PRIMARY KEY'));
    expect(metadataPlan.toUpperCase(), isNot(contains('TEMP')));
    db.close();
    await temp.delete(recursive: true);
  });

  test('schema2 migration keeps original index backup and rebuilds exact and trigram search without modifying NDJSON', () async {
    final temp = await Directory.systemTemp.createTemp('portly-index-upgrade-');
    final recorder = LogRecorder();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path),
    );
    recorder.writeEntry(LogEntry('RX', utf8.encode('升级验证 温度')));
    recorder.writeEntry(LogEntry('TX', [0x01, 0x03, 0, 0xff]));
    await recorder.stop();
    final raw = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.ndjson'));
    final original = raw.readAsBytesSync(),
        index = File('${temp.path}/.portly-index.sqlite');
    final old = sqlite3.open(index.path);
    old.execute('DROP TABLE record_search');
    old.execute('DROP TABLE record_tokens');
    old.execute('DROP TABLE record_text_search');
    old.execute(
      "CREATE VIRTUAL TABLE record_search USING fts5(hex,text,bytes,short,content='',contentless_delete=1,tokenize='trigram')",
    );
    old.execute('PRAGMA user_version=2');
    old.close();
    final archive = LogArchive();
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: '升级验证'),
      )).hits.length,
      1,
    );
    expect(
      (await archive.search(LogSearchQuery(directory: temp.path, query: '温度')))
          .hits
          .length,
      1,
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'FF', hex: true),
      )).hits.length,
      1,
    );
    await archive.close();
    expect(raw.readAsBytesSync(), original);
    final backup = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.contains('.schema2-backup-'));
    final verifyOld = sqlite3.open(backup.path);
    expect(verifyOld.select('PRAGMA user_version').single.values.single, 2);
    expect(
      verifyOld.select('SELECT COUNT(*) FROM records').single.values.single,
      2,
    );
    verifyOld.close();
    final verifyNew = sqlite3.open(index.path);
    expect(verifyNew.select('PRAGMA user_version').single.values.single, 3);
    verifyNew.close();
    await temp.delete(recursive: true);
  });

  test('migration refuses inadequate quota before changing old index and can retry with explicit space', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-index-upgrade-quota-',
    );
    final recorder = LogRecorder();
    await recorder.start(
      (e) => fail(e),
      options: LogRecordingOptions(directory: temp.path),
    );
    recorder.writeEntry(LogEntry('RX', utf8.encode('migration source')));
    await recorder.stop();
    final index = File('${temp.path}/.portly-index.sqlite');
    final old = sqlite3.open(index.path);
    old.execute('PRAGMA user_version=2');
    old.execute('CREATE TABLE padding(body BLOB)');
    old.execute('INSERT INTO padding VALUES(zeroblob(400000))');
    old.close();
    final original = index.readAsBytesSync();
    final manifest = File('${temp.path}/.portly-archive.json');
    final data = jsonDecode(manifest.readAsStringSync()) as Map;
    final used = Directory(temp.path)
        .listSync()
        .whereType<File>()
        .fold<int>(0, (sum, file) => sum + file.lengthSync());
    (data['options'] as Map)['maxTotalBytes'] = used + 65536;
    manifest.writeAsStringSync(jsonEncode(data));
    final archive = LogArchive();
    await expectLater(
      archive.listFiles(temp.path),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'reason',
          contains('升级空间不足'),
        ),
      ),
    );
    expect(index.readAsBytesSync(), original);
    expect(
      Directory(temp.path)
          .listSync()
          .where((f) => f.path.contains('.schema2-backup-')),
      isEmpty,
    );
    await archive.rebuild(
      temp.path,
      options: LogRecordingOptions(
        directory: temp.path,
        maxTotalBytes: 8 * 1024 * 1024,
      ),
    );
    expect(
      (await archive.search(
        LogSearchQuery(directory: temp.path, query: 'source'),
      )).hits.length,
      1,
    );
    await archive.close();
    await temp.delete(recursive: true);
  });
}
