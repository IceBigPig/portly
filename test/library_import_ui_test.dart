import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/core/models.dart';
import 'package:portly/ui/library_import.dart';
import 'package:portly/ui/theme.dart';

LibraryImportPreview preview({int count = 1, bool invalid = false}) {
  final commands = List.generate(
    count,
    (i) => SavedCommand(
      id: 'c$i',
      groupId: 'g',
      name: '命令 $i',
      draft: Draft(body: '01'),
    ),
  );
  final snapshot = LibrarySnapshot.capture(
    groups: {'g': '原分组'},
    commands: commands,
  );
  return inspectLibraryImport(
    jsonEncode({
      'format': commandLibraryFormat,
      'schemaVersion': 1,
      'groups': [
        {'id': 'g', 'name': '文件分组'},
      ],
      'commands': commands
          .map((c) => {...c.toJson(), if (invalid) 'bodyHex': 'GG'})
          .toList(),
    }),
    snapshot,
  );
}

Future<void> host(
  WidgetTester tester, {
  bool dark = false,
  required VoidCallback open,
}) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: open, child: const Text('打开')),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('cancel leaves snapshot untouched and no import plan', (
    tester,
  ) async {
    final source = preview();
    LibraryImportPlan? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(false),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showLibraryImportPreview(context, source);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.textContaining('UUID 冲突'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(source.existing.groups['g'], '原分组');
    expect(source.existing.commands.single.id, 'c0');
  });
  for (final dark in [false, true]) {
    testWidgets(
      '5000 conflicts virtualized and actionable at 900x600 dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(900, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final source = preview(count: 5000);
        LibraryImportPlan? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(dark),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showLibraryImportPreview(context, source);
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byType(DropdownButtonFormField<ImportChoice>).evaluate().length,
          lessThan(20),
        );
        await tester.enterText(find.byType(TextField), 'c4999');
        await tester.pumpAndSettle();
        expect(find.text('c4999'), findsWidgets);
        await tester.tap(find.text('全部冲突处理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('覆盖现有').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('导入'));
        await tester.pumpAndSettle();
        expect(result, isNotNull);
        expect(result!.overwrittenCommands, 5000);
        expect(result!.overwrittenGroups, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('invalid batch shows row reasons and disables commit', (
    tester,
  ) async {
    final source = preview(invalid: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(true),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLibraryImportPreview(context, source),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('commands[1]'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '导入'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'export selector supports current group/selected/all without implicit export',
    (tester) async {
      LibraryExportScope? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await chooseLibraryExportScope(
                    context,
                    currentGroup: '当前组',
                    selectedCount: 2,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(find.text('当前分组 · 当前组'), findsOneWidget);
      expect(find.text('全部命令库'), findsOneWidget);
      await tester.tap(find.text('选中命令 · 2'));
      await tester.pumpAndSettle();
      expect(result, LibraryExportScope.selected);
    },
  );
}
