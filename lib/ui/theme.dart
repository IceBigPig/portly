import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const blue = Color(0xFF3269F6);
const green = Color(0xFF18A77D);
const muted = Color(0xFF8692A8);
const ink = Color(0xFF202D45);
const mono = TextStyle(
  fontFamily: 'JetBrainsMono',
  fontFamilyFallback: ['Menlo', 'Consolas'],
  letterSpacing: .2,
);

Color accent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF93B8FF)
    : blue;

ThemeData appTheme(bool dark) {
  final scheme = ColorScheme.fromSeed(
    seedColor: blue,
    primary: dark ? const Color(0xFF93B8FF) : blue,
    secondary: dark ? const Color(0xFF93B8FF) : blue,
    brightness: dark ? Brightness.dark : Brightness.light,
    surface: dark ? const Color(0xFF1C2434) : Colors.white,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(
      color: dark ? const Color(0xFF344159) : const Color(0xFFE3E8F2),
    ),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xFF141B28)
        : const Color(0xFFF4F6FB),
    fontFamily: 'PingFang SC',
    fontFamilyFallback: const ['Microsoft YaHei', 'Noto Sans CJK SC'],
    textTheme: TextTheme(
      bodyMedium: TextStyle(
        fontSize: 13,
        color: dark ? const Color(0xFFE6ECF8) : ink,
      ),
      bodySmall: const TextStyle(fontSize: 11, color: muted),
      titleMedium: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: dark ? Colors.white : ink,
      ),
    ),
    dividerColor: dark ? const Color(0xFF303D52) : const Color(0xFFEDF0F6),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF202B3D) : const Color(0xFFFAFBFE),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: blue, width: 1.5),
      ),
      hintStyle: const TextStyle(color: muted, fontSize: 12),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: blue,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: dark ? Colors.white70 : ink,
        side: BorderSide(
          color: dark ? const Color(0xFF3D4A60) : const Color(0xFFE0E6F1),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: blue,
        textStyle: const TextStyle(fontSize: 12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: muted,
        iconSize: 18,
        minimumSize: const Size(32, 32),
        maximumSize: const Size(36, 36),
        padding: const EdgeInsets.all(6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: const BorderSide(color: Color(0xFFB8C3D7), width: 1.3),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 500),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(7),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ink,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      backgroundColor: scheme.surface,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(fontSize: 12, color: scheme.onSurface),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => (dark ? const Color(0xFF71819C) : const Color(0xFFA7B3C8))
            .withValues(alpha: states.contains(WidgetState.dragged) ? .9 : .55),
      ),
      trackVisibility: const WidgetStatePropertyAll(false),
      crossAxisMargin: 3,
      mainAxisMargin: 6,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(5)),
        elevation: const WidgetStatePropertyAll(6),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: dark ? const Color(0xFF344159) : const Color(0xFFE3E8F2),
            ),
          ),
        ),
      ),
    ),
    splashFactory: NoSplash.splashFactory,
  );
}

