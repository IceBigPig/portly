import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bytes.dart';
import '../platform/storage.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import 'shell.dart' show confirm;
import 'theme.dart';

String historyStatus(String status) =>
    const {
      'pending': '待提交',
      'submitting': '提交中',
      'waiting': '等待响应',
      'submitted': '已提交',
      'response': '已匹配响应',
      'device_exception': '设备异常',
      'timeout': '响应超时',
      'failed': '失败',
      'stopped': '已停止',
      'interrupted': '运行中断',
    }[status] ??
    status;
String _kind(String kind) =>
    const {'send': '发送', 'step': '步骤', 'task': '执行', 'file': '文件'}[kind] ??
    kind;
String _time(DateTime value) =>
    value.toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first;
Color _statusColor(HistoryRecord record) =>
    [
      'failed',
      'timeout',
      'device_exception',
      'interrupted',
    ].contains(record.status)
    ? Colors.red
    : record.status == 'response'
    ? green
    : record.pending
    ? Colors.orange
    : muted;

Future<void> showSendHistory(
  BuildContext context,
  AppModel model,
  Session target,
) async {
  if (model.externalView) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _HistoryDialog(model: model, target: target),
  );
}

class _HistoryDialog extends StatefulWidget {
  final AppModel model;
  final Session target;
  const _HistoryDialog({required this.model, required this.target});
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  List<HistoryRecord> records = [];
  late String sessionId = widget.target.id;
  String kind = '', taskId = '', cursor = '', error = '';
  int total = 0, bytes = 0, generation = 0;
  bool busy = false, paged = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!busy && !paged && records.any((r) => r.pending)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool more = false}) async {
    final token = ++generation;
    setState(() {
      busy = true;
      if (!more) paged = false;
      error = '';
    });
    try {
      final page = await widget.model.storage.queryHistory(
        sessionId: sessionId,
        taskId: taskId,
        kinds: kind.isEmpty ? const [] : [kind],
        before: more ? cursor : '',
        limit: 50,
      );
      if (!mounted || generation != token) return;
      setState(() {
        records = more ? [...records, ...page.records] : page.records;
        cursor = page.nextCursor;
        if (more) paged = true;
        total = page.count;
        bytes = page.bytes;
        busy = false;
      });
    } catch (e) {
      if (mounted && token == generation) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> _load(HistoryRecord record) async {
    final target = widget.model.sessions
        .where((s) => s.id == widget.target.id)
        .firstOrNull;
    if (target == null) {
      toast(context, '目标会话已关闭');
      return;
    }
    final draft = record.replayDraft();
    if (target.draft.body.isNotEmpty &&
        !await confirm(context, '载入历史', '替换 ${target.config.name} 的发送草稿？')) {
      return;
    }
    if (!mounted) return;
    if (!widget.model.sessions.contains(target)) {
      toast(context, '目标会话已关闭');
      return;
    }
    target.draft = draft;
    target.commandsMode = false;
    widget.model.page = 0;
    widget.model.selectSession(target.id);
    widget.model.changed();
    Navigator.pop(context);
  }

  Future<void> _focus(HistoryRecord record) async {
    final source = widget.model.sessions
        .where((s) => s.id == record.sessionId)
        .firstOrNull;
    final ids = [
      if (record.responseLogId.isNotEmpty) record.responseLogId,
      ...record.submittedLogIds,
    ];
    final id = ids
        .where((id) => source?.logs.any((e) => e.id == id) ?? false)
        .firstOrNull;
    if (source == null || id == null) {
      toast(context, '报文已离开内存缓存，可在日志文件中检索');
      return;
    }
    source.focusLogId = id;
    source.changed();
    widget.model.page = 0;
    widget.model.selectSession(source.id);
    widget.model.refresh();
    Navigator.pop(context);
  }

  Future<void> _details(HistoryRecord record) async {
    final action = await showDialog<({String action, HistoryRecord record})>(
      context: context,
      builder: (_) => _HistoryDetails(model: widget.model, initial: record),
    );
    if (!mounted) return;
    if (action == null) return;
    if (action.action == 'load') await _load(action.record);
    if (action.action == 'focus') await _focus(action.record);
    if (action.action == 'steps') {
      setState(() {
        taskId = action.record.id;
        kind = '';
      });
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('发送与执行历史', style: TextStyle(fontSize: 18)),
    content: SizedBox(
      width: 920,
      height: MediaQuery.sizeOf(context).height * .65,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Pick<String>(
                  value: sessionId,
                  options: {
                    '': '全部会话',
                    for (final s in widget.model.sessions) s.id: s.config.name,
                    for (final r in records)
                      if (r.sessionId.isNotEmpty) r.sessionId: r.sessionName,
                  },
                  onChanged: (v) {
                    sessionId = v;
                    taskId = '';
                    unawaited(_refresh());
                  },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 135,
                child: Pick<String>(
                  value: kind,
                  options: const {
                    '': '全部记录',
                    'send': '单条发送',
                    'task': '执行任务',
                    'step': '执行步骤',
                    'file': '文件发送',
                  },
                  onChanged: (v) {
                    kind = v;
                    unawaited(_refresh());
                  },
                ),
              ),
              const SizedBox(width: 8),
              iconAction(Icons.refresh_rounded, '刷新历史', busy ? null : _refresh),
              iconAction(
                Icons.delete_outline_rounded,
                '清空历史',
                busy
                    ? null
                    : () async {
                        if (!await confirm(
                          context,
                          '清空历史',
                          '${sessionId.isEmpty ? '清空全部' : '清空所选会话'}的发送与执行历史？运行任务会继续记录后续结果。',
                        )) {
                          return;
                        }
                        try {
                          await widget.model.storage.clearHistory(
                            sessionId: sessionId,
                          );
                          if (mounted) await _refresh();
                        } catch (e) {
                          if (mounted) setState(() => error = '$e');
                        }
                      },
              ),
            ],
          ),
          if (taskId.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  taskId = '';
                  unawaited(_refresh());
                },
                icon: const Icon(Icons.arrow_back_rounded, size: 15),
                label: const Text('全部任务'),
              ),
            ),
          const SizedBox(height: 10),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                error,
                style: const TextStyle(fontSize: 11, color: Colors.red),
              ),
            ),
          Expanded(
            child: records.isEmpty
                ? Center(
                    child: Text(
                      busy ? '读取中' : '暂无历史',
                      style: const TextStyle(fontSize: 12, color: muted),
                    ),
                  )
                : EdgeScroll(
                    builder: (context, controller) => ListView.builder(
                      controller: controller,
                      itemCount: records.length,
                      itemExtent: 69,
                      itemBuilder: (_, index) {
                        final record = records[index];
                        final name = record.name.isEmpty
                            ? _kind(record.kind)
                            : record.name;
                        return InkWell(
                          onTap: () => _details(record),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 10,
                              horizontal: 5,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      _kind(record.kind),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: blue,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      historyStatus(record.status),
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: _statusColor(record),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      _time(record.startedAt),
                                      style: mono.copyWith(
                                        fontSize: 10,
                                        color: muted,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        '${record.sessionName} · ${record.targets.join(', ')}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: muted,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      '${record.submittedBytes} B · ${record.elapsedMs} ms',
                                      style: mono.copyWith(
                                        fontSize: 10,
                                        color: muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
          Row(
            children: [
              Text(
                '$total 条 · ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
                style: const TextStyle(fontSize: 10, color: muted),
              ),
              const Spacer(),
              if (cursor.isNotEmpty)
                TextButton(
                  onPressed: busy ? null : () => _refresh(more: true),
                  child: const Text('加载更多'),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}

class _HistoryDetails extends StatefulWidget {
  final AppModel model;
  final HistoryRecord initial;
  const _HistoryDetails({required this.model, required this.initial});
  @override
  State<_HistoryDetails> createState() => _HistoryDetailsState();
}

class _HistoryDetailsState extends State<_HistoryDetails> {
  late HistoryRecord record = widget.initial;
  Timer? timer;
  bool refreshing = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!record.pending || refreshing) return;
      refreshing = true;
      try {
        final next = await widget.model.storage.getHistory(record.id);
        if (next != null && mounted) setState(() => record = next);
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      } finally {
        refreshing = false;
      }
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Widget _field(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: mono.copyWith(fontSize: 11),
          ),
        ),
      ],
    ),
  );
  Widget _body(
    String title,
    List<int> bytes,
    int length, {
    bool truncated = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '$title · $length B${truncated ? '（保留前 ${bytes.length} B）' : ''}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            iconAction(
              Icons.copy_rounded,
              truncated ? '复制保留的前 ${bytes.length} B' : '复制$title',
              bytes.isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: hex(bytes)));
                    },
            ),
          ],
        ),
        SelectableText(
          hex(bytes.take(4096)),
          style: mono.copyWith(fontSize: 11, height: 1.7),
        ),
        if (bytes.length > 4096)
          const Text(
            '预览前 4096 B',
            style: TextStyle(fontSize: 10, color: muted),
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final source = widget.model.sessions
        .where((s) => s.id == record.sessionId)
        .firstOrNull;
    final stop =
        record.pending &&
        source != null &&
        source.running &&
        source.activeHistoryTaskId == record.id;
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(
              record.name.isEmpty ? '${_kind(record.kind)}详情' : record.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18),
            ),
          ),
          const SizedBox(width: 16),
          Text(
            historyStatus(record.status),
            style: TextStyle(fontSize: 12, color: _statusColor(record)),
          ),
        ],
      ),
      content: SizedBox(
        width: 780,
        height: MediaQuery.sizeOf(context).height * .6,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field('时间', _time(record.startedAt)),
              _field('会话', record.sessionName),
              _field('目标', record.targets.join(', ')),
              _field(
                '提交 / 耗时',
                '${record.submittedBytes} B / ${record.elapsedMs} ms',
              ),
              if (record.kind == 'task')
                _field(
                  '步骤',
                  '${record.stepsCompleted} 已完成 / ${record.stepsStarted} 已开始',
                ),
              if (record.kind == 'step')
                _field('步骤 / 循环', '${record.stepIndex} / ${record.cycle}'),
              if (record.error.isNotEmpty) _field('错误', record.error),
              if (record.metadataTruncated) _field('快照范围', '部分元数据超出保留上限'),
              if (error.isNotEmpty) _field('读取失败', error),
              if (record.file.isNotEmpty) ...[
                for (final entry in record.file.entries)
                  _field(
                    const {
                          'name': '文件',
                          'size': '文件大小',
                          'chunkSize': '分块字节',
                          'delayMs': '块间隔/ms',
                          'path': '路径',
                        }[entry.key] ??
                        entry.key,
                    '${entry.value}',
                  ),
              ],
              if (record.parameters.isNotEmpty)
                _field(
                  '参数',
                  record.parameters.entries
                      .map((e) => '${e.key}=${e.value}')
                      .join(', '),
                ),
              if (record.draft case final draft?) ...[
                _field(
                  '处理策略',
                  '${draft.text ? draft.encoding : 'HEX'} · ${draft.crc ? 'CRC-16/MODBUS' : 'Raw'}${draft.suffix.isEmpty ? '' : ' · 尾缀 ${draft.suffix}'}',
                ),
              ],
              if (record.finalLength > 0)
                _body(
                  '最终字节',
                  record.finalBytes,
                  record.finalLength,
                  truncated: record.finalBytesTruncated,
                ),
              if (record.responseLength > 0)
                _body(
                  '匹配响应',
                  record.responseBytes,
                  record.responseLength,
                  truncated: record.responseBytesTruncated,
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text(
                  '快照标识',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
                children: [
                  _field('记录 ID', record.id),
                  _field('运行实例', record.runtimeId),
                  if (record.commandId.isNotEmpty)
                    _field('命令版本', '${record.commandId} · r${record.revision}'),
                  if (record.taskId.isNotEmpty) _field('任务 ID', record.taskId),
                  if (record.timeoutMs > 0)
                    _field('响应超时', '${record.timeoutMs} ms'),
                  if (record.periodMs > 0)
                    _field('循环周期', '${record.periodMs} ms'),
                  if (record.stepDelayMs > 0)
                    _field('步骤延时', '${record.stepDelayMs} ms'),
                  if (record.responseRule case final rule?) ...[
                    _field(
                      '响应规则',
                      const {
                            'none': '不等待',
                            'modbus_rtu': 'Modbus RTU',
                            'bytes_exact': '完整字节',
                            'bytes_prefix': '字节前缀',
                            'bytes_masked': '偏移掩码',
                            'text_exact': '文本精确',
                            'text_contains': '文本包含',
                          }[rule['type']] ??
                          '${rule['type']}',
                    ),
                    if (rule['framing'] != null)
                      _field(
                        '分帧',
                        const {
                              'rtu': 'Modbus RTU',
                              'fixed': '固定长度',
                              'delimiter': '分隔符',
                              'datagram': 'UDP 数据报',
                            }[rule['framing']] ??
                            '${rule['framing']}',
                      ),
                    if (rule['patternHex'] != null)
                      _field('匹配字节', '${rule['patternHex']}'),
                    if (rule['text'] != null) _field('匹配文本', '${rule['text']}'),
                    if (rule['maskHex'] != null)
                      _field('掩码', '${rule['maskHex']}'),
                    if (rule['length'] != null)
                      _field(
                        '帧长 / 偏移',
                        '${rule['length']} B / ${rule['offset'] ?? 0}',
                      ),
                    if (rule['unitId'] != null || rule['functionCode'] != null)
                      _field(
                        '站号 / 功能',
                        '${rule['unitId'] ?? '随请求'} / ${rule['functionCode'] ?? '随请求'}',
                      ),
                    if (rule['registerCount'] != null)
                      _field('预期数量', '${rule['registerCount']}'),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (stop)
          TextButton(
            onPressed: () {
              source.stop();
              unawaited(
                widget.model.storage
                    .getHistory(record.id)
                    .then((value) {
                      if (value != null && mounted) {
                        setState(() => record = value);
                      }
                    })
                    .catchError((Object e) {
                      if (mounted) setState(() => error = '$e');
                    }),
              );
            },
            child: const Text('停止任务'),
          ),
        if (record.kind == 'task')
          TextButton(
            onPressed: () =>
                Navigator.pop(context, (action: 'steps', record: record)),
            child: const Text('查看步骤'),
          ),
        if (record.responseLogId.isNotEmpty ||
            record.submittedLogIds.isNotEmpty)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, (action: 'focus', record: record)),
            child: const Text('定位日志'),
          ),
        if (record.canReplay)
          OutlinedButton(
            onPressed: () =>
                Navigator.pop(context, (action: 'load', record: record)),
            child: const Text('载入发送框'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
