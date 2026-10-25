import 'package:flutter/material.dart';

import '../core/models.dart';
import '../state/app_model.dart';
import 'theme.dart';
import 'shell.dart';
import 'connection_panel.dart';
import 'send_panel.dart';
import 'log_panel.dart';
import 'compare_workspace.dart';

class Workspace extends StatefulWidget {
  final AppModel model;
  const Workspace({super.key, required this.model});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  double dockHeight = 296;
  bool collapsed = false;
  @override
  Widget build(BuildContext context) {
    if (widget.model.page != 0) return const SizedBox.shrink();
    final m = widget.model, s = m.current;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final narrow = box.maxWidth < 1000 || m.splitMode != 0;
          final left = ConnectionPanel(
            key: ValueKey(s.id),
            model: m,
            session: s,
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!narrow) ...[
                  SizedBox(width: box.maxWidth < 1280 ? 246 : 268, child: left),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: Column(
                    children: [
                      SizedBox(
                        height: 40,
                        child: Row(
                          children: [
                            if (narrow) ...[
                              iconAction(
                                Icons.tune_rounded,
                                '连接配置',
                                () => showModalBottomSheet(
                                  context: context,
                                  isScrollControlled: true,
                                  builder: (_) => SizedBox(
                                    height:
                                        MediaQuery.sizeOf(context).height * .85,
                                    child: left,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: m.sessions.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 6),
                                itemBuilder: (context, i) {
                                  final tab = m.sessions[i],
                                      selected = tab.id == s.id;
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(11),
                                    onTap: () => m.selectSession(tab.id),
                                    onDoubleTap: () async {
                                      final name = await askText(
                                        context,
                                        '重命名会话',
                                        initial: tab.config.name,
                                      );
                                      if (name != null) {
                                        tab.config.name = name;
                                        m.changed();
                                      }
                                    },
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 180,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .surface
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(11),
                                        border: Border.all(
                                          color: selected
                                              ? blue.withValues(alpha: .22)
                                              : Colors.transparent,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          StatusDot(tab.connected),
                                          const SizedBox(width: 9),
                                          Text(
                                            tab.config.name,
                                            style: TextStyle(
                                              color: selected ? blue : muted,
                                              fontWeight: selected
                                                  ? FontWeight.w600
                                                  : FontWeight.w400,
                                              fontSize: 12,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          SizedBox(
                                            width: 24,
                                            child: iconAction(
                                              Icons.close_rounded,
                                              '关闭会话',
                                              () =>
                                                  closeSession(context, m, tab),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 6),
                            PopupMenuButton<int>(
                              tooltip: '会话布局',
                              icon: const Icon(
                                Icons.space_dashboard_outlined,
                                size: 19,
                                color: muted,
                              ),
                              onSelected: (mode) async {
                                if (mode == 3) {
                                  try {
                                    await m.openCompareWindow?.call();
                                  } catch (e) {
                                    if (context.mounted) {
                                      toast(context, '新建窗口失败：$e');
                                    }
                                  }
                                  return;
                                }
                                m.splitMode = mode;
                                m.changed();
                              },
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 0,
                                  child: Text('单会话'),
                                ),
                                const PopupMenuItem(
                                  value: 1,
                                  child: Text('左右分屏'),
                                ),
                                const PopupMenuItem(
                                  value: 2,
                                  child: Text('上下分屏'),
                                ),
                                PopupMenuItem(
                                  value: 3,
                                  enabled: m.openCompareWindow != null,
                                  child: const Text('新建对比窗口'),
                                ),
                              ],
                            ),
                            PopupMenuButton<ConnectionKind>(
                              tooltip: '新建会话',
                              icon: const Icon(
                                Icons.add_rounded,
                                size: 22,
                                color: muted,
                              ),
                              onSelected: (kind) => m.newSession(kind),
                              itemBuilder: (context) => ConnectionKind.values
                                  .map(
                                    (kind) => PopupMenuItem(
                                      value: kind,
                                      child: Text(kind.label),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (m.splitMode != 0)
                        Expanded(child: CompareWorkspace(model: m))
                      else ...[
                        Expanded(
                          child: LogPanel(
                            key: ValueKey('logs-${s.id}'),
                            session: s,
                            model: m,
                          ),
                        ),
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeUpDown,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragUpdate: (d) => setState(() {
                              dockHeight = (dockHeight - d.delta.dy).clamp(
                                190,
                                box.maxHeight * .7,
                              );
                            }),
                            child: SizedBox(
                              height: 13,
                              child: Center(
                                child: Container(
                                  width: 32,
                                  height: 3,
                                  decoration: BoxDecoration(
                                    color: muted.withValues(alpha: .25),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: collapsed
                              ? 54
                              : dockHeight.clamp(
                                  190,
                                  box.maxHeight < 600
                                      ? 242
                                      : box.maxHeight * .6,
                                ),
                          child: SendPanel(
                            key: ValueKey('send-${s.id}'),
                            model: m,
                            session: s,
                            collapsed: collapsed,
                            toggleCollapsed: () =>
                                setState(() => collapsed = !collapsed),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
