import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/library_import.dart';
import '../platform/storage.dart';
import '../platform/transport.dart';
import 'session.dart';

// Keep worker closures outside instance methods. Dart can otherwise capture
// the method context (and this model's ports/timers) through an unrelated local.
Future<LibraryImportPreview> _inspectLibraryWorker(
  String content,
  LibrarySnapshot snapshot,
) => Isolate.run(() => inspectLibraryImport(content, snapshot));
Future<List<SavedCommand>> _prepareImportWorker(LibraryImportPlan plan) =>
    Isolate.run(() => plan.commands);
Future<String> _exportLibraryWorker(
  LibrarySnapshot snapshot,
  LibraryExportScope scope,
  String groupId,
  Set<String> selected,
) => Isolate.run(
  () => exportCommandLibrary(
    snapshot,
    scope: scope,
    groupId: groupId,
    selectedIds: selected,
  ),
);

class AppModel extends ChangeNotifier {
  final AppStorage storage;
  final Future<List<SavedCommand>> Function(LibraryImportPlan) _prepareImport;
  AppModel({
    AppStorage? storage,
    Future<List<SavedCommand>> Function(LibraryImportPlan)? prepareImport,
  }) : storage = storage ?? AppStorage(),
       _prepareImport = prepareImport ?? _prepareImportWorker;
  List<PortInfo> availablePorts = [];
  DateTime? _portsAt;
  Future<List<PortInfo>>? _portScan;
  Future<List<PortInfo>> scanPorts({bool force = false}) async {
    if (_portScan != null) return _portScan!;
    if (!force &&
        _portsAt != null &&
        DateTime.now().difference(_portsAt!).inSeconds < 10) {
      return availablePorts;
    }
    final pending = enumeratePortsAsync();
    _portScan = pending;
    try {
      availablePorts = await pending;
      _portsAt = DateTime.now();
      return availablePorts;
    } finally {
      _portScan = null;
    }
  }

  final sessions = <Session>[];
  final commands = <SavedCommand>[];
  final groups = <String, String>{'default': '默认分组'};
  final profiles = <ConnectionConfig>[];
  final groupMetadata = <String, Map<String, dynamic>>{};
  bool libraryImporting = false, closing = false, shutdownComplete = false;
  bool _importPersistenceFailed = false;
  Future<String>? _libraryImportFuture;
  Future<void>? _shutdownFuture;
  final _sessionCloseTasks = <Future<void>>{};
  int libraryRevision = 0;
  String historyError = '', lastImportBackup = '';
  String get persistenceError =>
      [storageError, historyError].where((s) => s.isNotEmpty).join('\n');
  final toolDrafts = <String, String>{};
  LogRecordingOptions logOptions = LogRecordingOptions();
  String currentId = '',
      groupId = 'default',
      saveState = '本地保存',
      storageError = '';
  bool dark = false, ready = false, _readFailed = false;
  int page = 0, waveSeconds = 60;
  String waveSourceId = '';
  int splitMode = 0;
  String secondarySessionId = '';
  Future<void> Function()? openCompareWindow, closeCompareWindows;
  Future<void> Function(String, String, Map<String, dynamic>?)? remoteAction;
  bool externalView = false;
  void refresh() => notifyListeners();
  Timer? _saveTimer, _historyNoticeTimer;
  Future<void>? _saveInFlight;
  int _editRevision = 0, _savedRevision = 0;
  bool _disposed = false;
  Session get current => sessions.firstWhere(
    (s) => s.id == currentId,
    orElse: () => sessions.first,
  );
  Future<void> initialize({String? storagePath}) async {
    try {
      final json = await storage.open(path: storagePath);
      if (json != null) {
        if (json['schemaVersion'] != 1) {
          throw const FormatException('应用数据版本不兼容');
        }
        final restored = (json['sessions'] as List)
            .map((j) => Session.fromJson(Map<String, dynamic>.from(j)))
            .toList();
        final library = (json['commands'] as List)
            .map((j) => SavedCommand.fromJson(Map<String, dynamic>.from(j)))
            .toList();
        sessions.addAll(restored);
        commands.addAll(library);
        groups
          ..clear()
          ..addAll(Map<String, String>.from(json['groups']));
        groupMetadata.addAll({
          for (final entry in (json['groupMetadata'] as Map? ?? {}).entries)
            entry.key as String: Map<String, dynamic>.from(entry.value as Map),
        });
        profiles.addAll(
          (json['profiles'] as List? ?? []).map(
            (j) => ConnectionConfig.fromJson(Map<String, dynamic>.from(j)),
          ),
        );
        toolDrafts.addAll(Map<String, String>.from(json['toolDrafts'] ?? {}));
        dark = json['dark'] ?? false;
        currentId = json['currentId'] ?? '';
        page = json['page'] ?? 0;
        waveSourceId = json['waveSourceId'] ?? '';
        waveSeconds = json['waveSeconds'] ?? 60;
        splitMode = json['splitMode'] ?? 0;
        secondarySessionId = json['secondarySessionId'] ?? '';
        groupId = json['groupId'] ?? 'default';
        if (json['logRecording'] is Map) {
          logOptions = LogRecordingOptions.fromJson(
            Map<String, dynamic>.from(json['logRecording']),
          );
        }
      }
    } catch (e) {
      _readFailed = true;
      storageError = '读取本地数据失败：$e；原数据已保留';
    }
    final cleaned = _removeGeneratedExamples();
    if (sessions.isEmpty) sessions.add(Session(config: ConnectionConfig()));
    if (!sessions.any((s) => s.id == currentId)) currentId = sessions.first.id;
    if (groups.isEmpty) groups['default'] = '我的命令';
    if (!groups.containsKey(groupId)) groupId = groups.keys.first;
    for (final session in sessions) {
      _attachSession(session);
    }
    storage.onHistoryError = (error) {
      historyError = error.isEmpty ? '' : '历史记录：$error';
      _historyNoticeTimer ??= Timer(const Duration(milliseconds: 250), () {
        _historyNoticeTimer = null;
        if (!_disposed) notifyListeners();
      });
    };
    historyError = storage.historyError;
    if (cleaned && !_readFailed) {
      try {
        await storage.save(snapshot());
      } catch (e) {
        storageError = '保存失败：$e';
        saveState = '保存失败';
      }
    }
    ready = true;
    notifyListeners();
  }

