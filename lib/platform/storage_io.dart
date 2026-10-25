import 'dart:convert';
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:file_selector/file_selector.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/models.dart';
import '../core/log_archive.dart';
import '../core/history.dart';
import '../core/library_import.dart';
export '../core/history.dart';
export '../core/log_archive.dart';

class _StorageOwner {
  final Completer<void> released = Completer<void>();
  bool closing = false;
}

class AppStorage {
  // AppStorage workers use POSIX process locks. All primary repositories are
  // admitted here first because separate workers in one process share OS locks.
  static final _owners = <String, _StorageOwner>{};
  _StorageOwner? _owner;
  String? _ownerKey;
  Future<Map<String, dynamic>?>? _opening;
  Future<void>? _closeFuture;
  Future<void> get closed => _closeFuture ?? Future<void>.value();
  String location = '';
  ReceivePort? _replies;
  SendPort? _worker;
  int _next = 0;
  final _pending = <int, Completer<dynamic>>{};
  final _historyPending = <String, HistoryRecord>{};
  int _historyPendingBytes = 0,
      _historyInFlightBytes = 0,
      _historyInFlightCount = 0;
  Future<void>? _historyWrite;
  Timer? _historyTimer;
  String _historyError = '';
  String closeError = '';
  void Function(String)? onHistoryError;
  String get historyError => _historyError;
  set historyError(String value) {
    if (_historyError == value) return;
    _historyError = value;
    onHistoryError?.call(value);
  }

  int historyDropped = 0;
  bool _closing = false;

  /// Bounded, coalesced admission. Serial submission never waits for disk.
  bool recordHistory(HistoryRecord record) {
    if (_closing || _worker == null) {
      historyError = '历史存储未打开';
      return false;
    }
    final old = _historyPending[record.id];
    final nextBytes =
        _historyPendingBytes -
        (old?.estimatedBytes ?? 0) +
        record.estimatedBytes;
    if ((old == null &&
            _historyPending.length + _historyInFlightCount >= 256) ||
        nextBytes + _historyInFlightBytes > 2 * 1024 * 1024) {
      historyDropped++;
      historyError = '历史写入队列已满，$historyDropped 条更新未记录';
      return false;
    }
    _historyPending[record.id] = record;
    _historyPendingBytes = nextBytes;
    if (_historyPending.length >= 32 && _historyWrite == null) {
      _historyTimer?.cancel();
      _historyTimer = null;
      unawaited(_pumpHistory());
    } else {
      _historyTimer ??= Timer(const Duration(milliseconds: 50), () {
        _historyTimer = null;
        unawaited(_pumpHistory());
      });
    }
    return true;
  }

  Future<void> _pumpHistory() async {
    if (_historyWrite != null || _historyPending.isEmpty) return;
    final batch = _historyPending.values.take(32).toList(growable: false);
    _historyInFlightCount = batch.length;
    for (final item in batch) {
      _historyPending.remove(item.id);
      _historyPendingBytes -= item.estimatedBytes;
      _historyInFlightBytes += item.estimatedBytes;
    }
    final write = _request(
      'history_write',
      batch.map((r) => r.toJson()).toList(),
    );
    _historyWrite = write.then<void>(
      (_) {},
      onError: (Object e, StackTrace stack) {
        historyDropped += batch.length;
        historyError = '历史保存失败：$e';
      },
    );
    await _historyWrite;
    _historyWrite = null;
    _historyInFlightBytes = 0;
    _historyInFlightCount = 0;
    if (_historyPending.isNotEmpty) {
      // Retain idle coalescing but never impose a fixed throughput ceiling on
      // existing work. A zero-delay timer gives RX/UI events a turn per batch.
      _historyTimer?.cancel();
      _historyTimer = Timer(Duration.zero, () {
        _historyTimer = null;
        unawaited(_pumpHistory());
      });
    }
  }

  Future<void> flushHistory() async {
    _historyTimer?.cancel();
    _historyTimer = null;
    while (_historyWrite != null || _historyPending.isNotEmpty) {
      if (_historyWrite != null) await _historyWrite;
      await _pumpHistory();
    }
    _historyTimer?.cancel();
    _historyTimer = null;
  }

  Future<HistoryPage> queryHistory({
    String sessionId = '',
    String taskId = '',
    String before = '',
    int limit = 100,
    List<String> kinds = const [],
  }) async {
    await flushHistory();
    final j = Map<String, dynamic>.from(
      await _request('history_query', {
        'sessionId': sessionId,
        'taskId': taskId,
        'before': before,
        'limit': limit.clamp(1, 100),
        'kinds': kinds.take(4).toList(),
      }),
    );
    return HistoryPage(
      records: (j['records'] as List)
          .map((r) => HistoryRecord.fromJson(Map<String, dynamic>.from(r)))
          .toList(),
      nextCursor: j['nextCursor'],
      count: j['count'],
      bytes: j['bytes'],
    );
  }

  Future<HistoryRecord?> getHistory(String id) async {
    await flushHistory();
    final value = await _request('history_get', id);
    return value == null
        ? null
        : HistoryRecord.fromJson(Map<String, dynamic>.from(value));
  }

  Future<void> clearHistory({String sessionId = ''}) async {
    await flushHistory();
    await _request('history_clear', sessionId);
    historyError = '';
    historyDropped = 0;
  }

  Future<Map<String, dynamic>?> open({String? path}) {
    if (_opening != null) return Future.error(StateError('数据库正在打开，请勿重复打开'));
    final opening = _openOwned(path);
    _opening = opening;
    return opening.whenComplete(() {
      if (identical(_opening, opening)) _opening = null;
    });
  }

  Future<Map<String, dynamic>?> _openOwned(String? requestedPath) async {
    if (_closing) await closed;
    if (_worker != null || _owner != null) throw StateError('数据库已打开，请勿重复打开');
    _closing = false;
    _closeFuture = null;
    closeError = '';
    final requested =
        requestedPath ??
        '${(await getApplicationSupportDirectory()).path}/portly.sqlite';
    final file = File(requested).absolute;
    await file.parent.create(recursive: true);
    final parent = await file.parent.resolveSymbolicLinks();
    final name = file.uri.pathSegments.last;
    location = '$parent${Platform.pathSeparator}$name';
    _guardAppStorageMetadata(location);
    final key = Platform.isWindows || Platform.isMacOS
        ? location.toLowerCase()
        : location;
    while (true) {
      final existing = _owners[key];
      if (existing == null) break;
      if (!existing.closing) throw StateError('数据库已在当前进程中打开，请关闭另一个主窗口');
      await existing.released.future;
    }
    final owner = _StorageOwner()..closing = _closing;
    _owners[key] = owner;
    _owner = owner;
    _ownerKey = key;
    _replies = ReceivePort();
    final ready = Completer<dynamic>();
    _pending[0] = ready;
    _replies!.listen((dynamic message) {
      final values = message as List;
      if (values[0] == -1) {
        _worker = values[1] as SendPort;
        return;
      }
      final pending = _pending.remove(values[0]);
      if (pending == null) return;
      if (values[1] == true) {
        pending.complete(values[2]);
      } else {
        pending.completeError(StateError(values[2] as String));
      }
    });
    try {
      await Isolate.spawn(_storageWorker, [_replies!.sendPort, location]);
      return (await ready.future) as Map<String, dynamic>?;
    } catch (_) {
      _replies?.close();
      _replies = null;
      _worker = null;
      _releaseOwner();
      rethrow;
    }
  }

  void _releaseOwner() {
    final owner = _owner, key = _ownerKey;
    if (owner == null) return;
    if (identical(_owners[key], owner)) _owners.remove(key);
    _owner = null;
    _ownerKey = null;
    if (!owner.released.isCompleted) owner.released.complete();
  }

  Future<dynamic> _request(String operation, [dynamic value]) {
    if (_worker == null) return Future.error(StateError('存储未打开，未覆盖现有文件'));
    final id = ++_next, response = Completer<dynamic>();
    _pending[id] = response;
    _worker!.send([id, operation, value]);
    return response.future;
  }

  Future<void> save(Map<String, dynamic> data) async {
    await _request('save', data);
  }

  Future<String> commitLibraryImport({
    required String expectedFingerprint,
    required Map<String, dynamic> state,
  }) async => await _request('library_import', {
    'expectedFingerprint': expectedFingerprint,
    'state': state,
  }) as String;

  Future<void> backup() async {
    await _request('backup');
  }

  void close() {
    if (_closing || (_worker == null && _opening == null)) return;
    _closing = true;
    closeError = '';
    _owner?.closing = true;
    final opening = _opening, done = Completer<void>();
    _closeFuture = done.future;
    unawaited(() async {
      try {
        if (opening != null) {
          try {
            await opening;
          } catch (_) {
            /* Initialization already reports its error. */
          }
        }
        if (_worker != null) {
          await flushHistory();
          await _request('close');
        }
      } catch (e) {
        closeError = '$e';
        historyError = '历史存储关闭失败：$e';
      } finally {
        _worker = null;
        _replies?.close();
        _replies = null;
        _releaseOwner();
        done.complete();
      }
    }());
  }
}

