import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:timezone/timezone.dart' as tz;

import '../core/bytes.dart';
import '../core/modbus.dart';
import '../core/models.dart';
import '../core/time_tools.dart';
import '../state/app_model.dart';
import 'theme.dart';
import 'send_panel.dart';

const toolTitles = [
  'Modbus CRC16',
  'LRC / SUM / XOR',
  '进制转换',
  'HEX / 文本',
  '字节序与数值',
  'Modbus RTU 报文',
  'NMEA 校验',
  '时间戳转换',
];
const toolIcons = [
  Icons.calculate_outlined,
  Icons.functions_rounded,
  Icons.data_array_rounded,
  Icons.text_snippet_outlined,
  Icons.swap_horiz_rounded,
  Icons.description_outlined,
  Icons.explore_outlined,
  Icons.schedule_rounded,
];

class ToolResult {
  final Map<String, String> rows;
  final List<int>? bytes;
  final String status;
  ToolResult(this.rows, {this.bytes, this.status = '计算有效'});
}

class Toolbox extends StatefulWidget {
  final AppModel model;
  const Toolbox({super.key, required this.model});
  @override
  State<Toolbox> createState() => _ToolboxState();
}

class _ToolboxState extends State<Toolbox> {
  int tool = 0, radix = 10, width = 32, mode = 0;
  bool signed = false,
      pattern = false,
      crcText = false,
      verifyCrc = false,
      customRange = false,
      verifySum = false,
      textToHex = true,
      escapes = false,
      numberEncode = true,
      modbusGenerate = true,
      response = false,
      verifyNmea = true,
      crlf = false,
      dateInput = false,
      seconds = false;
  String encoding = 'UTF-8',
      algorithm = 'LRC',
      order = 'BE',
      numberType = 'float32',
      zone = 'Asia/Shanghai',
      ambiguity = 'ask',
      nmeaStart = r'$',
      bitOp = 'NOT';
  int unit = 1,
      function = 3,
      address = 0,
      quantity = 2,
      rangeStart = 0,
      rangeLength = 6;
  String writeValues = '250,300', operand = '0', bitOutput = '', search = '';
  late final inputs = List.generate(
    8,
    (i) =>
        TextEditingController(text: widget.model.toolDrafts['input$i'] ?? ''),
  );
  AppModel get m => widget.model;
  @override
  void initState() {
    super.initState();
    final saved = m.toolDrafts['options'];
    if (saved != null) {
      try {
        final j = jsonDecode(saved);
        tool = j['tool'] ?? 0;
        radix = j['radix'] ?? 10;
        width = j['width'] ?? 32;
        signed = j['signed'] ?? false;
        pattern = j['pattern'] ?? false;
        encoding = j['encoding'] ?? 'UTF-8';
        zone = j['zone'] ?? 'Asia/Shanghai';
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    for (final c in inputs) {
      c.dispose();
    }
    super.dispose();
  }

  void update(VoidCallback action) {
    setState(action);
    m.toolDrafts['options'] = jsonEncode({
      'tool': tool,
      'radix': radix,
      'width': width,
      'signed': signed,
      'pattern': pattern,
      'encoding': encoding,
      'zone': zone,
    });
    m.saveSoon();
  }

  ToolResult calculate() {
    final input = inputs[tool].text;
    if (input.trim().isEmpty && !(tool == 5 && modbusGenerate)) {
      throw const FormatException('请输入数据');
    }
    switch (tool) {
      case 0:
        final raw = crcText ? encodeText(input, encoding) : parseHex(input);
        if (verifyCrc && raw.length < 4) {
          throw const FormatException('完整 RTU 帧至少 4 字节');
        }
        final body = verifyCrc
            ? raw.sublist(0, raw.length - 2)
            : customRange
            ? raw.sublist(rangeStart, rangeStart + rangeLength)
            : raw;
        if (body.isEmpty) throw const FormatException('计算范围不能为空');
        final crc = crc16(body),
            value = crc.toRadixString(16).padLeft(4, '0').toUpperCase();
        final frame = verifyCrc ? raw : withCrc(body);
        return ToolResult(
          {
            'CRC 数值': '0x$value',
            'CRC 发送字节（低字节在前）': hex([crc & 255, crc >> 8]),
            if (verifyCrc) '接收 CRC 字节': hex(raw.sublist(raw.length - 2)),
            if (!customRange || verifyCrc) '完整报文': hex(frame),
            '算法参数': '16 bit   /   Poly 0x8005   /   Reflected 0xA001\nInit 0xFFFF   /   RefIn & RefOut true   /   XorOut 0x0000',
          },
          bytes: customRange && !verifyCrc ? null : frame,
          status: verifyCrc
              ? validCrc(raw)
                    ? 'CRC 校验通过 · 结构需另行验证'
                    : 'CRC 校验失败 · 原始报文保留'
              : customRange
              ? '局部校验 · 不生成完整 RTU 帧'
              : '${raw.length} 字节主体 · 计算成功',
        );
      case 1:
        final raw = parseHex(input);
        if (verifySum && raw.length < 2) {
          throw const FormatException('验证需要主体和末尾一个校验字节');
        }
        final body = verifySum ? raw.sublist(0, raw.length - 1) : raw;
        final checksum = algorithm == 'LRC'
            ? lrc(body)
            : algorithm == 'SUM8'
            ? sum8(body)
            : xor8(body);
        final frame = [...body, checksum];
        return ToolResult(
          {
            '$algorithm 校验字节': hex([checksum]),
            '附加校验后的 HEX': hex(frame),
            if (algorithm == 'LRC')
              'Modbus ASCII 完整语句（显示转义）':
                  ':${hex(frame).replaceAll(' ', '')}\\r\\n',
            '算法定义': algorithm == 'LRC'
                ? '所有字节和的 8 位二进制补码'
                : algorithm == 'SUM8'
                ? '初值 0 · 所有字节之和 mod 256'
                : '初值 0 · 逐字节异或',
          },
          bytes: verifySum ? raw : frame,
          status: verifySum
              ? raw.last == checksum
                    ? '校验通过'
                    : '校验失败，应为 ${hex([checksum])}'
              : '计算成功',
        );
      case 2:
        final r = convertRadix(
          input,
          radix: radix,
          width: width,
          signed: signed,
          bitPattern: pattern,
        );
        return ToolResult(
          {
            'BIN · 二进制数值': r.value.toRadixString(2),
            'OCT · 八进制数值': r.value.toRadixString(8),
            'DEC · 十进制数值': '${r.value}',
            'HEX · 十六进制数值': r.value.toRadixString(16).toUpperCase(),
            '固定 $width 位补码 · BIN': r.pattern(2),
            '固定 $width 位模式 · OCT / HEX': '${r.pattern(8)}\n${r.pattern(16)}',
            '有符号 / 无符号解释': '${r.signed}   /   ${r.bits}',
            '大端 · Big Endian': hex(r.be),
            '小端 · Little Endian': hex(r.be.reversed),
          },
          bytes: order == 'LE' ? r.be.reversed.toList() : r.be,
          status:
              '有效 · ${signed ? 'Int' : 'Uint'}$width · ${pattern ? '位模式输入' : '数学数值输入'}',
        );
      case 3:
        var text = input;
        if (textToHex && escapes) {
          text = text
              .replaceAll(r'\r', '\r')
              .replaceAll(r'\n', '\n')
              .replaceAll(r'\t', '\t')
              .replaceAll(r'\0', '\x00');
        }
        final data = textToHex ? encodeText(text, encoding) : parseHex(input);
        final decoded = decodeText(data, encoding);
        return ToolResult({
          'HEX 原始字节': hex(data),
          '文本（严格解码）': decoded,
          '不可见字符可视化': decoded
              .replaceAll('\r', r'\r')
              .replaceAll('\n', r'\n')
              .replaceAll('\t', r'\t')
              .replaceAll('\x00', r'\0'),
          '编码 / 长度': '$encoding · ${data.length} 字节 · 不自动添加 BOM',
        }, bytes: data);
      case 4:
        final data = numberEncode
            ? encodeNumber(input, numberType, order)
            : parseHex(input);
        final value = decodeNumber(data, numberType, order);
        return ToolResult(
          {
            '解析数值（实际读回值）': value,
            '线上字节': hex(data),
            '大端参考字节': hex(reorder(data, order)),
            '类型 / 长度': '$numberType · ${data.length} 字节',
            '字节排列': orderLabel(order, data.length),
          },
          bytes: data,
          status:
              '有效 · ${numberType.startsWith('float') ? 'IEEE 754 · 保留实际舍入值' : 'BigInt 精确整数'}',
        );
      case 5:
        final data = modbusGenerate
            ? modbusRequest(
                unit,
                function,
                address,
                quantity,
                values: function >= 15
                    ? writeValues
                          .split(RegExp(r'[,，\s]+'))
                          .where((e) => e.isNotEmpty)
                          .map(int.parse)
                          .toList()
                    : null,
              )
            : parseHex(input);
        return ToolResult(
          {
            '完整 RTU 帧': hex(data),
            ...parseRtu(data, response: !modbusGenerate && response),
          },
          bytes: data,
          status: modbusGenerate && unit == 0 ? '广播写请求 · 不等待响应' : 'CRC 与结构有效',
        );
      case 6:
        final lines = input
            .split(RegExp(r'\r?\n'))
            .where((line) => line.trim().isNotEmpty)
            .map(
              (line) =>
                  nmea(line, verify: verifyNmea, start: nmeaStart, crlf: crlf),
            )
            .toList();
        final output = lines.map((l) => l.output).join(crlf ? '' : '\r\n');
        return ToolResult(
          {
            for (var i = 0; i < lines.length; i++)
              '第 ${i + 1} 行 · ${lines[i].status}': lines[i].output
                  .replaceAll('\r', r'\r')
                  .replaceAll('\n', r'\n'),
          },
          bytes: encodeText(output, 'ASCII'),
          status:
              '${lines.length} 行 · ${lines.every((l) => !l.status.contains('失败') && !l.status.contains('缺少')) ? '校验有效' : '含未通过校验的语句'}',
        );
      default:
        final utc = dateInput
            ? parseZonedDate(input, zone, ambiguity: ambiguity)
            : DateTime.fromMillisecondsSinceEpoch(
                parseTimestamp(input, seconds),
                isUtc: true,
              );
        final ms = utc.millisecondsSinceEpoch;
        final abs = ms.abs(),
            exact =
                '${ms < 0 ? '-' : ''}${abs ~/ 1000}.${(abs % 1000).toString().padLeft(3, '0')}';
        return ToolResult({
          '$zone 日期时间': zonedDisplay(utc, zone),
          'UTC · ISO 8601': utc.toIso8601String(),
          'Unix 整数秒 · 向负无穷取整': '${floorSeconds(ms)}',
          'Unix 毫秒': '$ms',
          '精确秒': exact,
        }, status: '毫秒精度 · IANA 时区规则');
    }
  }

  String orderLabel(String value, int size) => size == 8
      ? {
          'BE': 'ABCDEFGH',
          'LE': 'HGFEDCBA',
          'SWAP_BYTES': 'BADCFEHG',
          'SWAP_WORDS': 'GHEFCDAB',
        }[value]!
      : size == 2
      ? value == 'BE' || value == 'SWAP_WORDS'
            ? 'AB'
            : 'BA'
      : {
          'BE': 'ABCD',
          'LE': 'DCBA',
          'SWAP_BYTES': 'BADC',
          'SWAP_WORDS': 'CDAB',
        }[value]!;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      ToolResult? result;
      String error = '';
      try {
        result = calculate();
      } catch (e) {
        error = e is RangeError
            ? '计算范围或字段长度越界，请检查输入'
            : e.toString().replaceFirst('FormatException: ', '');
      }
      final narrow = box.maxWidth < 1000;
      return Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!narrow) ...[
              SizedBox(width: 216, child: _navigation()),
              const SizedBox(width: 26),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (narrow)
                              SizedBox(
                                width: 235,
                                child: Pick(
                                  value: tool,
                                  options: {
                                    for (var i = 0; i < 8; i++)
                                      i: toolTitles[i],
                                  },
                                  onChanged: (v) => update(() => tool = v),
                                ),
                              )
                            else ...[
                              Text(
                                tool == 0
                                    ? 'Modbus RTU · CRC16 校验'
                                    : toolTitles[tool],
                                style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 208,
                        child: Pick(
                          value: m.currentId,
                          options: {
                            for (final s in m.sessions)
                              s.id:
                                  '${s.connected ? '●' : '○'}  ${s.config.name}',
                          },
                          onChanged: m.selectSession,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 23),
                  Expanded(
                    child: EdgeScroll(
                      builder: (context, controller) => ListView(
                        controller: controller,
                        children: [
                          Panel(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      '输入数据',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const Spacer(),
                                    iconAction(
                                      Icons.content_paste_rounded,
                                      '粘贴',
                                      () async {
                                        final data = await Clipboard.getData(
                                          'text/plain',
                                        );
                                        if (data != null) {
                                          update(() {
                                            inputs[tool].text = data.text ?? '';
                                          });
                                        }
                                      },
                                    ),
                                    iconAction(
                                      Icons.backspace_outlined,
                                      '清空',
                                      () => update(() => inputs[tool].clear()),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 14),
                                _options(),
                                if (tool != 5 || !modbusGenerate) ...[
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: inputs[tool],
                                    maxLines: tool == 2 || tool == 7 ? 1 : 3,
                                    style: mono.copyWith(
                                      fontSize: tool == 2 ? 24 : 14,
                                      height: 1.7,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: tool == 7 && dateInput
                                          ? '2026-10-25T00:00:00Z'
                                          : '请输入内容…',
                                    ),
                                    onChanged: (v) {
                                      update(() {});
                                      m.toolDrafts['input$tool'] = v;
                                    },
                                  ),
                                  const SizedBox(height: 9),
                                  Text(
                                    _inputHint(),
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: muted,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (result != null) ...[
                            Panel(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Text(
                                        '转换结果',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                        ),
                                      ),
                                      const Spacer(),
                                      const Icon(
                                        Icons.check_circle_rounded,
                                        color: green,
                                        size: 14,
                                      ),
                                      const SizedBox(width: 7),
                                      Flexible(
                                        child: Text(
                                          result.status,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: green,
                                            fontSize: 11,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 15),
                                  for (final entry in result.rows.entries)
                                    _resultRow(entry.key, entry.value),
                                  if (result.bytes != null) ...[
                                    const SizedBox(height: 15),
                                    Wrap(
                                      spacing: 10,
                                      runSpacing: 10,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        FilledButton.icon(
                                          onPressed: () {
                                            Clipboard.setData(
                                              ClipboardData(
                                                text: hex(result!.bytes!),
                                              ),
                                            );
                                            toast(context, '最终 HEX 字节已复制');
                                          },
                                          icon: const Icon(
                                            Icons.copy_rounded,
                                            size: 15,
                                          ),
                                          label: const Text('复制 HEX'),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: () =>
                                              _load(result!.bytes!),
                                          icon: const Icon(
                                            Icons.input_rounded,
                                            size: 16,
                                          ),
                                          label: const Text('载入发送框'),
                                        ),
                                        OutlinedButton.icon(
                                          onPressed: () => editCommand(
                                            context,
                                            m,
                                            initial: Draft(
                                              body: hex(result!.bytes!),
                                            ),
                                          ),
                                          icon: const Icon(
                                            Icons.bookmark_add_outlined,
                                            size: 16,
                                          ),
                                          label: const Text('保存为命令'),
                                        ),
                                        Text(
                                          '${result.bytes!.length} B · 载入后需在调试台确认发送',
                                          style: const TextStyle(
                                            color: muted,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (tool == 2) ...[
                              const SizedBox(height: 14),
                              _bitViewer(),
                            ],
                          ] else
                            Panel(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    color: inputs[tool].text.isEmpty
                                        ? muted
                                        : const Color(0xFFD05A65),
                                    size: 20,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      error,
                                      style: const TextStyle(
                                        color: muted,
                                        height: 1.7,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  Widget _navigation() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 4),
      const Text(
        '工具箱',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),

      const SizedBox(height: 20),
      TextField(
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search_rounded, size: 17),
          hintText: '查找工具',
        ),
        onChanged: (v) => setState(() => search = v),
      ),
      const SizedBox(height: 22),
      Expanded(
        child: EdgeScroll(
          builder: (context, controller) => ListView(
            controller: controller,
            children: [
              for (final category in {
                '校验工具': [0, 1, 6],
                '数据转换': [2, 3, 4],
                '报文工具': [5],
                '时间工具': [7],
              }.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 0, 9),
                  child: Text(
                    category.key,
                    style: const TextStyle(color: muted, fontSize: 10),
                  ),
                ),
                for (final i in category.value.where(
                  (i) => toolTitles[i].toLowerCase().contains(
                    search.toLowerCase(),
                  ),
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: InkWell(
                      onTap: () => update(() => tool = i),
                      borderRadius: BorderRadius.circular(12),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 13,
                        ),
                        decoration: BoxDecoration(
                          color: tool == i
                              ? blue.withValues(alpha: .09)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              toolIcons[i],
                              size: 19,
                              color: tool == i ? accent(context) : muted,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                toolTitles[i],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: tool == i ? accent(context) : null,
                                  fontWeight: tool == i
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (tool == i)
                              const Icon(
                                Icons.chevron_right_rounded,
                                size: 15,
                                color: blue,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 19),
              ],
            ],
          ),
        ),
      ),
    ],
  );
  Widget _resultRow(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(vertical: 13),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, color: muted, height: 1.7),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '（空文本）' : value,
            style: mono.copyWith(
              fontSize: label.startsWith('CRC 数值') ? 30 : 13,
              color: label.startsWith('CRC 数值') ? accent(context) : null,
              fontWeight: label.startsWith('CRC 数值')
                  ? FontWeight.w700
                  : FontWeight.w400,
              height: 1.7,
            ),
          ),
        ),
        const SizedBox(width: 14),
        iconAction(Icons.copy_rounded, '复制此结果', () {
          Clipboard.setData(ClipboardData(text: value));
          toast(context, '已复制');
        }),
      ],
    ),
  );
  Widget pick<T>(
    T value,
    Map<T, String> options,
    ValueChanged<T> action, {
    double size = 170,
  }) => SizedBox(
    width: size,
    child: Pick(
      value: value,
      options: options,
      onChanged: (v) => update(() => action(v)),
    ),
  );
  Widget numeric(String label, int value, ValueChanged<int> action) => SizedBox(
    width: 140,
    child: Labeled(
      label,
      TextFormField(
        key: ValueKey('$tool-$label'),
        initialValue: '$value',
        style: mono.copyWith(fontSize: 12),
        onChanged: (v) => update(() => action(int.tryParse(v) ?? -1)),
      ),
    ),
  );
  Widget _options() {
    switch (tool) {
      case 0:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segment(
              labels: const ['计算 CRC', '校验 RTU 帧'],
              value: verifyCrc ? 1 : 0,
              onChanged: (v) => update(() => verifyCrc = v == 1),
            ),
            Segment(
              labels: const ['HEX', '文本'],
              value: crcText ? 1 : 0,
              onChanged: (v) => update(() => crcText = v == 1),
            ),
            if (crcText)
              pick(encoding, const {
                'UTF-8': 'UTF-8',
                'ASCII': 'ASCII',
              }, (v) => encoding = v),
            if (!verifyCrc)
              check('自定义范围', customRange, (v) => update(() => customRange = v)),
            if (customRange && !verifyCrc) ...[
              numeric('起始偏移（0 起始）', rangeStart, (v) => rangeStart = v),
              numeric('字节数', rangeLength, (v) => rangeLength = v),
            ],
          ],
        );
      case 1:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            pick(algorithm, const {
              'LRC': 'Modbus ASCII LRC',
              'SUM8': 'SUM8',
              'XOR8': 'XOR8',
            }, (v) => algorithm = v),
            Segment(
              labels: const ['计算', '验证末尾校验'],
              value: verifySum ? 1 : 0,
              onChanged: (v) => update(() => verifySum = v == 1),
            ),
          ],
        );
      case 2:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            pick(radix, const {
              2: '二进制 BIN',
              8: '八进制 OCT',
              10: '十进制 DEC',
              16: '十六进制 HEX',
            }, (v) => radix = v),
            Segment(
              labels: const ['无符号', '有符号'],
              value: signed ? 1 : 0,
              onChanged: (v) => update(() => signed = v == 1),
            ),
            pick(
              width,
              const {32: '32 bit', 64: '64 bit'},
              (v) => width = v,
              size: 110,
            ),
            pick(pattern, const {
              false: '输入：数学数值',
              true: '输入：位模式',
            }, (v) => pattern = v),
            pick(order, const {
              'BE': '载入：大端 BE',
              'LE': '载入：小端 LE',
            }, (v) => order = v),
          ],
        );
      case 3:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segment(
              labels: const ['文本 → HEX', 'HEX → 文本'],
              value: textToHex ? 0 : 1,
              onChanged: (v) => update(() => textToHex = v == 0),
            ),
            pick(encoding, const {
              'UTF-8': 'UTF-8',
              'ASCII': 'ASCII',
              'UTF-16LE': 'UTF-16 LE',
              'UTF-16BE': 'UTF-16 BE',
            }, (v) => encoding = v),
            if (textToHex)
              check('解析转义字符', escapes, (v) => update(() => escapes = v)),
          ],
        );
      case 4:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            Segment(
              labels: const ['数值 → 字节', '字节 → 数值'],
              value: numberEncode ? 0 : 1,
              onChanged: (v) => update(() => numberEncode = v == 0),
            ),
            pick(
              numberType,
              {
                for (final t in [
                  'int16',
                  'uint16',
                  'int32',
                  'uint32',
                  'int64',
                  'uint64',
                  'float32',
                  'float64',
                ])
                  t: t,
              },
              (v) => numberType = v,
              size: 135,
            ),
            pick(
              order,
              {
                for (final v in ['BE', 'SWAP_WORDS', 'SWAP_BYTES', 'LE'])
                  v: orderLabel(v, typeSize(numberType)),
              },
              (v) => order = v,
              size: 150,
            ),
          ],
        );
      case 5:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Segment(
              labels: const ['生成请求', '解析报文'],
              value: modbusGenerate ? 0 : 1,
              onChanged: (v) => update(() => modbusGenerate = v == 0),
            ),
            const SizedBox(height: 16),
            if (modbusGenerate) ...[
              Wrap(
                spacing: 14,
                runSpacing: 5,
                children: [
                  numeric('站址（0–247）', unit, (v) => unit = v),
                  SizedBox(
                    width: 230,
                    child: Labeled(
                      '功能码',
                      Pick(
                        value: function,
                        options: const {
                          1: '01 · 读线圈',
                          2: '02 · 读离散输入',
                          3: '03 · 读保持寄存器',
                          4: '04 · 读输入寄存器',
                          5: '05 · 写单线圈',
                          6: '06 · 写单寄存器',
                          15: '0F · 写多线圈',
                          16: '10 · 写多寄存器',
                        },
                        onChanged: (v) => update(() => function = v),
                      ),
                    ),
                  ),
                  numeric('PDU 地址（0 起始）', address, (v) => address = v),
                  numeric(
                    function == 5 || function == 6 ? '写入值（十进制）' : '数量',
                    quantity,
                    (v) => quantity = v,
                  ),
                ],
              ),
              if (function >= 15)
                TextFormField(
                  initialValue: writeValues,
                  decoration: const InputDecoration(
                    hintText: '写入值，以逗号分隔，线圈填 0 或 1',
                  ),
                  onChanged: (v) => update(() => writeValues = v),
                ),
            ] else
              pick(response, const {
                false: '角色：请求',
                true: '角色：响应',
              }, (v) => response = v),
          ],
        );
      case 6:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segment(
              labels: const ['生成校验', '验证语句'],
              value: verifyNmea ? 1 : 0,
              onChanged: (v) => update(() => verifyNmea = v == 1),
            ),
            pick(
              nmeaStart,
              const {r'$': r'起始符 $', '!': '起始符 !'},
              (v) => nmeaStart = v,
              size: 120,
            ),
            check('追加 CRLF', crlf, (v) => update(() => crlf = v)),
          ],
        );
      default:
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Segment(
              labels: const ['Unix 时间戳', '日期时间'],
              value: dateInput ? 1 : 0,
              onChanged: (v) => update(() => dateInput = v == 1),
            ),
            if (!dateInput)
              pick(
                seconds,
                const {false: '单位：毫秒', true: '单位：秒'},
                (v) => seconds = v,
                size: 120,
              ),
            SizedBox(
              width: 215,
              child: Autocomplete<String>(
                initialValue: TextEditingValue(text: zone),
                optionsBuilder: (v) => tz.timeZoneDatabase.locations.keys
                    .where(
                      (z) => z.toLowerCase().contains(v.text.toLowerCase()),
                    )
                    .take(30),
                onSelected: (v) => update(() => zone = v),
                fieldViewBuilder: (_, controller, focus, _) => TextField(
                  controller: controller,
                  focusNode: focus,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(labelText: 'IANA 时区'),
                  onSubmitted: (v) => update(() => zone = v),
                ),
              ),
            ),
            if (dateInput)
              pick(ambiguity, const {
                'ask': 'DST 歧义：提示',
                'earlier': 'DST：较早时刻',
                'later': 'DST：较晚时刻',
              }, (v) => ambiguity = v),
            OutlinedButton(
              onPressed: () => update(
                () => inputs[tool].text = dateInput
                    ? DateTime.now().toUtc().toIso8601String()
                    : '${seconds ? floorSeconds(DateTime.now().millisecondsSinceEpoch) : DateTime.now().millisecondsSinceEpoch}',
              ),
              child: const Text('当前时间'),
            ),
          ],
        );
    }
  }

  String _inputHint() => tool == 2
      ? 'BigInt 精确计算 · 不经过浮点数 · 输入溢出时拒绝转换'
      : tool == 7
      ? dateInput
            ? '含 UTC offset 的日期先确定唯一时刻；未写 offset 时使用所选时区'
            : '秒最多支持三位小数；毫秒为整数；负数秒输出采用 floor'
      : 'HEX 接受连续偶数位、空白分隔字节及逐字节 0x 前缀；不自动补零';
  Widget _bitViewer() {
    final r = convertRadix(
      inputs[2].text,
      radix: radix,
      width: width,
      signed: signed,
      bitPattern: pattern,
    );
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('位查看器与运算', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 15),
          Wrap(
            spacing: 3,
            runSpacing: 6,
            children: List.generate(width, (i) {
              final index = width - i - 1,
                  enabled = r.bits & (BigInt.one << index) != BigInt.zero;
              return Tooltip(
                message: 'Bit $index',
                child: Container(
                  width: 22,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: enabled
                        ? blue.withValues(alpha: .12)
                        : Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    enabled ? '1' : '0',
                    textAlign: TextAlign.center,
                    style: mono.copyWith(
                      fontSize: 10,
                      color: enabled ? blue : muted,
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 17),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              pick(
                bitOp,
                const {
                  'NOT': 'NOT',
                  'AND': 'AND',
                  'OR': 'OR',
                  'XOR': 'XOR',
                  'SHL': '左移',
                  'SHR': '逻辑右移',
                  'SAR': '算术右移',
                },
                (v) => bitOp = v,
                size: 140,
              ),
              SizedBox(
                width: 180,
                child: TextFormField(
                  initialValue: operand,
                  decoration: const InputDecoration(
                    hintText: 'HEX 操作数 / 十进制移位量',
                  ),
                  onChanged: (v) => operand = v,
                ),
              ),
              OutlinedButton(
                onPressed: () {
                  try {
                    final mask = (BigInt.one << width) - BigInt.one;
                    BigInt output;
                    if (['SHL', 'SHR', 'SAR'].contains(bitOp)) {
                      final shift = int.parse(operand);
                      if (shift < 0 || shift >= width) {
                        throw const FormatException('移位量超出位宽');
                      }
                      if (bitOp == 'SAR' && !signed) {
                        throw const FormatException('算术右移需要有符号解释');
                      }
                      output = bitOp == 'SHL'
                          ? (r.bits << shift) & mask
                          : bitOp == 'SAR'
                          ? (r.signed >> shift).toUnsigned(width)
                          : r.bits >> shift;
                    } else {
                      final rhs = bitOp == 'NOT'
                          ? BigInt.zero
                          : convertRadix(
                              operand,
                              radix: 16,
                              width: width,
                              bitPattern: true,
                            ).bits;
                      output = bitOp == 'NOT'
                          ? r.bits ^ mask
                          : bitOp == 'AND'
                          ? r.bits & rhs
                          : bitOp == 'OR'
                          ? r.bits | rhs
                          : r.bits ^ rhs;
                    }
                    update(
                      () => bitOutput = output
                          .toRadixString(16)
                          .toUpperCase()
                          .padLeft(width ~/ 4, '0'),
                    );
                  } catch (e) {
                    toast(context, '$e');
                  }
                },
                child: const Text('计算'),
              ),
              if (bitOutput.isNotEmpty)
                TextButton(
                  onPressed: () => update(() {
                    inputs[2].text = bitOutput;
                    radix = 16;
                    pattern = true;
                  }),
                  child: Text('应用 $bitOutput'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _load(List<int> bytes) async {
    final s = m.current;
    if (s.draft.body.isNotEmpty) {
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('载入发送框', style: TextStyle(fontSize: 18)),
          content: Text('目标会话：${s.config.name}\n已有发送草稿，选择如何载入。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'append'),
              child: const Text('追加实际字节'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'replace'),
              child: const Text('替换草稿'),
            ),
          ],
        ),
      );
      if (action == null) return;
      if (action == 'append') {
        try {
          bytes = [...s.draft.build(), ...bytes];
        } catch (e) {
          if (mounted) toast(context, '现有草稿无效，无法追加：$e');
          return;
        }
      }
    }
    s.draft = Draft(body: hex(bytes));
    s.commandsMode = false;
    s.changed();
    m.page = 0;
    m.changed();
    if (mounted) toast(context, '已载入 ${s.config.name}');
  }
}