  bool _removeGeneratedExamples() {
    final sessionCount = sessions.length, commandCount = commands.length;
    var renamed = false;
    sessions.removeWhere((s) {
      final generated =
          s.config.name == '离线演示' &&
          s.config.kind == ConnectionKind.serial &&
          s.config.port.isEmpty;
      if (generated) s.dispose();
      return generated;
    });
    const samples = {
      '读取温湿度': '01 03 00 00 00 02',
      '读取设备状态': '01 03 00 10 00 02',
      '读取输入寄存器': '01 04 00 00 00 02',
      '发送 Hello': 'Hello',
    };
    commands.removeWhere(
      (c) =>
          groups[c.groupId] == '示例命令' &&
          c.revision == 1 &&
          c.parameters.isEmpty &&
          c.tags.isEmpty &&
          c.responseRule == null &&
          c.note.isEmpty &&
          samples[c.name] == c.draft.body &&
          c.draft.crc == (c.name != '发送 Hello') &&
          c.draft.text == (c.name == '发送 Hello'),
    );
    for (final id in groups.keys.toList()) {
      if (groups[id] == '示例命令') {
        groups[id] = '默认分组';
        renamed = true;
      }
    }
    return renamed ||
        sessions.length != sessionCount ||
        commands.length != commandCount;
  }

  void _attachSession(Session session) {
    session.enforceBudget = _pruneLogs;
    session.onHistory = (record) {
      if (!externalView) storage.recordHistory(record);
    };
  }

  void _pruneLogs() {
    var samples = sessions
        .expand((s) => s.waveform.channels)
        .fold(0, (n, c) => n + c.samples.length);
    while (samples > 250000) {
      final channels =
          sessions
              .expand((s) => s.waveform.channels)
              .where((c) => c.samples.isNotEmpty)
              .toList()
            ..sort(
              (a, b) => a.samples.first.time.compareTo(b.samples.first.time),
            );
      if (channels.isEmpty) break;
      channels.first.samples.removeFirst();
      channels.first.dropped++;
      samples--;
    }
    var count = sessions.fold(0, (sum, s) => sum + s.logs.length);
    var bytes = sessions.fold(0, (sum, s) => sum + s.rawBytes);
    while (count > 100000 || bytes > 64 * 1024 * 1024) {
      final available = sessions.where((s) => s.logs.isNotEmpty).toList()
        ..sort((a, b) => a.logs.first.time.compareTo(b.logs.first.time));
      if (available.isEmpty) break;
      final victim = available.first;
      final removed = victim.logs.removeFirst();
      bytes -= removed.bytes.length;
      victim.rawBytes -= removed.bytes.length;
      victim.dropped++;
      count--;
      victim.scheduleNotify();
    }
  }

