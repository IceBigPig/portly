import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/ui/log_archive.dart';
import 'package:portly/ui/log_panel.dart';
import 'package:portly/ui/theme.dart';

class _MemoryStorage extends AppStorage {
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {}
  @override
  void close() {}
}

Future<AppModel> _host(
  WidgetTester tester, {
  required bool dark,
  bool start = false,
}) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = AppModel(storage: _MemoryStorage());
  await model.initialize();
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () => configureLogRecording(
                  context,
                  model,
                  session: start ? model.current : null,
                ),
                child: const Text('设置记录'),
              ),
              TextButton(
                onPressed: () => showLogArchive(context, model),
                child: const Text('查看日志'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return model;
}

Finder _value(String value) => find.byWidgetPredicate(
  (widget) => widget is TextFormField && widget.controller?.text == value,
);

void main() {
  testWidgets(
    'External comparison window cannot open a second archive worker',
    (tester) async {
      final model = await _host(tester, dark: false);
      model.externalView = true;
      await tester.tap(find.text('设置记录'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(model.current.recorder.active, isFalse);
      await tester.tap(find.text('查看日志'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('日志文件'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: Scaffold(
            body: LogPanel(session: model.current, model: model, compact: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('日志文件 / 索引搜索'), findsNothing);
      expect(find.text('日志记录设置'), findsNothing);
      expect(find.text('重置 RX / TX 统计'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('重置 RX / TX 统计'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
  for (final dark in [false, true]) {
    testWidgets(
      'Recording settings default to bounded stop policy; directory required ($dark)',
      (tester) async {
        final model = await _host(tester, dark: dark, start: true);
        await tester.tap(find.text('设置记录'));
        await tester.pumpAndSettle();
        expect(_value('100'), findsOneWidget);
        expect(_value('20'), findsOneWidget);
        expect(_value('2048'), findsOneWidget);
        expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
        await tester.tap(find.text('开始记录'));
        await tester.pumpAndSettle();
        expect(find.text('请选择日志目录'), findsOneWidget);
        expect(model.current.recorder.active, isFalse);
        expect(model.logOptions.directory, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );

    testWidgets(
      'Archive search/filter expansion fits 900x600 without selecting directory ($dark)',
      (tester) async {
        final model = await _host(tester, dark: dark);
        await tester.tap(find.text('查看日志'));
        await tester.pumpAndSettle();
        expect(find.text('日志文件'), findsOneWidget);
        expect(find.text('0 个文件 · 日志占用 0 B'), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        final rebuild = find.widgetWithText(TextButton, '重建索引');
        expect(tester.widget<TextButton>(rebuild).onPressed, isNull);
        await tester.tap(find.text('筛选'));
        await tester.pumpAndSettle();
        expect(find.text('起始时间'), findsOneWidget);
        expect(find.text('结束时间'), findsOneWidget);
        final search = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '搜索文件中的报文',
        );
        await tester.enterText(search, 'test');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(LinearProgressIndicator), findsNothing);
        await tester.tap(find.text('文本'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('HEX'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部方向'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('RX'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('文件'));
        await tester.pumpAndSettle();
        expect(find.text('暂无日志文件'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      },
    );
  }

  testWidgets(
    'Recording settings save changed limits without starting capture',
    (tester) async {
      final model = await _host(tester, dark: false);
      model.logOptions = const LogRecordingOptions(
        directory: '/tmp/logs-not-opened-by-ui-test',
      );
      await tester.tap(find.text('设置记录'));
      await tester.pumpAndSettle();
      await tester.enterText(_value('100'), '64');
      await tester.enterText(_value('20'), '8');
      await tester.enterText(_value('2048'), '512');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(model.logOptions.fileLimitBytes, 64 * 1024 * 1024);
      expect(model.logOptions.maxFiles, 8);
      expect(model.logOptions.maxTotalBytes, 512 * 1024 * 1024);
      expect(model.logOptions.overwriteOldest, isTrue);
      expect(model.current.recorder.active, isFalse);
      expect(await model.flushPendingSave(), isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );
}
