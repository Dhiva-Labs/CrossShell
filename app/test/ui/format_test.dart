import 'package:cross_shell/src/ui/widgets/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('formatBytes', () {
    expect(formatBytes(null), '—');
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(150 * 1024), '150 KB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    expect(formatBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    expect(formatBytes(2 * 1024 * 1024 * 1024 * 1024 * 1024 * 1024), '2048 PB');
  });

  test('formatSpeed and durations', () {
    expect(formatSpeed(null), '');
    expect(formatSpeed(2.5 * 1024 * 1024), '2.5 MB/s');
    expect(formatDuration(const Duration(seconds: 42)), '42s');
    expect(formatDuration(const Duration(seconds: 125)), '2m 05s');
    expect(formatDuration(const Duration(hours: 1, minutes: 2)), '1h 02m');
  });

  test('formatModified', () {
    expect(formatModified(null), '—');
    expect(formatModified(DateTime(2026, 10, 11, 9, 5)), '2026-10-11 09:05');
  });

  test('naturalCompare orders numbers by value and ignores case', () {
    final names = ['file10', 'File2', 'file1', 'a', 'B', 'file02'];
    names.sort(naturalCompare);
    expect(names, ['a', 'B', 'file1', 'File2', 'file02', 'file10']);
    expect(naturalCompare('a', 'a'), 0);
    expect(naturalCompare('x9', 'x10'), lessThan(0));
    expect(
      naturalCompare('99999999999999999999', '100000000000000000000'),
      lessThan(0),
    );
  });
}
