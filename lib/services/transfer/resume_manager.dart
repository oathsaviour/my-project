import 'dart:convert';
import 'dart:io';

/// Checkpoint manager for tracking partially transferred files on disk.
class ResumeCheckpoint {
  final String fileId;
  final String fileName;
  final int totalBytes;
  final int transferredBytes;
  final int confirmedChunks;
  final int totalChunks;
  final String tempFilePath;
  final String expectedSha256;

  ResumeCheckpoint({
    required this.fileId,
    required this.fileName,
    required this.totalBytes,
    required this.transferredBytes,
    required this.confirmedChunks,
    required this.totalChunks,
    required this.tempFilePath,
    required this.expectedSha256,
  });

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'fileName': fileName,
        'totalBytes': totalBytes,
        'transferredBytes': transferredBytes,
        'confirmedChunks': confirmedChunks,
        'totalChunks': totalChunks,
        'tempFilePath': tempFilePath,
        'expectedSha256': expectedSha256,
      };

  factory ResumeCheckpoint.fromJson(Map<String, dynamic> json) => ResumeCheckpoint(
        fileId: json['fileId'] as String,
        fileName: json['fileName'] as String,
        totalBytes: (json['totalBytes'] as num).toInt(),
        transferredBytes: (json['transferredBytes'] as num).toInt(),
        confirmedChunks: (json['confirmedChunks'] as num).toInt(),
        totalChunks: (json['totalChunks'] as num).toInt(),
        tempFilePath: json['tempFilePath'] as String,
        expectedSha256: json['expectedSha256'] as String? ?? '',
      );
}

/// Manages serialization of transfer checkpoints to disk for crash recovery and resume.
class ResumeManager {
  final String storageDirectory;

  ResumeManager({required this.storageDirectory});

  String _metaPath(String fileId) => '$storageDirectory/$fileId.meta';

  Future<void> saveCheckpoint(ResumeCheckpoint checkpoint) async {
    try {
      final file = File(_metaPath(checkpoint.fileId));
      await file.writeAsString(jsonEncode(checkpoint.toJson()));
    } catch (_) {}
  }

  Future<ResumeCheckpoint?> loadCheckpoint(String fileId) async {
    try {
      final file = File(_metaPath(fileId));
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(content);
        return ResumeCheckpoint.fromJson(data);
      }
    } catch (_) {}
    return null;
  }

  Future<void> deleteCheckpoint(String fileId) async {
    try {
      final file = File(_metaPath(fileId));
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
