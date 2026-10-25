import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage_io.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 3)) {
      throw TimeoutException('durable archive acknowledgement');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('eight recorder ingress streams share durable bounded directory transactions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-directory-batch-',
    );
    final archive = LogArchive();
    await archive.listFiles(temp.path);
    final recorders = List.generate(8, (_) => LogRecorder()),
        errors = <String>[];
    final options = LogRecordingOptions(directory: temp.path);
    for (var i = 0; i < recorders.length; i++) {
      await recorders[i].start(
        errors.add,
        options: options,
        sessionId: 'writer-$i',
        runtimeId: 'run-$i',
      );
    }
    for (var round = 0; round < 8; round++) {
      for (var writer = 0; writer < 8; writer++) {
        for (var i = 0; i < 16; i++) {
          recorders[writer].writeEntry(
            LogEntry(
              'RX',
              List.generate(
                128,
                (at) => (writer * 17 + round * 13 + i + at) & 255,
              ),
            ),
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 70));
    }
    await Future.wait(recorders.map((r) => r.stop()));
    expect(errors, isEmpty);
    final usage = await archive.usage(temp.path);
    // Separate per-writer small-batch transactions would need about 64 commits.
    // Scheduling jitter may split a window, while the hard 128-record cap stays.
    expect(usage['appendTransactions'], inInclusiveRange(8, 16));
    final files = await archive.listFiles(temp.path);
    expect(files.single.records, 1024);
    expect(recorders.every((r) => r.status.queued == 0), true);
    final raw = await File(files.single.path).readAsLines();
    expect(raw.length, 1024);
    expect(
      raw.map((line) => (jsonDecode(line) as Map)['id']).toSet().length,
      1024,
    );
    final db = sqlite3.open('${temp.path}/.portly-index.sqlite');
    expect(
      db.select('SELECT COUNT(*) FROM records').single.values.single,
      1024,
    );
    expect(
      db.select('SELECT COUNT(*) FROM record_search').single.values.single,
      1024,
    );
    db.close();
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('directory batch has a 256 KiB ingress bound and preserves all writer acknowledgements', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-directory-byte-bound-',
    );
    final archive = LogArchive();
    await archive.listFiles(temp.path);
    final recorders = List.generate(5, (_) => LogRecorder()),
        errors = <String>[];
    for (var i = 0; i < 5; i++) {
      await recorders[i].start(
        errors.add,
        options: LogRecordingOptions(directory: temp.path),
        sessionId: 'writer-$i',
      );
    }
    for (final recorder in recorders) {
      recorder.writeEntry(LogEntry('RX', List.filled(60 * 1024, 0x55)));
    }
    await Future.wait(recorders.map((r) => r.stop()));
    expect(errors, isEmpty);
    final usage = await archive.usage(temp.path);
    expect(usage['appendTransactions'], 2); // Four <256 KiB frames, then one.
    expect((await archive.listFiles(temp.path)).single.records, 5);
    final page = await archive.search(LogSearchQuery(directory: temp.path));
    expect(page.hits.map((h) => h.sessionId).toSet().length, 5);
    expect(recorders.every((r) => r.status.queued == 0), true);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('mixed-writer partial failure reports only each request own unconfirmed suffix', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-directory-partial-',
    );
    final archive = LogArchive();
    await archive.listFiles(temp.path);
    final recorders = List.generate(3, (_) => LogRecorder()),
        errors = List.generate(3, (_) => <String>[]);
    final options = LogRecordingOptions(
      directory: temp.path,
      fileLimitBytes: 700,
      maxFiles: 20,
    );
    for (var i = 0; i < 3; i++) {
      await recorders[i].start(
        errors[i].add,
        options: options,
        sessionId: 'writer-$i',
      );
    }
    final first = LogEntry('RX', [1]);
    recorders[0].writeEntry(first);
    recorders[1].writeEntry(LogEntry('RX', List.filled(300, 2)));
    recorders[2].writeEntry(LogEntry('RX', [3]));
    await Future.wait(recorders.map((r) => r.stop()));
    expect(errors[0], isEmpty);
    expect(errors[1].single, contains('1 条记录未确认'));
    expect(errors[2].single, contains('1 条记录未确认'));
    expect(errors[1].single, isNot(contains('3 条记录未确认')));
    final hits = (await archive.search(LogSearchQuery(directory: temp.path)))
        .hits;
    expect(hits.single.recordId, first.id);
    expect(recorders.every((r) => r.status.queued == 0), true);
    await archive.close();
    await temp.delete(recursive: true);
  });

  test('coalescing waits briefly, barriers flush durable data, stop and reopen retain it', () async {
    final temp = await Directory.systemTemp.createTemp(
      'portly-directory-barrier-',
    );
    final recorder = LogRecorder(), archive = LogArchive(), errors = <String>[];
    await recorder.start(
      errors.add,
      options: LogRecordingOptions(directory: temp.path),
    );
    final first = LogEntry('RX', utf8.encode('barrier first'));
    recorder.writeEntry(first);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // The initial recorder timer is 50 ms; a small worker batch is not ACKed
    // before its own coalescing window or an explicit ordering barrier.
    expect(recorder.status.records, 0);
    final page = await archive.search(
      LogSearchQuery(directory: temp.path, query: 'barrier first'),
    );
    expect(page.hits.single.recordId, first.id);
    await until(() => recorder.status.records == 1);
    final second = LogEntry('RX', utf8.encode('timer second'));
    recorder.writeEntry(second);
    await until(
      () => recorder.status.records == 2,
    ); // Flushes without an extra query.
    await recorder.stop();
    await archive.close();
    expect(errors, isEmpty);
    final reopened = LogArchive();
    final hits = (await reopened.search(LogSearchQuery(directory: temp.path)))
        .hits;
    expect(hits.map((h) => h.recordId), [first.id, second.id]);
    await reopened.close();
    await temp.delete(recursive: true);
  });
}
