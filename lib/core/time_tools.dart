import 'package:timezone/timezone.dart' as tz;

DateTime parseZonedDate(String text, String zone, {String ambiguity = 'ask'}) {
  final input = text.trim();
  if (RegExp(r'(Z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(input)) {
    return DateTime.parse(input).toUtc();
  }
  final location = tz.getLocation(zone);
  final parts = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?$',
  ).firstMatch(input);
  if (parts == null) {
    throw const FormatException('请输入 ISO 日期，例如 2026-10-25 08:00:00');
  }
  final values = [
    for (var i = 1; i <= 6; i++) int.parse(parts.group(i) ?? '0'),
  ];
  final ms = int.parse((parts.group(7) ?? '').padRight(3, '0'));
  final wall = DateTime.utc(
    values[0],
    values[1],
    values[2],
    values[3],
    values[4],
    values[5],
    ms,
  );
  if (wall.year != values[0] ||
      wall.month != values[1] ||
      wall.day != values[2] ||
      wall.hour != values[3] ||
      wall.minute != values[4] ||
      wall.second != values[5]) {
    throw const FormatException('日期或时间超出合法范围');
  }
  final matches = <int>{};
  for (final offset
      in location.zones.map((z) => z.offset.inMilliseconds).toSet()) {
    final candidate = wall.millisecondsSinceEpoch - offset;
    final local = tz.TZDateTime.fromMillisecondsSinceEpoch(location, candidate);
    if (local.year == wall.year &&
        local.month == wall.month &&
        local.day == wall.day &&
        local.hour == wall.hour &&
        local.minute == wall.minute &&
        local.second == wall.second &&
        local.millisecond == wall.millisecond) {
      matches.add(candidate);
    }
  }
  final sorted = matches.toList()..sort();
  if (sorted.isEmpty) throw const FormatException('该时区不存在此当地时间（夏令时跳跃），请修改');
  if (sorted.length > 1 && ambiguity == 'ask') {
    throw const FormatException('当地时间有两个 UTC 偏移，请选择较早或较晚时刻');
  }
  return DateTime.fromMillisecondsSinceEpoch(
    ambiguity == 'later' ? sorted.last : sorted.first,
    isUtc: true,
  );
}

String zonedDisplay(DateTime utc, String zone) {
  final d = tz.TZDateTime.from(utc, tz.getLocation(zone));
  final offset = d.timeZoneOffset, minutes = offset.inMinutes.abs();
  return '${d.toIso8601String().replaceFirst(RegExp(r'[+-]\d\d:\d\d$'), '')} ${offset.isNegative ? '-' : '+'}${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')} · ${d.timeZoneName}';
}
