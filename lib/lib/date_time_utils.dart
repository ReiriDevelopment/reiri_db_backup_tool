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
  final month = _shortMonths[date.month - 1];
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
    return '${_shortMonths[date.month - 1]} ${date.day} $hour:$minute';
  }
  final label = date.hour >= 18 ? 'Tonight' : 'Today';
  return '$label $hour:$minute';
}

const _shortMonths = [
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