class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.color,
  });
  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: Theme.of(context).dividerColor),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class Segment extends StatelessWidget {
  final List<String> labels;
  final int value;
  final ValueChanged<int> onChanged;
  const Segment({
    super.key,
    required this.labels,
    required this.value,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: BorderRadius.circular(11),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        labels.length,
        (i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 8),
              decoration: BoxDecoration(
                color: value == i
                    ? Theme.of(context).colorScheme.surface
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                boxShadow: value == i
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: .04),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : [],
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  fontSize: 12,
                  color: value == i ? accent(context) : muted,
                  fontWeight: value == i ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class Pick<T> extends StatefulWidget {
  final T value;
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;
  const Pick({
    super.key,
    required this.value,
    required this.options,
    this.onChanged,
  });
  @override
  State<Pick<T>> createState() => _PickState<T>();
}

class _PickState<T> extends State<Pick<T>> {
  final _focus = FocusNode();
  final _menu = MenuController();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final value = widget.value,
          options = widget.options,
          onChanged = widget.onChanged;
      final theme = Theme.of(context), enabled = onChanged != null;
      final width = bounds.maxWidth.isFinite ? bounds.maxWidth : 220.0;
      return MenuAnchor(
        controller: _menu,
        childFocusNode: _focus,
        consumeOutsideTap: true,
        style: MenuStyle(
          minimumSize: WidgetStatePropertyAll(Size(width, 0)),
          maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 300)),
        ),
        menuChildren: options.entries
            .map(
              (entry) => MenuItemButton(
                key: ValueKey('pick-option-${entry.key}'),
                onPressed: enabled ? () => onChanged(entry.key) : null,
                style: ButtonStyle(
                  minimumSize: WidgetStatePropertyAll(
                    Size((width - 10).clamp(80, 700), 34),
                  ),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 10),
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => entry.key == value
                        ? accent(context).withValues(alpha: .1)
                        : states.contains(WidgetState.hovered) ||
                              states.contains(WidgetState.focused)
                        ? theme.scaffoldBackgroundColor
                        : Colors.transparent,
                  ),
                  foregroundColor: WidgetStatePropertyAll(
                    entry.key == value
                        ? accent(context)
                        : theme.colorScheme.onSurface,
                  ),
                ),
                trailingIcon: entry.key == value
                    ? Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: accent(context),
                      )
                    : const SizedBox(width: 16),
                child: Text(entry.value, style: const TextStyle(fontSize: 12)),
              ),
            )
            .toList(),
        builder: (context, controller, _) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): controller.close,
          },
          child: Tooltip(
            message: options[value] ?? '',
            waitDuration: const Duration(milliseconds: 800),
            child: OutlinedButton(
              focusNode: _focus,
              onPressed: enabled
                  ? () {
                      _focus.requestFocus();
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              style: ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(width, 36)),
                padding: const WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 11),
                ),
                backgroundColor: WidgetStatePropertyAll(
                  theme.inputDecorationTheme.fillColor,
                ),
                side: WidgetStateProperty.resolveWith(
                  (states) => BorderSide(
                    color: states.contains(WidgetState.focused)
                        ? accent(context)
                        : theme
                              .inputDecorationTheme
                              .enabledBorder!
                              .borderSide
                              .color,
                    width: states.contains(WidgetState.focused) ? 1.5 : 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      options[value] ?? '',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: enabled ? theme.colorScheme.onSurface : muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 17,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

class EdgeScroll extends StatefulWidget {
  final Widget Function(BuildContext, ScrollController) builder;
  final ScrollController? controller;
  const EdgeScroll({super.key, required this.builder, this.controller});
  @override
  State<EdgeScroll> createState() => _EdgeScrollState();
}

class _EdgeScrollState extends State<EdgeScroll> {
  late final ScrollController _ownController = ScrollController();
  @override
  void dispose() {
    _ownController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller ?? _ownController;
    return Scrollbar(
      controller: controller,
      interactive: true,
      child: Padding(
        padding: const EdgeInsets.only(right: 10),
        child: widget.builder(context, controller),
      ),
    );
  }
}

class Labeled extends StatelessWidget {
  final String label;
  final Widget child;
  const Labeled(this.label, this.child, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: muted,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 7),
        child,
      ],
    ),
  );
}

class StatusDot extends StatelessWidget {
  final bool active;
  const StatusDot(this.active, {super.key});
  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 220),
    width: 7,
    height: 7,
    decoration: BoxDecoration(
      color: active ? green : const Color(0xFFB6C0D1),
      shape: BoxShape.circle,
      boxShadow: active
          ? [
              BoxShadow(
                color: green.withValues(alpha: .15),
                blurRadius: 0,
                spreadRadius: 3,
              ),
            ]
          : [],
    ),
  );
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(text),
      width: 480,
      duration: const Duration(seconds: 3),
    ),
  );
}

Widget iconAction(IconData icon, String tooltip, VoidCallback? onPressed) =>
    IconButton(tooltip: tooltip, onPressed: onPressed, icon: Icon(icon));
Widget check(String label, bool value, ValueChanged<bool> onChanged) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Checkbox(value: value, onChanged: (v) => onChanged(v ?? false)),
    const SizedBox(width: 5),
    Text(label, style: const TextStyle(fontSize: 12)),
  ],
);
