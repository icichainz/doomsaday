/// Client-side formatting.
///
/// Revision 1.1 of `docs/agent-api.md` settles that the agent returns raw
/// values and RFC 3339 timestamps only; every display string in the app —
/// "Up 12 days", "3 weeks ago", "in 6 days", byte sizes and percentages — is
/// made here so the same figure reads the same on every screen.
library;

const int _kib = 1024;
const int _mib = _kib * 1024;
const int _gib = _mib * 1024;
const int _tib = _gib * 1024;

/// One decimal, but never a bare `.0`: the design writes `2 GB`, not `2.0 GB`.
String _figure(double value) {
  if (value >= 10) return value.round().toString();
  final String fixed = value.toStringAsFixed(1);
  return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
}

/// Byte formatting the way the design writes it: `412 MB`, `8.4 GB`, `31 GB`.
String formatBytes(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes >= _tib) return '${_figure(bytes / _tib)} TB';
  if (bytes >= _gib) return '${_figure(bytes / _gib)} GB';
  if (bytes >= _mib) return '${(bytes / _mib).round()} MB';
  if (bytes >= _kib) return '${(bytes / _kib).round()} KB';
  return '$bytes B';
}

/// The bare figure in gigabytes, for the stat cards that print the unit once:
/// `9.8 / 16 GB`.
String formatGigabytes(int bytes) => _figure(bytes / _gib);

/// `0.4%`, `18%`, `90%`. One decimal below 10 only when there is one to show.
String formatPercent(double value) {
  final double v = value.isNaN || value.isInfinite ? 0 : value;
  if (v < 10 && v != v.roundToDouble()) return '${v.toStringAsFixed(1)}%';
  return '${v.round()}%';
}

/// `12 days`, `3 h`, `18 min`, `less than a minute`.
///
/// Rounds to the nearest unit rather than truncating, so a token that expires
/// in six days minus a microsecond still reads "6 days".
String formatDuration(Duration d) {
  final int seconds = d.inSeconds.abs();
  if (seconds < 45) return 'less than a minute';
  final int minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final int hours = (seconds / 3600).round();
  if (hours < 24) return '$hours h';
  final int days = (seconds / 86400).round();
  return days == 1 ? '1 day' : '$days days';
}

/// `31 s`, `4 min`, `2 h` — short enough for a `Retry-After`.
String formatShortDuration(Duration d) {
  final int seconds = d.inSeconds.abs();
  if (seconds < 60) return '$seconds s';
  return formatDuration(d);
}

/// `Up 12 days` for a running container or host.
String formatUptime(Duration d) => 'Up ${formatDuration(d)}';

final RegExp _goDuration = RegExp(
  r'\b(?:(\d+)h)?(?:(\d+)m)?(\d+(?:\.\d+)?)s\b',
);

/// Rewrites Go's `10m0s`, `1h30m0s`, `90s` inside a sentence the agent wrote
/// into the app's own wording. No screen may ever print a raw duration.
String humanizeDurations(String text) =>
    text.replaceAllMapped(_goDuration, (Match m) {
      final int hours = int.tryParse(m[1] ?? '') ?? 0;
      final int minutes = int.tryParse(m[2] ?? '') ?? 0;
      final double seconds = double.tryParse(m[3] ?? '') ?? 0;
      if (hours == 0 && minutes == 0 && seconds == 0) return m[0]!;
      return formatDuration(
        Duration(
          hours: hours,
          minutes: minutes,
          milliseconds: (seconds * 1000).round(),
        ),
      );
    });

