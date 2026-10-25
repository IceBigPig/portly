import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:portly/main.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/ui/toolbox.dart';
import 'package:portly/ui/theme.dart';
import 'package:portly/ui/connection_panel.dart';
import 'package:portly/ui/packet_viewer.dart';
import 'package:portly/core/models.dart';
import 'package:portly/core/wave.dart';

import 'package:flutter/services.dart';

const toolSamples = [
  '01 03 00 00 00 02',
  '01 03 00 00 00 02',
  '65535',
  '温度',
  '12.34',
  '01 03 00 00 00 02 C4 0B',
  r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47',
  '1792886400000',
];

class MemoryStorage extends AppStorage {
  int writes = 0;
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    writes++;
  }

  @override
  void close() {}
}

void main() {
  setUpAll(tz.initializeTimeZones);
  for (final size in [
    const Size(1440, 900),
    const Size(1100, 700),
    const Size(900, 600),
  ]) {
    testWidgets('All pages fit ${size.width} x ${size.height}', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        FlutterError.dumpErrorToConsole(details, forceReport: true);
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);
      final model = AppModel(storage: MemoryStorage());
      await model.initialize();
      await tester.pumpWidget(PortlyApp(model: model));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      model.current.commandsMode = true;
      model.current.changed();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final page in [1, 2]) {
        model.page = page;
        model.notifyListeners();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      model.dark = true;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      model.dispose();
    });
  }
  for (final size in [const Size(900, 600), const Size(1440, 900)]) {
    testWidgets('Compare layouts and 8-channel waveform fit $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final m = AppModel(storage: MemoryStorage());
      await m.initialize();
      m.newSession(ConnectionKind.serial);
      await tester.pumpWidget(PortlyApp(model: m));
      for (final mode in [1, 2]) {
        m.splitMode = mode;
        m.refresh();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      for (var i = 0; i < 8; i++) {
        m.current.waveform.upsert(WaveMapping(name: 'C$i', field: i));
      }
      m.current.waveform.receive(LogEntry('RX', '1,2,3,4,5,6,7,8\n'.codeUnits));
      m.page = 1;
      m.refresh();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('添加通道 · 8/8'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    });
  }
  testWidgets('Baud presets include 4800/9600 and custom input validates', (
    tester,
  ) async {
    int value = 115200;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(false),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: StatefulBuilder(
              builder: (context, setState) => BaudRateField(
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('115200'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('4800'));
    await tester.tap(find.text('4800'));
    await tester.pumpAndSettle();
    expect(value, 4800);
    await tester.tap(find.text('4800'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自定义…'));
    await tester.tap(find.text('自定义…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('custom-baud')), '0');
    await tester.tap(find.text('应用'));
    await tester.pump();
    expect(find.text('请输入有效的正整数'), findsOneWidget);
    expect(value, 4800);
    await tester.enterText(find.byKey(const ValueKey('custom-baud')), '12345');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(value, 12345);
    expect(find.text('12345 · 自定义'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
  testWidgets(
    'Byte inspector links ASCII and byte selection; binary values are exact',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: Scaffold(
            body: ByteInspector(bytes: Uint8List.fromList([65, 0, 255, 66])),
          ),
        ),
      );
      expect(find.text('A'), findsOneWidget);
      expect(find.text('41'), findsOneWidget);
      await tester.tap(find.text('41'));
      await tester.pump();
      expect(find.text('Uint8 65'), findsOneWidget);
      expect(find.text('BIN 01000001'), findsOneWidget);
      expect(binaryBytes([0, 255]), '00000000 11111111');
      expect(byteCharacters([0, 65, 255]), '·A·');
    },
  );
  testWidgets(
    'Switches cached sessions in one frame without saving received data',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final storage = MemoryStorage();
      final m = AppModel(storage: storage);
      await m.initialize();
      final a = m.current, b = m.newSession(ConnectionKind.serial);
      await tester.pumpWidget(PortlyApp(model: m));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      final baseline = storage.writes;
      for (final s in [a, b]) {
        for (var i = 0; i < 20000; i++) {
          s.addLog(LogEntry('RX', [i & 255, 1, 2]));
        }
        for (var i = 0; i < 8; i++) {
          s.waveform.upsert(WaveMapping(field: i));
        }
      }
      final watch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        m.selectSession(i.isEven ? a.id : b.id);
        await tester.pump();
        expect(find.text('20000 条记录'), findsOneWidget);
      }
      watch.stop();
      // Debug widget timings are diagnostic; routing itself has no debounce/future.
      // ignore: avoid_print
      print(
        '20 cached-session switches (debug widgets): ${watch.elapsedMilliseconds} ms',
      );
      await tester.pump(const Duration(seconds: 3));
      expect(storage.writes, baseline);
      expect(tester.takeException(), isNull);
      expect(m.snapshot().toString(), isNot(contains('log_id')));
      await tester.pumpWidget(const SizedBox());
      m.dispose();
    },
  );
  testWidgets('Tool result loads draft without connecting or sending', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = AppModel(storage: MemoryStorage());
    await model.initialize();
    model.page = 2;
    for (var i = 0; i < toolSamples.length; i++) {
      model.toolDrafts['input$i'] = toolSamples[i];
    }
    await tester.pumpWidget(PortlyApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('0x0BC4'), findsOneWidget);
    await tester.ensureVisible(find.text('载入发送框'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('载入发送框'));
    await tester.pumpAndSettle();
    expect(model.page, 0);
    expect(model.current.draft.body, '01 03 00 00 00 02 C4 0B');
    expect(model.current.draft.crc, false);
    expect(model.current.connected, false);
    expect(model.current.tx, 0);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets('Eight tools render, invalid HEX removes stale actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = AppModel(storage: MemoryStorage());
    await model.initialize();
    model.page = 2;
    for (var i = 0; i < toolSamples.length; i++) {
      model.toolDrafts['input$i'] = toolSamples[i];
    }
    await tester.pumpWidget(PortlyApp(model: model));
    await tester.pumpAndSettle();
    for (final title in toolTitles) {
      final navigation = find
          .descendant(of: find.byType(Toolbox), matching: find.text(title))
          .first;
      await tester.ensureVisible(navigation);
      await tester.tap(navigation);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: title);
    }
    final crc = find.text('Modbus CRC16').first;
    await tester.ensureVisible(crc);
    await tester.tap(crc);
    await tester.pumpAndSettle();
    final editor = find
        .descendant(of: find.byType(Toolbox), matching: find.byType(TextField))
        .at(1);
    await tester.enterText(editor, '01 0');
    await tester.pumpAndSettle();
    expect(find.text('0x0BC4'), findsNothing);
    expect(find.text('载入发送框'), findsNothing);
    expect(model.current.tx, 0);
    await tester.pumpWidget(const SizedBox());
    model.dispose();
  });
  testWidgets('Desktop selection menu commits a value and closes with Escape', (
    tester,
  ) async {
    var value = 'serial';
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(false),
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: StatefulBuilder(
                builder: (context, update) => Pick(
                  value: value,
                  options: const {
                    'serial': '串口',
                    'tcp': 'TCP 客户端',
                    'udp': 'UDP',
                  },
                  onChanged: (next) => update(() => value = next),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('串口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TCP 客户端'));
    await tester.pumpAndSettle();
    expect(value, 'tcp');
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.tap(find.text('TCP 客户端'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(value, 'tcp');
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
