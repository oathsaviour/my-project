import 'dart:math';

/// Formatting helpers for byte sizes, speeds, and durations.
class Formatters {
  /// Formats byte count into human-readable string (e.g. "1.42 GB", "450 MB").
  static String formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final i = (log(bytes) / log(1024)).floor();
    final clampedIndex = i.clamp(0, suffixes.length - 1);
    final size = bytes / pow(1024, clampedIndex);
    return '${size.toStringAsFixed(decimals)} ${suffixes[clampedIndex]}';
  }

  /// Formats transfer speed into human-readable string (e.g. "48.5 MB/s").
  static String formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond <= 0) return '0.0 MB/s';
    final mbps = bytesPerSecond / (1024 * 1024);
    if (mbps >= 1.0) {
      return '${mbps.toStringAsFixed(1)} MB/s';
    }
    final kbps = bytesPerSecond / 1024;
    return '${kbps.toStringAsFixed(1)} KB/s';
  }

  /// Formats ETA Duration (e.g. "45s", "2m 10s", "1h 14m").
  static String formatEta(Duration? duration) {
    if (duration == null) return '--:--';
    if (duration.inSeconds <= 0) return '0s';

    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Truncates a filename while preserving its extension (e.g. "really_long...name.mp4").
  static String truncateFileName(String fileName, [int maxLength = 26]) {
    if (fileName.length <= maxLength) return fileName;

    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex == -1 || dotIndex == 0) {
      return '${fileName.substring(0, maxLength - 3)}...';
    }

    final ext = fileName.substring(dotIndex);
    final baseLength = maxLength - ext.length - 3;
    if (baseLength < 3) {
      return '${fileName.substring(0, maxLength - 3)}...';
    }

    return '${fileName.substring(0, baseLength)}...$ext';
  }
}