/// `3 days ago`, `3 weeks ago`, `2 months ago`, `today 09:15`, `in 6 days`.
///
/// The ladder is the one the boards use: minutes inside the hour, `today` and
/// the clock for the rest of the day, then days up to a fortnight, weeks up to
/// two months, then months and years. [now] is injectable for tests.
String formatRelative(DateTime when, {DateTime? now}) {
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  final DateTime local = when.toLocal();
  final Duration delta = reference.difference(local);
  if (delta.isNegative) return 'in ${formatDuration(delta)}';
  if (delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${(delta.inSeconds / 60).round()} min ago';
  if (_sameDay(local, reference)) {
    return 'today ${_two(local.hour)}:${_two(local.minute)}';
  }
  final int days = _calendarDays(local, reference);
  if (days < 14) return days == 1 ? '1 day ago' : '$days days ago';
  if (days < 60) {
    final int weeks = (days / 7).round();
    return weeks == 1 ? '1 week ago' : '$weeks weeks ago';
  }
  if (days < 365) {
    final int months = (days / 30).floor();
    return months == 1 ? '1 month ago' : '$months months ago';
  }
  final int years = (days / 365).floor();
  return years == 1 ? '1 year ago' : '$years years ago';
}

/// `09:41:52`, the log gutter.
String formatClock(DateTime when) {
  final DateTime t = when.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

const List<String> _weekdays = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<String> _monthNames = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// The activity gutter: `09:42` today, `Tue` this week, `12 Mar` before that.
String formatActivityTime(DateTime when, {DateTime? now}) {
  final DateTime t = when.toLocal();
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  if (_sameDay(t, reference)) return '${_two(t.hour)}:${_two(t.minute)}';
  if (_calendarDays(t, reference) < 7) return _weekdays[t.weekday - 1];
  return '${t.day} ${_months[t.month - 1]}';
}

/// When something was resolved: `Tue 14:10` within the week, `12 Mar 14:10`
/// after it. The design never spells a resolved alert as "2 days ago".
String formatWeekdayTime(DateTime when, {DateTime? now}) {
  final DateTime t = when.toLocal();
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  final String clock = '${_two(t.hour)}:${_two(t.minute)}';
  if (_sameDay(t, reference)) return 'today $clock';
  if (_calendarDays(t, reference) < 7) {
    return '${_weekdays[t.weekday - 1]} $clock';
  }
  return '${t.day} ${_months[t.month - 1]} $clock';
}

/// `March`, or `March 2024` once the year is not this one. What a volume that
/// has sat unused for months reads as.
String formatMonthName(DateTime when, {DateTime? now}) {
  final DateTime t = when.toLocal();
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  final String month = _monthNames[t.month - 1];
  return t.year == reference.year ? month : '$month ${t.year}';
}

String _two(int value) => value.toString().padLeft(2, '0');

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Whole calendar days between two local times, so "yesterday 23:00" is one
/// day ago at 00:30 rather than none.
int _calendarDays(DateTime from, DateTime to) => DateTime(
  to.year,
  to.month,
  to.day,
).difference(DateTime(from.year, from.month, from.day)).inDays;

/// `1,204` — thousands separators for the log line counter.
String formatCount(int value) => value.toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+$)'),
  (Match m) => '${m[1]},',
);

/// Shortens a long single-line value from the middle, so both ends stay
/// readable: `agent.example.com:8443` keeps its host and its port.
String ellipsizeMiddle(String value, int max) {
  if (max < 5 || value.length <= max) return value;
  final int head = (max - 1) ~/ 2;
  final int tail = max - 1 - head;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}

/// `09:41`, the activity log's time column once the day is its own heading.
String formatHourMinute(DateTime when) {
  final DateTime t = when.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// The day headings of the activity log: `Today`, `Yesterday`, `Tuesday`
/// within the week, then `12 Mar`, and `12 Mar 2025` once the year is not
/// this one.
String formatDayHeading(DateTime when, {DateTime? now}) {
  final DateTime t = when.toLocal();
  final DateTime reference = (now ?? DateTime.now()).toLocal();
  final int days = _calendarDays(t, reference);
  if (days <= 0) return 'Today';
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdayNames[t.weekday - 1];
  final String date = '${t.day} ${_months[t.month - 1]}';
  return t.year == reference.year ? date : '$date ${t.year}';
}

const List<String> _weekdayNames = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
