import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/bytes.dart';
import '../core/models.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import '../platform/storage.dart';
import 'theme.dart';
import 'packet_viewer.dart';
import 'log_archive.dart';

class LogPanel extends StatefulWidget {
  final Session session;
  final AppModel model;
  final bool compact;
  const LogPanel({
    super.key,
    required this.session,
    required this.model,
    this.compact = false,
  });
  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final scroll = ScrollController();
  String search = '';
  int format = 0;
  bool showSearch = false, following = true, paused = false;
  int frozenCount = 0;
  List<LogEntry>? frozen;
  Session get s => widget.session;
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = paused ? frozen ?? [] : s.logs.toList();
    final entries = search.isEmpty
        ? all
        : all.where((e) {
            final data = format == 3
                ? binaryBytes(e.bytes)
                : format == 2
                ? '${hex(e.bytes)} ${byteCharacters(e.bytes)}'
                : format == 0
                ? hex(e.bytes)
                : decodeText(e.bytes, s.draft.encoding, preview: true);
            return '$data ${e.message} ${e.endpoint}'.toLowerCase().contains(
              search.toLowerCase(),
            );
          }).toList();
    if (s.focusLogId.isNotEmpty) {
      final index = entries.indexWhere((e) => e.id == s.focusLogId);
      following = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients && index >= 0) {
          scroll.jumpTo(
            (index * 33.0).clamp(0, scroll.position.maxScrollExtent),
          );
        }
      });
    } else if (following && s.autoScroll && !paused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients && scroll.position.maxScrollExtent > 0) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        }
      });
    }
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Container(
            height: widget.compact ? 40 : 56,
            padding: EdgeInsets.fromLTRB(widget.compact ? 8 : 18, 4, 8, 4),
            child: Row(
              children: [
                if (!widget.compact) ...[
                  const Icon(Icons.subject_rounded, size: 18, color: blue),
                  const SizedBox(width: 9),
                  const Text(
                    '收发日志',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ],
                const Spacer(),
                SizedBox(
                  width: widget.compact ? 94 : 112,
                  child: Pick<int>(
                    value: format,
                    options: const {0: 'HEX', 1: '文本', 2: 'HEX + 字符', 3: '二进制'},
                    onChanged: (v) => setState(() {
                      format = v;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                iconAction(
                  Icons.search_rounded,
                  '搜索日志',
                  () => setState(() => showSearch = !showSearch),
                ),
                iconAction(
                  paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  paused ? '恢复显示' : '暂停显示（仍接收）',
                  () => setState(() {
                    if (!paused) {
                      frozen = s.logs.toList();
                      frozenCount = s.sequence;
                    }
                    paused = !paused;
                  }),
                ),
                iconAction(
                  Icons.file_download_outlined,
                  '导出日志 JSONL',
                  () async {
                    try {
                      await exportFile(
                        'portly-log.jsonl',
                        s.logs.map((e) => jsonEncode(e.toJson())).join('\n'),
                      );
                    } catch (e) {
                      if (context.mounted) toast(context, '$e');
                    }
                  },
                ),
                iconAction(
                  Icons.delete_outline_rounded,
                  '清空视图（保留计数）',
                  () => setState(() {
                    s.clearLogs();
                    frozen = [];
                    frozenCount = s.sequence;
                  }),
                ),
                PopupMenuButton<String>(
                  tooltip: '更多操作',
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    size: 20,
                    color: muted,
                  ),
                  onSelected: (v) async {
                    if (v == 'archive') {
                      await showLogArchive(context, widget.model, session: s);
                      return;
                    }
                    if (v == 'recording') {
                      await configureLogRecording(context, widget.model);
                      return;
                    }
                    if (v == 'stats') {
                      s.rx = 0;
                      s.tx = 0;
                      s.changed();
                    }
                  },
                  itemBuilder: (_) => [
                    if (!widget.model.externalView) ...[
                      const PopupMenuItem(
                        value: 'archive',
                        child: Text('日志文件 / 索引搜索'),
                      ),
                      const PopupMenuItem(
                        value: 'recording',
                        child: Text('日志记录设置'),
                      ),
                    ],
                    const PopupMenuItem(
                      value: 'stats',
                      child: Text('重置 RX / TX 统计'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showSearch)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
              child: TextField(
                autofocus: true,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 17),
                  hintText: '搜索当前显示文本或 HEX 字节序列',
                ),
                onChanged: (v) => setState(() => search = v),
              ),
            ),
          Container(
            height: widget.compact ? 22 : 31,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            color: Theme.of(context).scaffoldBackgroundColor
                .withValues(alpha: .6),
            child: Row(
              children: [
                if (s.timestamps)
                  SizedBox(
                    width: widget.compact ? 94 : 112,
                    child: Text(
                      '时间',
                      style: TextStyle(color: muted, fontSize: 10),
                    ),
                  ),
                SizedBox(
                  width: widget.compact ? 44 : 60,
                  child: Text(
                    '方向',
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
                ),
                const Expanded(
                  child: Text(
                    '数据',
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
                ),
                const Text('字节', style: TextStyle(color: muted, fontSize: 10)),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      search.isEmpty ? '暂无数据' : '无匹配日志',
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n is UserScrollNotification) {
                        following = n.metrics.extentAfter < 32;
                      }
                      return false;
                    },
                    child: EdgeScroll(
                      controller: scroll,
                      builder: (context, controller) => ListView.builder(
                        controller: controller,
                        itemCount: entries.length,
                        itemExtent: 33,
                        itemBuilder: (context, index) {
                          final e = entries[index];
                          final preview = e.bytes.length > 256
                              ? e.bytes.sublist(0, 256)
                              : e.bytes;

                          final data = e.direction == 'SYS'
                              ? e.message
                              : format == 3
                              ? binaryBytes(preview)
                              : format == 2
                              ? '${hex(preview)}  │  ${byteCharacters(preview)}'
                              : format == 0
                              ? hex(preview)
                              : decodeText(
                                  preview,
                                  s.draft.encoding,
                                  preview: true,
                                ).replaceAll('\r', '␍').replaceAll('\n', '␊');
                          final color = e.direction == 'RX'
                              ? green
                              : e.direction == 'TX'
                              ? blue
                              : muted;
                          return InkWell(
                            onDoubleTap: () => _details(e),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              color: s.focusLogId == e.id
                                  ? blue.withValues(alpha: .12)
                                  : index.isOdd
                                  ? blue.withValues(alpha: .025)
                                  : null,
                              child: Row(
                                children: [
                                  if (s.timestamps)
                                    SizedBox(
                                      width: widget.compact ? 94 : 112,
                                      child: Text(
                                        e.timestamp,
                                        style: mono.copyWith(
                                          color: muted,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  SizedBox(
                                    width: widget.compact ? 44 : 60,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: .1),
                                          borderRadius: BorderRadius.circular(
                                            5,
                                          ),
                                        ),
                                        child: Text(
                                          e.direction,
                                          style: mono.copyWith(
                                            color: color,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Tooltip(
                                      message: e.endpoint,
                                      child: format == 2 && e.direction != 'SYS'
                                          ? Row(
                                              children: [
                                                Expanded(
                                                  flex: 3,
                                                  child: Text(
                                                    hex(preview),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: mono.copyWith(
                                                      fontSize: 11,
                                                    ),
                                                  ),
                                                ),
                                                const Padding(
                                                  padding: EdgeInsets.symmetric(
                                                    horizontal: 9,
                                                  ),
                                                  child: Text(
                                                    '│',
                                                    style: TextStyle(
                                                      color: muted,
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  flex: 2,
                                                  child: Text(
                                                    byteCharacters(preview),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: mono.copyWith(
                                                      fontSize: 11,
                                                      color: muted,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            )
                                          : Text(
                                              data,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: mono.copyWith(
                                                fontSize: 12,
                                                color: e.direction == 'SYS'
                                                    ? muted
                                                    : null,
                                              ),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    e.bytes.isEmpty ? '' : '${e.bytes.length}',
                                    style: mono.copyWith(
                                      fontSize: 10,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
          Container(
            height: widget.compact ? 20 : 29,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  paused ? Icons.pause_circle_outline_rounded : Icons.circle,
                  color: paused ? muted : green,
                  size: paused ? 12 : 5,
                ),
                const SizedBox(width: 7),
                Text(
                  paused
                      ? '显示已暂停 · 新增 ${(s.sequence - frozenCount).clamp(0, 999999)} 条'
                      : s.dropped > 0
                      ? '已淘汰 ${s.dropped} 条历史记录'
                      : '${s.logs.length} 条记录',
                  style: const TextStyle(color: muted, fontSize: 9),
                ),
                const Spacer(),
                if (!following)
                  InkWell(
                    onTap: () => setState(() {
                      following = true;
                      s.focusLogId = '';
                    }),
                    child: const Text(
                      '回到最新 ↓',
                      style: TextStyle(fontSize: 10, color: blue),
                    ),
                  ),
                const SizedBox(width: 12),
                const Text('本地时间', style: TextStyle(color: muted, fontSize: 9)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _details(LogEntry e) =>
      showPacketDetails(context, e, session: s, model: widget.model);
}
