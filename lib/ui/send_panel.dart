import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bytes.dart';
import '../core/models.dart';
import '../core/library_import.dart';
import '../platform/storage.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import 'theme.dart';
import 'shell.dart';
import 'command_editor.dart';
import 'history.dart';
import 'library_import.dart';

export 'command_editor.dart' show editCommand;

class SendPanel extends StatefulWidget {
  final AppModel model;
  final Session session;
  final bool collapsed;
  final VoidCallback toggleCollapsed;
  const SendPanel({
    super.key,
    required this.model,
    required this.session,
    required this.collapsed,
    required this.toggleCollapsed,
  });
  @override
  State<SendPanel> createState() => _SendPanelState();
}

class _SendPanelState extends State<SendPanel> {
  String search = '';
  final invalid = <String>{};
  final pendingEdits = <String, String>{};
  int seenLibraryRevision = 0;
  @override
  void initState() {
    super.initState();
    seenLibraryRevision = m.libraryRevision;
  }

  @override
  void didUpdateWidget(SendPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (seenLibraryRevision != m.libraryRevision) {
      seenLibraryRevision = m.libraryRevision;
      invalid.clear();
      pendingEdits.clear();
      _editorKeys.clear();
    }
  }

  final _editorKeys = <String, GlobalKey<_InlineEditState>>{};
  GlobalKey<_InlineEditState> _editorKey(String id) =>
      _editorKeys.putIfAbsent(id, () => GlobalKey<_InlineEditState>());
  bool _invalidCommand(String id) =>
      invalid.contains('$id-name') || invalid.contains('$id-body');
  bool _commitCommandEditors(SavedCommand command) {
    var valid = true;
    for (final field in ['name', 'body']) {
      if (_editorKeys['${command.id}-$field']?.currentState?.commit() ==
          false) {
        valid = false;
      }
    }
    return valid;
  }

