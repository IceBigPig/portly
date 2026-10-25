import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/bytes.dart';
import '../core/models.dart';
import '../platform/storage.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import 'packet_viewer.dart';
import 'theme.dart';

String _bytes(int value) => value < 1024
    ? '$value B'
    : value < 1024 * 1024
    ? '${(value / 1024).toStringAsFixed(1)} KiB'
    : '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
String _fileState(String value) =>
    const {
      'active': '记录中',
      'closed': '已关闭',
      'missing': '已移除',
      'truncated': '末尾截断',
      'damaged': '损坏',
      'indexPending': '待重建索引',
    }[value] ??
    value;
String _fileName(String path) => path.replaceAll('\\', '/').split('/').last;
String _time(DateTime? value) => value == null
    ? '—'
    : value.toLocal().toIso8601String().replaceFirst('T', ' ').split('.').first;

Future<bool> configureLogRecording(
  BuildContext context,
  AppModel model, {
  Session? session,
}) async {
  if (model.externalView) return false;
  final options = await showDialog<LogRecordingOptions>(
    context: context,
    builder: (_) => _RecordingOptionsDialog(
      initial: model.logOptions,
      start: session != null,
    ),
  );
  if (options == null) return false;
  model.logOptions = options;
  model.saveSoon();
  if (session == null) return true;
  session.recorder.onUpdate = session.scheduleNotify;
  session.error = '';
  try {
    await session.recorder.start(
      (e) {
        session.error = '日志记录失败：$e';
        session.scheduleNotify();
      },
      options: options,
      sessionId: session.id,
      sessionName: session.config.name,
      runtimeId: session.runtimeId,
    );
    session.scheduleNotify();
    return session.recorder.active;
  } catch (e) {
    session.error = '日志记录失败：$e';
    session.scheduleNotify();
    return false;
  }
}

class _RecordingOptionsDialog extends StatefulWidget {
  final LogRecordingOptions initial;
  final bool start;
  const _RecordingOptionsDialog({required this.initial, required this.start});
  @override
  State<_RecordingOptionsDialog> createState() =>
      _RecordingOptionsDialogState();
}

class _RecordingOptionsDialogState extends State<_RecordingOptionsDialog> {
  final form = GlobalKey<FormState>();
  late final directory = TextEditingController(text: widget.initial.directory);
  late final base = TextEditingController(text: widget.initial.baseName);
  late final fileSize = TextEditingController(
    text: '${widget.initial.fileLimitBytes ~/ (1024 * 1024)}',
  );
  late final count = TextEditingController(text: '${widget.initial.maxFiles}');
  late final total = TextEditingController(
    text: '${widget.initial.maxTotalBytes ~/ (1024 * 1024)}',
  );
  late bool overwrite = widget.initial.overwriteOldest;
  String error = '';
  @override
  void dispose() {
    directory.dispose();
    base.dispose();
    fileSize.dispose();
    count.dispose();
    total.dispose();
    super.dispose();
  }

  Widget number(String label, TextEditingController controller, int max) =>
      Labeled(
        label,
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          style: mono.copyWith(fontSize: 12),
          validator: (v) {
            final n = int.tryParse(v ?? '');
            return n == null || n < 1 || n > max ? '范围 1–$max' : null;
          },
        ),
      );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('日志记录', style: TextStyle(fontSize: 18)),
    content: SizedBox(
      width: 470,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Labeled(
                '目录',
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: directory,
                        readOnly: true,
                        style: const TextStyle(fontSize: 12),
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? '请选择日志目录' : null,
                      ),
                    ),
                    const SizedBox(width: 6),
                    iconAction(Icons.folder_open_outlined, '选择日志目录', () async {
                      final chosen = await getDirectoryPath(
                        initialDirectory: directory.text.isEmpty
                            ? null
                            : directory.text,
                      );
                      if (chosen != null && mounted) {
                        setState(() => directory.text = chosen);
                      }
                    }),
                  ],
                ),
              ),
              Labeled(
                '文件名前缀',
                TextFormField(
                  controller: base,
                  style: mono.copyWith(fontSize: 12),
                  validator: (v) =>
                      RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(v ?? '')
                      ? null
                      : '支持字母、数字、下划线和短横线',
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: number('单文件 / MiB', fileSize, 102400)),
                  const SizedBox(width: 16),
                  Expanded(child: number('最多文件数', count, 10000)),
                ],
              ),
              number('日志总占用上限 / MiB（含索引）', total, 1048576),
              Row(
                children: [
                  const Expanded(
                    child: Text('循环覆盖最早的已关闭日志', style: TextStyle(fontSize: 12)),
                  ),
                  Switch.adaptive(
                    value: overwrite,
                    onChanged: (v) => setState(() => overwrite = v),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                overwrite ? '仅清理本目录中 Portly 管理的日志，活动文件保留。' : '达到文件数或占用上限时停止记录。',
                style: const TextStyle(fontSize: 11, color: muted),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error,
                    style: const TextStyle(fontSize: 11, color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!form.currentState!.validate()) return;
          try {
            final next = widget.initial.copy(
              directory: directory.text,
              baseName: base.text,
              fileLimitBytes: int.parse(fileSize.text) * 1024 * 1024,
              maxFiles: int.parse(count.text),
              maxTotalBytes: int.parse(total.text) * 1024 * 1024,
              overwriteOldest: overwrite,
            );
            next.validate();
            Navigator.pop(context, next);
          } catch (e) {
            setState(() => error = '$e');
          }
        },
        child: Text(widget.start ? '开始记录' : '保存'),
      ),
    ],
  );
}