void _guardAppStorageMetadata(String path) {
  for (final candidate in [
    path,
    '$path.owner.lock',
    '$path-wal',
    '$path-shm',
    '$path-journal',
  ]) {
    final type = FileSystemEntity.typeSync(candidate, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw StateError('数据库元数据路径不是普通文件，未修改数据：$candidate');
    }
  }
  // Backup targets must not redirect writes outside this database directory.
  for (final entry in File(path).parent.listSync(followLinks: false)) {
    if ((entry.path.startsWith('$path.backup') ||
            entry.path.startsWith('$path.migration-') ||
            entry.path.startsWith('$path.import-')) &&
        FileSystemEntity.typeSync(entry.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw StateError('数据库备份路径为符号链接，未修改数据：${entry.path}');
    }
  }
}

RandomAccessFile _acquireAppStorageLock(String path) {
  _guardAppStorageMetadata(path);
  final owner = File('$path.owner.lock').openSync(mode: FileMode.append);
  try {
    owner.lockSync(FileLock.exclusive);
    return owner;
  } catch (_) {
    owner.closeSync();
    throw StateError('数据库正在被另一个 Portly 进程使用，请先关闭另一个主窗口；原数据未修改');
  }
}

void _releaseAppStorageLock(RandomAccessFile? owner) {
  if (owner == null) return;
  try {
    owner.unlockSync();
  } finally {
    owner.closeSync();
  }
}

String _storedLibraryFingerprint(Database database) {
  final rows = database.select('SELECT json FROM app_state WHERE id=1');
  final current = rows.isEmpty
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(jsonDecode(rows.single['json'] as String));
  return LibrarySnapshot.capture(
    groups: Map<String, String>.from(current['groups'] ?? {'default': '默认分组'}),
    commands: (current['commands'] as List? ?? [])
        .map((v) => SavedCommand.fromJson(Map<String, dynamic>.from(v)))
        .toList(),
    groupMetadata: {
      for (final e in (current['groupMetadata'] as Map? ?? {}).entries)
        e.key as String: Map<String, dynamic>.from(e.value),
    },
  ).fingerprint;
}

// Configuration and history share one writer. RX never enters this worker.
void _storageWorker(List<dynamic> arguments) {
  final output = arguments[0] as SendPort, path = arguments[1] as String;
  final input = ReceivePort();
  Database? db;
  RandomAccessFile? owner;
  String? previous;
  output.send([-1, input.sendPort]);
  try {
    File(path).parent.createSync(recursive: true);
    owner = _acquireAppStorageLock(path);
    _guardAppStorageMetadata(path);
    db = sqlite3.open(path);
    db.execute('PRAGMA busy_timeout=3000');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 3) throw StateError('数据库版本高于当前应用，未修改数据');
    if (version > 0 && version < 3) {
      // VACUUM INTO includes committed WAL pages and produces a consistent backup.
      var backup = '$path.migration-v$version.backup';
      if (File(backup).existsSync()) {
        backup = '$backup.${DateTime.now().microsecondsSinceEpoch}';
      }
      db.execute('VACUUM INTO ?', [backup]);
    }
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('PRAGMA wal_autocheckpoint=256');
    db.execute('PRAGMA journal_size_limit=4194304');
    db.execute('PRAGMA busy_timeout=3000');
    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS app_state (id INTEGER PRIMARY KEY, json TEXT NOT NULL)',
      );
      db.execute(
        'CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER PRIMARY KEY, migrated_at TEXT NOT NULL)',
      );
      db.execute(
        "CREATE TABLE IF NOT EXISTS send_history (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, task_id TEXT NOT NULL, kind TEXT NOT NULL, updated_ms INTEGER NOT NULL, body TEXT NOT NULL, bytes INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'submitted')",
      );
      if (!db
          .select('PRAGMA table_info(send_history)')
          .any((r) => r['name'] == 'status')) {
        db.execute(
          "ALTER TABLE send_history ADD COLUMN status TEXT NOT NULL DEFAULT 'submitted'",
        );
        db.execute(
          "UPDATE send_history SET status=COALESCE(json_extract(body,'\$.status'),'submitted')",
        );
      }
      db.execute(
        'CREATE INDEX IF NOT EXISTS history_session ON send_history(session_id, updated_ms DESC, id DESC)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS history_task ON send_history(task_id, updated_ms DESC, id DESC)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS history_time ON send_history(updated_ms DESC, id DESC)',
      );
      db.execute(
        'INSERT OR IGNORE INTO schema_meta(version,migrated_at) VALUES(3,?)',
        [DateTime.now().toUtc().toIso8601String()],
      );
      db.execute('PRAGMA user_version=3');
      // A process exit cannot certify submission or a device response. Never replay.
      for (final row in db.select('SELECT id,body FROM send_history')) {
        final record = HistoryRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
        );
        if (record.pending) {
          final changed = record.update({
            'status': 'interrupted',
            'error': '上次运行未完成，任务未恢复',
          });
          final body = jsonEncode(changed.toJson());
          db.execute(
            'UPDATE send_history SET body=?,bytes=?,updated_ms=?,status=? WHERE id=?',
            [
              body,
              utf8.encode(body).length,
              changed.updatedAt.millisecondsSinceEpoch,
              changed.status,
              record.id,
            ],
          );
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    final rows = db.select('SELECT json FROM app_state WHERE id=1');
    previous = rows.isEmpty ? null : rows.first['json'] as String;
    output.send([0, true, previous == null ? null : jsonDecode(previous)]);
  } catch (e) {
    try {
      db?.close();
    } finally {
      _releaseAppStorageLock(owner);
    }
    owner = null;
    input.close();
    output.send([0, false, '$e']);
    return;
  }
  input.listen((dynamic message) {
    final id = message[0] as int, operation = message[1] as String;
    dynamic result;
    try {
      if (operation == 'save') {
        final encoded = jsonEncode(message[2]);
        if (encoded != previous) {
          db!.execute('BEGIN IMMEDIATE');
          try {
            db.execute(
              'INSERT OR REPLACE INTO app_state (id,json) VALUES (1,?)',
              [encoded],
            );
            db.execute('COMMIT');
            previous = encoded;
          } catch (_) {
            db.execute('ROLLBACK');
            rethrow;
          }
        }
      } else if (operation == 'history_write') {
        db!.execute('BEGIN IMMEDIATE');
        try {
          for (final value in message[2] as List) {
            final record = HistoryRecord.fromJson(
              Map<String, dynamic>.from(value),
            );
            final body = jsonEncode(record.toJson()),
                bytes = utf8.encode(body).length;
            db.execute(
              'INSERT OR REPLACE INTO send_history(id,session_id,task_id,kind,updated_ms,body,bytes,status) VALUES(?,?,?,?,?,?,?,?)',
              [
                record.id,
                record.sessionId,
                record.taskId,
                record.kind,
                record.updatedAt.millisecondsSinceEpoch,
                body,
                bytes,
                record.status,
              ],
            );
          }
          // Both limits apply globally. Long loops retain bounded recent steps.
          db.execute(
            "DELETE FROM send_history WHERE id IN (SELECT id FROM send_history ORDER BY CASE WHEN kind IN ('task','file') AND status IN ('pending','submitting','waiting') THEN 1 ELSE 0 END DESC,updated_ms DESC,id DESC LIMIT -1 OFFSET 1000)",
          );
          var total =
              db
                      .select(
                        'SELECT COALESCE(SUM(bytes),0) AS n FROM send_history',
                      )
                      .first['n']
                  as int;
          if (total > 32 * 1024 * 1024) {
            for (final row in db.select(
              "SELECT id,bytes FROM send_history ORDER BY CASE WHEN kind IN ('task','file') AND status IN ('pending','submitting','waiting') THEN 1 ELSE 0 END,updated_ms,id",
            )) {
              if (total <= 32 * 1024 * 1024) break;
              db.execute('DELETE FROM send_history WHERE id=?', [row['id']]);
              total -= row['bytes'] as int;
            }
          }
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (operation == 'history_query') {
        final q = message[2] as Map;
        final where = <String>[], values = <Object?>[];
        if (q['sessionId'] != '') {
          where.add('session_id=?');
          values.add(q['sessionId']);
        }
        if (q['taskId'] != '') {
          where.add('(task_id=? OR id=?)');
          values.addAll([q['taskId'], q['taskId']]);
        }
        final kinds = q['kinds'] as List;
        if (kinds.isNotEmpty) {
          where.add('kind IN (${List.filled(kinds.length, '?').join(',')})');
          values.addAll(kinds);
        }
        final base = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
        final stats = db!
            .select(
              'SELECT COUNT(*) AS n,COALESCE(SUM(bytes),0) AS b FROM send_history$base',
              values,
            )
            .first;
        if (q['before'] != '') {
          final cursor = jsonDecode(
            utf8.decode(base64Url.decode(q['before'] as String)),
          ) as List;
          where.add('(updated_ms<? OR (updated_ms=? AND id<?))');
          values.addAll([cursor[0], cursor[0], cursor[1]]);
        }
        final clause = where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}';
        final limit = (q['limit'] as int).clamp(1, 100);
        final rows = db.select(
          'SELECT id,updated_ms,body FROM send_history$clause ORDER BY updated_ms DESC,id DESC LIMIT ?',
          [...values, limit + 1],
        );
        final page = rows.take(limit).toList();
        result = {
          'records': page
              .map(
                (r) => HistoryRecord.fromJson(
                  Map<String, dynamic>.from(jsonDecode(r['body'] as String)),
                ).toJson(),
              )
              .toList(),
          'count': stats['n'],
          'bytes': stats['b'],
          'nextCursor': rows.length > limit && page.isNotEmpty
              ? base64Url.encode(
                  utf8.encode(
                    jsonEncode([page.last['updated_ms'], page.last['id']]),
                  ),
                )
              : '',
        };
      } else if (operation == 'history_get') {
        final rows = db!.select('SELECT body FROM send_history WHERE id=?', [
          message[2],
        ]);
        result = rows.isEmpty
            ? null
            : jsonDecode(rows.single['body'] as String);
      } else if (operation == 'history_clear') {
        if (message[2] == '') {
          db!.execute('DELETE FROM send_history');
        } else {
          db!.execute('DELETE FROM send_history WHERE session_id=?', [
            message[2],
          ]);
        }
      } else if (operation == 'library_import') {
        final data = message[2] as Map;
        if (_storedLibraryFingerprint(db!) != data['expectedFingerprint']) {
          throw StateError('命令库已改变，请重新检查导入冲突');
        }
        final encoded = jsonEncode(data['state']);
        _guardAppStorageMetadata(path);
        final backupPath =
            '$path.import-${DateTime.now().microsecondsSinceEpoch}.backup';
        db.execute('VACUUM INTO ?', [backupPath]);
        db.execute('BEGIN IMMEDIATE');
        try {
          if (_storedLibraryFingerprint(db) != data['expectedFingerprint']) {
            throw StateError('命令库已改变，请重新检查导入冲突');
          }
          db.execute('INSERT OR REPLACE INTO app_state(id,json) VALUES(1,?)', [
            encoded,
          ]);
          db.execute('COMMIT');
          previous = encoded;
          result = backupPath;
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      } else if (operation == 'backup') {
        _guardAppStorageMetadata(path);
        final temporary =
            '$path.backup.pending-${DateTime.now().microsecondsSinceEpoch}';
        try {
          db!.execute('VACUUM INTO ?', [temporary]);
          File(temporary).renameSync('$path.backup');
        } finally {
          if (File(temporary).existsSync()) File(temporary).deleteSync();
        }
      } else if (operation == 'close') {
        try {
          db!.close();
        } finally {
          _releaseAppStorageLock(owner);
          owner = null;
          input.close();
        }
      }
      output.send([id, true, result]);
    } catch (e) {
      output.send([id, false, '$e']);
    }
  });
}

Future<bool> exportFile(String name, String content) async {
  final result = await getSaveLocation(suggestedName: name);
  if (result == null) return false;
  await XFile.fromData(
    Uint8List.fromList(utf8.encode(content)),
    name: name,
  ).saveTo(result.path);
  return true;
}

Future<String?> importFile() async => (await openFile(
  acceptedTypeGroups: [
    const XTypeGroup(label: 'JSON', extensions: ['json']),
  ],
))?.readAsString();

/// Bounded ingress on the UI isolate. Encoding, disk flushes, rotation and index
/// transactions are performed by one shared worker per archive directory.
class LogRecorder {
  String? path;
  LogRecordingStatus status = const LogRecordingStatus();
  void Function()? onUpdate;
  _ArchiveService? _service;
  final _pending = ListQueue<Map<String, dynamic>>();
  int _pendingBytes = 0, _inFlightBytes = 0, _inFlightCount = 0;
  bool _accepting = false, _stopping = false;
  Timer? _timer;
  Future<void>? _pumping, _stoppingFuture, _startingFuture;
  int _lifecycle = 0;
  void Function(String)? _onError;
  String _writerId = '', _sessionId = '', _sessionName = '', _runtimeId = '';
  LogRecordingOptions _options = const LogRecordingOptions();
  bool get active => _accepting;

  Future<void> start(
    void Function(String) onError, {
    LogRecordingOptions? options,
    String sessionId = '',
    String sessionName = '',
    String? runtimeId,
  }) {
    if (_accepting) return Future.value();
    if (_startingFuture != null) return _startingFuture!;
    final generation = ++_lifecycle, done = Completer<void>();
    _startingFuture = done.future;
    final stopping = _stoppingFuture;
    _onError = onError;
    () async {
      _ArchiveService? acquired;
      String? writer;
      try {
        await stopping;
        if (generation != _lifecycle) return;
        var chosen = options ?? const LogRecordingOptions();
        if (chosen.directory.isEmpty) {
          final directory = await getDirectoryPath(confirmButtonText: '选择日志目录');
          if (directory == null || generation != _lifecycle) return;
          chosen = chosen.copy(directory: directory);
        }
        chosen.validate();
        acquired = await _ArchiveService.acquire(
          chosen.directory,
          options: chosen,
        );
        if (generation != _lifecycle) return;
        writer = newId();
        final result = await acquired.request('start', {
          'writerId': writer,
          'options': chosen.toJson(),
        }) as Map;
        if (generation != _lifecycle) return;
        _service = acquired;
        acquired = null;
        _writerId = writer;
        writer = null;
        _options = chosen;
        _sessionId = sessionId;
        _sessionName = sessionName;
        _runtimeId = runtimeId ?? newId();
        status = const LogRecordingStatus();
        _accepting = true;
        _stopping = false;
        _setStatus(result);
        _timer = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) => _pump(),
        );
      } catch (e) {
        if (generation == _lifecycle) _report('$e');
      } finally {
        if (acquired != null) {
          try {
            if (writer != null) await acquired.request('stop', writer);
          } catch (_) {}
          try {
            await acquired.release();
          } catch (_) {}
        }
        _startingFuture = null;
        done.complete();
      }
    }();
    return done.future;
  }

  void writeEntry(LogEntry entry, {String? runtimeId}) {
    if (!_accepting) return;
    // Send bytes as bytes. Canonical HEX and JSON are deliberately worker work.
    _enqueue(
      {
        'id': entry.id,
        'time': entry.time.millisecondsSinceEpoch,
        'utcOffsetMinutes': entry.time.timeZoneOffset.inMinutes,
        'direction': entry.direction,
        'sequence': entry.sequence,
        'endpoint': entry.endpoint,
        'message': entry.message,
        'bytes': entry.bytes,
        'sessionId': _sessionId,
        'sessionName': _sessionName,
        'runtimeId': runtimeId ?? _runtimeId,
      },
      entry.bytes.length +
          entry.message.length * 2 +
          entry.endpoint.length * 2 +
          256,
    );
  }

  /// Backward compatibility for callers outside Session. New capture code should
  /// use writeEntry to keep JSON/HEX creation off the UI isolate.
  void write(Map<String, dynamic> entry) {
    if (!_accepting) return;
    _enqueue(
      {
        ...entry,
        'sessionId': _sessionId,
        'sessionName': _sessionName,
        'runtimeId': _runtimeId,
      },
      (entry['hex'] as String? ?? '').length * 2 +
          (entry['message'] as String? ?? '').length * 2 +
          256,
    );
  }

  void _enqueue(Map<String, dynamic> entry, int size) {
    if (_pending.length + _inFlightCount >= _options.maxQueueRecords ||
        _pendingBytes + _inFlightBytes + size > _options.maxQueueBytes) {
      _report('日志落盘队列已满，已停止接收新记录；正在保存已接收的记录');
      unawaited(stop());
      return;
    }
    _pending.add({'entry': entry, 'size': size});
    _pendingBytes += size;
    if (_pending.length >= 128 || _pendingBytes >= 256 * 1024) _pump();
  }

  void _setStatus(Map result) {
    path = result['path'] as String? ?? path;
    status = LogRecordingStatus(
      active: _accepting,
      queued: _pending.length + _inFlightCount,
      records: result['records'] as int? ?? status.records,
      bytes: result['bytes'] as int? ?? status.bytes,
      files: result['files'] as int? ?? status.files,
      error: status.error,
      path: path ?? '',
    );
    onUpdate?.call();
  }

  void _report(String error) {
    _accepting = false;
    _timer?.cancel();
    status = LogRecordingStatus(
      active: false,
      queued: _pending.length + _inFlightCount,
      records: status.records,
      bytes: status.bytes,
      files: status.files,
      error: error,
      path: path ?? '',
    );
    _onError?.call(error);
    onUpdate?.call();
  }

  Future<void> _pump() {
    if (_pumping != null) return _pumping!;
    if (_pending.isEmpty || _service == null) return Future.value();
    final done = Completer<void>();
    _pumping = done.future;
    final batch = <Map<String, dynamic>>[];
    while (_pending.isNotEmpty &&
        batch.length < 128 &&
        _inFlightBytes < 256 * 1024) {
      final item = _pending.removeFirst();
      batch.add(item['entry'] as Map<String, dynamic>);
      final size = item['size'] as int;
      _pendingBytes -= size;
      _inFlightBytes += size;
    }
    _inFlightCount = batch.length;
    () async {
      try {
        final result = await _service!.request('append', {
          'writerId': _writerId,
          'entries': batch,
        }) as Map;
        if (result['error'] != null) {
          final unsaved = (result['unsaved'] as int? ?? 0) + _pending.length;
          _pending.clear();
          _pendingBytes = 0;
          _report(
            '${result['error']}；$unsaved 条记录未确认归档或索引；原始文件保留，可提高额度后重建，内存日志仍保留',
          );
        }
        _inFlightBytes = 0;
        _inFlightCount = 0;
        _setStatus(result);
      } catch (e) {
        final unsaved = batch.length + _pending.length;
        _pending.clear();
        _pendingBytes = 0;
        _inFlightBytes = 0;
        _inFlightCount = 0;
        _report('日志写入失败：$e；$unsaved 条记录未确认落盘');
      } finally {
        _pumping = null;
        done.complete();
        if (!_accepting && !_stopping) unawaited(stop());
      }
    }();
    return done.future;
  }

  Future<void> stop() {
    if (_stoppingFuture != null) return _stoppingFuture!;
    final done = Completer<void>();
    _stoppingFuture = done.future;
    ++_lifecycle;
    final starting = _startingFuture;
    _accepting = false;
    _stopping = true;
    _timer?.cancel();
    () async {
      try {
        await starting;
        await _pumping;
        while (_pending.isNotEmpty && _service != null) {
          await _pump();
        }
        final service = _service;
        if (service != null) {
          try {
            _setStatus(await service.request('stop', _writerId) as Map);
          } catch (e) {
            _report('日志关闭失败：$e');
          }
          _service = null;
          await service.release();
        }
      } catch (e) {
        _report('日志关闭失败：$e');
      } finally {
        _stopping = false;
        _stoppingFuture = null;
        onUpdate?.call();
        done.complete();
      }
    }();
    return done.future;
  }
}

