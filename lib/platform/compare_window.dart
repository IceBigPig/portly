import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/models.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import '../ui/compare_workspace.dart';
import '../ui/theme.dart';

Future<void> installCompareHost(
  AppModel model,
  WindowController controller,
) async {
  await controller.setWindowMethodHandler((call) async {
    if (call.method == 'snapshot') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final ids = (args['ids'] as List).cast<String>().take(2).toSet();
      final after = Map<String, dynamic>.from(args['after'] as Map);
      final views = <Map<String, dynamic>>[];
      for (final s in model.sessions.where((s) => ids.contains(s.id))) {
        final since = after[s.id] as int? ?? 0;
        final reset =
            since > s.sequence ||
            (s.logs.isNotEmpty && since < s.logs.first.sequence - 1);
        final candidates = s.logs
            .where((e) => e.sequence > (reset ? 0 : since))
            .toList();
        final records = <Map<String, dynamic>>[];
        var byteBudget = 512 * 1024;
        // Initial views start at the latest bounded page. Subsequent polls resume
        // from the last delivered sequence, never opening another transport.
        final page = since == 0 || reset
            ? candidates.skip(
                (candidates.length - 500).clamp(0, candidates.length),
              )
            : candidates.take(1000);
        for (final e in page) {
          if (byteBudget < e.bytes.length && records.isNotEmpty) break;
          byteBudget -= e.bytes.length;
          records.add({
            'id': e.id,
            'sequence': e.sequence,
            'time': e.time.toIso8601String(),
            'direction': e.direction,
            'endpoint': e.endpoint,
            'message': e.message,
            'bytes': e.bytes,
          });
        }
        views.add({
          'id': s.id,
          'config': s.config.toJson(),
          'draft': s.draft.toJson(),
          'connected': s.connected,
          'canSend': s.canSend,
          'state': s.state,
          'sequence': s.sequence,
          'empty': s.logs.isEmpty,
          'running': s.running,
          'task': s.task,
          'rx': s.rx,
          'tx': s.tx,
          'reset': reset,
          'logs': records,
        });
      }
      return {
        'dark': model.dark,
        'manifest': [
          for (final s in model.sessions)
            {
              'id': s.id,
              'config': s.config.toJson(),
              'draft': s.draft.toJson(),
            },
        ],
        'views': views,
      };
    }
    if (call.method == 'action') {
      if (model.closing || model.shutdownComplete) throw StateError('主窗口正在关闭');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final s = model.sessions.where((s) => s.id == args['id']).firstOrNull;
      if (s == null) throw StateError('会话已关闭');
      switch (args['action']) {
        case 'connect':
          if (s.parametersLocked) {
            await s.disconnect();
          } else {
            await s.connect();
          }
        case 'stop':
          s.stop();
        case 'send':
          final draft = Draft.fromJson(
            Map<String, dynamic>.from(args['data'] as Map),
          );
          await s.send(draft, remember: true);
        default:
          throw UnsupportedError('未知窗口操作');
      }
      return true;
    }
    throw UnsupportedError(call.method);
  });
  model.openCompareWindow = () async {
    if (model.closing || model.shutdownComplete) throw StateError('主窗口正在关闭');
    final second =
        model.sessions
            .where((s) => s.id == model.secondarySessionId)
            .firstOrNull ??
        model.sessions.where((s) => s.id != model.currentId).firstOrNull ??
        model.current;
    final window = await WindowController.create(
      WindowConfiguration(
        arguments: jsonEncode({
          'type': 'compare',
          'host': controller.windowId,
          'first': model.currentId,
          'second': second.id,
        }),
      ),
    );
    await window.show();
  };
  model.closeCompareWindows = () async {
    for (final window in await WindowController.getAll()) {
      if (window.windowId == controller.windowId) continue;
      try {
        await window.invokeMethod('close').timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
  };
}

class CompareWindow extends StatefulWidget {
  final WindowController controller;
  final Map<String, dynamic> arguments;
  const CompareWindow({
    super.key,
    required this.controller,
    required this.arguments,
  });
  @override
  State<CompareWindow> createState() => _CompareWindowState();
}

class _CompareWindowState extends State<CompareWindow> {
  final model = AppModel()..externalView = true;
  late final host = WindowController.fromWindowId(
    widget.arguments['host'] as String,
  );
  final after = <String, int>{};
  Timer? timer;
  bool polling = false;
  String _lastFingerprint = '';
  @override
  void initState() {
    super.initState();
    model.currentId = widget.arguments['first'] as String;
    model.secondarySessionId = widget.arguments['second'] as String;
    model.splitMode = 1;
    model.remoteAction = (id, action, data) async {
      await host.invokeMethod('action', {
        'id': id,
        'action': action,
        'data': data,
      });
      await poll();
    };
    widget.controller.setWindowMethodHandler((call) async {
      if (call.method == 'close') {
        unawaited(Future<void>.delayed(Duration.zero, windowManager.destroy));
        return true;
      }
      return null;
    });
    unawaited(poll());
    timer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => unawaited(poll()),
    );
  }

  Future<void> poll() async {
    if (polling || !mounted) return;
    polling = true;
    try {
      final raw = await host.invokeMethod('snapshot', {
        'ids': [model.currentId, model.secondarySessionId],
        'after': after,
      });
      if (!mounted || raw == null) return;
      final data = Map<String, dynamic>.from(raw as Map);
      final views = (data['views'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      final fingerprint = jsonEncode({
        'dark': data['dark'],
        'manifest': data['manifest'],
        'views': [
          for (final view in views) {...view}..remove('logs'),
        ],
      });
      if (_lastFingerprint == fingerprint &&
          views.every((v) => (v['logs'] as List).isEmpty)) {
        return;
      }
      _lastFingerprint = fingerprint;

      final manifest = (data['manifest'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      final ids = manifest.map((v) => v['id']).toSet();
      for (final s
          in model.sessions.where((s) => !ids.contains(s.id)).toList()) {
        model.sessions.remove(s);
        s.dispose();
        after.remove(s.id);
      }
      for (final value in manifest) {
        final existing = model.sessions
            .where((s) => s.id == value['id'])
            .firstOrNull;
        if (existing == null) {
          model.sessions.add(
            Session.fromJson(value)
              ..mirroredConnected = false
              ..mirroredCanSend = false,
          );
        } else {
          existing.config = ConnectionConfig.fromJson(
            Map<String, dynamic>.from(value['config'] as Map),
          );
        }
      }
      for (final rawView in data['views'] as List) {
        final view = Map<String, dynamic>.from(rawView as Map);
        final s = model.sessions.firstWhere((s) => s.id == view['id']);
        s.mirroredConnected = view['connected'];
        s.mirroredCanSend = view['canSend'];
        s.state = view['state'];
        s.running = view['running'];
        s.task = view['task'];
        s.rx = view['rx'];
        s.tx = view['tx'];
        if (view['reset'] == true || view['empty'] == true) {
          s.logs.clear();
          s.rawBytes = 0;
        }
        for (final rawEntry in view['logs'] as List) {
          final e = Map<String, dynamic>.from(rawEntry as Map);
          final entry = LogEntry(
            e['direction'],
            (e['bytes'] as List).cast<int>(),
            id: e['id'],
            time: DateTime.parse(e['time']),
            endpoint: e['endpoint'],
            message: e['message'],
          );
          s.addLog(entry);
          entry.sequence = e['sequence'];
          s.sequence = entry.sequence;
          after[s.id] = entry.sequence;
        }
        while (s.logs.length > 4000 || s.rawBytes > 4 * 1024 * 1024) {
          s.rawBytes -= s.logs.removeFirst().bytes.length;
          s.dropped++;
        }
        s.changed();
      }
      model.dark = data['dark'];
      model.ready = true;
      model.storageError = '';
      if (model.sessions.isNotEmpty) {
        if (!ids.contains(model.currentId)) {
          model.currentId = model.sessions.first.id;
        }
        if (!ids.contains(model.secondarySessionId)) {
          model.secondarySessionId = model.sessions.last.id;
        }
      }
      model.refresh();
    } catch (e) {
      if (mounted) {
        for (final s in model.sessions) {
          s.mirroredConnected = s.mirroredCanSend = false;
        }
        model.storageError = '主窗口连接中断';
        model.refresh();
      }
    } finally {
      polling = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: appTheme(false),
      darkTheme: appTheme(true),
      themeMode: model.dark ? ThemeMode.dark : ThemeMode.light,
      scrollBehavior: const AppScrollBehavior(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text(
                      '会话对比',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Segment(
                      labels: const ['左右分屏', '上下分屏'],
                      value: model.splitMode - 1,
                      onChanged: (v) {
                        model.splitMode = v + 1;
                        model.refresh();
                      },
                    ),
                  ],
                ),
                if (model.storageError.isNotEmpty)
                  Text(
                    model.storageError,
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: !model.ready || model.sessions.isEmpty
                      ? const Center(child: CircularProgressIndicator())
                      : CompareWorkspace(model: model, remote: true),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