Future<void> showLogArchive(
  BuildContext context,
  AppModel model, {
  Session? session,
}) async {
  if (model.externalView) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _LogArchiveDialog(model: model, session: session),
  );
}

class _LogArchiveDialog extends StatefulWidget {
  final AppModel model;
  final Session? session;
  const _LogArchiveDialog({required this.model, this.session});
  @override
  State<_LogArchiveDialog> createState() => _LogArchiveDialogState();
}

class _LogArchiveDialogState extends State<_LogArchiveDialog> {
  final archive = LogArchive();
  late final directory = TextEditingController(
    text: widget.model.logOptions.directory,
  );
  final search = TextEditingController(),
      from = TextEditingController(),
      to = TextEditingController();
  List<LogArchiveFile> files = [];
  String loadedDirectory = '';
  Map<String, int> usage = const {};
  Map<String, String> archivedSessions = const {};
  List<String> maintenanceWarnings = [];
  List<LogArchiveHit> hits = [];
  String sessionId = '',
      direction = '',
      filePath = '',
      nextCursor = '',
      error = '';
  List<String> warnings = [];
  bool hexMode = false, busy = false, rebuilding = false;
  int tab = 0, request = 0, fileRequest = 0;
  Timer? debounce;
  @override
  void initState() {
    super.initState();
    if (directory.text.isNotEmpty) unawaited(_refresh());
  }

  @override
  void dispose() {
    debounce?.cancel();
    archive.cancel();
    archive.close();
    directory.dispose();
    search.dispose();
    from.dispose();
    to.dispose();
    super.dispose();
  }

