import 'discovered_device.dart';
import 'file_manifest.dart';

enum TransferDirection {
  outgoing,
  incoming,
}

/// Represents an active or historical file transfer session between two peers.
class TransferSession {
  final String sessionId;
  final DiscoveredDevice peer;
  final TransferDirection direction;
  final String authPin;
  final List<FileManifestItem> files;
  final int activeFileIndex;
  final double currentSpeedBytesPerSec;
  final Duration? estimatedTimeRemaining;
  final DateTime startTime;
  final DateTime? completedTime;
  final bool isPaused;
  final bool isCanceled;

  const TransferSession({
    required this.sessionId,
    required this.peer,
    required this.direction,
    required this.authPin,
    required this.files,
    this.activeFileIndex = 0,
    this.currentSpeedBytesPerSec = 0.0,
    this.estimatedTimeRemaining,
    required this.startTime,
    this.completedTime,
    this.isPaused = false,
    this.isCanceled = false,
  });

  int get totalBytes => files.fold(0, (sum, item) => sum + item.fileSize);

  int get transferredBytes => files.fold(0, (sum, item) => sum + item.transferredBytes);

  double get overallProgress {
    if (totalBytes == 0) return 1.0;
    return (transferredBytes / totalBytes).clamp(0.0, 1.0);
  }

  int get overallProgressPercent => (overallProgress * 100).toInt();

  bool get isCompleted =>
      files.isNotEmpty && files.every((f) => f.status == TransferStatus.completed);

  FileManifestItem? get activeFile {
    if (activeFileIndex >= 0 && activeFileIndex < files.length) {
      return files[activeFileIndex];
    }
    return null;
  }

  TransferSession copyWith({
    String? sessionId,
    DiscoveredDevice? peer,
    TransferDirection? direction,
    String? authPin,
    List<FileManifestItem>? files,
    int? activeFileIndex,
    double? currentSpeedBytesPerSec,
    Duration? estimatedTimeRemaining,
    DateTime? startTime,
    DateTime? completedTime,
    bool? isPaused,
    bool? isCanceled,
  }) {
    return TransferSession(
      sessionId: sessionId ?? this.sessionId,
      peer: peer ?? this.peer,
      direction: direction ?? this.direction,
      authPin: authPin ?? this.authPin,
      files: files ?? this.files,
      activeFileIndex: activeFileIndex ?? this.activeFileIndex,
      currentSpeedBytesPerSec: currentSpeedBytesPerSec ?? this.currentSpeedBytesPerSec,
      estimatedTimeRemaining: estimatedTimeRemaining ?? this.estimatedTimeRemaining,
      startTime: startTime ?? this.startTime,
      completedTime: completedTime ?? this.completedTime,
      isPaused: isPaused ?? this.isPaused,
      isCanceled: isCanceled ?? this.isCanceled,
    );
  }
}
