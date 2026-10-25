import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';
import 'package:portly/ui/history.dart';
import 'package:portly/ui/send_panel.dart';
import 'package:portly/ui/theme.dart';

class _Storage extends AppStorage {
  final history = <HistoryRecord>[];
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {}
  @override
  Future<String> commitLibraryImport({
    required String expectedFingerprint,
    required Map<String, dynamic> state,
  }) async => '/tmp/production-ui-import.backup';
  @override
  Future<HistoryPage> queryHistory({
    String sessionId = '',
    String taskId = '',
    String before = '',
    int limit = 100,
    List<String> kinds = const [],
  }) async => HistoryPage(records: history, count: history.length);
  @override
  Future<HistoryRecord?> getHistory(String id) async =>
      history.where((r) => r.id == id).firstOrNull;
  @override
  void close() {}
}

class _Session extends Session {
  _Session() : super(config: ConnectionConfig()) {
    mirroredCanSend = true;
    commandsMode = true;
  }
}

Future<AppModel> _host(WidgetTester tester, {int count = 1}) async {
  tester.view.physicalSize = const Size(1100, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = AppModel(storage: _Storage());
  await model.initialize();
  for (final session in model.sessions) {
    session.dispose();
  }
  final session = _Session();
  model.sessions
    ..clear()
    ..add(session);
  model.currentId = session.id;
  model.commands.addAll(
    List.generate(
      count,
      (i) => SavedCommand(
        id: 'command-$i',
        name: '命令 $i',
        draft: Draft(body: 'AA'),
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(false),
      home: Scaffold(
        body: Column(
          children: [
            Builder(
              builder: (context) => TextButton(
                onPressed: () => showSendHistory(context, model, session),
                child: const Text('历史'),
              ),
            ),
            SizedBox(
              height: 500,
              child: AnimatedBuilder(
                animation: model,
                builder: (_, _) => SendPanel(
                  model: model,
                  session: session,
                  collapsed: false,
                  toggleCollapsed: () {},
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  return model;
}

Finder _body() => find.descendant(
  of: find.byWidgetPredicate((w) => w is InlineEdit && w.monospace).first,
  matching: find.byType(TextField),
);

void main() {
  testWidgets(
    'Import gate blocks focused keyboard submission and makes field read-only',
    (tester) async {
      final model = await _host(tester);
      final field = _body();
      await tester.enterText(field, 'BB');
      await tester.pump();
      expect(model.commands.single.draft.body, 'AA');
      // Simulate an Enter action already queued by the platform before the import
      // switched the focused editor to read-only. The old callback must also gate.
      final queuedSubmit = tester.widget<TextField>(field).onSubmitted!;
      model.libraryImporting = true;
      model.refresh();
      await tester.pump();
      expect(tester.widget<TextField>(field).readOnly, true);
      queuedSubmit('BB');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(model.commands.single.draft.body, 'AA');
      expect(model.commands.single.revision, 1);
      model.libraryImporting = false;
      model.refresh();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Invalid inline draft survives virtual-list eviction and blocks stale-byte sending',
    (tester) async {
      final model = await _host(tester, count: 100);
      await tester.enterText(_body(), 'GG');
      await tester.pump();
      expect(model.commands.first.draft.body, 'AA');
      expect(
        tester
            .widget<IconButton>(
              find
                  .byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == '发送此命令',
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      final list = find.byType(ListView);
      await tester.drag(list, const Offset(0, -2600));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((w) => w is InlineEdit && w.value == 'GG'),
        findsNothing,
      );
      final scrollable = find.descendant(
        of: list,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        ),
      );
      tester.state<ScrollableState>(scrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(_body()).controller!.text, 'GG');
      expect(model.commands.first.draft.body, 'AA');
      expect(
        tester
            .widget<IconButton>(
              find
                  .byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == '发送此命令',
                  )
                  .first,
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(_body(), 'AB');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(model.commands.first.draft.body, 'AB');
      await model.flushPendingSave();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find
                  .byWidgetPredicate(
                    (w) => w is IconButton && w.tooltip == '发送此命令',
                  )
                  .first,
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Same-UUID committed import replaces stale invalid editor state with imported bytes',
    (tester) async {
      final model = await _host(tester);
      final original = model.commands.single;
      final imported = SavedCommand(
        id: original.id,
        name: '导入命令',
        draft: Draft(body: 'CC DD'),
        revision: 7,
      );
      final preview = inspectLibraryImport(
        jsonEncode({
          'format': commandLibraryFormat,
          'schemaVersion': 1,
          'groups': [
            {'id': 'default', 'name': '默认分组'},
          ],
          'commands': [imported.toJson()],
        }),
        model.librarySnapshot,
      );
      final plan = preview.buildPlan(
        choices: {'command:${original.id}': ImportChoice.overwrite},
      );
      await tester.enterText(_body(), 'GG');
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '发送此命令',
              ),
            )
            .onPressed,
        isNull,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.runAsync(() => model.applyLibraryImport(plan));
      await tester.pumpAndSettle();
      expect(model.libraryRevision, 1);
      expect(model.commands.single.revision, 7);
      expect(tester.widget<TextField>(_body()).controller!.text, 'CC DD');
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '发送此命令',
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        find.byWidgetPredicate((w) => w is InlineEdit && w.value == 'GG'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'First recorded command step and cycle remain one-based in history details',
    (tester) async {
      final model = await _host(tester);
      (model.storage as _Storage).history.add(
        HistoryRecord(
          kind: 'step',
          sessionId: model.current.id,
          runtimeId: 'run',
          name: '首步骤',
          stepIndex: 1,
          cycle: 1,
          status: 'response',
          finalBytes: [1],
        ),
      );
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('首步骤'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.text('2 / 2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
