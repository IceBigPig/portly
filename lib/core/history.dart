import 'dart:typed_data';

import 'bytes.dart';
import 'models.dart';

/// A bounded, immutable audit snapshot. History never contains open handles or
/// executable work. Replaying always returns a draft, never starts a send.
class HistoryRecord {
  static const maxBytes = 65536, maxBodyChars = 65536;
  final Map<String, dynamic> _data;
  final int _estimatedBytes;
  HistoryRecord._(this._data, this._estimatedBytes);
  static const _fields = {
    'id',
    'kind',
    'sessionId',
    'runtimeId',
    'sessionName',
    'name',
    'taskId',
    'targets',
    'targetCount',
    'draft',
    'draftTruncated',
    'finalBytes',
    'finalLength',
    'finalBytesTruncated',
    'commandId',
    'revision',
    'parameters',
    'responseRule',
    'timeoutMs',
    'periodMs',
    'stepDelayMs',
    'stepIndex',
    'cycle',
    'status',
    'startedAt',
    'updatedAt',
    'submittedBytes',
    'elapsedMs',
    'stepsCompleted',
    'stepsStarted',
    'responseBytes',
    'responseLength',
    'responseBytesTruncated',
    'responseLogId',
    'submittedLogIds',
    'error',
    'file',
    'metadataTruncated',
  };

  factory HistoryRecord({
    String? id,
    required String kind,
    required String sessionId,
    required String runtimeId,
    String sessionName = '',
    String name = '',
    String taskId = '',
    List<String> targets = const [],
    Draft? draft,
    List<int> finalBytes = const [],
    String commandId = '',
    int revision = 0,
    Map<String, String> parameters = const {},
    Map<String, dynamic>? responseRule,
    int timeoutMs = 0,
    int periodMs = 0,
    int stepDelayMs = 0,
    int stepIndex = 0,
    int cycle = 0,
    String status = 'pending',
    DateTime? startedAt,
    Map<String, dynamic> file = const {},
  }) => HistoryRecord.fromJson({
    'id': id ?? newId(),
    'kind': kind,
    'sessionId': sessionId,
    'runtimeId': runtimeId,
    'sessionName': sessionName,
    'name': name,
    'taskId': taskId,
    'targets': targets,
    'targetCount': targets.length,
    'draft': ?draft?.toJson(),
    'finalBytes': finalBytes,
    'finalLength': finalBytes.length,
    'commandId': commandId,
    'revision': revision,
    'parameters': parameters,
    'responseRule': ?responseRule,
    'timeoutMs': timeoutMs,
    'periodMs': periodMs,
    'stepDelayMs': stepDelayMs,
    'stepIndex': stepIndex,
    'cycle': cycle,
    'status': status,
    'startedAt': (startedAt ?? DateTime.now()).toUtc().toIso8601String(),
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
    'submittedBytes': 0,
    'elapsedMs': 0,
    'stepsCompleted': 0,
    'stepsStarted': 0,
    'responseBytes': <int>[],
    'responseLength': 0,
    'responseLogId': '',
    'submittedLogIds': <String>[],
    'error': '',
    if (file.isNotEmpty) 'file': file,
  });

