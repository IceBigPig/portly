import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/bytes.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';
import 'package:portly/ui/send_panel.dart';
import 'package:portly/ui/theme.dart';

class _MemoryStorage extends AppStorage {
  int writes = 0;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    writes++;
    if (fail) throw StateError('磁盘写入失败');
  }

  @override
  void close() {}
}

class _CaptureSession extends Session {
  List<SavedCommand> executed = [];
  Map<String, Map<String, String>> values = {};
  int executions = 0;
  _CaptureSession() : super(config: ConnectionConfig()) {
    mirroredCanSend = true;
    commandsMode = true;
  }
  @override
  Future<void> execute(
    List<SavedCommand> commands, {
    bool repeat = false,
    Map<String, Map<String, String>> parameterValues = const {},
  }) async {
    executions++;
    executed = commands;
    values = parameterValues;
  }
}

SavedCommand _parameterCommand() => SavedCommand(
  id: 'parameter-command',
  name: '读取寄存器',
  draft: Draft(body: '{{station}} 03 00 00 00 02', crc: true),
  parameters: const [
    CommandParameter(
      name: 'station',
      type: 'uint8',
      defaultValue: '1',
      min: 1,
      max: 247,
    ),
  ],
  responseRule: const ResponseRule(),
  tags: ['读取', '传感器'],
);