  void selectSession(String id) {
    if (currentId == id) return;
    currentId = id;
    notifyListeners();
  }

  Session newSession(ConnectionKind kind, {String? name}) {
    if (closing || _disposed) throw StateError('应用正在关闭');
    final count = sessions.length + 1;
    final config = ConnectionConfig(
      name: name ?? '${kind.label} ${count.toString().padLeft(2, '0')}',
      kind: kind,
      networkPort: kind == ConnectionKind.udp ? 9001 : 9000,
    );
    final session = Session(config: config);
    _attachSession(session);
    sessions.add(session);
    currentId = session.id;
    notifyListeners();
    saveSoon();
    return session;
  }

  Future<void> closeSession(Session session) {
    if (closing || _disposed) return Future<void>.value();
    final work = _closeSession(session);
    _sessionCloseTasks.add(work);
    return work.whenComplete(() => _sessionCloseTasks.remove(work));
  }

  Future<void> _closeSession(Session session) async {
    await session.disconnect();
    await session.recorder.stop();
    if (closing || _disposed) return;
    sessions.remove(session);
    session.dispose();
    if (sessions.isEmpty) {
      final replacement = Session(config: ConnectionConfig());
      _attachSession(replacement);
      sessions.add(replacement);
    }
    if (currentId == session.id) currentId = sessions.first.id;
    notifyListeners();
    saveSoon();
  }

  void changed() {
    if (closing || _disposed) return;
    notifyListeners();
    saveSoon();
  }

