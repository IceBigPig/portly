import 'dart:ui' show AppExitResponse;
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../state/app_model.dart';
import '../state/session.dart';
import '../platform/desktop_window.dart';
import '../platform/storage.dart';
import 'theme.dart';
import 'workspace.dart';
import 'toolbox.dart';
import 'waveform.dart';

class AppShell extends StatefulWidget {
  final AppModel model;
  final Future<void> Function()? closeWindow;
  const AppShell({super.key, required this.model, this.closeWindow});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WindowListener, SingleTickerProviderStateMixin {
  late final AnimationController _pageMotion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..value = 1;
  late int _lastPage;
  late final AppLifecycleListener _exitListener;
  bool _closeRequested = false, _busyClosing = false;
  void _modelChanged() {
    if (_lastPage != model.page) {
      _lastPage = model.page;
      if (MediaQuery.disableAnimationsOf(context)) {
        _pageMotion.value = 1;
      } else {
        _pageMotion.forward(from: 0);
      }
    }
  }

  AppModel get model => widget.model;
  @override
  void initState() {
    super.initState();
    _lastPage = model.page;
    model.addListener(_modelChanged);
    _exitListener = AppLifecycleListener(
      onExitRequested: () async {
        if (model.shutdownComplete) return AppExitResponse.exit;
        // Cmd+Q and Dock Quit arrive through System.requestAppExit rather than
        // NSWindow.windowShouldClose. Cancel this request before the common
        // asynchronous shutdown destroys the window; do not await it here.
        onWindowClose();
        return AppExitResponse.cancel;
      },
    );
    if (!kIsWeb &&
        [
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        ].contains(defaultTargetPlatform)) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    _exitListener.dispose();
    _pageMotion.dispose();
    if (!kIsWeb &&
        [
          TargetPlatform.macOS,
          TargetPlatform.windows,
          TargetPlatform.linux,
        ].contains(defaultTargetPlatform)) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (_closeRequested || model.shutdownComplete) return;
    _closeRequested = true;
    try {
      if (model.sessions.any(
        (s) => s.connected || s.running || s.reconnecting,
      )) {
        final ok = await confirm(context, '关闭应用？', '将停止发送任务、关闭连接，并保存本地草稿。');
        if (!ok || !mounted) return;
      }
      FocusManager.instance.primaryFocus?.unfocus();
      var discard = false;
      while (mounted) {
        if (!mounted) return;
        setState(() => _busyClosing = true);
        final navigator = Navigator.of(context);
        final progress = DialogRoute<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('正在关闭'),
                ],
              ),
            ),
          ),
        );
        unawaited(navigator.push(progress));
        try {
          await model.shutdown(discardUnsavedChanges: discard);
          if (progress.isActive) navigator.removeRoute(progress);
          model.dispose();
          await (widget.closeWindow?.call() ?? closeDesktopWindow());
          return;
        } catch (e) {
          if (progress.isActive) navigator.removeRoute(progress);
          if (!mounted) return;
          setState(() => _busyClosing = false);
          final action = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('未能完成关闭'),
              content: Text('$e'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, 'cancel'),
                  child: const Text('取消关闭'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'retry'),
                  child: const Text('重试'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, 'discard'),
                  child: const Text('仍然退出'),
                ),
              ],
            ),
          );
          if (action != 'retry' && action != 'discard') return;
          discard = action == 'discard';
        }
      }
    } finally {
      _closeRequested = false;
      if (mounted && !model.shutdownComplete) {
        setState(() => _busyClosing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AbsorbPointer(
    absorbing: _busyClosing,
    child: ExcludeFocus(excluding: _busyClosing, child: _buildShell(context)),
  );

  Widget _buildShell(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 37,
                height: 37,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF5484FF), blue],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: blue.withValues(alpha: .18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.memory_rounded,
                  color: Colors.white,
                  size: 23,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Portly',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.7,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '串口调试助手',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: .65),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              Segment(
                labels: const ['调试台', '波形', '工具箱'],
                value: model.page,
                onChanged: (i) {
                  model.page = i;
                  model.changed();
                },
              ),
              const Spacer(),
              const SizedBox(width: 10),
              iconAction(
                model.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                '切换明暗主题',
                () {
                  model.dark = !model.dark;
                  model.changed();
                },
              ),
              const SizedBox(width: 4),
              iconAction(
                Icons.tune_rounded,
                '应用设置',
                () => settings(context, model),
              ),
            ],
          ),
        ),
        if (model.persistenceError.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.red.withValues(alpha: .1),
            child: Text(
              model.persistenceError,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        Expanded(
          child: FadeTransition(
            opacity: CurvedAnimation(
              parent: _pageMotion,
              curve: Curves.easeOutCubic,
            ),
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(0, .012),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(
                      parent: _pageMotion,
                      curve: Curves.easeOutCubic,
                    ),
                  ),
              child: IndexedStack(
                index: model.page,
                children: [
                  Workspace(model: model),
                  WaveformPage(model: model),
                  Toolbox(model: model),
                ],
              ),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: model.current,
          builder: (context, _) {
            final s = model.current;
            return Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: Row(
                children: [
                  StatusDot(s.connected),
                  const SizedBox(width: 8),
                  Text(s.state, style: const TextStyle(fontSize: 10)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      s.config.summary,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: muted),
                    ),
                  ),
                  if (s.running) ...[
                    const Icon(Icons.sync_rounded, color: blue, size: 13),
                    const SizedBox(width: 5),
                    Text(
                      s.task,
                      style: const TextStyle(fontSize: 10, color: blue),
                    ),
                    const SizedBox(width: 16),
                    TextButton(onPressed: s.stop, child: const Text('停止')),
                  ],
                  if (s.recorder.active) ...[
                    const Icon(
                      Icons.fiber_manual_record,
                      size: 8,
                      color: green,
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      '记录中',
                      style: TextStyle(fontSize: 10, color: green),
                    ),
                    const SizedBox(width: 15),
                  ],
                  Text(
                    '↓ RX  ${formatBytes(s.rx)}',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                  const SizedBox(width: 20),
                  Text(
                    '↑ TX  ${formatBytes(s.tx)}',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                  const SizedBox(width: 20),
                  const Text(
                    'v0.5.1',
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    ),
  );
}

String formatBytes(int n) => n < 1024
    ? '$n B'
    : n < 1024 * 1024
    ? '${(n / 1024).toStringAsFixed(1)} KB'
    : '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 18)),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 18)),
      content: SizedBox(
        width: 340,
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              Navigator.pop(context, controller.text.trim());
            }
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

Future<void> closeSession(
  BuildContext context,
  AppModel model,
  Session s,
) async {
  if ((s.connected || s.running || s.reconnecting) &&
      !await confirm(
        context,
        '停止并关闭会话？',
        '将关闭「${s.config.name}」的连接，取消尚未提交的任务。',
      )) {
    return;
  }
  await model.closeSession(s);
}

Future<void> settings(BuildContext context, AppModel model) => showDialog(
  context: context,
  builder: (context) => StatefulBuilder(
    builder: (context, update) => AlertDialog(
      title: const Text(
        '偏好设置',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('深色外观', style: TextStyle(fontSize: 13)),
              value: model.dark,
              onChanged: (v) {
                model.dark = v;
                model.changed();
                update(() {});
              },
            ),
            const Divider(height: 30),
            const Text('本地数据', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SelectableText(
              model.storage.location,
              style: mono.copyWith(fontSize: 10, color: muted),
            ),
            const SizedBox(height: 12),
            const Text(
              '恢复时仅载入配置与草稿；连接、循环和执行任务均保持关闭。',
              style: TextStyle(fontSize: 12, color: muted),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await exportFile(
                        'portly-backup.json',
                        const JsonEncoder.withIndent('  ')
                            .convert(model.snapshot()),
                      );
                      if (context.mounted) toast(context, '备份已导出');
                    } catch (e) {
                      if (context.mounted) toast(context, '$e');
                    }
                  },
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('导出数据备份'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text(
              'Portly 0.5.1',
              style: TextStyle(fontSize: 11, color: muted, height: 1.8),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  ),
);