class LogArchive {
  final _services = <String, _ArchiveService>{};
  int _generation = 0;
  bool _closed = false;
  Future<_ArchiveService> _service(
    String directory, {
    LogRecordingOptions? initialOptions,
  }) async {
    if (_closed) throw StateError('日志归档已关闭');
    final key = Directory(directory).absolute.path;
    if (_services[key] case final existing?) return existing;
    final service = await _ArchiveService.acquire(key, options: initialOptions);
    if (_closed) {
      await service.release();
      throw StateError('日志归档已关闭');
    }
    // Concurrent reads must retain the directory only once.
    if (_services[key] case final existing?) {
      await service.release();
      return existing;
    }
    _services[key] = service;
    return service;
  }

  Future<Map<String, String>> sessions(String directory) async =>
      Map<String, String>.from(
        await (await _service(directory)).request('sessions') as Map,
      );
  Future<Map<String, int>> usage(String directory) async =>
      Map<String, int>.from(
        await (await _service(directory)).request('usage') as Map,
      );
  Future<List<LogArchiveFile>> listFiles(String directory) async =>
      ((await (await _service(directory)).request('list')) as List)
          .map((e) => LogArchiveFile.fromJson(Map<String, dynamic>.from(e)))
          .toList();
  Future<LogSearchPage> search(LogSearchQuery query) async {
    final token = ++_generation;
    final service = await _service(query.directory);
    if (token != _generation) return const LogSearchPage(cancelled: true);
    final requestId = newId();
    final result = await service.request('search', {
      ...query.toJson(),
      'requestId': requestId,
      'owner': identityHashCode(this).toString(),
    }) as Map;
    if (token != _generation) return const LogSearchPage(cancelled: true);
    return LogSearchPage(
      hits: (result['hits'] as List)
          .map((e) => LogArchiveHit.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      nextCursor: result['nextCursor'] as String? ?? '',
      cancelled: result['cancelled'] == true,
      warnings: (result['warnings'] as List? ?? []).cast<String>(),
    );
  }

  void cancel() {
    ++_generation;
    for (final service in _services.values) {
      unawaited(service.request('cancel', identityHashCode(this).toString()));
    }
  }

  Future<Map<String, dynamic>> readRecord(LogArchiveHit hit) async =>
      Map<String, dynamic>.from(
        await (await _service(File(hit.filePath).parent.path))
                .request('read', hit.toJson())
            as Map,
      );
  Future<List<String>> rebuild(
    String directory, {
    LogRecordingOptions? options,
  }) async => (await (await _service(
    directory,
    initialOptions: options,
  )).request('rebuild', options?.toJson()) as List).cast<String>();
  Future<void> close() async {
    _closed = true;
    cancel();
    final services = _services.values.toList();
    _services.clear();
    for (final service in services) {
      await service.release();
    }
  }
}

class _ArchiveService {
  static final _workers = <String, Future<_ArchiveService>>{};
  final String directory;
  final ReceivePort _replies = ReceivePort();
  final _pending = <int, Completer<dynamic>>{};
  late SendPort _worker;
  int _id = 0, _references = 0;
  Future<void>? _closing;
  _ArchiveService(this.directory);
  static Future<_ArchiveService> acquire(
    String path, {
    LogRecordingOptions? options,
  }) async {
    final key = await Isolate.run(() {
      final folder = Directory(path)..createSync(recursive: true);
      return folder.resolveSymbolicLinksSync();
    });
    final pending = _workers.putIfAbsent(key, () async {
      final service = _ArchiveService(key);
      final ready = Completer<void>();
      service._replies.listen((dynamic message) {
        final values = message as List;
        if (values[0] == 0) {
          if (values[1] == true) {
            service._worker = values[2] as SendPort;
            ready.complete();
          } else {
            ready.completeError(StateError(values[2] as String));
          }
          return;
        }
        final completion = service._pending.remove(values[0]);
        if (completion == null) return;
        if (values[1] == true) {
          completion.complete(values[2]);
        } else {
          completion.completeError(StateError(values[2] as String));
        }
      });
      try {
        await Isolate.spawn(_archiveWorker, [
          service._replies.sendPort,
          key,
          options?.toJson(),
        ]);
        await ready.future;
        return service;
      } catch (_) {
        service._replies.close();
        rethrow;
      }
    });
    try {
      final service = await pending;
      if (service._closing != null) {
        await service._closing;
        return await acquire(key, options: options);
      }
      service._references++;
      return service;
    } catch (_) {
      _workers.remove(key);
      rethrow;
    }
  }