Future<({AppModel model, _CaptureSession session, _MemoryStorage storage})>
_panel(WidgetTester tester, SavedCommand command) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final storage = _MemoryStorage();
  final model = AppModel(storage: storage);
  await model.initialize();
  for (final session in model.sessions) {
    session.dispose();
  }
  final session = _CaptureSession();
  model.sessions
    ..clear()
    ..add(session);
  model.currentId = session.id;
  model.commands.add(command);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(false),
      home: Scaffold(
        body: SizedBox(
          height: 420,
          child: SendPanel(
            model: model,
            session: session,
            collapsed: false,
            toggleCollapsed: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  return (model: model, session: session, storage: storage);
}

void main() {
  testWidgets(
    'Parameter changes conflicting with fixed response criteria disable execution before send',
    (tester) async {
      final command = _parameterCommand()
        ..responseRule = const ResponseRule(unitId: 1);
      final state = await _panel(tester, command);
      await tester.tap(find.byTooltip('发送此命令'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('parameter-parameter-command-station')),
        '2',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm-command-parameters')),
            )
            .onPressed,
        isNull,
      );
      expect(find.textContaining('响应规则'), findsOneWidget);
      expect(state.session.executions, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('A failed command-library save prevents row execution', (
    tester,
  ) async {
    final state = await _panel(tester, _parameterCommand());
    state.storage.fail = true;
    final bodyField = find.descendant(
      of: find.byType(InlineEdit).at(1),
      matching: find.byType(TextField),
    );
    await tester.enterText(bodyField, '{{station}} 03 00 00 00 01');
    await tester.pump();
    await tester.tap(find.byTooltip('发送此命令'));
    await tester.pumpAndSettle();
    expect(state.storage.writes, 1);
    expect(state.model.storageError, contains('磁盘写入失败'));
    expect(state.session.executions, 0);
    expect(find.text('命令参数'), findsNothing);
    expect(state.session.tx, 0);
  });

  testWidgets('Command search includes tags', (tester) async {
    final command = _parameterCommand();
    await _panel(tester, command);
    final search = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.hintText == '搜索命令',
    );
    await tester.enterText(search, '传感器');
    await tester.pump();
    expect(find.byType(InlineEdit), findsNWidgets(2));
    await tester.enterText(search, '不存在的标签');
    await tester.pump();
    expect(find.byType(InlineEdit), findsNothing);
  });

  testWidgets(
    'Parameter prompt previews exact bytes and invalid values never send',
    (tester) async {
      final command = _parameterCommand();
      final state = await _panel(tester, command);
      await tester.tap(find.byTooltip('发送此命令'));
      await tester.pumpAndSettle();
      expect(find.text('命令参数'), findsOneWidget);
      expect(find.text('${hex(command.buildBytes())} · 8 B'), findsOneWidget);
      expect(state.session.executions, 0);
      final field = find.byKey(
        const ValueKey('parameter-parameter-command-station'),
      );
      await tester.enterText(field, '248');
      await tester.pump();
      final action = tester.widget<FilledButton>(
        find.byKey(const ValueKey('confirm-command-parameters')),
      );
      expect(action.onPressed, isNull);
      expect(find.textContaining('超出范围'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.session.executions, 0);
      expect(state.session.tx, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Row execution keeps response rules and freezes template before parameter dialog',
    (tester) async {
      final command = _parameterCommand();
      final state = await _panel(tester, command);
      await tester.tap(find.byTooltip('发送此命令'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('parameter-parameter-command-station')),
        '7',
      );
      await tester.pump();
      expect(
        find.text('${hex(command.buildBytes({'station': '7'}))} · 8 B'),
        findsOneWidget,
      );
      command.draft.body = 'FF';
      await tester.tap(
        find.byKey(const ValueKey('confirm-command-parameters')),
      );
      await tester.pumpAndSettle();
      expect(state.session.executions, 1);
      expect(
        state.session.executed.single.draft.body,
        '{{station}} 03 00 00 00 02',
      );
      expect(state.session.executed.single.responseRule!.kind, 'modbus_rtu');
      expect(state.session.values, {
        'parameter-command': {'station': '7'},
      });
      expect(
        state.storage.writes,
        0,
      ); // No unchanged command-library write on send.
    },
  );

  testWidgets(
    'Parameterized command load resolves bytes without transmitting',
    (tester) async {
      final command = _parameterCommand();
      final state = await _panel(tester, command);
      await tester.tap(find.byTooltip('命令操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('载入单条发送'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('parameter-parameter-command-station')),
        '2',
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('confirm-command-parameters')),
      );
      await tester.pumpAndSettle();
      expect(state.session.draft.build(), command.buildBytes({'station': '2'}));
      await tester.pump(const Duration(seconds: 3));
      expect(state.session.commandsMode, isFalse);
      expect(state.session.executions, 0);
      expect(state.session.tx, 0);
    },
  );

  testWidgets(
    'Invalid inline template blocks stale send; valid commit increments revision once',
    (tester) async {
      final command = _parameterCommand();
      final state = await _panel(tester, command);
      final bodyField = find.descendant(
        of: find.byType(InlineEdit).at(1),
        matching: find.byType(TextField),
      );
      await tester.enterText(bodyField, '{{missing}}');
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
      expect(command.draft.body, '{{station}} 03 00 00 00 02');
      await tester.enterText(bodyField, '{{station}} 03 00 00 00 01');
      await tester.pump();
      await tester.tap(find.byTooltip('发送此命令'));
      await tester.pumpAndSettle();
      expect(command.draft.body, '{{station}} 03 00 00 00 01');
      expect(command.revision, 2);
      expect(state.storage.writes, 1);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(state.session.executions, 0);
    },
  );

  testWidgets(
    'Advanced command editor preserves metadata and edits rule at 900x600 dark',
    (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(storage: _MemoryStorage());
      await model.initialize();
      final command = _parameterCommand()
        ..sortOrder = 4
        ..createdAt = '2026-10-25T00:00:00Z';
      model.commands.add(command);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(true),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editCommand(context, model, command: command),
                child: const Text('编辑'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('command-name')), '新名称');
      await tester.ensureVisible(find.text('响应匹配'));
      await tester.tap(find.text('响应匹配'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Modbus RTU'));
      await tester.tap(find.text('Modbus RTU'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('HEX 完全匹配'));
      await tester.tap(find.text('HEX 完全匹配'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('response-length')));
      await tester.enterText(
        find.byKey(const ValueKey('response-length')),
        '1',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('response-pattern')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('response-pattern')),
        '06',
      );
      await tester.tap(find.text('保存命令'));
      await tester.pumpAndSettle();
      expect(find.text('编辑命令'), findsNothing);
      final next = model.commands.single;
      expect(next.name, '新名称');
      expect(next.parameters.single.name, 'station');
      expect(next.responseRule!.kind, 'bytes_exact');
      expect(next.responseRule!.patternHex, '06');
      expect(next.tags, ['读取', '传感器']);
      expect(next.sortOrder, 4);
      expect(next.createdAt, '2026-10-25T00:00:00Z');
      expect(next.revision, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  testWidgets(
    'New command editor creates a typed parameter and resolves CRC preview',
    (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(storage: _MemoryStorage());
      await model.initialize();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editCommand(
                  context,
                  model,
                  initial: Draft(body: '{{station}} 03 00 00 00 02', crc: true),
                ),
                child: const Text('新增'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('新增'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('command-name')),
        '带参数读取',
      );
      await tester.ensureVisible(find.text('参数 · 0'));
      await tester.tap(find.text('参数 · 0'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('add-command-parameter')),
      );
      await tester.tap(find.byKey(const ValueKey('add-command-parameter')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('parameter-name-0')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('parameter-name-0')),
        'station',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('uint16'));
      await tester.tap(find.text('uint16'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('uint8'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('parameter-default-0')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('parameter-default-0')),
        '1',
      );
      await tester.pump();
      expect(find.text('01 03 00 00 00 02 C4 0B · 8 B'), findsOneWidget);
      await tester.tap(find.text('保存命令'));
      await tester.pumpAndSettle();
      expect(model.commands.single.parameters.single.type, 'uint8');
      expect(model.commands.single.buildBytes(), [
        1,
        3,
        0,
        0,
        0,
        2,
        0xC4,
        0x0B,
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
