import 'dart:convert';

import 'models.dart';

const commandLibraryFormat = 'serial-debug-assistant.command-library';
const maxLibraryImportBytes = 16 * 1024 * 1024;
const maxLibraryCommands = 5000;
const maxLibraryGroups = 100;

enum ImportChoice { keep, copy, overwrite }

enum LibraryExportScope { currentGroup, selected, all }

String _canonical(dynamic value) {
  dynamic order(dynamic input) {
    if (input is Map) {
      final keys = input.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: order(input[key])};
    }
    if (input is List) return input.map(order).toList();
    return input;
  }

  return jsonEncode(order(value));
}

dynamic _freeze(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freeze(entry.value),
    });
  }
  if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
  return value;
}

Map<String, dynamic> _map(dynamic value) {
  if (value is! Map) throw const FormatException('必须为 JSON 对象');
  return Map<String, dynamic>.from(value);
}

/// A library-only snapshot. Its exact canonical fingerprint excludes sessions,
/// counters and drafts, so live traffic cannot invalidate an import preview.
class LibrarySnapshot {
  final List<Map<String, dynamic>> _groups, _commands;
  final String fingerprint;
  LibrarySnapshot._(this._groups, this._commands)
    : fingerprint = _canonical({'groups': _groups, 'commands': _commands});

  factory LibrarySnapshot.capture({
    required Map<String, String> groups,
    required List<SavedCommand> commands,
    Map<String, Map<String, dynamic>> groupMetadata = const {},
  }) => LibrarySnapshot._(
    List.unmodifiable([
      for (var i = 0; i < groups.length; i++)
        _freeze({
          ...?groupMetadata[groups.keys.elementAt(i)],
          'id': groups.keys.elementAt(i),
          'name': groups.values.elementAt(i),
          'sortOrder':
              groupMetadata[groups.keys.elementAt(i)]?['sortOrder'] ?? i,
        }) as Map<String, dynamic>,
    ]),
    List.unmodifiable([
      for (final command in commands)
        _freeze(command.toJson()) as Map<String, dynamic>,
    ]),
  );

  List<Map<String, dynamic>> get groupRows => _groups;
  List<Map<String, dynamic>> get commandRows => _commands;
  Map<String, String> get groups => Map.unmodifiable({
    for (final group in _groups) group['id'] as String: group['name'] as String,
  });
  Map<String, Map<String, dynamic>> get groupMetadata => Map.unmodifiable({
    for (final group in _groups) group['id'] as String: group,
  });
  List<SavedCommand> get commands => [
    for (final command in _commands) SavedCommand.fromJson(command),
  ];
}

class LibraryImportIssue {
  final String location, reason;
  const LibraryImportIssue(this.location, this.reason);
}

class LibraryImportConflict {
  final bool group;
  final String id, incomingName, existingName;
  const LibraryImportConflict({
    required this.group,
    required this.id,
    required this.incomingName,
    required this.existingName,
  });
  String get key => '${group ? 'group' : 'command'}:$id';
}

class LibraryImportPreview {
  final LibrarySnapshot existing;
  final List<Map<String, dynamic>> _groups, _commands;
  final List<LibraryImportIssue> issues;
  final List<LibraryImportConflict> conflicts;
  LibraryImportPreview._({
    required this.existing,
    required List<Map<String, dynamic>> groups,
    required List<Map<String, dynamic>> commands,
    required List<LibraryImportIssue> issues,
    required List<LibraryImportConflict> conflicts,
  }) : _groups = List.unmodifiable(groups),
       _commands = List.unmodifiable(commands),
       issues = List.unmodifiable(issues),
       conflicts = List.unmodifiable(conflicts);
  bool get valid => issues.isEmpty;
  int get groupCount => _groups.length;
  int get commandCount => _commands.length;

