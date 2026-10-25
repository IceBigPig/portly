import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:window_manager/window_manager.dart';

import 'state/app_model.dart';
import 'platform/compare_window.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  WindowController? controller;
  if (!kIsWeb) {
    controller = await WindowController.fromCurrentEngine();
    if (controller.arguments.isNotEmpty) {
      final args = Map<String, dynamic>.from(jsonDecode(controller.arguments));
      if (args['type'] == 'compare') {
        await windowManager.ensureInitialized();
        await windowManager.waitUntilReadyToShow(
          const WindowOptions(
            size: Size(1280, 800),
            minimumSize: Size(900, 600),
            center: true,
            title: 'Portly · 会话对比',
          ),
          () async {
            await windowManager.show();
            await windowManager.focus();
          },
        );
        runApp(CompareWindow(controller: controller, arguments: args));
        return;
      }
    }
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1440, 900),
        minimumSize: Size(900, 600),
        center: true,
        title: 'Portly · 串口调试助手',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final model = AppModel();
  await model.initialize();
  if (controller != null) await installCompareHost(model, controller);
  runApp(PortlyApp(model: model));
}

class PortlyApp extends StatelessWidget {
  final AppModel model;
  const PortlyApp({super.key, required this.model});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      title: 'Portly · 串口调试助手',
      debugShowCheckedModeBanner: false,
      theme: appTheme(false),
      darkTheme: appTheme(true),
      themeMode: model.dark ? ThemeMode.dark : ThemeMode.light,
      scrollBehavior: const AppScrollBehavior(),
      home: AppShell(model: model),
    ),
  );
}
