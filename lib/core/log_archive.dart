import 'dart:convert';

/// A directory is shared by all recording sessions; limits apply to the archive,
/// including its SQLite index and temporary journal, rather than each session.
class LogRecordingOptions {
  final String directory, baseName;
  final int fileLimitBytes, maxFiles, maxTotalBytes;
  final int maxQueueRecords, maxQueueBytes;
  final bool overwriteOldest;
  const LogRecordingOptions({
    this.directory = '',
    this.baseName = 'portly',
    this.fileLimitBytes = 100 * 1024 * 1024,
    this.maxFiles = 20,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
    this.overwriteOldest = false,
    this.maxQueueRecords = 10000,
    this.maxQueueBytes = 8 * 1024 * 1024,
  });
  void validate() {
    if (fileLimitBytes < 128 ||
        maxFiles < 1 ||
        maxTotalBytes < 256 * 1024 ||
        maxQueueRecords < 1 ||
        maxQueueBytes < 1024) {
      throw const FormatException('日志限制无效：单文件至少 128 B，总占用至少 256 KiB');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(baseName)) {
      throw const FormatException('文件名前缀仅支持字母、数字、下划线和短横线');
    }
  }

  LogRecordingOptions copy({
    String? directory,
    String? baseName,
    int? fileLimitBytes,
    int? maxFiles,
    int? maxTotalBytes,
    bool? overwriteOldest,
    int? maxQueueRecords,
    int? maxQueueBytes,
  }) => LogRecordingOptions(
    directory: directory ?? this.directory,
    baseName: baseName ?? this.baseName,
    fileLimitBytes: fileLimitBytes ?? this.fileLimitBytes,
    maxFiles: maxFiles ?? this.maxFiles,
    maxTotalBytes: maxTotalBytes ?? this.maxTotalBytes,
    overwriteOldest: overwriteOldest ?? this.overwriteOldest,
    maxQueueRecords: maxQueueRecords ?? this.maxQueueRecords,
    maxQueueBytes: maxQueueBytes ?? this.maxQueueBytes,
  );
  Map<String, dynamic> toJson() => {
    'directory': directory,
    'baseName': baseName,
    'fileLimitBytes': fileLimitBytes,
    'maxFiles': maxFiles,
    'maxTotalBytes': maxTotalBytes,
    'overwriteOldest': overwriteOldest,
    'maxQueueRecords': maxQueueRecords,
    'maxQueueBytes': maxQueueBytes,
  };
  factory LogRecordingOptions.fromJson(Map<String, dynamic> j) =>
      LogRecordingOptions(
        directory: j['directory'] as String? ?? '',
        baseName: j['baseName'] as String? ?? 'portly',
        fileLimitBytes: j['fileLimitBytes'] as int? ?? 100 * 1024 * 1024,
        maxFiles: j['maxFiles'] as int? ?? 20,
        maxTotalBytes: j['maxTotalBytes'] as int? ?? 2 * 1024 * 1024 * 1024,
        overwriteOldest: j['overwriteOldest'] == true,
        maxQueueRecords: j['maxQueueRecords'] as int? ?? 10000,
        maxQueueBytes: j['maxQueueBytes'] as int? ?? 8 * 1024 * 1024,
      );
}

class LogRecordingStatus {
  final bool active;
  final int queued, records, bytes, files;
  final String error, path;
  const LogRecordingStatus({
    this.active = false,
    this.queued = 0,
    this.records = 0,
    this.bytes = 0,
    this.files = 0,
    this.error = '',
    this.path = '',
  });
}

class LogSearchQuery {
  final String directory, query, sessionId, direction, cursor, filePath;
  final bool hex;
  final DateTime? from, to;
  final int limit;
  const LogSearchQuery({
    required this.directory,
    this.query = '',
    this.hex = false,
    this.sessionId = '',
    this.direction = '',
    this.filePath = '',
    this.from,
    this.to,
    this.limit = 100,
    this.cursor = '',
  });
  Map<String, dynamic> toJson() => {
    'directory': directory,
    'query': query,
    'hex': hex,
    'sessionId': sessionId,
    'direction': direction,
    'filePath': filePath,
    'from': from?.millisecondsSinceEpoch,
    'to': to?.millisecondsSinceEpoch,
    'limit': limit.clamp(1, 500),
    'cursor': cursor,
  };
}

class LogArchiveHit {
  final String filePath,
      recordId,
      sessionId,
      sessionName,
      runtimeId,
      direction,
      endpoint,
      preview;
  final int offset, length;
  final DateTime time;
  const LogArchiveHit({
    required this.filePath,
    required this.offset,
    required this.length,
    required this.recordId,
    required this.sessionId,
    required this.sessionName,
    required this.runtimeId,
    required this.time,
    required this.direction,
    required this.endpoint,
    required this.preview,
  });
  factory LogArchiveHit.fromJson(Map<String, dynamic> j) => LogArchiveHit(
    filePath: j['filePath'],
    offset: j['offset'],
    length: j['length'],
    recordId: j['recordId'],
    sessionId: j['sessionId'],
    sessionName: j['sessionName'],
    runtimeId: j['runtimeId'],
    time: DateTime.fromMillisecondsSinceEpoch(j['time']),
    direction: j['direction'],
    endpoint: j['endpoint'],
    preview: j['preview'],
  );
  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'offset': offset,
    'length': length,
    'recordId': recordId,
    'sessionId': sessionId,
    'sessionName': sessionName,
    'runtimeId': runtimeId,
    'time': time.millisecondsSinceEpoch,
    'direction': direction,
    'endpoint': endpoint,
    'preview': preview,
  };
}

class LogArchiveFile {
  final String path, state, sessionId, sessionName;
  final int bytes, records;
  final DateTime? from, to;
  const LogArchiveFile({
    required this.path,
    required this.bytes,
    required this.records,
    required this.state,
    this.from,
    this.to,
    this.sessionId = '',
    this.sessionName = '',
  });
  factory LogArchiveFile.fromJson(Map<String, dynamic> j) => LogArchiveFile(
    path: j['path'],
    bytes: j['bytes'],
    records: j['records'],
    state: j['state'],
    sessionId: j['sessionId'] ?? '',
    sessionName: j['sessionName'] ?? '',
    from: j['from'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(j['from']),
    to: j['to'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['to']),
  );
}

class LogSearchPage {
  final List<LogArchiveHit> hits;
  final String nextCursor;
  final bool cancelled;
  final List<String> warnings;
  const LogSearchPage({
    this.hits = const [],
    this.nextCursor = '',
    this.cancelled = false,
    this.warnings = const [],
  });
}

String archiveCursor(int id) => base64Url.encode(utf8.encode('$id'));
int parseArchiveCursor(String value) =>
    value.isEmpty ? 0 : int.parse(utf8.decode(base64Url.decode(value)));