  LibraryImportPlan buildPlan({Map<String, ImportChoice> choices = const {}}) {
    if (!valid) throw StateError('命令库含无效数据，不能导入');
    final allowed = conflicts.map((c) => c.key).toSet();
    if (choices.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('导入冲突选项与预览不一致');
    }
    final groupRows = [...existing.groupRows];
    final commandRows = [...existing.commandRows];
    final groupIndices = {
      for (var i = 0; i < groupRows.length; i++) groupRows[i]['id']: i,
    };
    final commandIndices = {
      for (var i = 0; i < commandRows.length; i++) commandRows[i]['id']: i,
    };
    final usedIds = {
      ...groupRows.map((g) => g['id'] as String),
      ...commandRows.map((c) => c['id'] as String),
      ..._groups.map((g) => g['id'] as String),
      ..._commands.map((c) => c['id'] as String),
    };
    String fresh() {
      var id = newId();
      while (!usedIds.add(id)) {
        id = newId();
      }
      return id;
    }

    final remappedGroups = <String, String>{};
    var addedGroups = 0, overwrittenGroups = 0, copiedGroups = 0;
    var addedCommands = 0, overwrittenCommands = 0, copiedCommands = 0;
    var skippedGroups = 0, skippedCommands = 0;
    for (final incoming in _groups) {
      final id = incoming['id'] as String;
      final index = groupIndices[id];
      final choice = choices['group:$id'] ?? ImportChoice.keep;
      if (index == null) {
        groupIndices[id] = groupRows.length;
        groupRows.add(incoming);
        remappedGroups[id] = id;
        addedGroups++;
      } else if (choice == ImportChoice.copy) {
        final copyId = fresh();
        remappedGroups[id] = copyId;
        groupRows.add(
          _freeze({...incoming, 'id': copyId}) as Map<String, dynamic>,
        );
        copiedGroups++;
      } else if (choice == ImportChoice.overwrite) {
        remappedGroups[id] = id;
        groupRows[index] = incoming;
        overwrittenGroups++;
      } else {
        remappedGroups[id] = id;
        skippedGroups++;
      }
    }
    for (final incoming in _commands) {
      final id = incoming['id'] as String;
      final index = commandIndices[id];
      final choice = choices['command:$id'] ?? ImportChoice.keep;
      final groupId = remappedGroups[incoming['groupId']]!;
      if (index == null) {
        commandIndices[id] = commandRows.length;
        commandRows.add(
          _freeze({...incoming, 'groupId': groupId}) as Map<String, dynamic>,
        );
        addedCommands++;
      } else if (choice == ImportChoice.copy) {
        commandRows.add(
          _freeze({...incoming, 'id': fresh(), 'groupId': groupId})
              as Map<String, dynamic>,
        );
        copiedCommands++;
      } else if (choice == ImportChoice.overwrite) {
        commandRows[index] =
            _freeze({...incoming, 'groupId': groupId}) as Map<String, dynamic>;
        overwrittenCommands++;
      } else {
        skippedCommands++;
      }
    }
    if (groupRows.length > maxLibraryGroups ||
        commandRows.length > maxLibraryCommands) {
      throw const FormatException('导入后的命令库超过 100 个分组或 5000 条命令');
    }
    return LibraryImportPlan._(
      existing.fingerprint,
      groupRows,
      commandRows,
      addedGroups: addedGroups,
      overwrittenGroups: overwrittenGroups,
      copiedGroups: copiedGroups,
      skippedGroups: skippedGroups,
      addedCommands: addedCommands,
      overwrittenCommands: overwrittenCommands,
      copiedCommands: copiedCommands,
      skippedCommands: skippedCommands,
    );
  }
}

class LibraryImportPlan {
  final String expectedFingerprint;
  final List<Map<String, dynamic>> _groups, _commands;
  final int addedGroups, overwrittenGroups, copiedGroups, skippedGroups;
  final int addedCommands, overwrittenCommands, copiedCommands, skippedCommands;
  LibraryImportPlan._(
    this.expectedFingerprint,
    List<Map<String, dynamic>> groups,
    List<Map<String, dynamic>> commands, {
    required this.addedGroups,
    required this.overwrittenGroups,
    required this.copiedGroups,
    required this.skippedGroups,
    required this.addedCommands,
    required this.overwrittenCommands,
    required this.copiedCommands,
    required this.skippedCommands,
  }) : _groups = List.unmodifiable(groups),
       _commands = List.unmodifiable(commands);
  bool matches(LibrarySnapshot current) =>
      current.fingerprint == expectedFingerprint;
  bool get hasChanges =>
      addedGroups +
          overwrittenGroups +
          copiedGroups +
          addedCommands +
          overwrittenCommands +
          copiedCommands >
      0;
  bool get overwrites => overwrittenGroups + overwrittenCommands > 0;
  int get importedCommands =>
      addedCommands + overwrittenCommands + copiedCommands;
  Map<String, String> get groups => Map.unmodifiable({
    for (final row in _groups) row['id'] as String: row['name'] as String,
  });
  Map<String, Map<String, dynamic>> get groupMetadata =>
      Map.unmodifiable({for (final row in _groups) row['id'] as String: row});
  List<SavedCommand> get commands => [
    for (final row in _commands) SavedCommand.fromJson(row),
  ];
}

