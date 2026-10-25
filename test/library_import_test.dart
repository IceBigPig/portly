import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/core/models.dart';

SavedCommand command(String id, {String group = 'g', String name = '同名命令'}) =>
    SavedCommand(
      id: id,
      groupId: group,
      name: name,
      draft: Draft(body: '01 03 00 00 00 02', crc: true),
    );
LibrarySnapshot snapshot({
  Map<String, String> groups = const {'g': '已有组'},
  List<SavedCommand> commands = const [],
}) => LibrarySnapshot.capture(groups: groups, commands: commands);
String library({
  List<Map<String, dynamic>>? groups,
  List<Map<String, dynamic>>? commands,
  Map<String, dynamic>? defaults,
  dynamic version = 1,
}) => jsonEncode({
  'format': commandLibraryFormat,
  'schemaVersion': version,
  'groups':
      groups ??
      [
        {'id': 'g', 'name': '文件组', 'sortOrder': 0},
      ],
  'commands': commands ?? [command('c').toJson()],
  'executionDefaults': ?defaults,
});

void main() {
  test(
    'UUID conflicts default to keep and same-name independent UUID is added',
    () {
      final old = command('old');
      final source = library(
        commands: [
          command('old', name: '改名').toJson(),
          command('new').toJson(),
        ],
      );
      final preview = inspectLibraryImport(source, snapshot(commands: [old]));
      expect(preview.valid, true);
      expect(preview.conflicts.map((c) => c.key), ['group:g', 'command:old']);
      final plan = preview.buildPlan();
      expect(plan.groups['g'], '已有组');
      expect(plan.commands.map((c) => c.name), ['同名命令', '同名命令']);
      expect(plan.addedCommands, 1);
      expect(plan.skippedCommands, 1);
      expect(plan.skippedGroups, 1);
      expect(old.name, '同名命令');
    },
  );

  test('group copy remaps imported children and leaves original names/references intact', () {
    final preview = inspectLibraryImport(
      library(commands: [command('old').toJson(), command('new').toJson()]),
      snapshot(commands: [command('old', name: '原有')]),
    );
    final plan = preview.buildPlan(
      choices: {'group:g': ImportChoice.copy, 'command:old': ImportChoice.copy},
    );
    expect(plan.groups.length, 2);
    expect(plan.groups['g'], '已有组');
    final copyId = plan.groups.keys.singleWhere((id) => id != 'g');
    expect(plan.groups[copyId], '文件组');
    expect(plan.commands.singleWhere((c) => c.id == 'old').groupId, 'g');
    expect(
      plan.commands
          .where((c) => c.id != 'old')
          .every((c) => c.groupId == copyId),
      true,
    );
    expect(plan.commands.map((c) => c.id).toSet().length, 3);
    expect(plan.copiedGroups, 1);
    expect(plan.copiedCommands, 1);
  });

  test('command copy in kept group does not rename existing group', () {
    final preview = inspectLibraryImport(
      library(),
      snapshot(commands: [command('c')]),
    );
    final plan = preview.buildPlan(choices: {'command:c': ImportChoice.copy});
    expect(plan.groups, {'g': '已有组'});
    expect(plan.commands.length, 2);
    expect(plan.commands.every((c) => c.groupId == 'g'), true);
  });

  test('overwrite preserves parameter/rule/tags/order/times and is deeply immutable', () {
    final advanced = SavedCommand(
      id: 'c',
      groupId: 'g',
      name: '参数读取',
      draft: Draft(body: '{{unit}} 03 00 00 00 02', crc: true),
      parameters: const [
        CommandParameter(
          name: 'unit',
          type: 'uint8',
          defaultValue: '1',
          min: 1,
          max: 247,
        ),
      ],
      responseRule: const ResponseRule(),
      tags: ['读取', '设备'],
      sortOrder: 31,
      revision: 7,
      note: '备注',
      createdAt: '2026-10-25T00:00:00Z',
      updatedAt: '2026-10-25T01:00:00Z',
    );
    final incomingGroup = {
      'id': 'g',
      'name': '文件组',
      'sortOrder': 8,
      'createdAt': '2026-10-24T00:00:00Z',
    };
    final original = snapshot(commands: [command('c')]);
    final preview = inspectLibraryImport(
      library(groups: [incomingGroup], commands: [advanced.toJson()]),
      original,
    );
    expect(preview.issues, isEmpty);
    final plan = preview.buildPlan(
      choices: {
        'group:g': ImportChoice.overwrite,
        'command:c': ImportChoice.overwrite,
      },
    );
    expect(plan.overwrites, true);
    expect(plan.commands.single.toJson(), advanced.toJson());
    expect(plan.groupMetadata['g'], incomingGroup);
    expect(
      () => plan.groupMetadata['g']!['name'] = 'tamper',
      throwsUnsupportedError,
    );
    expect(
      () => original.commandRows.single['tags'].add('tamper'),
      throwsUnsupportedError,
    );
    final copy = plan.commands.single;
    copy.name = 'tamper';
    copy.tags.add('tamper');
    copy.draft.body = 'FF';
    expect(plan.commands.single.toJson(), advanced.toJson());
    expect(plan.matches(original), true);
    expect(
      plan.matches(snapshot(commands: [command('c', name: '预览后修改')])),
      false,
    );
    final switched = LibrarySnapshot.capture(
      groups: original.groups,
      commands: original.commands,
    );
    expect(plan.matches(switched), true);
  });

  test('full batch rejected with indexed reasons for malformed and invalid references', () {
    final preview = inspectLibraryImport(
      library(
        commands: [
          command('good').toJson(),
          {...command('bad').toJson(), 'bodyHex': 'XX'},
          command('orphan', group: 'missing').toJson(),
          {'id': 'empty'},
        ],
      ),
      snapshot(groups: {}),
    );
    expect(preview.valid, false);
    expect(preview.issues.map((i) => i.location), [
      'commands[2]',
      'commands[3]',
      'commands[4]',
    ]);
    expect(preview.issues.every((i) => i.reason.isNotEmpty), true);
    expect(() => preview.buildPlan(), throwsStateError);
  });

  test('duplicate group and command UUIDs reject full batch', () {
    final preview = inspectLibraryImport(
      library(
        groups: [
          {'id': 'g', 'name': 'A'},
          {'id': 'g', 'name': 'B'},
        ],
        commands: [command('c').toJson(), command('c').toJson()],
      ),
      snapshot(),
    );
    expect(preview.valid, false);
    expect(
      preview.issues.map((i) => i.location),
      containsAll(['groups[2]', 'commands[2]']),
    );
  });

  test('higher schema, wrong field types, timestamps and unsupported behavior reject', () {
    for (final source in [
      library(version: 2),
      library(version: 1.0),
      library(
        groups: [
          {'id': 'g', 'name': 'G', 'sortOrder': '0'},
        ],
      ),
      library(
        commands: [
          {...command('c').toJson(), 'updatedAt': 'yesterday'},
        ],
      ),
      library(
        commands: [
          {...command('c').toJson(), 'sortOrder': -1},
        ],
      ),
      library(defaults: {'retryCount': 1}),
      library(defaults: {'retryCount': 0.0}),
      library(defaults: {'onTimeout': 'retry'}),
      library(defaults: {'periodMs': 0}),
      library(
        groups: [
          {'id': 'g', 'name': 'G', 'unknown': true},
        ],
      ),
      '{"groups": []}',
      '[]',
      'invalid json',
    ]) {
      final preview = inspectLibraryImport(source, snapshot());
      expect(preview.valid, false, reason: source);
      expect(() => preview.buildPlan(), throwsStateError);
    }
  });

  test('incoming loop enabled never becomes executable state and export forces disabled', () {
    final preview = inspectLibraryImport(
      library(
        defaults: {
          'loopEnabled': true,
          'periodMs': 1000,
          'waitForResponse': true,
          'onTimeout': 'stop',
          'retryCount': 0,
        },
      ),
      snapshot(),
    );
    expect(preview.valid, true);
    final plan = preview.buildPlan();
    final output = jsonDecode(
      exportCommandLibrary(
        LibrarySnapshot.capture(
          groups: plan.groups,
          commands: plan.commands,
          groupMetadata: plan.groupMetadata,
        ),
      ),
    );
    expect(output['executionDefaults']['loopEnabled'], false);
    expect(output['commands'].single.containsKey('loopEnabled'), false);
  });

  test('scope exports preserve exact metadata and only referenced groups', () {
    final advanced = command('selected', group: 'other')
      ..sortOrder = 12
      ..createdAt = '2026-10-25T00:00:00Z';
    final source = LibrarySnapshot.capture(
      groups: {'g': '组一', 'other': '组二', 'empty': '空组'},
      commands: [command('c'), advanced],
      groupMetadata: {
        'other': {'sortOrder': 17, 'updatedAt': '2026-10-25T01:00:00Z'},
      },
    );
    final selected = jsonDecode(
      exportCommandLibrary(
        source,
        scope: LibraryExportScope.selected,
        selectedIds: {'selected'},
      ),
    );
    expect(selected['commands'], [advanced.toJson()]);
    expect(selected['groups'], [
      {
        'id': 'other',
        'name': '组二',
        'sortOrder': 17,
        'updatedAt': '2026-10-25T01:00:00Z',
      },
    ]);
    final current = jsonDecode(
      exportCommandLibrary(
        source,
        scope: LibraryExportScope.currentGroup,
        groupId: 'empty',
      ),
    );
    expect(current['commands'], isEmpty);
    expect(current['groups'].single['id'], 'empty');
    final all = jsonDecode(exportCommandLibrary(source));
    expect(all['groups'].length, 3);
    expect(all['commands'].length, 2);
    expect(
      () => exportCommandLibrary(
        source,
        scope: LibraryExportScope.currentGroup,
        groupId: 'missing',
      ),
      throwsFormatException,
    );
    expect(
      inspectLibraryImport(jsonEncode(selected), snapshot(groups: {})).valid,
      true,
    );
  });

  test(
    'bounded input and resulting library prevent unbounded allocations/merge',
    () {
      expect(
        inspectLibraryImport(
          ' ' * (maxLibraryImportBytes + 1),
          snapshot(),
        ).issues.single.reason,
        contains('16 MiB'),
      );
      final source = library(
        commands: List.generate(5001, (i) => command('c$i').toJson()),
      );
      expect(inspectLibraryImport(source, snapshot()).valid, false);
      final full = snapshot(
        commands: List.generate(5000, (i) => command('c$i')),
      );
      final preview = inspectLibraryImport(
        library(commands: [command('new').toJson()]),
        full,
      );
      expect(preview.valid, true);
      expect(() => preview.buildPlan(), throwsFormatException);
    },
  );

  test(
    'large-library validation and plan safely cross isolate boundaries',
    () async {
      final rows = List.generate(5000, (i) => command('c$i'));
      final captured = snapshot(commands: rows);
      final input = library(commands: rows.map((c) => c.toJson()).toList());
      final preview = await Isolate.run(
        () => inspectLibraryImport(input, captured),
      );
      expect(preview.valid, true);
      expect(preview.conflicts.length, 5001);
      final plan = await Isolate.run(
        () => preview.buildPlan(
          choices: {
            for (final conflict in preview.conflicts)
              conflict.key: ImportChoice.overwrite,
          },
        ),
      );
      expect(plan.matches(captured), true);
      expect(plan.commands.length, 5000);
      expect(plan.groupMetadata['g']!['name'], '文件组');
    },
  );

  test('unknown choice keys cannot mutate preview plan', () {
    final preview = inspectLibraryImport(library(), snapshot());
    expect(
      () => preview.buildPlan(
        choices: {'command:absent': ImportChoice.overwrite},
      ),
      throwsFormatException,
    );
  });
}