  factory HistoryRecord.fromJson(Map<String, dynamic> value) {
    final j = <String, dynamic>{
      for (final e in value.entries)
        if (_fields.contains(e.key)) e.key: e.value,
    };
    var metadataTruncated = j['metadataTruncated'] == true;
    String bounded(dynamic input, int max) {
      final s = '$input';
      if (s.length <= max) return s;
      metadataTruncated = true;
      return s.substring(0, max);
    }

    j['id'] = bounded(j['id'] ?? newId(), 128);
    for (final key in [
      'kind',
      'sessionId',
      'runtimeId',
      'taskId',
      'commandId',
      'status',
      'startedAt',
      'updatedAt',
      'responseLogId',
    ]) {
      if (j[key] != null) j[key] = bounded(j[key], 128);
    }
    for (final key in ['name', 'sessionName', 'error']) {
      final s = '${j[key] ?? ''}';
      j[key] = bounded(s, 2048);
    }
    for (final key in ['finalBytes', 'responseBytes']) {
      final input = j[key];
      final Uint8List bytes;
      int originalLength;
      if (input is String) {
        final parsed = parseHex(input);
        originalLength = parsed.length;
        bytes = Uint8List.fromList(
          Uint8List.sublistView(parsed, 0, parsed.length.clamp(0, maxBytes)),
        ).asUnmodifiableView();
      } else {
        final values = input as List? ?? [];
        originalLength = values.length;
        // Never copy the uncapped source before taking the retained prefix.
        if (values is Uint8List) {
          bytes = Uint8List.fromList(
            Uint8List.sublistView(values, 0, values.length.clamp(0, maxBytes)),
          ).asUnmodifiableView();
        } else {
          final out = Uint8List(values.length.clamp(0, maxBytes));
          for (var i = 0; i < out.length; i++) {
            final value = values[i];
            if (value is! int || value < 0 || value > 255) {
              throw const FormatException('历史字节无效');
            }
            out[i] = value;
          }
          bytes = out.asUnmodifiableView();
        }
      }
      final sizeKey = key == 'finalBytes' ? 'finalLength' : 'responseLength';
      j[sizeKey] = j[sizeKey] ?? originalLength;
      j['${key}Truncated'] =
          j['${key}Truncated'] == true || originalLength > maxBytes;
      j[key] = bytes;
    }
    if (j['draft'] is Map) {
      final d = Map<String, dynamic>.from(j['draft']);
      final body = '${d['body'] ?? ''}';
      j['draftTruncated'] =
          j['draftTruncated'] == true ||
          body.length > maxBodyChars ||
          '${d['suffix'] ?? ''}'.length > 4096;
      d['body'] = body.length > maxBodyChars
          ? body.substring(0, maxBodyChars)
          : body;
      d['suffix'] = '${d['suffix'] ?? ''}'.substring(
        0,
        '${d['suffix'] ?? ''}'.length.clamp(0, 4096),
      );
      j['draft'] = Map<String, dynamic>.unmodifiable(d);
    }
    j['targetCount'] ??= (j['targets'] as List? ?? []).length;
    for (final key in ['targets', 'submittedLogIds']) {
      final values = j[key] as List? ?? [];
      if (values.length > 64) metadataTruncated = true;
      j[key] = List<String>.unmodifiable(
        values.take(64).map((v) => bounded(v, key == 'targets' ? 512 : 128)),
      );
    }
    final params = j['parameters'] as Map? ?? {};
    if (params.length > 64) metadataTruncated = true;
    var parameterCharacters = 0;
    j['parameters'] = Map<String, String>.unmodifiable({
      for (final e in params.entries.take(64))
        bounded(e.key, 64): (() {
          final value = bounded(
            e.value,
            (32768 - parameterCharacters).clamp(0, 4096),
          );
          parameterCharacters += value.length;
          return value;
        })(),
    });
    var nodes = 0, characters = 0;
    dynamic freeze(dynamic v, [int depth = 0]) {
      if (++nodes > 256 || depth > 8 || characters >= 32768) {
        metadataTruncated = true;
        return null;
      }
      if (v == null || v is bool || v is num) return v;
      if (v is String) {
        final result = bounded(v, (32768 - characters).clamp(0, 4096));
        characters += result.length;
        return result;
      }
      if (v is Map) {
        if (v.length > 64) metadataTruncated = true;
        return Map<String, dynamic>.unmodifiable({
          for (final e in v.entries.take(64))
            bounded(e.key, 128): freeze(e.value, depth + 1),
        });
      }
      if (v is List) {
        if (v.length > 64) metadataTruncated = true;
        return List<dynamic>.unmodifiable(
          v.take(64).map((e) => freeze(e, depth + 1)),
        );
      }
      metadataTruncated = true;
      return null;
    }

    if (j['responseRule'] is Map) j['responseRule'] = freeze(j['responseRule']);
    if (j['file'] is Map) j['file'] = freeze(j['file']);
    j['metadataTruncated'] = metadataTruncated;
    return HistoryRecord._(Map<String, dynamic>.unmodifiable(j), _estimate(j));
  }

