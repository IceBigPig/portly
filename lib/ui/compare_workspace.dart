import 'package:flutter/material.dart';

import '../state/app_model.dart';
import '../state/session.dart';
import 'connection_panel.dart';
import 'log_panel.dart';
import 'theme.dart';

class CompareWorkspace extends StatefulWidget {
  final AppModel model;
  final bool remote;
  const CompareWorkspace({super.key, required this.model, this.remote = false});
  @override
  State<CompareWorkspace> createState() => _CompareWorkspaceState();
}

class _CompareWorkspaceState extends State<CompareWorkspace> {
  double ratio = .5;
  @override
  Widget build(BuildContext context) {
    final m = widget.model, vertical = m.splitMode == 2;
    final second =
        m.sessions.where((s) => s.id == m.secondarySessionId).firstOrNull ??
        m.sessions.where((s) => s.id != m.currentId).firstOrNull ??
        m.current;
    return LayoutBuilder(
      builder: (context, box) {
        final extent = (vertical ? box.maxHeight : box.maxWidth) - 12;
        return Flex(
          direction: vertical ? Axis.vertical : Axis.horizontal,
          children: [
            SizedBox(
              width: vertical ? null : extent * ratio,
              height: vertical ? extent * ratio : null,
              child: ComparePane(
                key: ValueKey('first-${m.current.id}'),
                model: m,
                session: m.current,
                remote: widget.remote,
                onSelect: m.selectSession,
              ),
            ),
            MouseRegion(
              cursor: vertical
                  ? SystemMouseCursors.resizeUpDown
                  : SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (e) => setState(
                  () => ratio =
                      (ratio + (vertical ? e.delta.dy : e.delta.dx) / extent)
                          .clamp(.3, .7),
                ),
                child: SizedBox(
                  width: vertical ? double.infinity : 12,
                  height: vertical ? 12 : double.infinity,
                  child: Center(
                    child: Container(
                      width: vertical ? 32 : 3,
                      height: vertical ? 3 : 32,
                      decoration: BoxDecoration(
                        color: muted.withValues(alpha: .25),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ComparePane(
                key: ValueKey('second-${second.id}'),
                model: m,
                session: second,
                remote: widget.remote,
                onSelect: (id) {
                  m.secondarySessionId = id;
                  m.refresh();
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class ComparePane extends StatelessWidget {
  final AppModel model;
  final Session session;
  final ValueChanged<String> onSelect;
  final bool remote;
  const ComparePane({
    super.key,
    required this.model,
    required this.session,
    required this.onSelect,
    this.remote = false,
  });
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final s = session;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: Pick<String>(
                    value: s.id,
                    options: {
                      for (final item in model.sessions)
                        item.id: item.config.name,
                    },
                    onChanged: onSelect,
                  ),
                ),
                const SizedBox(width: 9),
                StatusDot(s.connected),
                iconAction(
                  s.connected || s.reconnecting
                      ? Icons.link_off_rounded
                      : Icons.power_settings_new_rounded,
                  s.connected
                      ? '断开连接'
                      : s.reconnecting
                      ? '停止重连'
                      : '打开连接',
                  () async {
                    if (remote) {
                      await model.remoteAction?.call(s.id, 'connect', null);
                      return;
                    }
                    if (s.parametersLocked) {
                      await s.disconnect();
                    } else {
                      await s.connect();
                    }
                  },
                ),
                if (!remote)
                  iconAction(
                    Icons.tune_rounded,
                    '连接配置',
                    () => showDialog(
                      context: context,
                      builder: (_) => Dialog(
                        child: SizedBox(
                          width: 320,
                          height: MediaQuery.sizeOf(context).height * .8,
                          child: ListenableBuilder(
                            listenable: s,
                            builder: (_, _) =>
                                ConnectionPanel(model: model, session: s),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LogPanel(session: s, model: model, compact: true),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  key: ValueKey('draft-${s.id}-${identityHashCode(s.draft)}'),
                  initialValue: s.draft.body,
                  style: mono.copyWith(fontSize: 11),
                  maxLines: 1,
                  decoration: InputDecoration(
                    hintText: s.draft.text ? '文本' : 'HEX',
                  ),
                  onChanged: (v) {
                    s.draft.body = v;
                    if (!remote) model.saveSoon();
                  },
                  onFieldSubmitted: (_) => _send(context),
                ),
              ),
              const SizedBox(width: 6),
              iconAction(
                Icons.send_rounded,
                '发送',
                s.canSend && !s.running ? () => _send(context) : null,
              ),
              if (s.running)
                iconAction(Icons.stop_rounded, '停止任务', () {
                  if (remote) {
                    model.remoteAction?.call(s.id, 'stop', null);
                  } else {
                    s.stop();
                  }
                }),
            ],
          ),
        ],
      );
    },
  );
  Future<void> _send(BuildContext context) async {
    try {
      if (remote) {
        await model.remoteAction?.call(
          session.id,
          'send',
          session.draft.toJson(),
        );
      } else {
        await session.send(session.draft, remember: true);
      }
    } catch (e) {
      if (context.mounted) toast(context, '$e');
    }
  }
}
