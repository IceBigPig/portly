import 'package:flutter/material.dart';

import '../core/bytes.dart';
import '../core/models.dart';
import '../state/app_model.dart';
import 'theme.dart';

String _error(Object e) => e.toString().replaceFirst('FormatException: ', '');

Future<void> editCommand(
  BuildContext context,
  AppModel model, {
  SavedCommand? command,
  Draft? initial,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _CommandEditor(model: model, command: command, initial: initial),
);

/// Resolves every parameter before the caller starts any transport operation.
/// Returning null always means cancellation, including closing the dialog.
Future<Map<String, Map<String, String>>?> resolveCommandParameters(
  BuildContext context,
  List<SavedCommand> commands, {
  String action = '发送',
}) async {
  for (final command in commands) {
    command.validate();
  }
  if (commands.every((c) => c.parameters.isEmpty)) return {};
  return showDialog<Map<String, Map<String, String>>>(
    context: context,
    builder: (_) => _ParameterDialog(commands: commands, action: action),
  );
}

class _ParameterDialog extends StatefulWidget {
  final List<SavedCommand> commands;
  final String action;
  const _ParameterDialog({required this.commands, required this.action});
  @override
  State<_ParameterDialog> createState() => _ParameterDialogState();
}

class _ParameterDialogState extends State<_ParameterDialog> {
  final values = <String, Map<String, TextEditingController>>{};
  @override
  void initState() {
    super.initState();
    for (final command in widget.commands) {
      values[command.id] = {
        for (final parameter in command.parameters)
          parameter.name: TextEditingController(text: parameter.defaultValue),
      };
    }
  }

  Map<String, String> forCommand(SavedCommand command) => {
    for (final entry in values[command.id]!.entries)
      entry.key: entry.value.text,
  };

  @override
  void dispose() {
    for (final command in values.values) {
      for (final controller in command.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var valid = true;
    final sections = <Widget>[];
    for (final command in widget.commands) {
      String preview;
      String? error;
      try {
        final bytes = command.buildDraft(forCommand(command)).build();
        final rule = command.responseRule;
        if (rule != null && rule.kind != 'none') ResponseMatcher(rule, bytes);
        preview = '${hex(bytes)} · ${bytes.length} B';
      } catch (e) {
        preview = '';
        error = _error(e);
        valid = false;
      }
      sections.addAll([
        Text(command.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        for (final parameter in command.parameters)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              key: ValueKey('parameter-${command.id}-${parameter.name}'),
              controller: values[command.id]![parameter.name],
              decoration: InputDecoration(
                labelText: '${parameter.name} · ${parameter.type}',
                helperText: parameter.min != null || parameter.max != null
                    ? '${parameter.min ?? '−∞'} ～ ${parameter.max ?? '∞'}'
                    : null,
              ),
              style: mono.copyWith(fontSize: 12),
              onChanged: (_) => setState(() {}),
            ),
          ),
        SelectableText(
          error ?? preview,
          key: ValueKey('parameter-preview-${command.id}'),
          style: mono.copyWith(
            fontSize: 11,
            color: error == null ? muted : Colors.red,
          ),
        ),
        const SizedBox(height: 20),
      ]);
    }
    return AlertDialog(
      title: const Text('命令参数'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: sections,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-command-parameters'),
          onPressed: valid
              ? () => Navigator.pop(context, {
                  for (final command in widget.commands)
                    command.id: forCommand(command),
                })
              : null,
          child: Text(widget.action),
        ),
      ],
    );
  }
}

class _ParameterFields {
  final TextEditingController name, value, min, max;
  String type, order;
  _ParameterFields([CommandParameter? parameter])
    : name = TextEditingController(text: parameter?.name ?? ''),
      value = TextEditingController(text: parameter?.defaultValue ?? '0'),
      min = TextEditingController(text: parameter?.min?.toString() ?? ''),
      max = TextEditingController(text: parameter?.max?.toString() ?? ''),
      type = parameter?.type ?? 'uint16',
      order = parameter?.byteOrder ?? 'BE';
  CommandParameter build() {
    int? bound(TextEditingController controller) {
      if (controller.text.trim().isEmpty) return null;
      final result = int.tryParse(controller.text.trim());
      if (result == null) throw const FormatException('参数范围必须是整数');
      return result;
    }

    return CommandParameter(
      name: name.text.trim(),
      type: type,
      defaultValue: value.text,
      min: ['hex', 'text'].contains(type) ? null : bound(min),
      max: ['hex', 'text'].contains(type) ? null : bound(max),
      byteOrder: order,
    );
  }

  void dispose() {
    for (final controller in [name, value, min, max]) {
      controller.dispose();
    }
  }
}

class _CommandEditor extends StatefulWidget {
  final AppModel model;
  final SavedCommand? command;
  final Draft? initial;
  const _CommandEditor({required this.model, this.command, this.initial});
  @override
  State<_CommandEditor> createState() => _CommandEditorState();
}

class _CommandEditorState extends State<_CommandEditor> {
  late final Draft draft = (widget.command?.draft ?? widget.initial ?? Draft())
      .copy();
  late final name = TextEditingController(text: widget.command?.name ?? '');
  late final body = TextEditingController(text: draft.body);
  late final note = TextEditingController(text: widget.command?.note ?? '');
  late final tags = TextEditingController(
    text: widget.command?.tags.join(', ') ?? '',
  );
  late final timeout = TextEditingController(
    text: '${widget.command?.timeoutMs ?? 1000}',
  );
  late final delay = TextEditingController(
    text: '${widget.command?.stepDelayMs ?? 1000}',
  );
  late final parameters = [
    for (final parameter in widget.command?.parameters ?? <CommandParameter>[])
      _ParameterFields(parameter),
  ];
  late final originalRule = widget.command?.responseRule;
  late String ruleKind = originalRule?.kind ?? 'auto';
  late String framing = originalRule?.framing ?? 'fixed';
  late String encoding = originalRule?.encoding ?? 'UTF-8';
  late bool allowException = originalRule?.allowException ?? true;
  late final pattern = TextEditingController(
    text: originalRule?.patternHex ?? '',
  );
  late final mask = TextEditingController(text: originalRule?.maskHex ?? '');
  late final responseText = TextEditingController(
    text: originalRule?.text ?? '',
  );
  late final length = TextEditingController(
    text: originalRule == null || originalRule!.length == 0
        ? ''
        : '${originalRule!.length}',
  );
  late final delimiter = TextEditingController(
    text: originalRule?.delimiterHex ?? '0A',
  );
  late final offset = TextEditingController(
    text: '${originalRule?.offset ?? 0}',
  );
  late final unit = TextEditingController(
    text: originalRule?.unitId?.toString() ?? '',
  );
  late final function = TextEditingController(
    text: originalRule?.functionCode?.toString() ?? '',
  );
  late final registers = TextEditingController(
    text: originalRule?.registerCount?.toString() ?? '',
  );
  late String group = widget.command?.groupId ?? widget.model.groupId;
  String error = '';
  bool saving = false;
  final removedParameters = <_ParameterFields>[];
  final errorAnchor = GlobalKey();

  @override
  void dispose() {
    for (final controller in [
      name,
      body,
      note,
      tags,
      timeout,
      delay,
      pattern,
      mask,
      responseText,
      length,
      delimiter,
      offset,
      unit,
      function,
      registers,
    ]) {
      controller.dispose();
    }
    for (final parameter in [...parameters, ...removedParameters]) {
      parameter.dispose();
    }
    super.dispose();
  }

  int integer(TextEditingController controller, String label, {int? fallback}) {
    final value = controller.text.trim();
    if (value.isEmpty && fallback != null) return fallback;
    final parsed = int.tryParse(value);
    if (parsed == null) throw FormatException('$label 必须是整数');
    return parsed;
  }

  int? optional(TextEditingController controller, String label) =>
      controller.text.trim().isEmpty ? null : integer(controller, label);

  ResponseRule? responseRule() {
    if (ruleKind == 'auto') return null;
    if (ruleKind == 'none') return ResponseRule(kind: 'none');
    return ResponseRule(
      kind: ruleKind,
      framing: ruleKind == 'modbus_rtu' ? 'rtu' : framing,
      patternHex: pattern.text,
      maskHex: mask.text,
      text: responseText.text,
      encoding: encoding,
      length: ruleKind != 'modbus_rtu' && framing == 'fixed'
          ? integer(length, '帧长度')
          : 0,
      delimiterHex: delimiter.text,
      offset: integer(offset, '匹配偏移', fallback: 0),
      unitId: optional(unit, '站号'),
      functionCode: optional(function, '功能码'),
      registerCount: optional(registers, '寄存器数量'),
      allowException: allowException,
    );
  }

  SavedCommand candidate() => SavedCommand(
    id: widget.command?.id,
    name: name.text.trim(),
    groupId: group,
    draft: draft.copy()..body = body.text,
    note: note.text,
    tags: tags.text
        .split(RegExp(r'[,，]'))
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList(),
    parameters: parameters.map((v) => v.build()).toList(),
    responseRule: responseRule(),
    timeoutMs: integer(timeout, '响应超时'),
    stepDelayMs: integer(delay, '步骤延时'),
    revision: (widget.command?.revision ?? 0) + 1,
    sortOrder: widget.command?.sortOrder ?? widget.model.commands.length,
    createdAt:
        widget.command?.createdAt ?? DateTime.now().toUtc().toIso8601String(),
    updatedAt: DateTime.now().toUtc().toIso8601String(),
  );

  Future<void> save() async {
    try {
      if (widget.model.libraryImporting) throw StateError('命令库正在导入');
      if (widget.command == null && widget.model.commands.length >= 5000) {
        throw StateError('命令库最多保存 5000 条命令');
      }
      final next = candidate()..validate();
      final before = List<SavedCommand>.of(widget.model.commands);
      setState(() {
        saving = true;
        error = '';
      });
      if (widget.command == null) {
        widget.model.commands.add(next);
      } else {
        final index = widget.model.commands.indexOf(widget.command!);
        if (index < 0) throw StateError('命令已被删除');
        widget.model.commands[index] = next;
      }
      widget.model.saveSoon();
      if (!await widget.model.flushPendingSave()) {
        widget.model.commands
          ..clear()
          ..addAll(before);
        throw StateError(widget.model.storageError);
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = _error(e);
          saving = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final target = errorAnchor.currentContext;
          if (mounted && target != null) {
            Scrollable.ensureVisible(target, alignment: 1);
          }
        });
      }
    }
  }

  Widget textInput(
    String label,
    TextEditingController controller, {
    String? key,
    int lines = 1,
  }) => Labeled(
    label,
    TextField(
      key: key == null ? null : ValueKey(key),
      controller: controller,
      maxLines: lines,
      style: const TextStyle(fontSize: 12),
      onChanged: (_) => setState(() {}),
    ),
  );

  Widget pair(Widget left, Widget right) => Row(
    children: [
      Expanded(child: left),
      const SizedBox(width: 12),
      Expanded(child: right),
    ],
  );

  Widget advanced(
    String title,
    List<Widget> children, {
    bool expanded = false,
  }) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 12),
    initiallyExpanded: expanded,
    title: Text(
      title,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    shape: const Border(),
    collapsedShape: const Border(),
    children: children,
  );

  @override
  Widget build(BuildContext context) {
    String preview;
    bool previewValid;
    try {
      final resolved = SavedCommand(
        name: '预览',
        draft: draft.copy()..body = body.text,
        parameters: parameters.map((v) => v.build()).toList(),
      ).buildDraft().build();
      preview = '${hex(resolved)} · ${resolved.length} B';
      previewValid = true;
    } catch (e) {
      preview = _error(e);
      previewValid = false;
    }
    return AlertDialog(
      title: Text(widget.command == null ? '新建命令' : '编辑命令'),
      content: SizedBox(
        width: 580,
        height: (MediaQuery.sizeOf(context).height - 190)
            .clamp(180, 650)
            .toDouble(),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              textInput('名称', name, key: 'command-name'),
              Labeled(
                '分组',
                Pick(
                  value: group,
                  options: widget.model.groups,
                  onChanged: (v) => setState(() => group = v),
                ),
              ),
              Row(
                children: [
                  Segment(
                    labels: const ['HEX', '文本'],
                    value: draft.text ? 1 : 0,
                    onChanged: (v) => setState(() {
                      draft.text = v == 1;
                      if (draft.text) draft.crc = false;
                    }),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Pick<bool>(
                      value: draft.crc,
                      options: const {false: '原样发送', true: '自动 CRC-16/MODBUS'},
                      onChanged: draft.text
                          ? null
                          : (v) => setState(() => draft.crc = v),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('command-body'),
                controller: body,
                maxLines: 3,
                style: mono.copyWith(fontSize: 12),
                decoration: const InputDecoration(labelText: '命令主体'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              SelectableText(
                preview,
                key: const ValueKey('command-byte-preview'),
                style: mono.copyWith(
                  fontSize: 10,
                  color: previewValid ? muted : Colors.red,
                ),
              ),
              if (draft.text) ...[
                const SizedBox(height: 10),
                pair(
                  Labeled(
                    '编码',
                    Pick(
                      value: draft.encoding,
                      options: const {
                        'UTF-8': 'UTF-8',
                        'ASCII': 'ASCII',
                        'UTF-16LE': 'UTF-16LE',
                        'UTF-16BE': 'UTF-16BE',
                      },
                      onChanged: (v) => setState(() => draft.encoding = v),
                    ),
                  ),
                  Labeled(
                    '尾缀',
                    Pick(
                      value: draft.suffix,
                      options: {
                        '': '无',
                        '0A': 'LF',
                        '0D 0A': 'CRLF',
                        if (!['', '0A', '0D 0A'].contains(draft.suffix))
                          draft.suffix: draft.suffix,
                      },
                      onChanged: (v) => setState(() => draft.suffix = v),
                    ),
                  ),
                ),
              ],
              advanced('参数 · ${parameters.length}', [
                for (var i = 0; i < parameters.length; i++)
                  parameterEditor(parameters[i], i),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('add-command-parameter'),
                    onPressed: parameters.length >= 32
                        ? null
                        : () => setState(
                            () => parameters.add(_ParameterFields()),
                          ),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('添加参数'),
                  ),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '占位符 {{参数名}}',
                    style: TextStyle(color: muted, fontSize: 10),
                  ),
                ),
              ]),
              advanced('响应匹配', responseEditor()),
              advanced('执行设置', [
                pair(
                  textInput('响应超时 / ms', timeout),
                  textInput('步骤延时 / ms', delay),
                ),
                textInput('标签（逗号分隔）', tags, key: 'command-tags'),
                textInput('备注', note),
              ]),
              if (error.isNotEmpty)
                Padding(
                  key: errorAnchor,
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    key: const ValueKey('command-editor-error'),
                    style: const TextStyle(color: Colors.red, fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: const Text('保存命令'),
        ),
      ],
    );
  }

  Widget parameterEditor(_ParameterFields parameter, int index) => Container(
    key: ObjectKey(parameter),
    padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
    margin: const EdgeInsets.only(bottom: 8),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).dividerColor),
    ),
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: textInput(
                '名称',
                parameter.name,
                key: 'parameter-name-$index',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Labeled(
                '类型',
                Pick(
                  value: parameter.type,
                  options: {
                    for (final type in CommandParameter.allowedTypes)
                      type: type,
                  },
                  onChanged: (v) => setState(() => parameter.type = v),
                ),
              ),
            ),
            iconAction(
              Icons.close_rounded,
              '删除参数',
              () => setState(() {
                parameters.remove(parameter);
                removedParameters.add(parameter);
              }),
            ),
          ],
        ),
        pair(
          textInput('默认值', parameter.value, key: 'parameter-default-$index'),
          Labeled(
            '字节序',
            Pick<String>(
              value: parameter.order,
              options: const {'BE': '大端 BE', 'LE': '小端 LE'},
              onChanged: ['hex', 'text'].contains(parameter.type)
                  ? null
                  : (v) => setState(() => parameter.order = v),
            ),
          ),
        ),
        if (!['hex', 'text'].contains(parameter.type))
          pair(
            textInput('最小值（可选）', parameter.min),
            textInput('最大值（可选）', parameter.max),
          ),
      ],
    ),
  );

  List<Widget> responseEditor() => [
    Labeled(
      '规则',
      Pick<String>(
        value: ruleKind,
        options: const {
          'auto': '自动识别 Modbus RTU',
          'none': '不等待响应',
          'modbus_rtu': 'Modbus RTU',
          'bytes_exact': 'HEX 完全匹配',
          'bytes_prefix': 'HEX 前缀匹配',
          'bytes_masked': 'HEX 掩码匹配',
          'text_exact': '文本完全匹配',
          'text_contains': '文本包含',
        },
        onChanged: (v) => setState(() {
          ruleKind = v;
          if (framing == 'rtu') framing = 'fixed';
        }),
      ),
    ),
    if (ruleKind == 'modbus_rtu') ...[
      pair(textInput('站号（留空跟随请求）', unit), textInput('功能码（留空跟随请求）', function)),
      textInput('寄存器数量（可选）', registers),
      Align(
        alignment: Alignment.centerLeft,
        child: check(
          '识别异常响应',
          allowException,
          (v) => setState(() => allowException = v),
        ),
      ),
    ],
    if (!['auto', 'none', 'modbus_rtu'].contains(ruleKind)) ...[
      Labeled(
        '分帧',
        Pick(
          value: framing,
          options: const {
            'fixed': '固定长度',
            'delimiter': '分隔符',
            'datagram': 'UDP 数据报',
          },
          onChanged: (v) => setState(() => framing = v),
        ),
      ),
      if (framing == 'fixed')
        textInput('帧长度 / 字节', length, key: 'response-length'),
      if (framing == 'delimiter')
        textInput('分隔符 / HEX', delimiter, key: 'response-delimiter'),
      if (ruleKind.startsWith('bytes_')) ...[
        textInput('匹配字节 / HEX', pattern, key: 'response-pattern'),
        if (ruleKind == 'bytes_masked')
          textInput('掩码 / HEX', mask, key: 'response-mask'),
        textInput('帧内偏移 / 字节', offset),
      ] else ...[
        textInput('匹配文本', responseText, key: 'response-text', lines: 2),
        Labeled(
          '编码',
          Pick(
            value: encoding,
            options: const {
              'UTF-8': 'UTF-8',
              'ASCII': 'ASCII',
              'UTF-16LE': 'UTF-16LE',
              'UTF-16BE': 'UTF-16BE',
            },
            onChanged: (v) => setState(() => encoding = v),
          ),
        ),
      ],
    ],
  ];
}