  Future<dynamic> request(String action, [dynamic value]) {
    final id = ++_id, done = Completer<dynamic>();
    _pending[id] = done;
    _worker.send([id, action, value]);
    return done.future;
  }

  Future<void> release() async {
    if (--_references > 0) return;
    final done = Completer<void>();
    _closing = done.future;
    try {
      await request('close');
    } finally {
      _workers.remove(directory);
      for (final pending in _pending.values) {
        pending.completeError(StateError('日志任务已关闭'));
      }
      _pending.clear();
      _replies.close();
      done.complete();
    }
  }
}

void _archiveWorker(List<dynamic> arguments) {
  final output = arguments[0] as SendPort, input = ReceivePort();
  late _ArchiveDirectory archive;
  try {
    archive = _ArchiveDirectory(
      arguments[1] as String,
      initialOptions: arguments.length > 2 && arguments[2] != null
          ? LogRecordingOptions.fromJson(
              Map<String, dynamic>.from(arguments[2]),
            )
          : null,
    );
    output.send([0, true, input.sendPort]);
  } catch (e) {
    output.send([0, false, '$e']);
    input.close();
    return;
  }
  final searches = <String, int>{};
  final activeSearches = <Future<void>>{};
  final pendingAppends = <({int id, Map<String, dynamic> value})>[];
  var pendingRecords = 0, pendingBytes = 0;
  Timer? appendTimer;
  void flushAppends() {
    appendTimer?.cancel();
    appendTimer = null;
    if (pendingAppends.isEmpty) return;
    final requests = pendingAppends.toList(growable: false);
    pendingAppends.clear();
    pendingRecords = pendingBytes = 0;
    try {
      final entries = <dynamic>[
        for (final request in requests) ...request.value['entries'] as List,
      ];
      // All writers were validated on admission; every non-append operation is
      // a barrier, so none can stop or change options inside this durable batch.
      final result = archive.append({
        'writerId': requests.first.value['writerId'],
        'entries': entries,
      });
      final error = result['error'];
      final accepted = error == null
          ? entries.length
          : entries.length - (result['unsaved'] as int? ?? entries.length);
      var before = 0;
      for (final request in requests) {
        final count = (request.value['entries'] as List).length;
        final committed = (accepted - before).clamp(0, count);
        final response = Map<String, dynamic>.of(result)
          ..remove('error')
          ..remove('unsaved');
        if (error != null && committed < count) {
          response['error'] = error;
          response['unsaved'] = count - committed;
        }
        // archive.append returns only after raw flush + FULL index COMMIT. Each
        // request gets its own confirmed prefix, never another writer's count.
        output.send([request.id, true, response]);
        before += count;
      }
    } catch (e) {
      for (final request in requests) {
        output.send([request.id, false, '$e']);
      }
    }
  }

  void queueAppend(int id, Map<String, dynamic> value) {
    if (!archive.writers.contains(value['writerId'])) {
      throw StateError('记录任务已停止');
    }
    final entries = value['entries'] as List;
    if (entries.isEmpty) {
      output.send([id, true, archive.status]);
      return;
    }
    var bytes = 0;
    for (final raw in entries) {
      final entry = raw as Map;
      final data = entry['bytes'];
      bytes +=
          (data is List
              ? data.length
              : (entry['hex'] as String? ?? '').length) +
          (entry['message'] as String? ?? '').length * 2 +
          (entry['endpoint'] as String? ?? '').length * 2 +
          256;
    }
    if (pendingAppends.isNotEmpty &&
        (pendingRecords + entries.length > 128 ||
            pendingBytes + bytes > 256 * 1024)) {
      flushAppends();
    }
    pendingAppends.add((id: id, value: value));
    pendingRecords += entries.length;
    pendingBytes += bytes;
    // An individual ingress request is already recorder-bounded. Oversized
    // single requests flush immediately instead of extending the pending queue.
    if (pendingRecords >= 128 || pendingBytes >= 256 * 1024) {
      flushAppends();
    } else {
      appendTimer ??= Timer(const Duration(milliseconds: 50), flushAppends);
    }
  }

  input.listen((dynamic raw) {
    final id = raw[0] as int, action = raw[1] as String, value = raw[2];
    void reply(dynamic data) => output.send([id, true, data]);
    try {
      // Preserve request ordering and drain pending durable writes before stop,
      // close, maintenance, visibility queries or any writer/options changes.
      if (action != 'append') flushAppends();
      switch (action) {
        case 'start':
          reply(archive.start(Map<String, dynamic>.from(value)));
          break;
        case 'append':
          queueAppend(id, Map<String, dynamic>.from(value));
          break;
        case 'stop':
          reply(archive.stop(value as String));
          break;
        case 'sessions':
          reply(archive.sessions);
          break;
        case 'usage':
          reply(archive.usage);
          break;
        case 'list':
          archive.reconcile();
          reply(archive.listFiles());
          break;
        case 'read':
          reply(archive.read(Map<String, dynamic>.from(value)));
          break;
        case 'rebuild':
          for (final owner in searches.keys.toList()) {
            searches[owner] = searches[owner]! + 1;
          }
          if (value != null) {
            archive.setMaintenanceOptions(Map<String, dynamic>.from(value));
          }
          reply(archive.reconcile(force: true));
          break;
        case 'cancel':
          searches[value as String] = (searches[value] ?? 0) + 1;
          reply(null);
          break;
        case 'search':
          final query = Map<String, dynamic>.from(value);
          final owner = query['owner'] as String;
          final generation = (searches[owner] ?? 0) + 1;
          searches[owner] = generation;
          late Future<void> running;
          running = archive
              .search(query, () => searches[owner] != generation)
              .then<void>(
                reply,
                onError: (Object e, StackTrace _) =>
                    output.send([id, false, '$e']),
              );
          activeSearches.add(running);
          unawaited(running.whenComplete(() => activeSearches.remove(running)));
          break;
        case 'close':
          for (final owner in searches.keys.toList()) {
            searches[owner] = searches[owner]! + 1;
          }
          Object? failure;
          try {
            archive.close();
          } catch (e) {
            failure = e;
          }
          // Deliver outstanding search cancellations before closing the reply
          // port. A disposing search view must never leave a pending Future.
          unawaited(
            Future.wait(activeSearches.toList()).whenComplete(() {
              if (failure == null) {
                reply(null);
              } else {
                output.send([id, false, '$failure']);
              }
              input.close();
            }),
          );
          break;
        default:
          throw StateError('未知日志操作：$action');
      }
    } catch (e) {
      output.send([id, false, '$e']);
    }
  });
}

class _FutureArchiveVersion implements Exception {
  @override
  String toString() => '日志索引版本高于当前应用，未修改数据';
}

class _ArchiveMigrationBlocked implements Exception {
  @override
  String toString() => '日志索引升级空间不足，原索引和日志未修改；请提高目录占用限制';
}

class _ArchiveDirectory {
  final String directory;
  late final File _manifest;
  late final String _dbPath;
  late Database db;
  late String archiveId;
  List<Map<String, dynamic>> files = [];
  final writers = <String>{};
  LogRecordingOptions options = const LogRecordingOptions();
  RandomAccessFile? _output;
  Map<String, dynamic>? _current;
  bool _closed = false;
  int _recordCount = 0, _appendTransactions = 0;
  bool _indexBlocked = false;
  RandomAccessFile? _lock;
  final warnings = <String>[];
  final _openingWarnings = <String>[];
  _ArchiveDirectory(this.directory, {LogRecordingOptions? initialOptions}) {
    Directory(directory).createSync(recursive: true);
    _guardMetadata();
    _lock = File('$directory/.portly-archive.lock')
        .openSync(mode: FileMode.append);
    try {
      _lock!.lockSync(FileLock.exclusive);
    } catch (_) {
      _lock!.closeSync();
      _lock = null;
      throw StateError('日志目录正在被另一个进程使用');
    }
    try {
      _manifest = File('$directory/.portly-archive.json');
      _dbPath = '$directory/.portly-index.sqlite';
      if (_manifest.existsSync()) {
        final data = jsonDecode(_manifest.readAsStringSync()) as Map;
        if (data['format'] != 'portly.log-archive' || data['version'] != 1) {
          throw StateError('日志目录清单版本不兼容，未修改现有文件');
        }
        archiveId = data['archiveId'] as String;
        if (data['options'] is Map) {
          options = LogRecordingOptions.fromJson(
            Map<String, dynamic>.from(data['options']),
          );
        }
        files = (data['files'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        for (final file in files) {
          if (!_safeName(file['name'] as String)) {
            throw StateError('日志目录清单包含无效文件名');
          }
          if (file['state'] == 'active') file['state'] = 'closed';
        }
      } else {
        archiveId = newId();
        _saveManifest();
      }
      if (initialOptions != null) {
        initialOptions.validate();
        options = initialOptions.copy(directory: directory);
      }
      try {
        _openDb();
      } catch (e) {
        try {
          db.close();
        } catch (_) {}
        if (e is _FutureArchiveVersion || e is _ArchiveMigrationBlocked) {
          rethrow;
        }
        final broken = File(_dbPath);
        if (broken.existsSync()) {
          broken.renameSync(
            '$_dbPath.corrupt-${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        _openDb();
        warnings.add('索引损坏，已保留原文件并重建：$e');
      }
      reconcile();
      _recordCount =
          db.select('SELECT COUNT(*) AS n FROM records').first['n'] as int;
    } catch (_) {
      try {
        db.close();
      } catch (_) {}
      try {
        _lock?.unlockSync();
        _lock?.closeSync();
      } catch (_) {}
      _lock = null;
      rethrow;
    }
  }
  bool _safeName(String name) =>
      RegExp(r'^[A-Za-z0-9_-]+\.ndjson$').hasMatch(name) &&
      name.contains('-$archiveId-');
  void _openDb() {
    _guardMetadata();
    if (!File(_dbPath).existsSync() &&
        _diskBytes + 128 * 1024 > options.maxTotalBytes) {
      throw StateError('索引修复空间不足：已保留日志和现有索引，请提高目录占用限制');
    }
    db = sqlite3.open(_dbPath);
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 3) throw _FutureArchiveVersion();
    final hasRecords = db
        .select(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name='records'",
        )
        .isNotEmpty;
    if (version < 3 && hasRecords) {
      // Close/checkpoint the supported old index before moving its complete
      // image to a unique backup. Authoritative NDJSON files are never touched.
      // Renaming preserves the old index without doubling existing disk usage;
      // the retained backup still counts against the archive's quota.
      if (_diskBytes + 128 * 1024 > options.maxTotalBytes) {
        throw _ArchiveMigrationBlocked();
      }
      db.execute('PRAGMA wal_checkpoint(FULL)');
      db.close();
      final backup =
          '$_dbPath.schema$version-backup-${DateTime.now().microsecondsSinceEpoch}-${newId()}';
      File(_dbPath).renameSync(backup);
      _openingWarnings.add('日志索引已升级为版本 3，原索引备份：$backup');
      _openDb();
      return;
    }
    if (version == 3) {
      final tables = db.select(
        "SELECT name FROM sqlite_master WHERE name IN ('record_search','record_text_search','record_tokens') AND type='table'",
      );
      if (tables.length != 3) {
        throw const FormatException('日志索引缺少搜索表');
      }
    }
    db.execute('PRAGMA journal_mode=DELETE');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('PRAGMA auto_vacuum=INCREMENTAL');
    db.execute('PRAGMA busy_timeout=3000');
    db.execute(
      'CREATE TABLE IF NOT EXISTS files(name TEXT PRIMARY KEY,bytes INTEGER NOT NULL DEFAULT 0,mtime INTEGER NOT NULL DEFAULT 0,state TEXT NOT NULL DEFAULT "closed")',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS records(id INTEGER PRIMARY KEY AUTOINCREMENT,file TEXT NOT NULL,offset INTEGER NOT NULL,length INTEGER NOT NULL,recordId TEXT NOT NULL,time INTEGER NOT NULL,sessionId TEXT NOT NULL,sessionName TEXT NOT NULL,runtimeId TEXT NOT NULL,direction TEXT NOT NULL,endpoint TEXT NOT NULL,preview TEXT NOT NULL,UNIQUE(file,offset))',
    );
    db.execute('CREATE INDEX IF NOT EXISTS record_time ON records(time,id)');
    db.execute(
      'CREATE INDEX IF NOT EXISTS record_session_time ON records(sessionId,time,id)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS record_direction_time ON records(direction,time,id)',
    );
    db.execute('CREATE INDEX IF NOT EXISTS record_file ON records(file,id)');
    // Trigrams are appropriate for substring bodies, but not for synthetic
    // bXX/uXXXXXX/vXXXXXXXXXXXX keys: trigramming those keys multiplied both
    // postings and position lists. Exact tokens use a separate, position-free
    // index. Prefixes make byte / one-rune / two-rune namespaces disjoint.
    db.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS record_search USING fts5(hex,content='',contentless_delete=1,detail=none,tokenize='trigram')",
    );
    db.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS record_text_search USING fts5(text,content='',contentless_delete=1,detail=none,tokenize='trigram')",
    );
    db.execute(
      "CREATE VIRTUAL TABLE IF NOT EXISTS record_tokens USING fts5(terms,content='',contentless_delete=1,detail=none,tokenize='ascii')",
    );
    db.execute('PRAGMA user_version=3');
  }

  void _guardMetadata() {
    for (final name in [
      '.portly-archive.lock',
      '.portly-archive.json',
      '.portly-archive.json.tmp',
      '.portly-index.sqlite',
      '.portly-index.sqlite-journal',
      '.portly-index.sqlite-wal',
      '.portly-index.sqlite-shm',
    ]) {
      final type = FileSystemEntity.typeSync(
        '$directory/$name',
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw StateError('日志元数据路径不是普通文件，未修改：$name');
      }
    }
  }

  void _saveManifest() {
    _guardMetadata();
    final temporary = File('${_manifest.path}.tmp');
    temporary.writeAsStringSync(
      jsonEncode({
        'format': 'portly.log-archive',
        'version': 1,
        'archiveId': archiveId,
        'options': options.toJson(),
        'files': files,
      }),
      flush: true,
    );
    temporary.renameSync(_manifest.path);
  }

  Map<String, String> get sessions => {
    for (final row in db.select(
      'SELECT sessionId,MAX(sessionName) AS name FROM records GROUP BY sessionId',
    ))
      if ((row['sessionId'] as String).isNotEmpty)
        row['sessionId'] as String: row['name'] as String,
  };
  Map<String, int> get usage {
    var logBytes = 0, indexBytes = 0, count = 0;
    final managed = files.map((f) => f['name']).toSet();
    for (final entry in Directory(directory).listSync(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (managed.contains(name)) {
        logBytes += entry.lengthSync();
        count++;
      } else if (name.startsWith('.portly-index.sqlite') ||
          name.startsWith('.portly-archive.')) {
        indexBytes += entry.lengthSync();
      }
    }
    return {
      'logBytes': logBytes,
      'indexBytes': indexBytes,
      'totalBytes': logBytes + indexBytes,
      'appendTransactions': _appendTransactions,
      'files': count,
    };
  }

  int get _diskBytes {
    var total = 0;
    for (final entry in Directory(directory).listSync(followLinks: false)) {
      if (entry is! File) continue;
      final name = entry.uri.pathSegments.last;
      if (name.startsWith('.portly-index.sqlite') ||
          name.startsWith('.portly-archive.') ||
          files.any((f) => f['name'] == name)) {
        total += entry.lengthSync();
      }
    }
    return total;
  }

  Map<String, dynamic> get status => {
    'path': _current == null
        ? '$directory/'
        : '$directory/${_current!['name']}',
    'records': _recordCount,
    'bytes': _diskBytes,
    'files': files.where((f) => f['state'] != 'missing').length,
  };
  Map<String, dynamic> start(Map<String, dynamic> value) {
    final requested = LogRecordingOptions.fromJson(
      Map<String, dynamic>.from(value['options']),
    );
    requested.validate();
    if (writers.isNotEmpty) {
      final a = options.toJson()
        ..remove('directory')
        ..remove('maxQueueRecords')
        ..remove('maxQueueBytes');
      final b = requested.toJson()
        ..remove('directory')
        ..remove('maxQueueRecords')
        ..remove('maxQueueBytes');
      if (jsonEncode(a) != jsonEncode(b)) {
        throw StateError('该目录已有记录任务，请使用相同轮转和占用限制');
      }
    }
    options = requested.copy(directory: directory);
    reconcile();
    _saveManifest();
    if (_diskBytes + 65536 >= options.maxTotalBytes) {
      if (!options.overwriteOldest) throw StateError('日志目录已达到磁盘占用限制（包含索引）');
      _makeRoom(65536);
    }
    writers.add(value['writerId'] as String);
    return status;
  }

  void _closeCurrent() {
    final output = _output, current = _current;
    _output = null;
    _current = null;
    Object? failure;
    try {
      output?.flushSync();
    } catch (e) {
      failure = e;
    }
    try {
      output?.closeSync();
    } catch (e) {
      failure ??= e;
    }
    if (current != null) {
      current['state'] = 'closed';
      try {
        db.execute('UPDATE files SET state=? WHERE name=?', [
          'closed',
          current['name'],
        ]);
        _saveManifest();
      } catch (e) {
        failure ??= e;
      }
    }
    if (failure != null) throw StateError('关闭日志文件失败：$failure');
  }

  bool _owned(Map<String, dynamic> info) {
    final name = info['name'] as String, path = '$directory/$name';
    if (!_safeName(name) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    final file = File(path), reader = file.openSync();
    try {
      final buffer = BytesBuilder(copy: false);
      while (buffer.length < 16 * 1024 * 1024) {
        final next = reader.readSync(64 * 1024);
        if (next.isEmpty) break;
        final end = next.indexOf(10);
        buffer.add(end < 0 ? next : next.sublist(0, end));
        if (end >= 0) break;
      }
      final first = jsonDecode(utf8.decode(buffer.takeBytes())) as Map;
      return first['format'] == 'portly.log' && first['archiveId'] == archiveId;
    } catch (_) {
      return false;
    } finally {
      reader.closeSync();
    }
  }

  void _removeOldest() {
    final candidates = files
        .where(
          (f) =>
              f != _current &&
              f['state'] != 'active' &&
              f['state'] != 'missing',
        )
        .toList();
    if (candidates.isEmpty) throw StateError('日志已达到占用限制，没有可淘汰的已关闭文件');
    final oldest = candidates.first;
    if (!_owned(oldest)) throw StateError('最早日志文件的归属校验失败，已停止记录且未删除文件');
    if (!_maintenanceBudget()) throw StateError('清理索引所需空间不足，未删除日志；请提高目录占用限制');
    // Contentless-delete FTS marks row ids without reading or decoding the old
    // file body. Keep ids bounded even when a 100 MiB file has many tiny frames.
    final name = oldest['name'] as String;
    var deleted = 0;
    db.execute('BEGIN IMMEDIATE');
    try {
      var after = 0;
      while (true) {
        final rows = db.select(
          'SELECT id FROM records WHERE file=? AND id>? ORDER BY id LIMIT 128',
          [name, after],
        );
        if (rows.isEmpty) break;
        final ids = rows.map((r) => r['id'] as int).toList();
        deleted += ids.length;
        after = ids.last;
        db.execute(
          'DELETE FROM record_search WHERE rowid IN (${List.filled(ids.length, '?').join(',')})',
          ids,
        );
        db.execute(
          'DELETE FROM record_text_search WHERE rowid IN (${List.filled(ids.length, '?').join(',')})',
          ids,
        );
        db.execute(
          'DELETE FROM record_tokens WHERE rowid IN (${List.filled(ids.length, '?').join(',')})',
          ids,
        );
      }
      db.execute('DELETE FROM records WHERE file=?', [name]);
      db.execute('DELETE FROM files WHERE name=?', [name]);
      db.execute('COMMIT');
    } catch (_) {
      _rollback();
      rethrow;
    }
    _recordCount -= deleted;
    File('$directory/$name').deleteSync();
    files.remove(oldest);
    _saveManifest();
    db.execute('PRAGMA incremental_vacuum(256)');
  }

  void _makeRoom(int reserve, {bool newFile = false}) {
    if (reserve > options.maxTotalBytes) {
      throw StateError('单批日志及索引安全余量超过磁盘占用限制，记录已停止');
    }
    while ((newFile &&
            files.where((f) => f['state'] != 'missing').length >=
                options.maxFiles) ||
        _diskBytes + reserve > options.maxTotalBytes) {
      if (!options.overwriteOldest) {
        throw StateError(
          newFile &&
                  files.where((f) => f['state'] != 'missing').length >=
                      options.maxFiles
              ? '已达到日志文件数量上限，记录已停止'
              : '已达到日志磁盘占用限制（包含索引），记录已停止',
        );
      }
      _removeOldest();
    }
  }

  void _newFile(int reserve) {
    _closeCurrent();
    _makeRoom(reserve, newFile: true);
    final name =
        '${options.baseName}-$archiveId-${DateTime.now().microsecondsSinceEpoch}-${newId()}.ndjson';
    // create exclusively; a preexisting arbitrary file can never be appended.
    final file = File('$directory/$name');
    file.createSync(exclusive: true);
    _output = file.openSync(mode: FileMode.writeOnlyAppend);
    _current = {'name': name, 'state': 'active'};
    files.add(_current!);
    _saveManifest();
    db.execute('INSERT INTO files(name,bytes,mtime,state) VALUES(?,0,0,?)', [
      name,
      'active',
    ]);
  }

  Map<String, dynamic> _canonical(Map<String, dynamic> input) {
    final raw = input['bytes'];
    late String encoded;
    if (raw is List<int>) {
      encoded = raw
          .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
          .join(' ');
    } else {
      final compact = (input['hex'] as String? ?? '')
          .replaceAll(RegExp(r'\s+'), '')
          .toUpperCase();
      if (!RegExp(r'^(?:[0-9A-F]{2})*$').hasMatch(compact)) {
        throw const FormatException('日志 HEX 数据无效');
      }
      encoded = List.generate(
        compact.length ~/ 2,
        (i) => compact.substring(i * 2, i * 2 + 2),
      ).join(' ');
    }
    final inputTime = input['time'];
    final time = inputTime is int
        ? DateTime.fromMillisecondsSinceEpoch(inputTime, isUtc: true)
        : DateTime.parse(inputTime as String).toUtc();
    return {
      'format': 'portly.log',
      'schemaVersion': 1,
      'archiveId': archiveId,
      'id': input['id'] ?? newId(),
      'time': time.toIso8601String(),
      'utcOffsetMinutes': input['utcOffsetMinutes'] ?? 0,
      'sessionId': input['sessionId'] ?? '',
      'sessionName': input['sessionName'] ?? '',
      'runtimeId': input['runtimeId'] ?? '',
      'direction': input['direction'] ?? 'SYS',
      'sequence': input['sequence'] ?? 0,
      'endpoint': input['endpoint'] ?? '',
      'hex': encoded,
      'message': input['message'] ?? '',
    };
  }

  String _textBody(Map<String, dynamic> record) {
    if (record['direction'] == 'SYS') {
      return (record['message'] as String).toLowerCase();
    }
    final compact = (record['hex'] as String).replaceAll(' ', '');
    final raw = Uint8List.fromList(
      List.generate(
        compact.length ~/ 2,
        (i) => int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
    return utf8.decode(raw, allowMalformed: true).toLowerCase();
  }

  List<String> _searchFields(Map<String, dynamic> record) {
    for (final field in [
      'id',
      'time',
      'sessionId',
      'sessionName',
      'runtimeId',
      'direction',
      'endpoint',
      'hex',
      'message',
    ]) {
      if (record[field] is! String) throw FormatException('日志字段无效：$field');
    }
    final compact = (record['hex'] as String).replaceAll(' ', '').toLowerCase();
    if (!RegExp(r'^(?:[0-9a-f]{2})*$').hasMatch(compact)) {
      throw const FormatException('日志HEX字段无效');
    }
    final bytes = Uint8List.fromList(
      List.generate(
        compact.length ~/ 2,
        (i) => int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
    final text =
        (record['direction'] == 'SYS'
                ? record['message'] as String
                : utf8.decode(bytes, allowMalformed: true))
            .toLowerCase();
    final pairs = <String>{};
    for (var i = 0; i < compact.length; i += 2) {
      pairs.add('b${compact.substring(i, i + 2)}');
    }
    final runes = text.runes.toList(), short = <String>{};
    String key(int r) => r.toRadixString(16).padLeft(6, '0');
    for (var i = 0; i < runes.length; i++) {
      short.add('u${key(runes[i])}');
      if (i + 1 < runes.length) {
        short.add('v${key(runes[i])}${key(runes[i + 1])}');
      }
    }
    return [compact, text, pairs.join(' '), short.join(' ')];
  }

  void _index(
    Map<String, dynamic> record,
    String name,
    int offset,
    int length,
  ) {
    final fields = _searchFields(record);
    db.execute(
      'INSERT INTO records(file,offset,length,recordId,time,sessionId,sessionName,runtimeId,direction,endpoint,preview) VALUES(?,?,?,?,?,?,?,?,?,?,?)',
      [
        name,
        offset,
        length,
        record['id'],
        DateTime.parse(record['time'] as String).millisecondsSinceEpoch,
        record['sessionId'],
        record['sessionName'],
        record['runtimeId'],
        record['direction'],
        record['endpoint'],
        (record['direction'] == 'SYS'
                ? record['message'] as String
                : record['hex'] as String)
            .substring(
              0,
              (record['direction'] == 'SYS'
                      ? record['message'] as String
                      : record['hex'] as String)
                  .length
                  .clamp(0, 160),
            ),
      ],
    );
    final rowId = db.lastInsertRowId;
    db.execute('INSERT INTO record_search(rowid,hex) VALUES(?,?)', [
      rowId,
      fields[0],
    ]);
    db.execute('INSERT INTO record_text_search(rowid,text) VALUES(?,?)', [
      rowId,
      fields[1],
    ]);
    db.execute('INSERT INTO record_tokens(rowid,terms) VALUES(?,?)', [
      rowId,
      '${fields[2]} ${fields[3]}',
    ]);
  }

  Map<String, dynamic> append(Map<String, dynamic> value) {
    if (!writers.contains(value['writerId'])) throw StateError('记录任务已停止');
    final entries = (value['entries'] as List).cast<Map>();
    var accepted = 0;
    while (accepted < entries.length) {
      try {
        final group = <({Map<String, dynamic> record, List<int> bytes})>[];
        var groupBytes = 0;
        final indexBytes = File(_dbPath).lengthSync();
        final headroom = indexBytes > 65536 ? indexBytes : 65536;
        final available = options.overwriteOldest
            ? options.maxTotalBytes - indexBytes - headroom
            : options.maxTotalBytes - _diskBytes - headroom;
        final batchBodyBudget = available > 0 ? available ~/ 32 : 0;
        final remaining = _current == null
            ? options.fileLimitBytes
            : options.fileLimitBytes - _output!.positionSync();
        for (var i = accepted; i < entries.length && group.length < 128; i++) {
          final record = _canonical(Map<String, dynamic>.from(entries[i]));
          final bytes = utf8.encode('${jsonEncode(record)}\n');
          if (bytes.length > options.fileLimitBytes ||
              bytes.length > 16 * 1024 * 1024) {
            if (group.isNotEmpty) break;
            throw StateError('单条日志 ${bytes.length} B 超过单文件限制，记录已停止');
          }
          if (group.isEmpty && bytes.length > remaining) break;
          if (groupBytes + bytes.length > remaining) break;
          if (group.isNotEmpty && groupBytes + bytes.length > batchBodyBudget) {
            break;
          }
          group.add((record: record, bytes: bytes));
          groupBytes += bytes.length;
        }
        if (group.isEmpty) {
          final record = _canonical(
            Map<String, dynamic>.from(entries[accepted]),
          );
          final bytes = utf8.encode('${jsonEncode(record)}\n');
          if (bytes.length > options.fileLimitBytes ||
              bytes.length > 16 * 1024 * 1024) {
            throw StateError('单条日志 ${bytes.length} B 超过单文件限制，记录已停止');
          }
          _newFile(_reserve(bytes.length));
          continue;
        }
        final reserve = _reserve(groupBytes);
        // Use one flush/transaction per bounded IPC batch, never one per packet.
        // Reserve the entire existing index as rollback-journal headroom, plus
        // conservative growth for UTF-8/HEX postings before writing original data.
        _makeRoom(reserve);
        if (_current == null) _newFile(reserve);
        if (!_maintenanceBudget(
          additionalBodyBytes: groupBytes,
          stableLimit: false,
        )) {
          throw StateError('日志索引及事务安全余量达到磁盘占用限制，记录已停止');
        }
        final name = _current!['name'] as String;
        final start = _output!.positionSync();
        final combined = BytesBuilder(copy: false);
        for (final item in group) {
          combined.add(item.bytes);
        }
        _output!.writeFromSync(combined.takeBytes());
        _output!.flushSync();
        db.execute('BEGIN IMMEDIATE');
        try {
          var offset = start;
          for (final item in group) {
            _index(item.record, name, offset, item.bytes.length);
            offset += item.bytes.length;
          }
          db.execute('UPDATE files SET bytes=?,mtime=? WHERE name=?', [
            start + groupBytes,
            File('$directory/$name').lastModifiedSync().microsecondsSinceEpoch,
            name,
          ]);
          db.execute('COMMIT');
        } catch (_) {
          _rollback();
          rethrow;
        }
        accepted += group.length;
        _recordCount += group.length;
        _appendTransactions++;
      } catch (e) {
        return {
          ...status,
          'error': _describeFailure(e),
          'unsaved': entries.length - accepted,
        };
      }
    }
    return status;
  }

  String _describeFailure(Object error) =>
      error is SqliteException && error.resultCode == 13
      ? '日志索引达到磁盘占用限制，原始文件已保留，待增加空间后重建索引'
      : '$error';
  void _rollback() {
    try {
      db.execute('ROLLBACK');
    } catch (_) {}
  }

  int _reserve(int bodyBytes) {
    final indexBytes = File(_dbPath).lengthSync();
    return bodyBytes * 32 + (indexBytes > 65536 ? indexBytes : 65536);
  }

  Map<String, dynamic> stop(String writer) {
    writers.remove(writer);
    if (writers.isEmpty) _closeCurrent();
    return status;
  }

  Map<String, dynamic> _readAt(String name, int offset, int length) {
    if (!_safeName(name)) throw StateError('文件不属于此日志归档');
    final path = '$directory/$name';
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('日志文件已移走或不可用');
    }
    final input = File(path).openSync();
    try {
      if (offset < 0 ||
          length < 1 ||
          length > 16 * 1024 * 1024 ||
          offset + length > input.lengthSync()) {
        throw StateError('日志文件已截断，原记录不完整');
      }
      input.setPositionSync(offset);
      final raw = input.readSync(length);
      if (raw.length != length || raw.last != 10) throw StateError('日志记录不完整');
      final record = Map<String, dynamic>.from(
        jsonDecode(utf8.decode(raw)) as Map,
      );
      if (record['format'] != 'portly.log' ||
          record['archiveId'] != archiveId) {
        throw StateError('日志文件归属校验失败');
      }
      return record;
    } finally {
      input.closeSync();
    }
  }

  Map<String, dynamic> read(Map<String, dynamic> hit) {
    final expectedDirectory = File(hit['filePath'] as String)
        .parent
        .absolute
        .path;
    if (expectedDirectory != Directory(directory).absolute.path) {
      throw StateError('日志文件不在此归档目录');
    }
    final name = File(hit['filePath'] as String).uri.pathSegments.last;
    final record = _readAt(name, hit['offset'] as int, hit['length'] as int);
    if (record['id'] != hit['recordId']) throw StateError('日志文件已改变，请重建索引后重新搜索');
    return record;
  }

  Iterable<
    ({Map<String, dynamic>? record, int offset, int length, String error})
  >
  _scan(String name) sync* {
    final input = File('$directory/$name').openSync();
    var offset = 0, start = 0, invalid = false;
    var line = BytesBuilder(copy: false);
    try {
      while (true) {
        final chunk = input.readSync(64 * 1024);
        if (chunk.isEmpty) break;
        var segment = 0;
        for (var i = 0; i < chunk.length; i++) {
          if (chunk[i] != 10) continue;
          if (!invalid) line.add(chunk.sublist(segment, i));
          final length = offset + i + 1 - start;
          if (invalid || line.length > 16 * 1024 * 1024) {
            yield (record: null, offset: start, length: length, error: '过长记录');
          } else {
            try {
              final value = Map<String, dynamic>.from(
                jsonDecode(utf8.decode(line.takeBytes())) as Map,
              );
              if (value['format'] != 'portly.log' ||
                  value['archiveId'] != archiveId) {
                throw const FormatException('归属无效');
              }
              // Validate all required fields and byte body before indexing.
              _searchFields(value);
              DateTime.parse(value['time'] as String);
              yield (record: value, offset: start, length: length, error: '');
            } catch (e) {
              yield (
                record: null,
                offset: start,
                length: length,
                error: '无效记录：$e',
              );
            }
          }
          line = BytesBuilder(copy: false);
          invalid = false;
          start = offset + i + 1;
          segment = i + 1;
        }
        if (!invalid) {
          line.add(chunk.sublist(segment));
          if (line.length > 16 * 1024 * 1024) {
            line = BytesBuilder(copy: false);
            invalid = true;
          }
        }
        offset += chunk.length;
      }
      if (offset > start) {
        yield (
          record: null,
          offset: start,
          length: offset - start,
          error: '末尾记录截断',
        );
      }
    } finally {
      input.closeSync();
    }
  }

  void setMaintenanceOptions(Map<String, dynamic> value) {
    if (writers.isNotEmpty) throw StateError('请先停止该目录的文件记录，再重建索引');
    final next = LogRecordingOptions.fromJson(value);
    next.validate();
    options = next.copy(directory: directory);
    _indexBlocked = false;
    _saveManifest();
  }

  bool _maintenanceBudget({
    int additionalBodyBytes = 0,
    bool stableLimit = true,
  }) {
    _guardMetadata();
    final current = File(_dbPath).lengthSync();
    final other = _diskBytes - current + additionalBodyBytes;
    // During a SQLite rollback transaction both the DB and its old pages may
    // occupy disk. max_page_count is a second hard bound on index growth.
    final allowed = stableLimit
        ? (options.maxTotalBytes - other - 65536) ~/ 2
        : options.maxTotalBytes - other - current - 65536;
    if (allowed < current || allowed < 65536) return false;
    final pageSize = db.select('PRAGMA page_size').first.values.first as int;
    db.execute('PRAGMA max_page_count=${allowed ~/ pageSize}');
    return true;
  }

  List<String> reconcile({bool force = false}) {
    if (_closed) return [];
    if (_indexBlocked && !force) return warnings.toList();
    if (force && writers.isNotEmpty) throw StateError('请先停止该目录的文件记录，再重建索引');
    final changes = <String>[..._openingWarnings];
    var changed = force;
    for (final info in files) {
      final name = info['name'] as String;
      if (info == _current) continue;
      final file = File('$directory/$name');
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      final rows = db.select('SELECT bytes,mtime FROM files WHERE name=?', [
        name,
      ]);
      if (type != FileSystemEntityType.file) {
        if (info['state'] != 'missing' || rows.isNotEmpty) changed = true;
        info['state'] = 'missing';
        changes.add('文件缺失或不可用：$name');
      } else if (rows.isEmpty ||
          rows.first['bytes'] != file.lengthSync() ||
          rows.first['mtime'] !=
              file.lastModifiedSync().microsecondsSinceEpoch) {
        changed = true;
      }
    }
    if (changed && writers.isNotEmpty) {
      changes.add('索引与文件有差异；停止该目录的文件记录后可重建索引');
      warnings
        ..clear()
        ..addAll(changes.take(100));
      return changes;
    }
    if (changed) {
      if (!_maintenanceBudget()) {
        _indexBlocked = true;
        for (final info in files) {
          if (info['state'] != 'missing') info['state'] = 'indexPending';
        }
        changes.add('索引修复空间不足：已保留原日志和现有索引，请提高目录占用限制');
        warnings
          ..clear()
          ..addAll(changes.take(100));
        return changes;
      }
      try {
        // Rebuilding postings from original files also removes references to a
        // truncated/replaced tail without requiring those missing old bytes.
        db.execute('BEGIN IMMEDIATE');
        try {
          db.execute(
            "INSERT INTO record_search(record_search) VALUES('delete-all')",
          );
          db.execute(
            "INSERT INTO record_text_search(record_text_search) VALUES('delete-all')",
          );
          db.execute(
            "INSERT INTO record_tokens(record_tokens) VALUES('delete-all')",
          );
          db.execute('DELETE FROM records');
          db.execute('DELETE FROM files');
          db.execute('COMMIT');
        } catch (_) {
          _rollback();
          rethrow;
        }
        for (final info in files) {
          final name = info['name'] as String, file = File('$directory/$name');
          if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
          var count = 0;
          info['state'] = info == _current ? 'active' : 'closed';
          db.execute('BEGIN IMMEDIATE');
          try {
            for (final line in _scan(name)) {
              if (line.record == null) {
                info['state'] = line.error == '末尾记录截断'
                    ? 'truncated'
                    : 'damaged';
                changes.add('$name @ ${line.offset}：${line.error}');
                continue;
              }
              _index(line.record!, name, line.offset, line.length);
              count++;
              if (count % 128 == 0) {
                db.execute('COMMIT');
                db.execute('BEGIN IMMEDIATE');
              }
            }
            db.execute(
              'INSERT INTO files(name,bytes,mtime,state) VALUES(?,?,?,?)',
              [
                name,
                file.lengthSync(),
                file.lastModifiedSync().microsecondsSinceEpoch,
                info['state'],
              ],
            );
            db.execute('COMMIT');
          } catch (_) {
            _rollback();
            rethrow;
          }
        }
        _recordCount =
            db.select('SELECT COUNT(*) AS n FROM records').first['n'] as int;
        _saveManifest();
      } catch (e) {
        _rollback();
        if (e is! SqliteException || e.resultCode != 13) rethrow;
        _indexBlocked = true;
        _recordCount =
            db.select('SELECT COUNT(*) AS n FROM records').first['n'] as int;
        for (final info in files) {
          if (info['state'] != 'missing') info['state'] = 'indexPending';
        }
        changes.add('索引修复达到磁盘占用限制：原始日志完整保留，请提高上限后重建索引');
        _saveManifest();
      }
    }
    warnings
      ..clear()
      ..addAll(changes.take(100));
    return changes;
  }

  List<Map<String, dynamic>> listFiles() => files.map((info) {
    final name = info['name'] as String;
    final rows = db.select(
      'SELECT COUNT(*) AS n,MIN(time) AS first,MAX(time) AS last,COUNT(DISTINCT sessionId) AS sessions,MIN(sessionId) AS sessionId,MIN(sessionName) AS sessionName FROM records WHERE file=?',
      [name],
    );
    final row = rows.first;
    final file = File('$directory/$name');
    return {
      'path': file.path,
      'bytes':
          FileSystemEntity.typeSync(file.path, followLinks: false) ==
              FileSystemEntityType.file
          ? file.lengthSync()
          : 0,
      'records': row['n'],
      'from': row['first'],
      'to': row['last'],
      'state': info['state'],
      'sessionId': row['sessions'] == 1 ? row['sessionId'] : '',
      'sessionName': row['sessions'] == 1 ? row['sessionName'] : '',
    };
  }).toList();
  Future<Map<String, dynamic>> search(
    Map<String, dynamic> query,
    bool Function() cancelled,
  ) async {
    final token = query['query'] as String;
    if (token.length > 65536) throw const FormatException('搜索内容超过 65536 字符');
    final isHex = query['hex'] == true;
    String needle = token.toLowerCase(), match = '';
    var searchTable = isHex ? 'record_search' : 'record_text_search';
    String key(int r) => r.toRadixString(16).padLeft(6, '0');
    String candidateMatch(String value) {
      // Without per-token positions SQLite cannot run phrase queries. A bounded
      // intersection of three-rune tokens yields an indexed superset instead;
      // the authoritative body below always checks actual order and alignment.
      final runes = value.runes.toList(), grams = <String>{};
      for (var i = 0; i + 2 < runes.length && grams.length < 32; i++) {
        final gram = String.fromCharCodes(runes.sublist(i, i + 3));
        // NUL is not representable inside an FTS query string. Such searches
        // still use an exact encoded rune token, then verify the whole body.
        if (!gram.contains('\u0000')) grams.add(gram);
      }
      if (grams.isEmpty) {
        searchTable = 'record_tokens';
        return '"u${key(runes.first)}"';
      }
      return grams
          .map((gram) => '"${gram.replaceAll('"', '""')}"')
          .join(' AND ');
    }

    if (isHex && token.isNotEmpty) {
      needle = token.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      if (!RegExp(r'^(?:[a-f0-9]{2})+$').hasMatch(needle)) {
        throw const FormatException('HEX 搜索请输入完整字节，例如 01 03');
      }
      if (needle.length == 2) {
        searchTable = 'record_tokens';
        match = '"b$needle"';
      } else {
        match = candidateMatch(needle);
      }
    } else if (token.isNotEmpty) {
      final runes = needle.runes.toList();
      if (runes.length < 3) {
        final short = runes.length == 1
            ? 'u${key(runes.first)}'
            : 'v${key(runes[0])}${key(runes[1])}';
        searchTable = 'record_tokens';
        match = '"$short"';
      } else {
        match = candidateMatch(needle);
      }
    }
    var after = parseArchiveCursor(query['cursor'] as String? ?? '');
    final limit = (query['limit'] as int? ?? 100).clamp(1, 500),
        hits = <Map<String, dynamic>>[];
    final startWarnings = warnings.toList();
    final filters = <String>[], filterArgs = <Object?>[];
    for (final column in ['sessionId', 'direction']) {
      if ((query[column] as String? ?? '').isNotEmpty) {
        filters.add('r.$column=?');
        filterArgs.add(query[column]);
      }
    }
    if ((query['filePath'] as String? ?? '').isNotEmpty) {
      final path = query['filePath'] as String;
      if (File(path).parent.absolute.path !=
          Directory(directory).absolute.path) {
        throw const FormatException('文件不在当前日志目录');
      }
      filters.add('r.file=?');
      filterArgs.add(File(path).uri.pathSegments.last);
    }
    if (query['from'] != null) {
      filters.add('r.time>=?');
      filterArgs.add(query['from']);
    }
    if (query['to'] != null) {
      filters.add('r.time<=?');
      filterArgs.add(query['to']);
    }
    while (hits.length < limit + 1) {
      if (cancelled() || _closed) {
        return {'hits': [], 'nextCursor': '', 'cancelled': true};
      }
      final clauses = <String>[], args = <Object?>[];
      late final int candidateMax;
      late final bool candidatesExhausted;
      if (match.isNotEmpty) {
        // Apply the hard batch bound inside the FTS cursor itself. An unlimited
        // IN(SELECT MATCH...) would materialize every common-token match before
        // the outer LIMIT, growing temporary memory with the whole archive.
        final candidates = db.select(
          'SELECT rowid FROM $searchTable WHERE $searchTable MATCH ? AND rowid>? ORDER BY rowid LIMIT 128',
          [match, after],
        );
        if (candidates.isEmpty) break;
        final ids = candidates.map((row) => row['rowid'] as int).toList();
        candidateMax = ids.last;
        candidatesExhausted = ids.length < 128;
        clauses.add('r.id IN (${List.filled(ids.length, '?').join(',')})');
        args.addAll(ids);
      } else {
        clauses.add('r.id>?');
        args.add(after);
      }
      clauses.addAll(filters);
      args.addAll(filterArgs);
      // Candidate ids are already bounded. Force rowid lookups here so the
      // planner cannot scan/sort an entire session index before applying IN.
      // A query without a body match retains normal metadata index planning.
      final source = match.isEmpty ? 'records r' : 'records r NOT INDEXED';
      final rows = db.select(
        'SELECT r.* FROM $source WHERE ${clauses.join(' AND ')} ORDER BY r.id LIMIT 128',
        args,
      );
      if (match.isEmpty) {
        if (rows.isEmpty) break;
        candidateMax = rows.last['id'] as int;
        candidatesExhausted = rows.length < 128;
      }
      for (final row in rows) {
        if (cancelled()) {
          return {'hits': [], 'nextCursor': '', 'cancelled': true};
        }
        after = row['id'] as int;
        try {
          final record = _readAt(
            row['file'] as String,
            row['offset'] as int,
            row['length'] as int,
          );
          if (record['id'] != row['recordId']) throw StateError('文件内容已变更');
          if (needle.isNotEmpty) {
            if (isHex) {
              final body = (record['hex'] as String)
                  .replaceAll(' ', '')
                  .toLowerCase();
              var at = body.indexOf(needle), valid = false;
              while (at >= 0) {
                if (at.isEven) {
                  valid = true;
                  break;
                }
                at = body.indexOf(needle, at + 1);
              }
              if (!valid) continue;
            } else if (!_textBody(record).contains(needle)) {
              continue;
            }
          }
          hits.add({
            'filePath': '$directory/${row['file']}',
            'offset': row['offset'],
            'length': row['length'],
            'recordId': row['recordId'],
            'sessionId': row['sessionId'],
            'sessionName': row['sessionName'],
            'runtimeId': row['runtimeId'],
            'time': row['time'],
            'direction': row['direction'],
            'endpoint': row['endpoint'],
            'preview': row['preview'],
            '_id': row['id'],
          });
          if (hits.length >= limit + 1) break;
        } catch (e) {
          if (startWarnings.length < 100) {
            startWarnings.add('${row['file']} @ ${row['offset']}：$e');
          }
        }
      }
      if (hits.length >= limit + 1) break;
      // Metadata may reject all 128 candidates. Still advance by the candidate
      // cursor, not by the filtered row count, or sparse filters would stop early
      // or re-read the same batch. The public cursor below stays at the last
      // returned hit so its lookahead and unconsumed candidates are not skipped.
      after = candidateMax;
      if (candidatesExhausted) break;
      // Yield even for empty filtered batches so recording and cancel can run.
      await Future<void>.delayed(Duration.zero);
    }
    final hasMore = hits.length > limit;
    if (hasMore) hits.removeLast();
    final cursor = hasMore ? archiveCursor(hits.last['_id'] as int) : '';
    for (final hit in hits) {
      hit.remove('_id');
    }
    return {'hits': hits, 'nextCursor': cursor, 'warnings': startWarnings};
  }

  void close() {
    _closed = true;
    try {
      _closeCurrent();
    } finally {
      try {
        db.close();
      } finally {
        try {
          _lock?.unlockSync();
        } finally {
          _lock?.closeSync();
          _lock = null;
        }
      }
    }
  }
}
