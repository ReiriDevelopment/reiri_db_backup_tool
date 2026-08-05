import 'package:reiri_app_core/reiri_app_core.dart';

/// Converts the 12-digit DB date integer `YYYYMMDDHHmm` to a [DateTime].
DateTime dbIntToDateTime(int date) {
  final year = date ~/ 100000000;
  final rest = date % 100000000;
  final month = rest ~/ 1000000;
  final rest2 = rest % 1000000;
  final day = rest2 ~/ 10000;
  final rest3 = rest2 % 10000;
  final hour = rest3 ~/ 100;
  final minute = rest3 % 100;
  return DateTime(year, month, day, hour, minute);
}

/// Formats a date as `dd Mon HH:mm`, optionally including seconds.
String formatDateTime(DateTime date, {bool includeSeconds = false}) {
  final day = date.day.toString().padLeft(2, '0');
  final month = _dateWord('mon${date.month}');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  final second = includeSeconds
      ? ':${date.second.toString().padLeft(2, '0')}'
      : '';
  return '$day $month $hour:$minute$second';
}

/// Formats a recovery schedule using the app's existing relative labels.
String formatScheduledDateTime(DateTime date, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final isToday =
      date.day == current.day &&
      date.month == current.month &&
      date.year == current.year;
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  if (!isToday) {
    return '${_dateWord('mon${date.month}')} ${date.day} $hour:$minute';
  }
  final label = _dateWord(date.hour >= 18 ? 'tonight' : 'today');
  return '$label $hour:$minute';
}

String _dateWord(String key) {
  try {
    final value = app.word(key);
    if (value != key) return value;
  } catch (_) {
    // Unit tests call these pure formatting helpers before app.init().
  }

  return switch (key) {
    'today' => 'Today',
    'tonight' => 'Tonight',
    'mon1' => 'Jan',
    'mon2' => 'Feb',
    'mon3' => 'Mar',
    'mon4' => 'Apr',
    'mon5' => 'May',
    'mon6' => 'Jun',
    'mon7' => 'Jul',
    'mon8' => 'Aug',
    'mon9' => 'Sep',
    'mon10' => 'Oct',
    'mon11' => 'Nov',
    'mon12' => 'Dec',
    _ => key,
  };
}