bool _id(dynamic value) =>
    value is String && value.trim().isNotEmpty && value.length <= 128;
void _dates(Map<String, dynamic> row) {
  for (final key in ['createdAt', 'updatedAt']) {
    final value = row[key];
    if (value != null &&
        (value is! String ||
            !value.endsWith('Z') ||
            DateTime.tryParse(value) == null)) {
      throw FormatException('$key 须为 UTC ISO 8601 时间');
    }
  }
}

/// Pure, bounded validation. Any issue prevents creating an import plan.
LibraryImportPreview inspectLibraryImport(
  String content,
  LibrarySnapshot existing,
) {
  final issues = <LibraryImportIssue>[];
  final groups = <Map<String, dynamic>>[], commands = <Map<String, dynamic>>[];
  final conflicts = <LibraryImportConflict>[];
  LibraryImportPreview result() => LibraryImportPreview._(
    existing: existing,
    groups: groups,
    commands: commands,
    issues: issues,
    conflicts: conflicts,
  );
  void issue(String field, Object error) => issues.add(
    LibraryImportIssue(
      field,
      error is FormatException ? error.message : '$error',
    ),
  );
  if (content.length > maxLibraryImportBytes ||
      utf8.encode(content).length > maxLibraryImportBytes) {
    issue('文件', '文件超过 16 MiB');
    return result();
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(content);
  } catch (e) {
    issue('JSON', e);
    return result();
  }
  if (decoded is! Map<String, dynamic>) {
    issue('文件', '顶层必须为 JSON 对象');
    return result();
  }
  final j = decoded;
  if (j['format'] != commandLibraryFormat) issue('format', '不是支持的命令库格式');
  if (j['schemaVersion'] is! int || j['schemaVersion'] != 1) {
    issue('schemaVersion', '版本 ${j['schemaVersion']} 不兼容；仅支持 schemaVersion 1');
  }
  for (final key in j.keys) {
    if (!{
      'format',
      'schemaVersion',
      'exportedAt',
      'groups',
      'commands',
      'executionDefaults',
    }.contains(key)) {
      issue(key, '未支持的字段');
      if (issues.length >= 100) {
        issue('文件', '未支持的字段过多');
        return result();
      }
    }
  }
  if (j['exportedAt'] != null) {
    try {
      _dates({'createdAt': j['exportedAt']});
    } catch (e) {
      issue('exportedAt', e);
    }
  }
  if (j['groups'] is! List || j['commands'] is! List) {
    issue('文件', 'groups 与 commands 必须为数组');
    return result();
  }
  final rawGroups = j['groups'] as List, rawCommands = j['commands'] as List;
  if (rawGroups.length > maxLibraryGroups ||
      rawCommands.length > maxLibraryCommands) {
    issue('文件', '最多 100 个分组、5000 条命令');
    return result();
  }
  final groupIds = <String>{}, commandIds = <String>{};
  final existingGroups = existing.groups;
  final existingCommands = {
    for (final row in existing.commandRows) row['id']: row,
  };
  for (var i = 0; i < rawGroups.length; i++) {
    final location = 'groups[${i + 1}]';
    try {
      final row = _map(rawGroups[i]);
      if (row.keys.any(
        (key) => !{
          'id',
          'name',
          'sortOrder',
          'createdAt',
          'updatedAt',
        }.contains(key),
      )) {
        throw const FormatException('分组包含未支持的字段');
      }
      if (!_id(row['id']) ||
          row['name'] is! String ||
          (row['name'] as String).trim().isEmpty ||
          (row['name'] as String).length > 80) {
        throw const FormatException('分组 ID 或名称无效');
      }
      if (row['sortOrder'] != null &&
          (row['sortOrder'] is! int ||
              row['sortOrder'] < 0 ||
              row['sortOrder'] > 0x7fffffff)) {
        throw const FormatException('sortOrder 必须为整数');
      }
      _dates(row);
      if (!groupIds.add(row['id'])) {
        throw const FormatException('文件内分组 UUID 重复');
      }
      groups.add(
        _freeze({...row, 'sortOrder': row['sortOrder'] ?? i})
            as Map<String, dynamic>,
      );
      if (existingGroups.containsKey(row['id'])) {
        conflicts.add(
          LibraryImportConflict(
            group: true,
            id: row['id'],
            incomingName: row['name'],
            existingName: existingGroups[row['id']]!,
          ),
        );
      }
    } catch (e) {
      issue(location, e);
    }
  }
  for (var i = 0; i < rawCommands.length; i++) {
    final location = 'commands[${i + 1}]';
    try {
      final row = _map(rawCommands[i]);
      if (!_id(row['id']) || !_id(row['groupId'])) {
        throw const FormatException('命令 UUID 或分组引用无效');
      }
      if (row['note'] is String && (row['note'] as String).length > 65536) {
        throw const FormatException('备注超过 65536 字符');
      }
      for (final field in ['bodyHex', 'bodyText']) {
        if (row[field] is String &&
            (row[field] as String).length > 1024 * 1024) {
          throw const FormatException('命令正文超过 1 MiB');
        }
      }
      _dates(row);
      if (row['sortOrder'] != null &&
          (row['sortOrder'] is! int ||
              row['sortOrder'] < 0 ||
              row['sortOrder'] > 0x7fffffff)) {
        throw const FormatException('sortOrder 超出范围');
      }
      final command = SavedCommand.fromJson(row);
      if (!groupIds.contains(command.groupId)) {
        throw const FormatException('引用的分组不存在或无效');
      }
      if (!commandIds.add(command.id)) {
        throw const FormatException('文件内命令 UUID 重复');
      }
      commands.add(_freeze(command.toJson()) as Map<String, dynamic>);
      final old = existingCommands[command.id];
      if (old != null) {
        conflicts.add(
          LibraryImportConflict(
            group: false,
            id: command.id,
            incomingName: command.name,
            existingName: old['name'],
          ),
        );
      }
    } catch (e) {
      issue(location, e);
    }
  }
  final defaults = j['executionDefaults'];
  if (defaults != null) {
    try {
      final d = _map(defaults);
      if (d.keys.any(
        (key) => !{
          'loopEnabled',
          'periodMs',
          'waitForResponse',
          'onTimeout',
          'retryCount',
        }.contains(key),
      )) {
        throw const FormatException('执行默认值包含未支持的字段');
      }
      for (final key in ['loopEnabled', 'waitForResponse']) {
        if (d[key] != null && d[key] is! bool) {
          throw FormatException('$key 必须为布尔值');
        }
      }
      if (d['periodMs'] != null &&
          (d['periodMs'] is! int ||
              d['periodMs'] < 10 ||
              d['periodMs'] > 86400000)) {
        throw const FormatException('periodMs 超出范围');
      }
      if (d['onTimeout'] != null && d['onTimeout'] != 'stop') {
        throw const FormatException('仅支持超时停止');
      }
      if (d['retryCount'] != null &&
          (d['retryCount'] is! int || d['retryCount'] != 0)) {
        throw const FormatException('不支持自动重试');
      }
    } catch (e) {
      issue('executionDefaults', e);
    }
  }
  return result();
}

