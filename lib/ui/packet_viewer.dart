import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/bytes.dart';
import '../core/models.dart';
import '../state/app_model.dart';
import '../state/session.dart';
import 'theme.dart';

String byteCharacters(Iterable<int> bytes) =>
    String.fromCharCodes(bytes.map((b) => b >= 32 && b <= 126 ? b : 0xB7));
String binaryBytes(Iterable<int> bytes) =>
    bytes.map((b) => b.toRadixString(2).padLeft(8, '0')).join(' ');

Future<void> showPacketDetails(
  BuildContext context,
  LogEntry entry, {
  Session? session,
  AppModel? model,
}) => showDialog(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text(
      '${entry.direction} · 报文详情',
      style: const TextStyle(fontSize: 17),
    ),
    content: SizedBox(
      width: 880,
      height: MediaQuery.sizeOf(ctx).height * .64,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            '${entry.time.toIso8601String()} · ${entry.endpoint} · ${entry.bytes.length} B',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: entry.bytes.isEmpty
                ? SelectableText(entry.message)
                : ByteInspector(bytes: entry.bytes),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () =>
            Clipboard.setData(ClipboardData(text: hex(entry.bytes))),
        child: const Text('复制 HEX'),
      ),
      TextButton(
        onPressed: entry.bytes.isEmpty
            ? null
            : () async {
                final result = await getSaveLocation(
                  suggestedName: 'packet.bin',
                );
                if (result != null) {
                  await XFile.fromData(
                    entry.bytes,
                    name: 'packet.bin',
                  ).saveTo(result.path);
                }
              },
        child: const Text('导出原始字节'),
      ),
      if (session != null)
        TextButton(
          onPressed: entry.bytes.isEmpty
              ? null
              : () {
                  session.draft = Draft(body: hex(entry.bytes));
                  session.commandsMode = false;
                  session.changed();
                  model?.saveSoon();
                  Navigator.pop(ctx);
                },
          child: const Text('载入发送框'),
        ),
      FilledButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('关闭'),
      ),
    ],
  ),
);

class ByteInspector extends StatefulWidget {
  final Uint8List bytes;
  const ByteInspector({super.key, required this.bytes});
  @override
  State<ByteInspector> createState() => _ByteInspectorState();
}

class _ByteInspectorState extends State<ByteInspector> {
  int? selected;
  String format = 'HEX', order = 'BE';
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          SizedBox(
            width: 100,
            child: Pick(
              value: format,
              options: const {'HEX': 'HEX', 'BIN': '二进制', 'DEC': '十进制'},
              onChanged: (v) => setState(() => format = v),
            ),
          ),
          const SizedBox(width: 12),
          const Text('ASCII', style: TextStyle(fontSize: 11, color: muted)),
          const Spacer(),
          SizedBox(
            width: 100,
            child: Pick(
              value: order,
              options: const {'BE': '大端', 'LE': '小端'},
              onChanged: (v) => setState(() => order = v),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) {
            final perRow = format == 'BIN'
                ? (box.maxWidth > 740 ? 8 : 4)
                : box.maxWidth > 650
                ? 16
                : 8;
            return EdgeScroll(
              builder: (context, controller) => ListView.builder(
                controller: controller,
                itemCount: (widget.bytes.length / perRow).ceil(),
                itemExtent: 30,
                itemBuilder: (context, row) {
                  Widget cell(int index, bool character) {
                    final isSelected = index == selected;
                    final b = index < widget.bytes.length
                        ? widget.bytes[index]
                        : null;
                    final text = b == null
                        ? ''
                        : character
                        ? byteCharacters([b])
                        : format == 'BIN'
                        ? b.toRadixString(2).padLeft(8, '0')
                        : format == 'DEC'
                        ? '$b'.padLeft(3, '0')
                        : hex([b]);
                    return Expanded(
                      child: InkWell(
                        onTap: b == null
                            ? null
                            : () => setState(() => selected = index),
                        child: Container(
                          alignment: Alignment.center,
                          height: 26,
                          decoration: BoxDecoration(
                            color: isSelected
                                ? blue.withValues(alpha: .18)
                                : null,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            text,
                            style: mono.copyWith(
                              fontSize: 11,
                              color: isSelected
                                  ? blue
                                  : b == 0
                                  ? muted
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    );
                  }

                  return Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: Text(
                          (row * perRow)
                              .toRadixString(16)
                              .padLeft(8, '0')
                              .toUpperCase(),
                          style: mono.copyWith(fontSize: 10, color: muted),
                        ),
                      ),
                      Expanded(
                        flex: format == 'BIN' ? 5 : 3,
                        child: Row(
                          children: [
                            for (var i = 0; i < perRow; i++)
                              cell(row * perRow + i, false),
                          ],
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 17,
                        margin: const EdgeInsets.symmetric(horizontal: 12),
                        color: Theme.of(context).dividerColor,
                      ),
                      Expanded(
                        flex: 2,
                        child: Row(
                          children: [
                            for (var i = 0; i < perRow; i++)
                              cell(row * perRow + i, true),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
      const SizedBox(height: 10),
      Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(10),
        ),
        child: selected == null
            ? const Text('选择字节', style: TextStyle(fontSize: 11, color: muted))
            : _interpret(),
      ),
    ],
  );
  Widget _interpret() {
    final index = selected!, b = widget.bytes[index];
    final parts = [
      '偏移 $index (0x${index.toRadixString(16).toUpperCase()})',
      'HEX ${hex([b])}',
      'BIN ${binaryBytes([b])}',
      'Uint8 $b',
      'Int8 ${b >= 128 ? b - 256 : b}',
    ];
    for (final type in ['uint16', 'int16', 'uint32', 'int32', 'float32']) {
      final size = typeSize(type);
      if (index + size <= widget.bytes.length) {
        parts.add(
          '$type ${decodeNumber(widget.bytes.sublist(index, index + size), type, order)}',
        );
      }
    }
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: parts
          .map((t) => SelectableText(t, style: mono.copyWith(fontSize: 11)))
          .toList(),
    );
  }
}
