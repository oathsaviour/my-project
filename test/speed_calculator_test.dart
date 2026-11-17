import 'package:test/test.dart';
import '../lib/core/utils/speed_calculator.dart';
import '../lib/core/utils/formatters.dart';

void main() {
  group('SpeedCalculator & Formatters Tests', () {
    test('Calculates sliding window speed and ETA accurately', () async {
      final calc = SpeedCalculator(windowDuration: const Duration(seconds: 2));

      calc.recordProgress(0);
      await Future.delayed(const Duration(milliseconds: 100));
      calc.recordProgress(5 * 1024 * 1024); // 5MB in 100ms => ~50 MB/s

      final speedMb = calc.getSpeedMegaBytesPerSecond();
      expect(speedMb, greaterThan(20.0));

      final eta = calc.calculateEta(50 * 1024 * 1024); // 50MB remaining
      expect(eta, isNotNull);
      expect(eta!.inSeconds, lessThanOrEqualTo(5));
    });

    test('Formats byte sizes across scale', () {
      expect(Formatters.formatBytes(512), equals('512.00 B'));
      expect(Formatters.formatBytes(1024 * 500), equals('500.00 KB'));
      expect(Formatters.formatBytes(1024 * 1024 * 75), equals('75.00 MB'));
      expect(Formatters.formatBytes(1024 * 1024 * 1024 * 4), equals('4.00 GB'));
    });

    test('Formats ETA and speed strings', () {
      expect(Formatters.formatSpeed(52428800), equals('50.0 MB/s'));
      expect(Formatters.formatEta(const Duration(seconds: 45)), equals('45s'));
      expect(Formatters.formatEta(const Duration(minutes: 3, seconds: 12)), equals('3m 12s'));
      expect(Formatters.formatEta(const Duration(hours: 1, minutes: 15, seconds: 2)), equals('1h 15m'));
    });

    test('Truncates long filenames properly', () {
      expect(Formatters.truncateFileName('short.png'), equals('short.png'));
      expect(
        Formatters.truncateFileName('very_long_recording_video_from_camera_2026.mp4', 24),
        contains('...mp4'),
      );
    });
  });
}
