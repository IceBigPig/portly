import 'package:flutter/material.dart';

import '../core/models.dart';
import '../platform/transport.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import 'theme.dart';
import 'log_archive.dart';

class ConnectionPanel extends StatefulWidget {
  final AppModel model;
  final Session session;
  const ConnectionPanel({
    super.key,
    required this.model,
    required this.session,
  });
  @override
  State<ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends State<ConnectionPanel> {
  List<PortInfo> ports = [];
  bool recordingPending = false;
  Session get s => widget.session;
  ConnectionConfig get c => s.config;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh({bool force = false}) async {
    ports = widget.model.availablePorts;
    try {
      final result = await widget.model.scanPorts(force: force);
      if (mounted) setState(() => ports = result);
    } catch (e) {
      if (mounted && force) toast(context, '枚举串口失败：$e');
    }
  }

  void update(VoidCallback fn) {
    setState(fn);
    s.changed();
    widget.model.saveSoon();
  }

  Future<void> _saveProfile() async {
    final copy = c.copy();
    final index = widget.model.profiles.indexWhere((p) => p.id == copy.id);
    if (index >= 0) {
      widget.model.profiles[index] = copy;
    } else {
      widget.model.profiles.add(copy);
    }
    await widget.model.save();
    if (mounted) toast(context, widget.model.saveState);
  }

  Widget field(
    String label,
    String value,
    ValueChanged<String> changed, {
    String? hint,
    bool number = false,
    bool activeEditable = false,
  }) => Labeled(
    label,
    TextFormField(
      key: ValueKey('${s.id}-$label-${c.kind.name}'),
      initialValue: value,
      enabled: activeEditable || !s.parametersLocked,
      style: const TextStyle(fontSize: 12),
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(hintText: hint),
      onChanged: (v) {
        changed(v);
        s.changed();
        widget.model.saveSoon();
      },
    ),
  );
  Widget pair(Widget a, Widget b) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: a),
      const SizedBox(width: 10),
      Expanded(child: b),
    ],
  );
  Future<void> _setLine({bool? dtr, bool? rts}) async {
    await s.setControlLines(dtr: dtr, rts: rts);
    widget.model.saveSoon();
  }

  Widget _controlLine(String name, bool? value, ValueChanged<bool>? change) =>
      Tooltip(
        message: !s.connected
            ? '串口未连接'
            : value == null
            ? '状态不可用，可尝试设置'
            : name,
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                tristate: true,
                onChanged: change == null
                    ? null
                    : (_) => change(!(value ?? false)),
              ),
            ),
            const SizedBox(width: 5),
            Text(name, style: const TextStyle(fontSize: 11)),
          ],
        ),
      );
  Widget _inputLine(String name, bool? value) => Row(
    children: [
      Icon(
        value == null ? Icons.remove_circle_outline : Icons.circle,
        size: 9,
        color: value == true ? green : muted,
      ),
      const SizedBox(width: 6),
      Text(
        '$name · ${value == null
            ? '不可用'
            : value
            ? '高'
            : '低'}',
        style: const TextStyle(fontSize: 10, color: muted),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => Panel(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 14, 0),
          child: Row(
            children: [
              const Icon(Icons.cable_rounded, size: 18, color: blue),
              const SizedBox(width: 9),
              const Text(
                '连接配置',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '已保存的连接配置',
                icon: const Icon(
                  Icons.bookmarks_outlined,
                  size: 17,
                  color: muted,
                ),
                onSelected: (id) {
                  if (s.parametersLocked) {
                    toast(context, '请先断开连接，再载入配置');
                    return;
                  }
                  final profile = widget.model.profiles.firstWhere(
                    (p) => p.id == id,
                  );
                  update(() {
                    s.config = profile.copy();
                  });
                },
                itemBuilder: (context) => widget.model.profiles.isEmpty
                    ? [
                        const PopupMenuItem(
                          enabled: false,
                          child: Text('尚未保存连接配置'),
                        ),
                      ]
                    : widget.model.profiles
                          .map(
                            (p) =>
                                PopupMenuItem(value: p.id, child: Text(p.name)),
                          )
                          .toList(),
              ),
            ],
          ),
        ),
        Expanded(
          child: EdgeScroll(
            builder: (context, controller) => ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(18, 0, 8, 12),
              children: [
                const SizedBox(height: 18),
                Labeled(
                  '连接类型',
                  Pick<ConnectionKind>(
                    value: c.kind,
                    options: {
                      for (final k in ConnectionKind.values) k: k.label,
                    },
                    onChanged: s.parametersLocked
                        ? null
                        : (v) => update(() {
                            if (RegExp(r'^(串口|TCP 客户端|TCP 服务端|UDP) \d+$')
                                .hasMatch(c.name)) {
                              c.name = '${v.label} ${c.name.split(' ').last}';
                            }
                            c.kind = v;
                            c.networkPort = v == ConnectionKind.udp
                                ? 9001
                                : 9000;
                          }),
                  ),
                ),
                field('会话名称', c.name, (v) {
                  c.name = v;
                  s.changed();
                }),
                if (c.kind == ConnectionKind.serial) ...[
                  Labeled(
                    '串口设备',
                    Row(
                      children: [
                        Expanded(
                          child: Pick<String>(
                            value: c.port,
                            options: {
                              '': ports.isEmpty ? '暂无串口设备' : '选择设备',
                              for (final p in ports)
                                p.path:
                                    '${p.description} · ${p.path.split('/').last}',
                              if (c.port.isNotEmpty &&
                                  !ports.any((p) => p.path == c.port))
                                c.port: c.port,
                            },
                            onChanged: s.parametersLocked
                                ? null
                                : (v) => update(() => c.port = v),
                          ),
                        ),
                        const SizedBox(width: 4),
                        iconAction(
                          Icons.refresh_rounded,
                          '刷新串口',
                          () => refresh(force: true),
                        ),
                      ],
                    ),
                  ),
                  if (c.port.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        c.port,
                        style: mono.copyWith(fontSize: 10, color: muted),
                      ),
                    ),
                  Labeled(
                    '波特率',
                    BaudRateField(
                      value: c.baud,
                      onChanged: s.parametersLocked
                          ? null
                          : (value) => update(() => c.baud = value),
                    ),
                  ),
                  pair(
                    Labeled(
                      '数据位',
                      Pick<int>(
                        value: c.dataBits,
                        options: const {
                          5: '5 bit',
                          6: '6 bit',
                          7: '7 bit',
                          8: '8 bit',
                        },
                        onChanged: s.parametersLocked
                            ? null
                            : (v) => update(() => c.dataBits = v),
                      ),
                    ),
                    Labeled(
                      '校验位',
                      Pick<String>(
                        value: c.parity,
                        options: const {
                          'None': '无 · None',
                          'Even': '偶 · Even',
                          'Odd': '奇 · Odd',
                        },
                        onChanged: s.parametersLocked
                            ? null
                            : (v) => update(() => c.parity = v),
                      ),
                    ),
                  ),
                  pair(
                    Labeled(
                      '停止位',
                      Pick<int>(
                        value: c.stopBits,
                        options: const {1: '1 bit', 2: '2 bit'},
                        onChanged: s.parametersLocked
                            ? null
                            : (v) => update(() => c.stopBits = v),
                      ),
                    ),
                    Labeled(
                      '流控制',
                      Pick<String>(
                        value: c.flowControl,
                        options: const {
                          '无': '无',
                          'RTS/CTS': 'RTS/CTS',
                          'XON/XOFF': 'XON/XOFF',
                        },
                        onChanged: s.parametersLocked
                            ? null
                            : (v) => update(() => c.flowControl = v),
                      ),
                    ),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: const Text('串口高级', style: TextStyle(fontSize: 12)),
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text('自动重连', style: TextStyle(fontSize: 12)),
                          ),
                          Switch.adaptive(
                            value: c.autoReconnect,
                            onChanged: s.parametersLocked
                                ? null
                                : (v) => update(() => c.autoReconnect = v),
                          ),
                        ],
                      ),
                      if (c.autoReconnect)
                        pair(
                          field(
                            '重连间隔 / ms',
                            '${c.reconnectIntervalMs}',
                            (v) =>
                                c.reconnectIntervalMs = int.tryParse(v) ?? 2000,
                            number: true,
                          ),
                          field(
                            '最大次数',
                            '${c.reconnectMaxAttempts}',
                            (v) =>
                                c.reconnectMaxAttempts = int.tryParse(v) ?? 10,
                            number: true,
                          ),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: _controlLine(
                              'DTR',
                              s.serialStatus.dtr,
                              s.connected && !s.controlBusy
                                  ? (v) => _setLine(dtr: v)
                                  : null,
                            ),
                          ),
                          Expanded(
                            child: _controlLine(
                              'RTS',
                              s.serialStatus.rts,
                              s.connected &&
                                      !s.controlBusy &&
                                      c.flowControl != 'RTS/CTS'
                                  ? (v) => _setLine(rts: v)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _inputLine('CTS', s.serialStatus.cts),
                          ),
                          Expanded(
                            child: _inputLine('DSR', s.serialStatus.dsr),
                          ),
                        ],
                      ),
                      if (c.flowControl == 'RTS/CTS')
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'RTS 由硬件流控管理',
                            style: TextStyle(fontSize: 10, color: muted),
                          ),
                        ),
                      if (s.controlError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            s.controlError,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.red,
                            ),
                          ),
                        ),
                    ],
                  ),
                ] else ...[
                  if (c.kind == ConnectionKind.tcpClient)
                    field('服务器地址', c.host, (v) => c.host = v, hint: 'IP 或域名')
                  else
                    field('本地绑定地址', c.bindAddress, (v) => c.bindAddress = v),
                  field(
                    c.kind == ConnectionKind.tcpClient
                        ? '服务器端口'
                        : c.kind == ConnectionKind.tcpServer
                        ? '监听端口'
                        : '本地端口',
                    '${c.networkPort}',
                    (v) => c.networkPort = int.tryParse(v) ?? 0,
                    number: true,
                  ),
                  if (c.kind == ConnectionKind.tcpClient)
                    field(
                      '连接超时 / ms',
                      '${c.timeoutMs}',
                      (v) => c.timeoutMs = int.tryParse(v) ?? 5000,
                      number: true,
                    ),
                  if (c.kind == ConnectionKind.udp) ...[
                    const Divider(height: 20),
                    field(
                      '固定目标地址',
                      c.targetHost,
                      (v) => c.targetHost = v,
                      activeEditable: !s.running,
                      hint: '填写接收方 IP',
                    ),
                    field(
                      '目标端口',
                      '${c.targetPort}',
                      (v) => c.targetPort = int.tryParse(v) ?? 0,
                      activeEditable: !s.running,
                      number: true,
                    ),
                    check('允许广播', c.broadcast, (v) {
                      if (!s.connected) update(() => c.broadcast = v);
                    }),
                    if (s.recentSource.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '最近来源 ${s.recentSource}\n固定目标不会自动变化',
                          style: const TextStyle(fontSize: 10, color: muted),
                        ),
                      ),
                  ],
                ],
                if (c.kind == ConnectionKind.tcpServer && s.connected) ...[
                  const SizedBox(height: 16),
                  Text(
                    '在线客户端 · ${s.transport!.peers.length}',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  const SizedBox(height: 8),
                  Pick(
                    value: s.selectedPeer,
                    options: {
                      '': '请选择发送目标',
                      '*': '全部客户端（主动选择）',
                      for (final peer in s.transport!.peers)
                        peer.id: peer.endpoint,
                    },
                    onChanged: (v) => update(() => s.selectedPeer = v),
                  ),
                  for (final peer in s.transport!.peers)
                    Row(
                      children: [
                        const StatusDot(true),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            peer.endpoint,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                        iconAction(
                          Icons.close_rounded,
                          '断开此客户端',
                          () => s.transport!.disconnectPeer(peer.id),
                        ),
                      ],
                    ),
                ],
                const Divider(height: 30),
                const Text(
                  '接收与显示',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: check(
                        '时间戳',
                        s.timestamps,
                        (v) => update(() => s.timestamps = v),
                      ),
                    ),
                    Expanded(
                      child: check(
                        '自动滚动',
                        s.autoScroll,
                        (v) => update(() => s.autoScroll = v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Expanded(
                      child: AbsorbPointer(
                        absorbing: recordingPending,
                        child: check('记录到文件', s.recorder.active, (v) async {
                          setState(() => recordingPending = true);
                          try {
                            if (v) {
                              await configureLogRecording(
                                context,
                                widget.model,
                                session: s,
                              );
                            } else {
                              await s.recorder.stop();
                            }
                          } catch (e) {
                            s.error = '日志记录失败：$e';
                          } finally {
                            if (mounted) {
                              setState(() => recordingPending = false);
                            }
                            s.scheduleNotify();
                          }
                        }),
                      ),
                    ),
                    iconAction(
                      Icons.folder_open_outlined,
                      '日志文件与索引搜索',
                      () => showLogArchive(context, widget.model, session: s),
                    ),
                  ],
                ),
                if (s.recorder.active || s.recorder.status.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      s.recorder.status.error.isNotEmpty
                          ? s.recorder.status.error
                          : '${s.recorder.status.files} 个文件 · ${s.recorder.status.records} 条 · 日志 ${(s.recorder.status.bytes / (1024 * 1024)).toStringAsFixed(1)} MiB',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: s.recorder.status.error.isEmpty
                            ? muted
                            : Colors.red,
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                Labeled(
                  '文本显示编码',
                  Pick(
                    value: s.draft.encoding,
                    options: const {
                      'UTF-8': 'UTF-8',
                      'ASCII': 'ASCII',
                      'UTF-16LE': 'UTF-16 LE',
                      'UTF-16BE': 'UTF-16 BE',
                    },
                    onChanged: (v) => update(() => s.draft.encoding = v),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  StatusDot(s.connected),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      s.state,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: s.connected ? green : muted,
                      ),
                    ),
                  ),
                  iconAction(
                    Icons.bookmark_add_outlined,
                    '保存连接配置',
                    _saveProfile,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              FilledButton.icon(
                onPressed: () async {
                  if (s.parametersLocked) {
                    await s.disconnect();
                  } else {
                    await s.connect();
                  }
                },
                icon: s.busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        s.connected
                            ? Icons.link_off_rounded
                            : Icons.power_settings_new_rounded,
                        size: 17,
                      ),
                label: Text(
                  s.reconnecting
                      ? '停止重连'
                      : s.busy
                      ? '取消连接'
                      : s.connected
                      ? '断开连接'
                      : c.kind == ConnectionKind.tcpServer
                      ? '开始监听'
                      : c.kind == ConnectionKind.udp
                      ? '绑定并接收'
                      : '打开连接',
                ),
              ),
              if (s.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    s.error,
                    maxLines: 3,
                    style: const TextStyle(
                      color: Color(0xFFD05A65),
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

const commonBaudRates = [
  300,
  600,
  1200,
  2400,
  4800,
  9600,
  14400,
  19200,
  38400,
  57600,
  115200,
  128000,
  230400,
  256000,
  460800,
  500000,
  921600,
  1000000,
  1500000,
  2000000,
  3000000,
];

class BaudRateField extends StatelessWidget {
  final int value;
  final ValueChanged<int>? onChanged;
  const BaudRateField({super.key, required this.value, this.onChanged});
  @override
  Widget build(BuildContext context) => Pick<int>(
    value: value,
    options: {
      for (final rate in commonBaudRates) rate: '$rate',
      if (!commonBaudRates.contains(value)) value: '$value · 自定义',
      -1: '自定义…',
    },
    onChanged: onChanged == null
        ? null
        : (rate) async {
            if (rate != -1) {
              onChanged!(rate);
              return;
            }
            final controller = TextEditingController(text: '$value');
            final form = GlobalKey<FormState>();
            final result = await showDialog<int>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('自定义波特率'),
                content: SizedBox(
                  width: 280,
                  child: Form(
                    key: form,
                    child: TextFormField(
                      key: const ValueKey('custom-baud'),
                      controller: controller,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '波特率',
                        hintText: '1–2147483647',
                      ),
                      validator: (v) {
                        final number = int.tryParse(v ?? '');
                        return number == null ||
                                number < 1 ||
                                number > 2147483647
                            ? '请输入有效的正整数'
                            : null;
                      },
                      onFieldSubmitted: (_) {
                        if (form.currentState!.validate()) {
                          Navigator.pop(context, int.parse(controller.text));
                        }
                      },
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
                      if (form.currentState!.validate()) {
                        Navigator.pop(context, int.parse(controller.text));
                      }
                    },
                    child: const Text('应用'),
                  ),
                ],
              ),
            );
            // The dialog route owns its exit animation; defer disposal until it is gone.
            Future<void>.delayed(
              const Duration(milliseconds: 300),
              controller.dispose,
            );
            if (result != null) onChanged!(result);
          },
  );
}