  void _searchSoon() {
    debounce?.cancel();
    archive.cancel();
    request++;
    debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_search()),
    );
  }

  Future<void> _refresh() async {
    if (directory.text.isEmpty) return;
    final path = directory.text, token = ++fileRequest;
    archive.cancel();
    request++;
    if (loadedDirectory != path) {
      setState(() {
        loadedDirectory = path;
        files = [];
        hits = [];
        usage = const {};
        archivedSessions = const {};
        warnings = maintenanceWarnings = [];
        filePath = nextCursor = error = '';
      });
    }
    try {
      final results = await Future.wait<dynamic>([
        archive.listFiles(path),
        archive.usage(path),
        archive.sessions(path),
      ]);
      if (!mounted || token != fileRequest || directory.text != path) return;
      setState(() {
        files = results[0] as List<LogArchiveFile>;
        usage = results[1] as Map<String, int>;
        archivedSessions = results[2] as Map<String, String>;
        if (filePath.isNotEmpty && !files.any((f) => f.path == filePath)) {
          filePath = '';
        }
        if (sessionId.isNotEmpty &&
            !archivedSessions.containsKey(sessionId) &&
            !widget.model.sessions.any((s) => s.id == sessionId)) {
          sessionId = '';
        }
      });
      await _search();
    } catch (e) {
      if (mounted && token == fileRequest && directory.text == path) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> _search({bool more = false}) async {
    debounce?.cancel();
    archive.cancel();
    final token = ++request;
    if (directory.text.isEmpty) return;
    DateTime? start, end;
    try {
      start = from.text.trim().isEmpty
          ? null
          : DateTime.parse(from.text.trim());
      end = to.text.trim().isEmpty ? null : DateTime.parse(to.text.trim());
      if (start != null && end != null && start.isAfter(end)) {
        throw const FormatException('起始时间晚于结束时间');
      }
      if (hexMode && search.text.isNotEmpty) parseHex(search.text);
    } catch (e) {
      setState(() {
        error = '筛选条件无效：$e';
        busy = false;
        hits = [];
        nextCursor = '';
      });
      return;
    }
    setState(() {
      busy = true;
      error = '';
      if (!more) {
        hits = [];
        nextCursor = '';
      }
    });
    try {
      final result = await archive.search(
        LogSearchQuery(
          directory: directory.text,
          query: search.text,
          hex: hexMode,
          sessionId: sessionId,
          direction: direction,
          filePath: filePath,
          from: start,
          to: end,
          limit: 100,
          cursor: more ? nextCursor : '',
        ),
      );
      if (!mounted || token != request || result.cancelled) return;
      setState(() {
        hits = more ? [...hits, ...result.hits] : result.hits;
        nextCursor = result.nextCursor;
        warnings = [...maintenanceWarnings, ...result.warnings];
        busy = false;
      });
    } catch (e) {
      if (mounted && token == request) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  Future<void> _details(LogArchiveHit hit) async {
    try {
      final record = await archive.readRecord(hit);
      if (!mounted) return;
      final entry = LogEntry(
        record['direction'] ?? 'RX',
        parseHex(record['hex'] ?? ''),
        id: record['id'],
        time: DateTime.parse(record['time']),
        endpoint: record['endpoint'] ?? '',
        message: record['message'] ?? '',
      );
      final source = widget.model.sessions
          .where((s) => s.id == hit.sessionId)
          .firstOrNull;
      await showPacketDetails(
        context,
        entry,
        session: source,
        model: widget.model,
      );
    } catch (e) {
      if (mounted) toast(context, '无法读取原报文：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = {
      ...archivedSessions,
      for (final s in widget.model.sessions) s.id: s.config.name,
      for (final f in files)
        if (f.sessionId.isNotEmpty)
          f.sessionId: f.sessionName.isEmpty ? f.sessionId : f.sessionName,
    };
    return AlertDialog(
      title: Row(
        children: [
          const Text('日志文件', style: TextStyle(fontSize: 18)),
          const Spacer(),
          iconAction(Icons.settings_outlined, '记录设置', () async {
            await configureLogRecording(context, widget.model);
            if (mounted) {
              directory.text = widget.model.logOptions.directory;
              await _refresh();
            }
          }),
        ],
      ),
      content: SizedBox(
        width: 1020,
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: directory,
                    readOnly: true,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(hintText: '选择日志目录'),
                  ),
                ),
                iconAction(Icons.folder_open_outlined, '选择目录', () async {
                  final chosen = await getDirectoryPath(
                    initialDirectory: directory.text.isEmpty
                        ? null
                        : directory.text,
                  );
                  if (chosen != null && mounted) {
                    directory.text = chosen;
                    filePath = '';
                    await _refresh();
                  }
                }),
                iconAction(Icons.refresh_rounded, '刷新文件', _refresh),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Segment(
                  labels: const ['搜索', '文件'],
                  value: tab,
                  onChanged: (v) => setState(() => tab = v),
                ),
                const Spacer(),
                Tooltip(
                  message:
                      '日志 ${_bytes(usage['logBytes'] ?? 0)} · 索引及管理文件 ${_bytes(usage['indexBytes'] ?? 0)}',
                  child: Text(
                    '${files.where((file) => file.state != 'missing').length} 个文件 · 日志占用 ${_bytes(usage['totalBytes'] ?? 0)}',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: rebuilding || directory.text.isEmpty
                      ? null
                      : () async {
                          final path = directory.text;
                          setState(() {
                            rebuilding = true;
                            error = '';
                          });
                          archive.cancel();
                          try {
                            final result = await archive.rebuild(
                              path,
                              options: widget.model.logOptions.copy(
                                directory: path,
                              ),
                            );
                            if (mounted && directory.text == path) {
                              maintenanceWarnings = result;
                              await _refresh();
                            }
                          } catch (e) {
                            if (mounted && directory.text == path) {
                              setState(() => error = '$e');
                            }
                          } finally {
                            if (mounted) setState(() => rebuilding = false);
                          }
                        },
                  icon: const Icon(Icons.manage_search_rounded, size: 16),
                  label: Text(rebuilding ? '重建中' : '重建索引'),
                ),
              ],
            ),
            if (tab == 0) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: search,
                      style: mono.copyWith(fontSize: 12),
                      decoration: const InputDecoration(
                        hintText: '搜索文件中的报文',
                        prefixIcon: Icon(Icons.search_rounded, size: 17),
                      ),
                      onChanged: (_) => _searchSoon(),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 105,
                    child: Pick<bool>(
                      value: hexMode,
                      options: const {false: '文本', true: 'HEX'},
                      onChanged: (v) {
                        hexMode = v;
                        _searchSoon();
                        setState(() {});
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: Pick<String>(
                      value: direction,
                      options: const {
                        '': '全部方向',
                        'RX': 'RX',
                        'TX': 'TX',
                        'SYS': 'SYS',
                      },
                      onChanged: (v) {
                        direction = v;
                        _searchSoon();
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  filePath.isEmpty ? '筛选' : _fileName(filePath),
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      SizedBox(
                        width: 185,
                        child: Pick<String>(
                          value: sessionId,
                          options: {'': '全部会话', ...sessions},
                          onChanged: (v) {
                            sessionId = v;
                            _searchSoon();
                            setState(() {});
                          },
                        ),
                      ),
                      SizedBox(
                        width: 210,
                        child: TextField(
                          controller: from,
                          decoration: const InputDecoration(
                            labelText: '起始时间',
                            hintText: 'YYYY-MM-DD HH:mm:ss',
                          ),
                          style: const TextStyle(fontSize: 11),
                          onChanged: (_) => _searchSoon(),
                        ),
                      ),
                      SizedBox(
                        width: 210,
                        child: TextField(
                          controller: to,
                          decoration: const InputDecoration(
                            labelText: '结束时间',
                            hintText: 'YYYY-MM-DD HH:mm:ss',
                          ),
                          style: const TextStyle(fontSize: 11),
                          onChanged: (_) => _searchSoon(),
                        ),
                      ),
                      if (filePath.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            setState(() => filePath = '');
                            _searchSoon();
                          },
                          child: const Text('全部文件'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ],
            if (busy || rebuilding) const LinearProgressIndicator(minHeight: 2),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  error,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
              ),
            if (warnings.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Text(
                  warnings.join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
              ),
            const SizedBox(height: 6),
            Expanded(child: tab == 0 ? _results() : _files()),
            if (tab == 0)
              Row(
                children: [
                  Text(
                    '${hits.length} 条',
                    style: const TextStyle(fontSize: 10, color: muted),
                  ),
                  const Spacer(),
                  if (busy)
                    TextButton(
                      onPressed: () {
                        archive.cancel();
                        request++;
                        setState(() => busy = false);
                      },
                      child: const Text('取消搜索'),
                    ),
                  if (nextCursor.isNotEmpty)
                    TextButton(
                      onPressed: busy ? null : () => _search(more: true),
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

  Widget _results() => hits.isEmpty
      ? Center(
          child: Text(
            directory.text.isEmpty
                ? '选择日志目录'
                : busy
                ? '搜索中'
                : '无匹配记录',
            style: const TextStyle(fontSize: 12, color: muted),
          ),
        )
      : EdgeScroll(
          builder: (context, controller) => ListView.builder(
            controller: controller,
            itemCount: hits.length,
            itemExtent: 57,
            itemBuilder: (context, i) {
              final hit = hits[i];
              return InkWell(
                onDoubleTap: () => _details(hit),
                onTap: () => _details(hit),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 7,
                    horizontal: 7,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _time(hit.time),
                            style: mono.copyWith(fontSize: 10, color: muted),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            hit.direction,
                            style: mono.copyWith(
                              fontSize: 10,
                              color: hit.direction == 'RX' ? green : blue,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '${hit.sessionName} · ${hit.endpoint}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10,
                                color: muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        hit.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
  Widget _files() => files.isEmpty
      ? const Center(
          child: Text('暂无日志文件', style: TextStyle(fontSize: 12, color: muted)),
        )
      : EdgeScroll(
          builder: (context, controller) => ListView.builder(
            controller: controller,
            itemCount: files.length,
            itemExtent: 61,
            itemBuilder: (context, i) {
              final file = files[i];
              return InkWell(
                onTap: () {
                  setState(() {
                    filePath = file.path;
                    tab = 0;
                  });
                  unawaited(_search());
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 7,
                    horizontal: 7,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _fileName(file.path),
                              overflow: TextOverflow.ellipsis,
                              style: mono.copyWith(fontSize: 11),
                            ),
                          ),
                          Text(
                            '${_bytes(file.bytes)} · ${file.records} 条 · ${_fileState(file.state)}',
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${file.sessionName} · ${_time(file.from)} → ${_time(file.to)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: muted),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
}
