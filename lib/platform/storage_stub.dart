import 'dart:convert';
import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../core/models.dart';
import '../core/log_archive.dart';
import '../core/history.dart';
import '../core/library_import.dart';
export '../core/history.dart';
export '../core/log_archive.dart';

class AppStorage {
  String location = '浏览器本地存储';
  final _history = <String, HistoryRecord>{};
  Timer? _historyTimer;
  void Function(String)? onHistoryError;
  String _historyError = '';
  String closeError = '';
  int historyDropped = 0;
  String get historyError => _historyError;
  set historyError(String value) {
    if (value == _historyError) return;
    _historyError = value;
    onHistoryError?.call(value);
  }

  Future<Map<String, dynamic>?> open({String? path}) async {
    final h = web.window.localStorage.getItem('portly-history-v1');
    if (h != null) {
      for (final j in (jsonDecode(h) as List).take(1000)) {
        var r = HistoryRecord.fromJson(Map<String, dynamic>.from(j));
        if (r.pending) {
          r = r.update({'status': 'interrupted', 'error': '上次运行未完成，任务未恢复'});
        }
        _history[r.id] = r;
      }
    }
    final value = web.window.localStorage.getItem('portly-state-v1');
    return value == null ? null : jsonDecode(value) as Map<String, dynamic>;
  }

  bool recordHistory(HistoryRecord record) {
    _history[record.id] = record;
    final ordered = _history.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    var size = 0;
    _history.clear();
    for (final item in ordered.take(1000)) {
      if (size + item.estimatedBytes > 2 * 1024 * 1024) break;
      _history[item.id] = item;
      size += item.estimatedBytes;
    }
    _historyTimer ??= Timer(const Duration(milliseconds: 500), () {
      _historyTimer = null;
      unawaited(flushHistory());
    });
    return true;
  }

  Future<void> flushHistory() async {
    _historyTimer?.cancel();
    _historyTimer = null;
    try {
      web.window.localStorage.setItem(
        'portly-history-v1',
        jsonEncode(_history.values.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      historyError = '历史保存失败：$e';
    }
  }

  Future<HistoryPage> queryHistory({
    String sessionId = '',
    String taskId = '',
    String before = '',
    int limit = 100,
    List<String> kinds = const [],
  }) async {
    final all =
        _history.values
            .where(
              (r) =>
                  (sessionId.isEmpty || r.sessionId == sessionId) &&
                  (taskId.isEmpty || r.taskId == taskId || r.id == taskId) &&
                  (kinds.isEmpty || kinds.contains(r.kind)),
            )
            .toList()
          ..sort((a, b) {
            final v = b.updatedAt.compareTo(a.updatedAt);
            return v == 0 ? b.id.compareTo(a.id) : v;
          });
    final start = before.isEmpty
        ? 0
        : all.indexWhere((r) => r.id == before) + 1;
    final rows = all.skip(start).take(limit.clamp(1, 100)).toList();
    return HistoryPage(
      records: rows,
      count: all.length,
      bytes: all.fold(0, (n, r) => n + r.estimatedBytes),
      nextCursor: start + rows.length < all.length && rows.isNotEmpty
          ? rows.last.id
          : '',
    );
  }

  Future<HistoryRecord?> getHistory(String id) async => _history[id];

  Future<void> clearHistory({String sessionId = ''}) async {
    _history.removeWhere(
      (_, r) => sessionId.isEmpty || r.sessionId == sessionId,
    );
    await flushHistory();
    historyError = '';
  }

  Future<void> save(Map<String, dynamic> data) async =>
      web.window.localStorage.setItem('portly-state-v1', jsonEncode(data));
  Future<String> commitLibraryImport({
    required String expectedFingerprint,
    required Map<String, dynamic> state,
  }) async {
    final value = web.window.localStorage.getItem('portly-state-v1');
    final j = value == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(value));
    final current = LibrarySnapshot.capture(
      groups: Map<String, String>.from(j['groups'] ?? {'default': '默认分组'}),
      commands: (j['commands'] as List? ?? [])
          .map((v) => SavedCommand.fromJson(Map<String, dynamic>.from(v)))
          .toList(),
      groupMetadata: {
        for (final e in (j['groupMetadata'] as Map? ?? {}).entries)
          e.key as String: Map<String, dynamic>.from(e.value),
      },
    );
    if (current.fingerprint != expectedFingerprint) {
      throw StateError('命令库已改变，请重新检查导入冲突');
    }
    await backup();
    await save(state);
    return '浏览器本地备份';
  }

  Future<void> backup() async {
    final value = web.window.localStorage.getItem('portly-state-v1');
    if (value != null) web.window.localStorage.setItem('portly-backup', value);
  }

  Future<void> get closed => Future<void>.value();
  void close() {
    _historyTimer?.cancel();
    unawaited(flushHistory());
  }
}

Future<bool> exportFile(String name, String content) async {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  (web.HTMLAnchorElement()
        ..href = url
        ..download = name)
      .click();
  web.URL.revokeObjectURL(url);
  return true;
}

// The shared file selector supports opening files on web.
Future<String?> importFile() async => null;

class LogRecorder {
  bool get active => false;
  String? get path => null;
  LogRecordingStatus status = const LogRecordingStatus();
  void Function()? onUpdate;
  Future<void> start(
    void Function(String) onError, {
    LogRecordingOptions? options,
    String sessionId = '',
    String sessionName = '',
    String? runtimeId,
  }) async => onError('持续记录到文件需要桌面版');
  void writeEntry(LogEntry entry, {String? runtimeId}) {}
  void write(Map<String, dynamic> entry) {}
  Future<void> stop() async {}
}

class LogArchive {
  Future<Map<String, String>> sessions(String directory) async => {};
  Future<Map<String, int>> usage(String directory) async => {
    'logBytes': 0,
    'indexBytes': 0,
    'totalBytes': 0,
    'files': 0,
  };
  Future<List<LogArchiveFile>> listFiles(String directory) async => [];
  Future<LogSearchPage> search(LogSearchQuery query) async =>
      const LogSearchPage(warnings: ['文件日志搜索需要桌面版']);
  Future<Map<String, dynamic>> readRecord(LogArchiveHit hit) async =>
      throw UnsupportedError('文件日志搜索需要桌面版');
  Future<List<String>> rebuild(
    String directory, {
    LogRecordingOptions? options,
  }) async => ['文件日志索引需要桌面版'];
  void cancel() {}
  Future<void> close() async {}
}