  AppModel get m => widget.model;
  Session get s => widget.session;
  Future<void> _executeCommands(List<SavedCommand> commands) async {
    try {
      if (m.libraryImporting) return;
      for (final command in commands) {
        if (!_commitCommandEditors(command)) return;
      }
      if (!await m.flushPendingSave() || !mounted) return;
      final snapshot = [
        for (final command in commands) SavedCommand.fromJson(command.toJson()),
      ];
      final values = await resolveCommandParameters(
        context,
        snapshot,
        action: snapshot.length == 1 ? '发送' : '顺序执行',
      );
      if (values == null || !mounted) return;
      await s.execute(snapshot, repeat: s.loop, parameterValues: values);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<Draft?> _resolveCommand(SavedCommand command, String action) async {
    try {
      if (!_commitCommandEditors(command)) return null;
      final snapshot = SavedCommand.fromJson(command.toJson());
      final values = await resolveCommandParameters(context, [
        snapshot,
      ], action: action);
      if (values == null || !mounted) return null;
      return snapshot.buildDraft(values[snapshot.id] ?? {});
    } catch (e) {
      if (mounted) toast(context, '$e');
      return null;
    }
  }

  Future<void> send(Draft draft) async {
    try {
      if (s.loop) {
        await s.execute([
          SavedCommand(name: '单条循环', draft: draft.copy()),
        ], repeat: true);
      } else {
        await s.send(draft, remember: true);
      }
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  Future<void> _sendFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    final length = await file.length();
    if (!mounted) return;
    if (length == 0) {
      toast(context, '文件为空');
      return;
    }
    final chunk = TextEditingController(text: '256'),
        delay = TextEditingController(text: '20');
    final form = GlobalKey<FormState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('发送文件'),
        content: SizedBox(
          width: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '$length B · 原始字节',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                Text(
                  '目标 ${s.targetSummary}',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: chunk,
                        decoration: const InputDecoration(labelText: '分块 / 字节'),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return n == null || n < 1 || n > 65507
                              ? '范围 1–65507'
                              : null;
                        },
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextFormField(
                        controller: delay,
                        decoration: const InputDecoration(
                          labelText: '块间隔 / ms',
                        ),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return n == null || n < 0 || n > 60000
                              ? '范围 0–60000'
                              : null;
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('开始发送'),
          ),
        ],
      ),
    );
    final size = int.tryParse(chunk.text) ?? 256,
        pause = int.tryParse(delay.text) ?? 20;
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      chunk.dispose();
      delay.dispose();
    });
    if (confirmed == true) {
      try {
        await s.sendFile(
          file.openRead(),
          length: length,
          name: file.name,
          chunkSize: size,
          delayMs: pause,
        );
      } catch (e) {
        if (mounted) toast(context, '$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Panel(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 7),
          child: Row(
            children: [
              Segment(
                labels: ['单条发送', '扩展命令 · ${m.commands.length}'],
                value: s.commandsMode ? 1 : 0,
                onChanged: (v) {
                  s.commandsMode = v == 1;
                  s.changed();
                  m.saveSoon();
                },
              ),
              const Spacer(),
              if (m.storageError.isNotEmpty)
                const Tooltip(
                  message: '配置保存失败',
                  child: Icon(Icons.error_outline, size: 14, color: Colors.red),
                ),
              const SizedBox(width: 8),
              if (s.commandsMode)
                iconAction(
                  Icons.history_rounded,
                  '发送与执行历史',
                  () => showSendHistory(context, m, s),
                ),
              iconAction(
                widget.collapsed
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                '收起 / 展开发送面板',
                widget.toggleCollapsed,
              ),
            ],
          ),
        ),
        if (!widget.collapsed)
          Expanded(child: s.commandsMode ? _commands() : _single()),
      ],
    ),
  );
  Widget _single() {
    String? previewError;
    List<int> bytes = [];
    try {
      bytes = s.draft.build();
    } catch (e) {
      if (s.draft.body.isNotEmpty) {
        previewError = e.toString().replaceFirst('FormatException: ', '');
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.near_me_outlined, size: 12, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '发送至  ${s.targetSummary}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: muted, fontSize: 10),
                ),
              ),
              iconAction(
                Icons.upload_file_rounded,
                '发送文件',
                s.canSend && !s.running ? _sendFile : null,
              ),
              iconAction(
                Icons.history_rounded,
                '发送与执行历史',
                () => showSendHistory(context, m, s),
              ),
            ],
          ),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  meta: true,
                ): () {
                  if (s.canSend && bytes.isNotEmpty) send(s.draft);
                },
                const SingleActivator(
                  LogicalKeyboardKey.enter,
                  control: true,
                ): () {
                  if (s.canSend && bytes.isNotEmpty) send(s.draft);
                },
              },
              child: TextFormField(
                key: ValueKey('${s.id}-${identityHashCode(s.draft)}'),
                initialValue: s.draft.body,
                expands: true,
                maxLines: null,
                minLines: null,
                style: mono.copyWith(fontSize: 13, height: 1.6),
                textAlignVertical: TextAlignVertical.top,
                decoration: InputDecoration(
                  hintText: s.draft.text
                      ? '输入文本内容…'
                      : '输入 HEX 字节，例如 01 03 00 00 00 02',
                  contentPadding: const EdgeInsets.all(13),
                ),
                onChanged: (v) {
                  setState(() => s.draft.body = v);
                  m.saveSoon();
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Segment(
                  labels: const ['HEX', '文本'],
                  value: s.draft.text ? 1 : 0,
                  onChanged: (v) {
                    try {
                      if (s.draft.body.isNotEmpty) {
                        final raw = s.draft.text
                            ? encodeText(s.draft.body, s.draft.encoding)
                            : parseHex(s.draft.body);
                        s.draft.body = v == 1
                            ? decodeText(raw, s.draft.encoding)
                            : hex(raw);
                      }
                      s.draft.text = v == 1;
                      if (s.draft.text) s.draft.crc = false;
                      setState(() {});
                      m.saveSoon();
                    } catch (e) {
                      toast(context, '无法无损转换：$e');
                    }
                  },
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 215,
                  child: Pick<bool>(
                    value: s.draft.crc,
                    options: const {
                      false: '原样发送 · Raw',
                      true: '自动 CRC-16/MODBUS',
                    },
                    onChanged: s.draft.text
                        ? null
                        : (v) {
                            setState(() => s.draft.crc = v);
                            m.saveSoon();
                          },
                  ),
                ),
                if (s.draft.text) ...[
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 112,
                    child: Pick(
                      value: s.draft.suffix,
                      options: const {'': '无尾缀', '0A': 'LF', '0D 0A': 'CRLF'},
                      onChanged: (v) {
                        setState(() => s.draft.suffix = v);
                        m.saveSoon();
                      },
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                check('循环', s.loop, (v) => setState(() => s.loop = v)),
                if (s.loop) ...[
                  SizedBox(
                    width: 70,
                    child: TextFormField(
                      initialValue: '${s.periodMs}',
                      style: mono.copyWith(fontSize: 11),
                      onChanged: (v) => s.periodMs = (int.tryParse(v) ?? 1000)
                          .clamp(10, 86400000),
                    ),
                  ),
                  const Text(
                    ' ms',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          if (s.fileSending)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(
                value: s.fileSize == 0 ? 0 : s.fileSent / s.fileSize,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: Text(
                  (s.fileSending
                          ? '${s.fileName} · ${s.fileSent} / ${s.fileSize} B'
                          : null) ??
                      previewError ??
                      (bytes.isEmpty
                          ? '最终字节预览 · 等待输入'
                          : '${hex(bytes)}  ·  ${bytes.length} B'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: mono.copyWith(
                    fontSize: 10,
                    color: previewError == null ? muted : Colors.red,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              iconAction(
                Icons.bookmark_add_outlined,
                '保存为命令',
                bytes.isEmpty
                    ? null
                    : () => editCommand(context, m, initial: s.draft.copy()),
              ),
              if (s.running) ...[
                OutlinedButton.icon(
                  onPressed: s.stop,
                  icon: const Icon(Icons.stop_rounded, size: 15),
                  label: const Text('停止'),
                ),
                const SizedBox(width: 8),
              ],
              FilledButton.icon(
                onPressed: s.canSend && bytes.isNotEmpty && !s.running
                    ? () => send(s.draft)
                    : null,
                icon: const Icon(Icons.send_rounded, size: 15),
                label: const Text('发送'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _commands() {
    final needle = search.toLowerCase();
    final rows = m.commands
        .where(
          (c) =>
              c.groupId == m.groupId &&
              (needle.isEmpty ||
                  '${c.name} ${c.draft.body} ${c.tags.join(' ')}'
                      .toLowerCase()
                      .contains(needle)),
        )
        .toList();
    final selected = m.commands
        .where(
          (c) => c.groupId == m.groupId && s.selectedCommands.contains(c.id),
        )
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 9),
          child: Row(
            children: [
              SizedBox(
                width: 150,
                child: Pick<String>(
                  value: m.groupId,
                  options: m.groups,
                  onChanged: m.libraryImporting
                      ? null
                      : (v) {
                          m.groupId = v;
                          s.selectedCommands.clear();
                          m.changed();
                        },
                ),
              ),
              const SizedBox(width: 8),
              iconAction(
                Icons.create_new_folder_outlined,
                '新增命令组',
                m.libraryImporting
                    ? null
                    : () async {
                        if (m.groups.length >= maxLibraryGroups) {
                          toast(context, '最多保存 $maxLibraryGroups 个分组');
                          return;
                        }
                        final name = await askText(context, '新增命令组');
                        if (!mounted || m.libraryImporting) return;
                        if (name != null) {
                          final id = newId();
                          m.groups[id] = name;
                          m.groupId = id;
                          m.changed();
                        }
                      },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    style: const TextStyle(fontSize: 11),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded, size: 16),
                      hintText: '搜索命令',
                    ),
                    onChanged: (v) => setState(() => search = v),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: m.libraryImporting
                    ? null
                    : () => editCommand(context, m),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('新增'),
              ),
              const SizedBox(width: 6),
              iconAction(
                Icons.file_upload_outlined,
                '导入命令库',
                m.libraryImporting ? null : _import,
              ),
              iconAction(
                Icons.file_download_outlined,
                '导出命令库',
                m.libraryImporting ? null : _export,
              ),
            ],
          ),
        ),
        Container(
          height: 27,
          color: Theme.of(context).scaffoldBackgroundColor
              .withValues(alpha: .6),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              SizedBox(
                width: 33,
                child: Checkbox(
                  value:
                      rows.isNotEmpty &&
                      rows.every((r) => s.selectedCommands.contains(r.id)),
                  onChanged: (v) => setState(() {
                    for (final r in rows) {
                      if (v == true) {
                        s.selectedCommands.add(r.id);
                      } else {
                        s.selectedCommands.remove(r.id);
                      }
                    }
                  }),
                ),
              ),
              const SizedBox(
                width: 150,
                child: Text('名称', style: TextStyle(fontSize: 10, color: muted)),
              ),
              const Expanded(
                child: Text(
                  '命令内容',
                  style: TextStyle(fontSize: 10, color: muted),
                ),
              ),
              const SizedBox(
                width: 130,
                child: Text(
                  '处理策略',
                  style: TextStyle(fontSize: 10, color: muted),
                ),
              ),
              const SizedBox(
                width: 70,
                child: Text('操作', style: TextStyle(fontSize: 10, color: muted)),
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text(
                    '此分组暂无命令，点击「新增」创建',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                )
              : AbsorbPointer(
                  absorbing: m.libraryImporting,
                  child: EdgeScroll(
                    builder: (context, controller) => ListView.builder(
                      controller: controller,
                      itemExtent: 41,
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final c = rows[i];
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          color: s.selectedCommands.contains(c.id)
                              ? blue.withValues(alpha: .045)
                              : null,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 33,
                                child: Checkbox(
                                  value: s.selectedCommands.contains(c.id),
                                  onChanged: (v) => setState(() {
                                    if (v == true) {
                                      s.selectedCommands.add(c.id);
                                    } else {
                                      s.selectedCommands.remove(c.id);
                                    }
                                  }),
                                ),
                              ),
                              SizedBox(
                                width: 150,
                                child: InlineEdit(
                                  key: _editorKey('${c.id}-name'),
                                  value: pendingEdits['${c.id}-name'] ?? c.name,
                                  readOnly: m.libraryImporting,
                                  onDirty: (v) => setState(() {
                                    pendingEdits['${c.id}-name'] = v;
                                    if (v.trim().isEmpty || v.length > 80) {
                                      invalid.add('${c.id}-name');
                                    } else {
                                      invalid.remove('${c.id}-name');
                                    }
                                  }),
                                  onCommit: (v) {
                                    if (m.libraryImporting) return false;
                                    if (v.trim().isEmpty || v.length > 80) {
                                      return false;
                                    }
                                    if (c.name != v) {
                                      c.name = v;
                                      c.revision++;
                                      m.changed();
                                    }
                                    invalid.remove('${c.id}-name');
                                    pendingEdits.remove('${c.id}-name');
                                    return true;
                                  },
                                ),
                              ),
                              Expanded(
                                child: InlineEdit(
                                  key: _editorKey('${c.id}-body'),
                                  value:
                                      pendingEdits['${c.id}-body'] ??
                                      c.draft.body,
                                  monospace: true,
                                  readOnly: m.libraryImporting,
                                  onDirty: (v) => setState(() {
                                    pendingEdits['${c.id}-body'] = v;
                                    final json = c.toJson();
                                    json[c.draft.text
                                            ? 'bodyText'
                                            : 'bodyHex'] =
                                        v;
                                    try {
                                      SavedCommand.fromJson(json).validate();
                                      invalid.remove('${c.id}-body');
                                    } catch (_) {
                                      invalid.add('${c.id}-body');
                                    }
                                  }),
                                  onCommit: (v) {
                                    if (m.libraryImporting) return false;
                                    final json = c.toJson();
                                    json[c.draft.text
                                            ? 'bodyText'
                                            : 'bodyHex'] =
                                        v;
                                    SavedCommand next;
                                    try {
                                      next = SavedCommand.fromJson(json)
                                        ..validate();
                                    } catch (_) {
                                      return false;
                                    }
                                    if (c.draft.body != v) {
                                      c.draft = next.draft;
                                      c.revision++;
                                      m.changed();
                                    }
                                    invalid.remove('${c.id}-body');
                                    pendingEdits.remove('${c.id}-body');
                                    return true;
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 130,
                                child: Text(
                                  [
                                    c.parameters.isEmpty
                                        ? ''
                                        : '${c.parameters.length} 参数',
                                    c.responseRule == null
                                        ? (c.draft.crc
                                              ? '自动 Modbus CRC'
                                              : c.draft.text
                                              ? '文本 · ${c.draft.encoding}'
                                              : 'HEX · 原样')
                                        : '响应匹配',
                                  ].where((v) => v.isNotEmpty).join(' · '),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: c.draft.crc ? blue : muted,
                                  ),
                                ),
                              ),
                              SizedBox(
                                width: 34,
                                child: iconAction(
                                  Icons.play_arrow_rounded,
                                  '发送此命令',
                                  s.canSend &&
                                          !s.running &&
                                          !_invalidCommand(c.id)
                                      ? () => _executeCommands([c])
                                      : null,
                                ),
                              ),
                              SizedBox(
                                width: 34,
                                child: PopupMenuButton<String>(
                                  tooltip: '命令操作',
                                  icon: const Icon(
                                    Icons.more_horiz_rounded,
                                    size: 17,
                                    color: muted,
                                  ),
                                  onSelected: (v) async {
                                    if (v == 'edit') {
                                      await editCommand(context, m, command: c);
                                      if (mounted &&
                                          m.commands.any(
                                            (next) =>
                                                next.id == c.id &&
                                                !identical(next, c),
                                          )) {
                                        setState(() {
                                          invalid.remove('${c.id}-name');
                                          invalid.remove('${c.id}-body');
                                          _editorKeys.remove('${c.id}-name');
                                          _editorKeys.remove('${c.id}-body');
                                        });
                                      }
                                    }
                                    if (v == 'load') {
                                      final draft = await _resolveCommand(
                                        c,
                                        '载入',
                                      );
                                      if (draft == null || !mounted) return;
                                      s.draft = draft;
                                      s.commandsMode = false;
                                      s.changed();
                                      m.saveSoon();
                                    }
                                    if (v == 'copy') {
                                      final draft = await _resolveCommand(
                                        c,
                                        '复制',
                                      );
                                      if (draft == null) return;
                                      Clipboard.setData(
                                        ClipboardData(text: hex(draft.build())),
                                      );
                                    }
                                    if (v == 'up') {
                                      final index = m.commands.indexOf(c);
                                      if (index > 0) {
                                        m.commands.removeAt(index);
                                        m.commands.insert(index - 1, c);
                                        m.changed();
                                      }
                                    }
                                    if (v == 'delete' &&
                                        context.mounted &&
                                        await confirm(
                                          context,
                                          '删除命令？',
                                          '删除「${c.name}」。已经提交的任务不会被撤回。',
                                        )) {
                                      m.commands.remove(c);
                                      s.selectedCommands.remove(c.id);
                                      m.changed();
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: Text('编辑 / 移动分组'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'load',
                                      child: Text('载入单条发送'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'copy',
                                      child: Text('复制最终 HEX'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'up',
                                      child: Text('上移'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('删除'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 7, 18, 10),
          child: Row(
            children: [
              Text(
                '已选 ${selected.length} 条',
                style: const TextStyle(fontSize: 10, color: muted),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed:
                    s.canSend &&
                        !s.running &&
                        selected.isNotEmpty &&
                        selected.every((c) => !_invalidCommand(c.id))
                    ? () => _executeCommands(selected)
                    : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 17),
                label: const Text('顺序执行'),
              ),
              const SizedBox(width: 8),
              if (s.running)
                OutlinedButton.icon(
                  onPressed: s.stop,
                  icon: const Icon(Icons.stop_rounded, size: 15),
                  label: const Text('停止'),
                ),
              const SizedBox(width: 10),
              check(
                '自动等待 RTU',
                s.waitResponse,
                (v) => setState(() => s.waitResponse = v),
              ),
              const SizedBox(width: 12),
              check('循环', s.loop, (v) => setState(() => s.loop = v)),
              const Spacer(),
              Flexible(
                child: Text(
                  s.task,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _import() async {
    try {
      if (m.libraryImporting) return;
      for (final command in m.commands) {
        if (!_commitCommandEditors(command)) {
          throw const FormatException('请先修正命令编辑内容');
        }
      }
      if (invalid.isNotEmpty) throw const FormatException('请先修正命令编辑内容');
      FocusManager.instance.primaryFocus?.unfocus();
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '命令库 JSON', extensions: ['json']),
        ],
      );
      if (file == null) return;
      if (await file.length() > maxLibraryImportBytes) {
        throw const FormatException('命令库文件不能超过 16 MiB');
      }
      final content = await file.readAsString();
      final preview = await m.previewLibraryImport(content);
      if (!mounted) return;
      final plan = await showLibraryImportPreview(context, preview);
      if (plan == null || !mounted) return;
      FocusManager.instance.primaryFocus?.unfocus();
      final backup = await m.applyLibraryImport(plan);
      if (!mounted) return;
      if (backup.isEmpty) {
        toast(context, '未修改命令库');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('导入完成', style: TextStyle(fontSize: 18)),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '新增 ${plan.addedCommands} · 副本 ${plan.copiedCommands} · 覆盖 ${plan.overwrittenCommands} · 跳过 ${plan.skippedCommands}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                const Text(
                  '导入前备份',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                const SizedBox(height: 6),
                SelectableText(backup, style: mono.copyWith(fontSize: 11)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: backup));
              },
              child: const Text('复制备份路径'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) toast(context, '导入失败：$e');
    }
  }

  Future<void> _export() async {
    try {
      for (final command in m.commands) {
        if (!_commitCommandEditors(command)) {
          throw const FormatException('请先修正命令编辑内容');
        }
      }
      final selected = s.selectedCommands.toSet();
      final scope = await chooseLibraryExportScope(
        context,
        currentGroup: m.groups[m.groupId] ?? '',
        selectedCount: selected.length,
      );
      if (scope == null) return;
      final content = await m.exportLibraryAsync(
        scope: scope,
        selectedIds: selected,
      );
      if (!mounted) return;
      await exportFile('portly-commands.json', content);
    } catch (e) {
      if (mounted) toast(context, '导出失败：$e');
    }
  }
}

class InlineEdit extends StatefulWidget {
  final String value;
  final bool monospace, readOnly;
  final ValueChanged<String> onDirty;
  final bool Function(String) onCommit;
  const InlineEdit({
    super.key,
    required this.value,
    this.monospace = false,
    this.readOnly = false,
    required this.onDirty,
    required this.onCommit,
  });
  @override
  State<InlineEdit> createState() => _InlineEditState();
}

class _InlineEditState extends State<InlineEdit> {
  late final controller = TextEditingController(text: widget.value);
  late final FocusNode focus = FocusNode()
    ..addListener(() {
      if (!focus.hasFocus) commit();
    });
  bool error = false;
  bool commit() {
    final valid = widget.onCommit(controller.text);
    if (mounted) setState(() => error = !valid);
    return valid;
  }

  @override
  void didUpdateWidget(InlineEdit old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !focus.hasFocus) {
      controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: TextField(
      controller: controller,
      focusNode: focus,
      readOnly: widget.readOnly,
      style: widget.monospace
          ? mono.copyWith(fontSize: 11, color: error ? Colors.red : null)
          : TextStyle(fontSize: 11, color: error ? Colors.red : null),
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 5, vertical: 9),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: error ? Colors.red : Colors.transparent,
          ),
        ),
      ),
      onChanged: widget.onDirty,
      onSubmitted: (_) {
        commit();
        focus.unfocus();
      },
    ),
  );
}