  String get id => _data['id'];
  String get kind => _data['kind'] ?? 'send';
  String get sessionId => _data['sessionId'] ?? '';
  String get sessionName => _data['sessionName'] ?? '';
  String get runtimeId => _data['runtimeId'] ?? '';
  String get name => _data['name'] ?? '';
  String get taskId => _data['taskId'] ?? '';
  String get status => _data['status'] ?? 'submitted';
  String get error => _data['error'] ?? '';
  String get commandId => _data['commandId'] ?? '';
  String get responseLogId => _data['responseLogId'] ?? '';
  List<String> get submittedLogIds =>
      List<String>.from(_data['submittedLogIds']);
  int get targetCount => _data['targetCount'] ?? targets.length;
  bool get targetsTruncated => targetCount > targets.length;
  List<String> get targets => List<String>.from(_data['targets']);
  List<int> get finalBytes => _data['finalBytes'];
  List<int> get responseBytes => _data['responseBytes'];
  int get finalLength => _data['finalLength'] ?? finalBytes.length;
  int get responseLength => _data['responseLength'] ?? responseBytes.length;
  int get submittedBytes => _data['submittedBytes'] ?? 0;
  int get elapsedMs => _data['elapsedMs'] ?? 0;
  int get revision => _data['revision'] ?? 0;
  int get stepIndex => _data['stepIndex'] ?? 0;
  int get cycle => _data['cycle'] ?? 0;
  int get stepsCompleted => _data['stepsCompleted'] ?? 0;
  int get stepsStarted => _data['stepsStarted'] ?? 0;
  int get timeoutMs => _data['timeoutMs'] ?? 0;
  int get periodMs => _data['periodMs'] ?? 0;
  int get stepDelayMs => _data['stepDelayMs'] ?? 0;
  Map<String, String> get parameters =>
      Map<String, String>.from(_data['parameters']);
  Map<String, dynamic>? get responseRule => _data['responseRule'] == null
      ? null
      : Map<String, dynamic>.from(_data['responseRule']);
  Map<String, dynamic> get file =>
      Map<String, dynamic>.from(_data['file'] ?? {});
  DateTime get startedAt =>
      DateTime.tryParse(_data['startedAt'] ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  DateTime get updatedAt =>
      DateTime.tryParse(_data['updatedAt'] ?? '') ?? startedAt;
  bool get pending => ['pending', 'submitting', 'waiting'].contains(status);
  bool get metadataTruncated => _data['metadataTruncated'] == true;
  bool get finalBytesTruncated => _data['finalBytesTruncated'] == true;
  bool get responseBytesTruncated => _data['responseBytesTruncated'] == true;
  bool get canReplay =>
      (kind == 'send' || kind == 'step') &&
      !finalBytesTruncated &&
      _data['draftTruncated'] != true &&
      finalBytes.isNotEmpty;
  Draft? get draft => _data['draft'] is Map
      ? Draft.fromJson(Map<String, dynamic>.from(_data['draft']))
      : null;
  Draft replayDraft() {
    if (!canReplay) throw StateError('该记录不包含完整发送内容');
    // A legacy final-only record must never acquire a second checksum.
    return draft ?? Draft(body: hex(finalBytes));
  }

  HistoryRecord update(Map<String, dynamic> changes) => HistoryRecord.fromJson({
    ..._data,
    ...changes,
    'updatedAt': DateTime.now().toUtc().toIso8601String(),
  });
  Map<String, dynamic> toJson() => Map<String, dynamic>.of(_data);
  int get estimatedBytes => _estimatedBytes;
  static int _estimate(dynamic v) {
    if (v == null) return 4;
    if (v is String) {
      return v.length * 6 + 2; // JSON control-character escaping.
    }
    if (v is bool) return 5;
    if (v is num) return 32;
    if (v is List<int>) return 2 + v.length * 4;
    if (v is List) return 2 + v.fold<int>(0, (n, e) => n + _estimate(e) + 1);
    if (v is Map) {
      return 2 +
          v.entries.fold<int>(
            0,
            (n, e) => n + '${e.key}'.length * 6 + _estimate(e.value) + 4,
          );
    }
    return 0;
  }
}

class HistoryPage {
  final List<HistoryRecord> records;
  final String nextCursor;
  final int count, bytes;
  const HistoryPage({
    this.records = const [],
    this.nextCursor = '',
    this.count = 0,
    this.bytes = 0,
  });
}