  void saveSoon() {
    if (_readFailed || externalView || _disposed || closing) return;
    _editRevision++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () => unawaited(save()));
  }

  Map<String, dynamic> snapshot() => {
    'schemaVersion': 1,
    'page': page,
    'groupId': groupId,
    'sessions': sessions.map((s) => s.toJson()).toList(),
    'currentId': currentId,
    'commands': commands.map((c) => c.toJson()).toList(),
    'groups': Map<String, String>.of(groups),
    'profiles': profiles.map((p) => p.toJson()).toList(),
    'groupMetadata': {
      for (final entry in groupMetadata.entries)
        entry.key: Map<String, dynamic>.of(entry.value),
    },
    'toolDrafts': Map<String, String>.of(toolDrafts),
    'dark': dark,
    'logRecording': logOptions.toJson(),
    'waveSourceId': waveSourceId,
    'waveSeconds': waveSeconds,
    'splitMode': splitMode,
    'secondarySessionId': secondarySessionId,
  };
  Future<void> save() async {
    _saveTimer?.cancel();
    if (_readFailed || externalView || _disposed) return;
    final currentWrite = _saveInFlight;
    if (currentWrite != null) {
      await currentWrite;
      if (_savedRevision < _editRevision &&
          !_disposed &&
          storageError.isEmpty) {
        await save();
      }
      return;
    }
    final revision = _editRevision;
    final state = snapshot();
    final write = _writeState(state, revision);
    _saveInFlight = write;
    try {
      await write;
    } finally {
      if (identical(_saveInFlight, write)) _saveInFlight = null;
    }
  }

  Future<void> _writeState(Map<String, dynamic> state, int revision) async {
    try {
      await storage.save(state);
      _savedRevision = revision;
      saveState = '已保存到本机';
      storageError = '';
      _importPersistenceFailed = false;
    } catch (e) {
      saveState = '保存失败';
      storageError = '$e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<bool> flushPendingSave() async {
    if (_disposed || _readFailed || externalView) return false;
    final pending = _saveInFlight;
    if (pending != null) {
      await pending;
      // All callers of the same failed write see the failure. A later explicit
      // action may retry, but concurrent send clicks must not start retry writes.
      if (storageError.isNotEmpty) return false;
    }
    while ((_saveTimer?.isActive ?? false) ||
        _savedRevision < _editRevision ||
        storageError.isNotEmpty) {
      if (_disposed || _readFailed || externalView) return false;
      await save();
      if (storageError.isNotEmpty) return false;
    }
    return !_disposed && !_readFailed;
  }

  LibrarySnapshot get librarySnapshot => LibrarySnapshot.capture(
    groups: groups,
    commands: commands,
    groupMetadata: groupMetadata,
  );

  String exportLibrary({
    LibraryExportScope scope = LibraryExportScope.all,
    Set<String> selectedIds = const {},
  }) => exportCommandLibrary(
    librarySnapshot,
    scope: scope,
    groupId: groupId,
    selectedIds: selectedIds,
  );

  Future<String> exportLibraryAsync({
    LibraryExportScope scope = LibraryExportScope.all,
    Set<String> selectedIds = const {},
  }) {
    final current = librarySnapshot,
        group = groupId,
        selected = Set<String>.of(selectedIds);
    return kIsWeb
        ? Future.value(
            exportCommandLibrary(
              current,
              scope: scope,
              groupId: group,
              selectedIds: selected,
            ),
          )
        : _exportLibraryWorker(current, scope, group, selected);
  }

  Future<LibraryImportPreview> previewLibraryImport(String content) async {
    final current = librarySnapshot;
    return kIsWeb
        ? inspectLibraryImport(content, current)
        : await _inspectLibraryWorker(content, current);
  }

  // Compatibility entry points use the same validation and default keep policy.
  ({List<SavedCommand> commands, Map<String, String> groups, int conflicts})
  validateImport(String content) {
    final preview = inspectLibraryImport(content, librarySnapshot);
    if (!preview.valid) {
      throw FormatException(
        preview.issues.map((e) => '${e.location}: ${e.reason}').join('\n'),
      );
    }
    final incoming = jsonDecode(content) as Map<String, dynamic>;
    return (
      commands: (incoming['commands'] as List)
          .map((r) => SavedCommand.fromJson(Map<String, dynamic>.from(r)))
          .toList(),
      groups: {
        for (final r in incoming['groups'] as List)
          r['id'] as String: r['name'] as String,
      },
      conflicts: preview.conflicts.where((c) => !c.group).length,
    );
  }

  Future<int> importLibrary(String content) async {
    final preview = await previewLibraryImport(content);
    if (!preview.valid) {
      throw FormatException(
        preview.issues.map((e) => '${e.location}: ${e.reason}').join('\n'),
      );
    }
    final plan = preview.buildPlan();
    await applyLibraryImport(plan);
    return plan.importedCommands;
  }

  Future<String> applyLibraryImport(LibraryImportPlan plan) {
    if (closing || libraryImporting || _disposed) {
      return Future.error(StateError('命令库当前不可写'));
    }
    final work = _applyLibraryImport(plan);
    _libraryImportFuture = work;
    return work.whenComplete(() {
      if (identical(_libraryImportFuture, work)) _libraryImportFuture = null;
    });
  }

  Future<String> _applyLibraryImport(LibraryImportPlan plan) async {
    if (libraryImporting || _readFailed || externalView || _disposed) {
      throw StateError('命令库当前不可写');
    }
    libraryImporting = true;
    notifyListeners();
    try {
      if (!await flushPendingSave()) {
        throw StateError('请先处理配置保存失败：$storageError');
      }
      if (!plan.matches(librarySnapshot)) throw StateError('命令库已变化，请重新预览导入');
      if (!plan.hasChanges) return '';
      final prepared = kIsWeb ? plan.commands : await _prepareImport(plan);
      if (!await flushPendingSave()) {
        throw StateError('请先处理配置保存失败：$storageError');
      }
      if (_disposed || !plan.matches(librarySnapshot)) {
        throw StateError('命令库已变化，请重新预览导入');
      }
      final nextGroups = plan.groups, nextMetadata = plan.groupMetadata;
      final state = snapshot()
        ..['groups'] = nextGroups
        ..['groupMetadata'] = nextMetadata
        ..['commands'] = prepared.map((c) => c.toJson()).toList();
      final revision = _editRevision;
      final done = Completer<void>();
      _saveInFlight = done.future;
      try {
        final backup = await storage.commitLibraryImport(
          expectedFingerprint: plan.expectedFingerprint,
          state: state,
        );
        // The import dialog and library gate prevent mutations during commit;
        // connection state and receive buffers are deliberately outside the CAS.
        groups
          ..clear()
          ..addAll(nextGroups);
        groupMetadata
          ..clear()
          ..addAll(nextMetadata);
        commands
          ..clear()
          ..addAll(prepared);
        if (!groups.containsKey(groupId)) groupId = groups.keys.first;
        for (final session in sessions) {
          session.selectedCommands.removeWhere(
            (id) => !commands.any((c) => c.id == id),
          );
        }
        libraryRevision++;
        lastImportBackup = backup;
        _savedRevision = revision;
        storageError = '';
        _importPersistenceFailed = false;
        saveState = '已保存到本机';
        return backup;
      } catch (e) {
        _importPersistenceFailed = true;
        storageError = '导入保存失败：$e';
        saveState = '保存失败';
        rethrow;
      } finally {
        done.complete();
        if (identical(_saveInFlight, done.future)) _saveInFlight = null;
      }
    } finally {
      libraryImporting = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> shutdown({bool discardUnsavedChanges = false}) {
    if (externalView) return Future.error(StateError('对比窗口不拥有主数据库'));
    if (shutdownComplete) return Future<void>.value();
    final existing = _shutdownFuture;
    if (existing != null) return existing;
    final work = _performShutdown(discardUnsavedChanges);
    _shutdownFuture = work;
    return work.whenComplete(() {
      if (identical(_shutdownFuture, work)) _shutdownFuture = null;
    });
  }

  Future<void> _performShutdown(bool discardUnsavedChanges) async {
    closing = true;
    notifyListeners();
    final priorHistoryError = storage.historyError,
        priorDropped = storage.historyDropped;
    final priorArchiveErrors = {
      for (final session in sessions) session.id: session.recorder.status.error,
    };
    final archiveFailures = <String>[];
    for (final session in sessions) {
      session.beginShutdown();
    }
    try {
      await closeCompareWindows?.call();
      await Future.wait(_sessionCloseTasks.toList());
      for (final session in List<Session>.of(sessions)) {
        await session.disconnect();
        await session.recorder.stop();
        await session.drainSends();
        final archiveError = session.recorder.status.error;
        if (archiveError.isNotEmpty) {
          final previous = priorArchiveErrors[session.id] == archiveError;
          archiveFailures.add(
            '${previous ? '此前已有未保存日志' : '退出时日志归档失败'} · ${session.config.name}：$archiveError',
          );
        }
      }
      final importing = _libraryImportFuture;
      if (importing != null) {
        try {
          await importing;
        } catch (e) {
          if (!discardUnsavedChanges) throw StateError('导入未完成保存，尚未退出：$e');
        }
      }
      if (!discardUnsavedChanges) {
        if (_importPersistenceFailed) {
          throw StateError('命令库导入保存失败，原数据已保留：$storageError');
        }
        if (!await flushPendingSave()) {
          throw StateError('本地配置尚未保存，尚未退出：$storageError');
        }
        // Persist the last workspace selection as well as dirty drafts.
        await save();
        if (storageError.isNotEmpty) {
          throw StateError('本地配置尚未保存，尚未退出：$storageError');
        }
      } else {
        // An explicit discard still waits for work already handed to SQLite.
        await _saveInFlight;
      }
      await storage.flushHistory();
      if (!discardUnsavedChanges) {
        final failures = <String>[...archiveFailures];
        if (storage.historyError.isNotEmpty) {
          final previous =
              priorHistoryError == storage.historyError &&
              priorDropped == storage.historyDropped;
          failures.add(
            '${previous ? '此前已有未保存历史' : '退出时历史保存失败'}：${storage.historyError}',
          );
        }
        if (failures.isNotEmpty) {
          throw StateError('${failures.join('\n')}。仍然退出将放弃这些未保存记录。');
        }
      }
      storage.close();
      await storage.closed;
      if (!discardUnsavedChanges && storage.closeError.isNotEmpty) {
        throw StateError('数据库关闭失败：${storage.closeError}');
      }
      shutdownComplete = true;
    } finally {
      if (!shutdownComplete) {
        closing = false;
        for (final session in sessions) {
          session.cancelShutdown();
        }
        if (!_disposed) notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _saveTimer?.cancel();
    _historyNoticeTimer?.cancel();
    for (final s in sessions) {
      s.dispose();
    }
    if (!externalView) {
      storage.onHistoryError = null;
      storage.close();
    }
    super.dispose();
  }
}
