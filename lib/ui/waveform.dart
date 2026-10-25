import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/wave.dart';
import '../platform/storage.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import 'packet_viewer.dart';
import 'theme.dart';

class WaveformPage extends StatefulWidget {
  final AppModel model;
  const WaveformPage({super.key, required this.model});
  @override
  State<WaveformPage> createState() => _WaveformPageState();
}

class _WaveformPageState extends State<WaveformPage> {
  bool paused = false;
  final frozen = <String, List<WaveSample>>{};
  DateTime? cursor, pausedEnd;
  String? previousSource;
  String _cacheKey = '';
  Map<String, List<WaveSample>> _windowCache = {};
  DateTime _cachedEnd = DateTime.now(), _cachedStart = DateTime.now();
  Session get source =>
      widget.model.sessions
          .where((s) => s.id == widget.model.waveSourceId)
          .firstOrNull ??
      widget.model.current;
  void _sourceChanged() {
    paused = false;
    frozen.clear();
    cursor = null;
    pausedEnd = null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.model.page != 1) return const SizedBox.shrink();
    final m = widget.model;
    if (m.waveSourceId.isNotEmpty &&
        !m.sessions.any((s) => s.id == m.waveSourceId)) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            SizedBox(
              width: 260,
              child: Pick<String>(
                value: '',
                options: {
                  '': '数据源已关闭',
                  for (final s in m.sessions) s.id: s.config.name,
                },
                onChanged: (id) {
                  m.waveSourceId = id;
                  m.changed();
                },
              ),
            ),
            const Expanded(
              child: Center(
                child: Text('数据源已关闭', style: TextStyle(color: muted)),
              ),
            ),
          ],
        ),
      );
    }
    final s = source;
    if (previousSource != s.id) {
      previousSource = s.id;
      _sourceChanged();
    }
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final channels = s.waveform.channels;
        final cacheKey =
            '${s.id}:${s.sequence}:$paused:${s.connected && !paused ? DateTime.now().millisecondsSinceEpoch ~/ 500 : 0}:${m.waveSeconds}:${channels.map((c) => '${c.mapping.id}:${c.mapping.visible}:${c.samples.length}:${c.dropped}').join('|')}';
        if (_cacheKey != cacheKey) {
          _cacheKey = cacheKey;
          final all = {
            for (final c in channels)
              c.mapping.id: paused
                  ? frozen[c.mapping.id] ?? <WaveSample>[]
                  : c.samples.toList(),
          };
          final last = all.values
              .expand((v) => v)
              .map((v) => v.time)
              .fold<DateTime?>(
                null,
                (a, b) => a == null || b.isAfter(a) ? b : a,
              );
          _cachedEnd = paused
              ? pausedEnd ?? last ?? DateTime.now()
              : s.connected
              ? DateTime.now()
              : last ?? DateTime.now();
          _cachedStart = _cachedEnd.subtract(Duration(seconds: m.waveSeconds));
          _windowCache = {
            for (final c in channels)
              c.mapping.id: (all[c.mapping.id] ?? [])
                  .where((p) => !p.time.isBefore(_cachedStart))
                  .toList(),
          };
        }
        final window = _windowCache, end = _cachedEnd, start = _cachedStart;
        final series = [
          for (final c in channels)
            if (c.mapping.visible) WaveSeries(c.mapping, window[c.mapping.id]!),
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
          child: Column(
            children: [
              Row(
                children: [
                  const Text(
                    '波形',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 16),
                  StatusDot(s.connected),
                  const SizedBox(width: 7),
                  Text(
                    s.state,
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: 220,
                    child: Pick<String>(
                      value: s.id,
                      options: {
                        for (final item in m.sessions)
                          item.id: item.config.name,
                      },
                      onChanged: (id) => setState(() {
                        m.waveSourceId = id;
                        _sourceChanged();
                        m.saveSoon();
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  iconAction(
                    m.waveSourceId.isEmpty
                        ? Icons.lock_open_rounded
                        : Icons.lock_rounded,
                    m.waveSourceId.isEmpty ? '固定数据源' : '跟随当前会话',
                    () => setState(() {
                      m.waveSourceId = m.waveSourceId.isEmpty ? s.id : '';
                      _sourceChanged();
                      m.saveSoon();
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Panel(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          iconAction(
                            paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded,
                            paused ? '恢复绘图' : '暂停绘图（仍采集）',
                            () => setState(() {
                              if (!paused) {
                                for (final c in channels) {
                                  frozen[c.mapping.id] = c.samples.toList();
                                }
                              }
                              paused = !paused;
                            }),
                          ),
                          if (paused)
                            const Text(
                              '已暂停',
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 112,
                            child: Pick<int>(
                              value: m.waveSeconds,
                              options: {
                                10: '10 秒',
                                60: '60 秒',
                                300: '5 分钟',
                                if (![10, 60, 300].contains(m.waveSeconds))
                                  m.waveSeconds: '${m.waveSeconds} 秒',
                                -1: '自定义…',
                              },
                              onChanged: (v) async {
                                if (v == -1) {
                                  final ctl = TextEditingController(
                                    text: '${m.waveSeconds}',
                                  );
                                  final result = await showDialog<int>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('时间窗 / 秒'),
                                      content: TextField(
                                        controller: ctl,
                                        keyboardType: TextInputType.number,
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('取消'),
                                        ),
                                        FilledButton(
                                          onPressed: () {
                                            final n = int.tryParse(ctl.text);
                                            if (n != null &&
                                                n >= 1 &&
                                                n <= 86400) {
                                              Navigator.pop(ctx, n);
                                            }
                                          },
                                          child: const Text('应用'),
                                        ),
                                      ],
                                    ),
                                  );
                                  Future<void>.delayed(
                                    const Duration(milliseconds: 300),
                                    ctl.dispose,
                                  );
                                  if (result == null || !mounted) return;
                                  v = result;
                                }
                                setState(() {
                                  m.waveSeconds = v;
                                  m.saveSoon();
                                });
                              },
                            ),
                          ),
                          iconAction(
                            Icons.center_focus_strong_rounded,
                            '复位并跟随最新',
                            () => setState(_sourceChanged),
                          ),
                          const Spacer(),
                          if (s.running)
                            TextButton.icon(
                              onPressed: s.stop,
                              icon: const Icon(Icons.stop_rounded, size: 16),
                              label: const Text('停止发送'),
                            ),
                          iconAction(
                            Icons.file_download_outlined,
                            '导出原始样本 CSV',
                            () async {
                              try {
                                await exportFile(
                                  'portly-wave.csv',
                                  s.waveform.exportCsv(),
                                );
                              } catch (e) {
                                if (context.mounted) toast(context, '$e');
                              }
                            },
                          ),
                          iconAction(
                            Icons.delete_outline_rounded,
                            '清空波形',
                            () => setState(() {
                              for (final c in channels) {
                                c.clear();
                              }
                              frozen.clear();
                              cursor = null;
                            }),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed: channels.length >= 8
                                ? null
                                : () => _mapping(s),
                            icon: const Icon(Icons.add_rounded, size: 16),
                            label: Text('添加通道 · ${channels.length}/8'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, bounds) => MouseRegion(
                            onHover: (e) => setState(() {
                              final x =
                                  ((e.localPosition.dx - 58) /
                                          math.max(1, bounds.maxWidth - 80))
                                      .clamp(0, 1);
                              cursor = start.add(
                                Duration(
                                  microseconds:
                                      (end.difference(start).inMicroseconds * x)
                                          .round(),
                                ),
                              );
                            }),
                            onExit: (_) => setState(() => cursor = null),
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: WavePainter(
                                      series: series,
                                      start: start,
                                      end: end,
                                      dark: m.dark,
                                      cursor: cursor,
                                    ),
                                  ),
                                ),
                                if (series.every(
                                  (v) =>
                                      v.samples.every((p) => p.value == null),
                                ))
                                  Center(
                                    child: Text(
                                      channels.isEmpty
                                          ? '添加数值映射'
                                          : !s.connected
                                          ? '数据源未连接'
                                          : '暂无有效样本',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: muted,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (channels.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 7,
                          ),
                          color: Theme.of(context).scaffoldBackgroundColor,
                          child: const Row(
                            children: [
                              SizedBox(width: 32),
                              Expanded(
                                flex: 2,
                                child: Text(
                                  '通道 / 单位',
                                  style: TextStyle(fontSize: 10, color: muted),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '最新',
                                  style: TextStyle(fontSize: 10, color: muted),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '最小 / 最大',
                                  style: TextStyle(fontSize: 10, color: muted),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  '样本 / 错误',
                                  style: TextStyle(fontSize: 10, color: muted),
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: Text(
                                  '光标',
                                  style: TextStyle(fontSize: 10, color: muted),
                                ),
                              ),
                              SizedBox(width: 64),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: math.min(
                            channels.length * 39.0,
                            MediaQuery.sizeOf(context).height < 700 ? 120 : 195,
                          ),
                          child: EdgeScroll(
                            builder: (context, controller) => ListView.builder(
                              controller: controller,
                              itemCount: channels.length,
                              itemExtent: 39,
                              itemBuilder: (context, i) {
                                final c = channels[i],
                                    map = c.mapping,
                                    points = window[map.id]!;
                                final valid = points
                                    .where((p) => p.value != null)
                                    .toList();
                                final values = valid.map((p) => p.value!);
                                WaveSample? nearest;
                                if (cursor != null && points.isNotEmpty) {
                                  var lo = 0, hi = points.length;
                                  while (lo < hi) {
                                    final mid = (lo + hi) ~/ 2;
                                    if (points[mid].time.isBefore(cursor!)) {
                                      lo = mid + 1;
                                    } else {
                                      hi = mid;
                                    }
                                  }
                                  nearest =
                                      points[lo.clamp(0, points.length - 1)];
                                  if (lo > 0 &&
                                      points[lo - 1].time
                                              .difference(cursor!)
                                              .abs() <
                                          nearest.time
                                              .difference(cursor!)
                                              .abs()) {
                                    nearest = points[lo - 1];
                                  }
                                }
                                String number(double? v) =>
                                    v == null ? '—' : v.toStringAsPrecision(6);
                                return Row(
                                  children: [
                                    SizedBox(
                                      width: 32,
                                      child: Checkbox(
                                        value: map.visible,
                                        activeColor: Color(map.color),
                                        onChanged: (v) => setState(() {
                                          map.visible = v!;
                                          m.saveSoon();
                                        }),
                                      ),
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Tooltip(
                                        message: c.lastError.isEmpty
                                            ? map.mode
                                            : c.lastError,
                                        child: Text(
                                          '${map.name}${map.unit.isEmpty ? '' : ' · ${map.unit}'}${map.enabled ? '' : '（停用）'}',
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Color(map.color),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        number(valid.lastOrNull?.value),
                                        style: mono.copyWith(fontSize: 11),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        valid.isEmpty
                                            ? '—'
                                            : '${number(values.reduce(math.min))} / ${number(values.reduce(math.max))}',
                                        overflow: TextOverflow.ellipsis,
                                        style: mono.copyWith(fontSize: 10),
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        '${valid.length} / ${points.length - valid.length}',
                                        style: mono.copyWith(fontSize: 10),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 80,
                                      child: Text(
                                        nearest?.value == null &&
                                                nearest != null
                                            ? '缺口'
                                            : number(nearest?.value),
                                        style: mono.copyWith(fontSize: 10),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 30,
                                      child: iconAction(
                                        Icons.link_rounded,
                                        '查看光标对应报文',
                                        nearest == null || nearest.logId.isEmpty
                                            ? null
                                            : () => _openSample(s, nearest!),
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: '通道设置',
                                      padding: EdgeInsets.zero,
                                      iconSize: 17,
                                      onSelected: (v) {
                                        if (v == 'edit') {
                                          _mapping(s, channel: c);
                                          return;
                                        }
                                        setState(() {
                                          if (v == 'enable') {
                                            map.enabled = !map.enabled;
                                            c.resetStream();
                                          }
                                          if (v == 'delete') {
                                            s.waveform.channels.remove(c);
                                          }
                                          m.saveSoon();
                                        });
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Text('编辑映射'),
                                        ),
                                        PopupMenuItem(
                                          value: 'enable',
                                          child: Text(
                                            map.enabled ? '停用映射' : '启用映射',
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('删除通道'),
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 7),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '当前 ${m.waveSeconds} 秒${paused ? ' · 采集继续' : ''}${channels.any((c) => c.dropped > 0) ? ' · 旧样本已淘汰' : ''}',
                          style: const TextStyle(fontSize: 10, color: muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _openSample(Session s, WaveSample sample) {
    final entry = s.logs.where((e) => e.id == sample.logId).firstOrNull;
    if (entry == null) {
      toast(
        context,
        '原报文已从内存淘汰${s.recorder.path == null ? '' : ' · ${s.recorder.path}'}',
      );
      return;
    }
    widget.model.selectSession(s.id);
    widget.model.page = 0;
    widget.model.changed();
    s.focusLogId = entry.id;
    showPacketDetails(context, entry, session: s, model: widget.model);
  }

  Future<void> _mapping(Session s, {WaveChannel? channel}) async {
    final mapping =
        channel?.mapping.copy() ??
        WaveMapping(
          name: '通道 ${s.waveform.channels.length + 1}',
          color: waveColors[s.waveform.channels.length % 8],
        );
    final controls = <String, TextEditingController>{
      '名称': TextEditingController(text: mapping.name),
      '单位': TextEditingController(text: mapping.unit),
      '分隔符': TextEditingController(text: mapping.delimiter),
      '字段编号 / 从 0 开始': TextEditingController(text: '${mapping.field}'),
      '字节偏移 / 从 0 开始': TextEditingController(text: '${mapping.offset}'),
      '固定帧长 / 字节': TextEditingController(text: '${mapping.frameLength}'),
      '比例': TextEditingController(text: '${mapping.scale}'),
      '偏移': TextEditingController(text: '${mapping.bias}'),
      '来源端点 / 留空匹配全部': TextEditingController(text: mapping.endpoint),
      '报文前缀 / HEX，可留空': TextEditingController(text: mapping.prefix),
      '超时缺口 / ms，0 关闭': TextEditingController(text: '${mapping.gapMs}'),
      '站号': TextEditingController(text: '${mapping.station}'),
      '寄存器地址 / 十进制': TextEditingController(text: '${mapping.registerAddress}'),
    };
    String error = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, edit) {
          Widget field(String label) => Labeled(
            label,
            TextField(
              controller: controls[label],
              style: const TextStyle(fontSize: 12),
            ),
          );
          Widget pair(Widget a, Widget b) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 14),
              Expanded(child: b),
            ],
          );
          return AlertDialog(
            title: Text(channel == null ? '添加通道' : '编辑映射'),
            content: SizedBox(
              width: 540,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(ctx).height * .65,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      pair(field('名称'), field('单位')),
                      Wrap(
                        spacing: 12,
                        children: [
                          for (final color in waveColors)
                            InkWell(
                              onTap: () => edit(() => mapping.color = color),
                              child: Container(
                                width: 26,
                                height: 26,
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: Color(color),
                                  shape: BoxShape.circle,
                                ),
                                child: mapping.color == color
                                    ? const Icon(
                                        Icons.check_rounded,
                                        color: Colors.white,
                                        size: 18,
                                      )
                                    : null,
                              ),
                            ),
                        ],
                      ),
                      Labeled(
                        '数据来源',
                        Pick(
                          value: mapping.mode,
                          options: const {
                            '文本字段': '文本分隔字段',
                            '固定字节偏移': '固定字节偏移',
                            'Modbus 寄存器': 'Modbus 寄存器响应',
                          },
                          onChanged: (v) => edit(() => mapping.mode = v),
                        ),
                      ),
                      if (mapping.mode == '文本字段')
                        pair(field('分隔符'), field('字段编号 / 从 0 开始')),
                      if (mapping.mode == '固定字节偏移')
                        pair(field('字节偏移 / 从 0 开始'), field('固定帧长 / 字节')),
                      if (mapping.mode == 'Modbus 寄存器') ...[
                        pair(field('站号'), field('寄存器地址 / 十进制')),
                        Labeled(
                          '功能码',
                          Pick<int>(
                            value: mapping.function,
                            options: const {3: '03 · 保持寄存器', 4: '04 · 输入寄存器'},
                            onChanged: (v) => edit(() => mapping.function = v),
                          ),
                        ),
                      ],
                      if (mapping.mode != '文本字段')
                        pair(
                          Labeled(
                            '数据类型',
                            Pick(
                              value: mapping.type,
                              options: {
                                for (final t in [
                                  'int16',
                                  'uint16',
                                  'int32',
                                  'uint32',
                                  'float32',
                                  'float64',
                                ])
                                  t: t,
                              },
                              onChanged: (v) => edit(() => mapping.type = v),
                            ),
                          ),
                          Labeled(
                            '字节排列',
                            Pick(
                              value: mapping.order,
                              options: const {
                                'BE': '大端 · ABCD',
                                'LE': '小端 · DCBA',
                                'SWAP_BYTES': '字节交换 · BADC',
                                'SWAP_WORDS': '字交换 · CDAB',
                              },
                              onChanged: (v) => edit(() => mapping.order = v),
                            ),
                          ),
                        ),
                      pair(field('比例'), field('偏移')),
                      field('超时缺口 / ms，0 关闭'),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text(
                          '报文匹配',
                          style: TextStyle(fontSize: 12),
                        ),
                        children: [
                          field('来源端点 / 留空匹配全部'),
                          field('报文前缀 / HEX，可留空'),
                        ],
                      ),
                      if (error.isNotEmpty)
                        Text(
                          error,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.red,
                          ),
                        ),
                    ],
                  ),
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
                  try {
                    String text(String k) => controls[k]!.text;
                    mapping.gapMs = int.parse(text('超时缺口 / ms，0 关闭'));
                    mapping.name = text('名称');
                    mapping.unit = text('单位');
                    mapping.delimiter = text('分隔符');
                    mapping.field = int.parse(text('字段编号 / 从 0 开始'));
                    mapping.offset = int.parse(text('字节偏移 / 从 0 开始'));
                    mapping.frameLength = int.parse(text('固定帧长 / 字节'));
                    mapping.station = int.parse(text('站号'));
                    mapping.registerAddress = int.parse(text('寄存器地址 / 十进制'));
                    mapping.scale = double.parse(text('比例'));
                    mapping.bias = double.parse(text('偏移'));
                    mapping.endpoint = text('来源端点 / 留空匹配全部');
                    mapping.prefix = text('报文前缀 / HEX，可留空');
                    s.waveform.upsert(mapping);
                    Navigator.pop(ctx, true);
                  } catch (e) {
                    edit(
                      () => error = e.toString().replaceFirst(
                        'FormatException: ',
                        '',
                      ),
                    );
                  }
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      for (final c in controls.values) {
        c.dispose();
      }
    });
    if (saved == true && mounted) {
      s.changed();
      widget.model.saveSoon();
      setState(() {});
    }
  }
}

class WaveSeries {
  final WaveMapping mapping;
  final List<WaveSample> samples;
  WaveSeries(this.mapping, this.samples);
}

class WavePainter extends CustomPainter {
  final List<WaveSeries> series;
  final DateTime start, end;
  final bool dark;
  final DateTime? cursor;
  WavePainter({
    required this.series,
    required this.start,
    required this.end,
    required this.dark,
    this.cursor,
  });
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Rect.fromLTRB(
      58,
      16,
      math.max(59, size.width - 22),
      math.max(17, size.height - 28),
    );
    final values = series
        .expand((s) => s.samples)
        .where((p) => p.value != null)
        .map((p) => p.value!);
    var min = values.isEmpty ? 0.0 : values.reduce(math.min),
        max = values.isEmpty ? 1.0 : values.reduce(math.max);
    if (max == min) {
      min -= 1;
      max += 1;
    }
    final padding = (max - min) * .08;
    min -= padding;
    max += padding;
    void label(String text, Offset position, {bool right = false}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: mono.copyWith(fontSize: 9, color: muted),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, position - Offset(right ? painter.width : 0, 0));
    }

    final grid = Paint()
      ..color = muted.withValues(alpha: dark ? .14 : .10)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = bounds.top + bounds.height * i / 4;
      canvas.drawLine(Offset(bounds.left, y), Offset(bounds.right, y), grid);
      label(
        (max - (max - min) * i / 4).toStringAsPrecision(4),
        Offset(50, y - 5),
        right: true,
      );
    }
    final duration = math.max(1, end.difference(start).inMicroseconds);
    double x(DateTime t) =>
        bounds.left +
        t.difference(start).inMicroseconds / duration * bounds.width;
    for (var i = 0; i <= 4; i++) {
      final at = start.add(Duration(microseconds: (duration * i / 4).round()));
      final xx = bounds.left + bounds.width * i / 4;
      canvas.drawLine(Offset(xx, bounds.top), Offset(xx, bounds.bottom), grid);
      label(
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}',
        Offset(xx - 22, bounds.bottom + 10),
      );
    }
    canvas.save();
    canvas.clipRect(bounds.inflate(1));
    for (final s in series) {
      final path = Path();
      bool pen = false;
      final buckets = <int, List<int>>{};
      void flush() {
        for (final bucket in buckets.values) {
          final indices = bucket.toSet().toList()..sort();
          for (final index in indices) {
            final p = s.samples[index];
            final xx = x(p.time),
                y =
                    bounds.bottom -
                    (p.value! - min) / (max - min) * bounds.height;
            if (!pen) {
              path.moveTo(xx, y);
              pen = true;
              canvas.drawCircle(
                Offset(xx, y),
                2,
                Paint()..color = Color(s.mapping.color),
              );
            } else {
              path.lineTo(xx, y);
            }
          }
        }
        buckets.clear();
      }

      for (var i = 0; i < s.samples.length; i++) {
        final p = s.samples[i];
        if (p.value == null) {
          flush();
          pen = false;
          continue;
        }
        final key = x(p.time).floor();
        final bucket = buckets[key];
        if (bucket == null) {
          buckets[key] = [i, i, i, i];
        } else {
          bucket[3] = i;
          if (p.value! < s.samples[bucket[1]].value!) bucket[1] = i;
          if (p.value! > s.samples[bucket[2]].value!) bucket[2] = i;
        }
      }
      flush();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color(s.mapping.color)
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
    if (cursor != null) {
      canvas.drawLine(
        Offset(x(cursor!), bounds.top),
        Offset(x(cursor!), bounds.bottom),
        Paint()..color = muted.withValues(alpha: .6),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant WavePainter oldDelegate) => true;
}