String exportCommandLibrary(
  LibrarySnapshot snapshot, {
  LibraryExportScope scope = LibraryExportScope.all,
  String? groupId,
  Set<String> selectedIds = const {},
  DateTime? now,
}) {
  if (scope == LibraryExportScope.currentGroup &&
      !snapshot.groups.containsKey(groupId)) {
    throw const FormatException('当前分组不存在');
  }
  final commands = snapshot.commandRows
      .where(
        (row) => switch (scope) {
          LibraryExportScope.currentGroup => row['groupId'] == groupId,
          LibraryExportScope.selected => selectedIds.contains(row['id']),
          LibraryExportScope.all => true,
        },
      )
      .toList();
  final needed = commands.map((row) => row['groupId']).toSet();
  final groups = snapshot.groupRows
      .where(
        (row) =>
            scope == LibraryExportScope.all ||
            needed.contains(row['id']) ||
            (scope == LibraryExportScope.currentGroup && row['id'] == groupId),
      )
      .toList();
  return const JsonEncoder.withIndent('  ').convert({
    'format': commandLibraryFormat,
    'schemaVersion': 1,
    'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
    'groups': groups,
    'commands': commands,
    'executionDefaults': {
      'loopEnabled': false,
      'periodMs': 1000,
      'waitForResponse': true,
      'onTimeout': 'stop',
      'retryCount': 0,
    },
  });
}
