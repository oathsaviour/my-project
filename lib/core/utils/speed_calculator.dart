import 'dart:collection';

class _ByteTimestamp {
  final int bytes;
  final DateTime time;

  _ByteTimestamp(this.bytes, this.time);
}

/// Sliding-window calculator for smoothed transfer speed (MB/s) and ETA.
class SpeedCalculator {
  final Duration windowDuration;
  final Queue<_ByteTimestamp> _history = Queue<_ByteTimestamp>();

  SpeedCalculator({this.windowDuration = const Duration(seconds: 3)});

  void recordProgress(int totalTransferredBytes) {
    final now = DateTime.now();
    _history.addLast(_ByteTimestamp(totalTransferredBytes, now));

    // Evict points older than the window
    final cutoff = now.subtract(windowDuration);
    while (_history.length > 2 && _history.first.time.isBefore(cutoff)) {
      _history.removeFirst();
    }
  }

  /// Current smoothed speed in bytes per second.
  double getSpeedBytesPerSecond() {
    if (_history.length < 2) return 0.0;

    final first = _history.first;
    final last = _history.last;

    final elapsedMs = last.time.difference(first.time).inMilliseconds;
    if (elapsedMs <= 0) return 0.0;

    final deltaBytes = last.bytes - first.bytes;
    if (deltaBytes <= 0) return 0.0;

    return (deltaBytes / (elapsedMs / 1000.0));
  }

  /// Current smoothed speed in megabytes per second (MB/s).
  double getSpeedMegaBytesPerSecond() {
    return getSpeedBytesPerSecond() / (1024 * 1024);
  }

  /// Calculates ETA given the total remaining bytes.
  Duration? calculateEta(int remainingBytes) {
    if (remainingBytes <= 0) return Duration.zero;

    final speed = getSpeedBytesPerSecond();
    if (speed <= 1024) return null; // Speed too low or zero to estimate accurately

    final seconds = remainingBytes / speed;
    if (seconds > 86400 * 7) return null; // Over 7 days, omit ETA

    return Duration(seconds: seconds.ceil());
  }

  void reset() {
    _history.clear();
  }
}
