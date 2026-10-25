// Run explicitly: PORTLY_CAPTURE_UI=1 ./tool/flutter.sh test tool/capture_desktop_ui_test.dart
// Capture actual Flutter widgets against a temporary archive; never opens the
// user's application database, and removes all generated archive data at exit.
// PORTLY_CAPTURE_ARCHIVE_DIR=/absolute/empty/path retains a disposable archive
// for a separate native directory-picker check; the caller removes it afterward.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/ui/command_editor.dart';
import 'package:portly/ui/log_archive.dart';
import 'package:portly/ui/shell.dart';
import 'package:portly/ui/theme.dart';

class _CaptureStorage extends AppStorage {
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {}
  @override
  void close() {}
}

ThemeData _captureTheme() {
  final theme = appTheme(false);
  // Native button labels use the platform fallback. flutter_tester forces that
  // fallback to Ahem; specify the same PingFang face for captures only.
  ButtonStyle fontStyle(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) =>
              (style?.textStyle?.resolve(states) ?? theme.textTheme.labelLarge!)
                  .copyWith(fontFamily: 'PingFang SC'),
        ),
      );
  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: fontStyle(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: fontStyle(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: fontStyle(theme.textButtonTheme.style),
    ),
  );
}

Future<void> _font(String family, String path) async {
  final font = FontLoader(family);
  final bytes = await File(path).readAsBytes();
  font.addFont(Future.value(ByteData.sublistView(bytes)));
  await font.load();
}

Future<void> _settleIo(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 40));
    if (ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  throw StateError('Timed out waiting for archive UI');
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  expect(tester.takeException(), isNull);
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = File('docs/screenshots/$name');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final enabled = Platform.environment['PORTLY_CAPTURE_UI'] == '1';
  setUpAll(() async {
    if (!enabled) return;
    var fontPath = Platform.environment['PORTLY_CJK_FONT'];
    fontPath ??=
        Directory('/System/Library/AssetsV2/com_apple_MobileAsset_Font8')
            .listSync(recursive: true)
            .whereType<File>()
            .firstWhere((file) => file.path.endsWith('/PingFang.ttc'))
            .path;
    await _font('PingFang SC', fontPath);
    // Flutter's test host defaults button typography to Roboto. Register the
    // same CJK face there so captures include readable labels, rather than the
    // test host's Ahem replacement glyphs.
    await _font('Roboto', fontPath);
    await _font('Ahem', fontPath);
    await _font('Menlo', fontPath);
    await _font('JetBrainsMono', 'assets/fonts/JetBrainsMono-Regular.ttf');
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets(
    'Render actual indexed archive, parameter rules and original packet',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = AppModel(storage: _CaptureStorage());
      await model.initialize();
      final session = model.current;
      session.config.name = '串口 01';
      session.config.port = '/dev/cu.usbserial-01';
      final errors = <String>[];
      Directory? temporary;
      final retainedPath = Platform.environment['PORTLY_CAPTURE_ARCHIVE_DIR'];
      final keepArchive = retainedPath != null && retainedPath.isNotEmpty;
      try {
        await tester.runAsync(() async {
          if (keepArchive) {
            if (!retainedPath.startsWith('/')) {
              throw const FormatException(
                'PORTLY_CAPTURE_ARCHIVE_DIR requires an absolute path',
              );
            }
            temporary = await Directory(retainedPath).create(recursive: true);
            if (!await temporary!.list().isEmpty) {
              throw StateError('Capture archive directory must be empty');
            }
          } else {
            temporary = await Directory.systemTemp.createTemp(
              'portly-ui-capture-',
            );
          }
          model.logOptions = LogRecordingOptions(
            directory: temporary!.path,
            baseName: 'serial01',
          );
          await session.recorder.start(
            errors.add,
            options: model.logOptions,
            sessionId: session.id,
            sessionName: session.config.name,
            runtimeId: session.runtimeId,
          );
          for (var i = 0; i < 8; i++) {
            session.addLog(
              LogEntry(
                'TX',
                [1, 3, 0, 0, 0, 2, 0xC4, 0x0B],
                endpoint: session.config.port,
                time: DateTime(2026, 10, 25, 14, 32, i),
              ),
            );
            session.addLog(
              LogEntry(
                'RX',
                utf8.encode(
                  'temperature=${(23.5 + i * .05).toStringAsFixed(2)},humidity=48.2\r\n',
                ),
                endpoint: session.config.port,
                time: DateTime(2026, 10, 25, 14, 32, i, 24),
              ),
            );
          }
          await session.recorder.stop();
        });
        expect(errors, isEmpty);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _captureTheme(),
              scrollBehavior: const AppScrollBehavior(),
              home: AppShell(model: model),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(AppShell));
        unawaited(showLogArchive(context, model, session: session));
        await tester.pump();
        await _settleIo(tester, () => find.text('16 条').evaluate().isNotEmpty);
        final search = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.hintText == '搜索文件中的报文',
        );
        await tester.enterText(search, 'temperature');
        await tester.pump(const Duration(milliseconds: 300));
        await _settleIo(tester, () => find.text('8 条').evaluate().isNotEmpty);
        await tester.tap(find.text('筛选'));
        await tester.pumpAndSettle();
        await _capture(tester, key, '0.4-log-index-1440.png');

        final firstHit = find
            .descendant(
              of: find.byType(AlertDialog).last,
              matching: find.textContaining('74 65 6D 70'),
            )
            .first;
        await tester.tap(firstHit);
        await tester.pump();
        await _settleIo(
          tester,
          () => find.text('RX · 报文详情').evaluate().isNotEmpty,
        );
        tester.view.physicalSize = const Size(900, 600);
        await tester.pumpAndSettle();
        await tester.tap(find.text('74').first);
        await tester.pump();
        await _capture(tester, key, '0.4-packet-900.png');
        await tester.tap(find.text('关闭').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();

        tester.view.physicalSize = const Size(1440, 900);
        await tester.pumpAndSettle();
        final command = SavedCommand(
          name: '读取温湿度',
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
          responseRule: const ResponseRule(registerCount: 2),
          tags: ['读取'],
        );
        model.commands.add(command);
        unawaited(editCommand(context, model, command: command));
        await tester.pumpAndSettle();
        await tester.tap(find.text('参数 · 1'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('响应匹配'));
        await tester.tap(find.text('响应匹配'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('识别异常响应'));
        await tester.pumpAndSettle();
        final editorScroll = find
            .descendant(
              of: find.byType(AlertDialog).last,
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        await tester.drag(editorScroll, const Offset(0, 70));
        await tester.pumpAndSettle();
        await _capture(tester, key, '0.4-command-editor-1440.png');

        tester.view.physicalSize = const Size(900, 600);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('parameter-name-0')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('识别异常响应'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        model.dispose();
        if (!keepArchive) {
          await tester.runAsync(() => temporary!.delete(recursive: true));
        }
        temporary = null;
      } finally {
        if (temporary != null) {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await session.recorder.stop();
            model.dispose();
            if (!keepArchive) await temporary!.delete(recursive: true);
          });
        }
      }
    },
    skip: !enabled,
  );
}
