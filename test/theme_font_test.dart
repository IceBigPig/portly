import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/transport.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';
import 'package:portly/ui/connection_panel.dart';
import 'package:portly/ui/theme.dart';

class _PortsModel extends AppModel {
  _PortsModel() {
    externalView = true;
    availablePorts = [
      PortInfo('COM17', 'USB 串行设备（调试端口）'),
      PortInfo('COM18', '温湿度传感器 · μC UART'),
    ];
  }
  @override
  Future<List<PortInfo>> scanPorts({bool force = false}) async =>
      availablePorts;
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final dark in [false, true]) {
    test(
      'Windows ${dark ? 'dark' : 'light'} theme starts with a native CJK font',
      () {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        final theme = appTheme(dark);
        for (final style in [
          theme.textTheme.bodyMedium!,
          theme.textTheme.bodySmall!,
          theme.textTheme.titleMedium!,
          theme.textTheme.labelLarge!,
        ]) {
          expect(style.fontFamily, 'Microsoft YaHei UI');
          expect(
            style.fontFamilyFallback,
            containsAllInOrder([
              'Microsoft YaHei',
              'Segoe UI',
              'Noto Sans CJK SC',
            ]),
          );
        }
      },
    );
  }
  test('macOS and Linux select their own system fonts', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(appTheme(false).textTheme.bodyMedium!.fontFamily, 'PingFang SC');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(appTheme(false).textTheme.bodyMedium!.fontFamily, 'Noto Sans');
    expect(
      appTheme(false).textTheme.bodyMedium!.fontFamilyFallback,
      contains('Noto Sans CJK SC'),
    );
  });
  test('Monospaced data and errors retain bundled font plus explicit Chinese fallback', () {
    final styled = mono.copyWith(fontSize: 12, color: ink);
    expect(styled.fontFamily, 'JetBrainsMono');
    expect(
      styled.fontFamilyFallback,
      containsAll([
        'Consolas',
        'Microsoft YaHei UI',
        'PingFang SC',
        'Noto Sans CJK SC',
      ]),
    );
  });
  testWidgets(
    'Serial selector preserves injected Unicode descriptions and uses the Windows font in its popup',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final model = _PortsModel();
      final session = Session(config: ConnectionConfig(port: 'COM17'));
      try {
        await tester.binding.setSurfaceSize(const Size(1100, 850));
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(false),
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: ConnectionPanel(model: model, session: session),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        const first = 'USB 串行设备（调试端口） · COM17';
        const second = '温湿度传感器 · μC UART · COM18';
        expect(find.text(first), findsOneWidget);
        final pick = find.byWidgetPredicate(
          (widget) =>
              widget is Pick<String> && widget.options.containsKey('COM17'),
        );
        await tester.tap(
          find.descendant(of: pick, matching: find.byType(OutlinedButton)),
        );
        await tester.pumpAndSettle();
        final item = find.byKey(const ValueKey('pick-option-COM18'));
        expect(item, findsOneWidget);
        expect(
          find.descendant(of: item, matching: find.text(second)),
          findsOneWidget,
        );
        final text = tester.widget<RichText>(
          find.descendant(of: item, matching: find.byType(RichText)).first,
        );
        expect(text.text.toPlainText(), second);
        expect(text.text.style!.fontFamily, 'Microsoft YaHei UI');
        expect(
          text.text.style!.fontFamilyFallback,
          contains('Microsoft YaHei'),
        );
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(session.config.port, 'COM18');
        expect(find.text(second), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.binding.setSurfaceSize(null);
        model.dispose();
        session.dispose();
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
