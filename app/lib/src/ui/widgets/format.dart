/// Human-readable formatting shared by the file manager and transfer panel.
library;

/// Binary units, one decimal below 100 so "1.4 GB" reads better than
/// "1503238553 bytes".
String formatBytes(int? bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String formatSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond.isNaN) return '';
  return '${formatBytes(bytesPerSecond.round())}/s';
}

/// `2026-10-11 14:03`, or an em dash when the server reported no time.
String formatModified(DateTime? time) {
  if (time == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${time.year}-${two(time.month)}-${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

/// `1h 02m`, `3m 05s`, `42s`.
String formatDuration(Duration d) {
  final seconds = d.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = d.inMinutes;
  if (minutes < 60) {
    return '${minutes}m ${(seconds % 60).toString().padLeft(2, '0')}s';
  }
  return '${d.inHours}h ${(minutes % 60).toString().padLeft(2, '0')}m';
}

/// Case-insensitive ordering where digit runs compare numerically, so
/// `file2` sorts before `file10` like every desktop file manager.
int naturalCompare(String a, String b) {
  final la = a.toLowerCase();
  final lb = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < la.length && j < lb.length) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(j);
    final da = _isDigit(ca);
    final db = _isDigit(cb);
    if (da && db) {
      var ei = i;
      while (ei < la.length && _isDigit(la.codeUnitAt(ei))) {
        ei++;
      }
      var ej = j;
      while (ej < lb.length && _isDigit(lb.codeUnitAt(ej))) {
        ej++;
      }
      // Compare by value without parsing, so huge digit runs cannot overflow.
      final na = la.substring(i, ei).replaceFirst(RegExp(r'^0+(?=.)'), '');
      final nb = lb.substring(j, ej).replaceFirst(RegExp(r'^0+(?=.)'), '');
      if (na.length != nb.length) return na.length.compareTo(nb.length);
      final c = na.compareTo(nb);
      if (c != 0) return c;
      i = ei;
      j = ej;
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    i++;
    j++;
  }
  final byLength = (la.length - i).compareTo(lb.length - j);
  if (byLength != 0) return byLength;
  // Stable tiebreak so names differing only by case have a fixed order.
  return a.compareTo(b);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
