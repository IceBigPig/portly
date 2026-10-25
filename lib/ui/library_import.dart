import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/library_import.dart';
import 'theme.dart';

Future<LibraryImportPlan?> showLibraryImportPreview(
  BuildContext context,
  LibraryImportPreview preview,
) => showDialog<LibraryImportPlan>(
  context: context,
  builder: (_) => _ImportDialog(preview: preview),
);

String _choiceLabel(ImportChoice choice) => switch (choice) {
  ImportChoice.keep => '保留现有 / 跳过',
  ImportChoice.copy => '生成新副本',
  ImportChoice.overwrite => '覆盖现有',
};

class _ImportDialog extends StatefulWidget {
  final LibraryImportPreview preview;
  const _ImportDialog({required this.preview});
  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final choices = <String, ImportChoice>{};
  final filter = TextEditingController();
  String search = '', error = '';
  LibraryImportPreview get preview => widget.preview;
  @override
  void dispose() {
    filter.dispose();
    super.dispose();
  }

  void _apply(ImportChoice choice) => setState(() {
    for (final conflict in preview.conflicts) {
      choices[conflict.key] = choice;
    }
    error = '';
  });

  void _finish() {
    try {
      final plan = preview.buildPlan(choices: choices);
      Navigator.of(context).pop(plan);
    } catch (e) {
      setState(() => error = e is FormatException ? e.message : '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final conflicts = preview.conflicts
        .where(
          (item) =>
              search.isEmpty ||
              '${item.incomingName} ${item.existingName} ${item.id}'
                  .toLowerCase()
                  .contains(search),
        )
        .toList();
    final overwrite = choices.values
        .where((v) => v == ImportChoice.overwrite)
        .length;
    final copies = choices.values.where((v) => v == ImportChoice.copy).length;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: SizedBox(
        width: math.min(920, size.width - 40),
        height: math.min(680, size.height - 40),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '导入预览',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                preview.valid
                    ? '${preview.groupCount} 个分组 · ${preview.commandCount} 条命令 · ${preview.conflicts.length} 项 UUID 冲突'
                    : '${preview.issues.length} 项无效数据 · 未导入',
                style: const TextStyle(color: muted),
              ),
              const SizedBox(height: 16),
              if (!preview.valid)
                Expanded(child: _issues())
              else if (preview.conflicts.isEmpty)
                const Expanded(child: Center(child: Text('没有 UUID 冲突')))
              else ...[
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: math.min(300, constraints.maxWidth),
                        child: TextField(
                          controller: filter,
                          decoration: const InputDecoration(
                            hintText: '搜索名称或 UUID',
                            prefixIcon: Icon(Icons.search_rounded, size: 18),
                          ),
                          onChanged: (value) => setState(
                            () => search = value.trim().toLowerCase(),
                          ),
                        ),
                      ),
                      PopupMenuButton<ImportChoice>(
                        tooltip: '全部冲突处理',
                        onSelected: _apply,
                        itemBuilder: (_) => [
                          for (final choice in ImportChoice.values)
                            PopupMenuItem(
                              value: choice,
                              child: Text(_choiceLabel(choice)),
                            ),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('全部冲突处理'),
                              Icon(Icons.expand_more_rounded, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  color: Theme.of(context).scaffoldBackgroundColor,
                  child: const Row(
                    children: [
                      SizedBox(
                        width: 54,
                        child: Text('类型', style: TextStyle(color: muted)),
                      ),
                      Expanded(
                        child: Text(
                          '文件记录 / 现有记录',
                          style: TextStyle(color: muted),
                        ),
                      ),
                      SizedBox(
                        width: 154,
                        child: Text('处理方式', style: TextStyle(color: muted)),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: conflicts.length,
                    itemExtent: 76,
                    itemBuilder: (context, index) {
                      final item = conflicts[index];
                      return Container(
                        key: ValueKey('conflict:${item.key}'),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 54,
                              child: Text(item.group ? '分组' : '命令'),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${item.incomingName} / ${item.existingName}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      item.id,
                                      maxLines: 1,
                                      style: mono.copyWith(
                                        fontSize: 10,
                                        color: muted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 154,
                              child: DropdownButtonFormField<ImportChoice>(
                                key: ValueKey(
                                  '${item.key}:${choices[item.key]}',
                                ),
                                initialValue:
                                    choices[item.key] ?? ImportChoice.keep,
                                isExpanded: true,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface,
                                ),
                                items: [
                                  for (final choice in ImportChoice.values)
                                    DropdownMenuItem(
                                      value: choice,
                                      child: Text(
                                        _choiceLabel(choice),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (choice) => setState(() {
                                  choices[item.key] = choice!;
                                  error = '';
                                }),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    maxLines: 2,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      !preview.valid
                          ? '修正后重新导入'
                          : overwrite > 0
                          ? '$overwrite 项覆盖 · $copies 项副本 · 覆盖前备份'
                          : copies > 0
                          ? '$copies 项副本'
                          : 'UUID 冲突默认保留现有项',
                      maxLines: 2,
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: preview.valid ? _finish : null,
                    child: const Text('导入'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _issues() => ListView.builder(
    itemCount: preview.issues.length,
    itemExtent: 70,
    itemBuilder: (context, index) {
      final item = preview.issues[index];
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 132,
              child: Text(item.location, style: mono.copyWith(fontSize: 11)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SelectableText(
                item.reason,
                maxLines: 2,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Future<LibraryExportScope?> chooseLibraryExportScope(
  BuildContext context, {
  required String currentGroup,
  required int selectedCount,
}) => showDialog<LibraryExportScope>(
  context: context,
  builder: (context) => SimpleDialog(
    title: const Text('导出命令库'),
    children: [
      SimpleDialogOption(
        onPressed: () =>
            Navigator.pop(context, LibraryExportScope.currentGroup),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('当前分组 · $currentGroup'),
        ),
      ),
      SimpleDialogOption(
        onPressed: selectedCount > 0
            ? () => Navigator.pop(context, LibraryExportScope.selected)
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            '选中命令 · $selectedCount',
            style: selectedCount > 0 ? null : const TextStyle(color: muted),
          ),
        ),
      ),
      SimpleDialogOption(
        onPressed: () => Navigator.pop(context, LibraryExportScope.all),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('全部命令库'),
        ),
      ),
    ],
  ),
);
