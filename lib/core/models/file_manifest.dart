import 'package:mime/mime.dart';

/// Categories for categorized tabs in the File Picker Hub.
enum FileCategory {
  photos,
  videos,
  audio,
  documents,
  apps,
  raw;

  String get displayName {
    switch (this) {
      case FileCategory.photos:
        return 'Photos';
      case FileCategory.videos:
        return 'Videos';
      case FileCategory.audio:
        return 'Audio';
      case FileCategory.documents:
        return 'Documents';
      case FileCategory.apps:
        return 'Apps (APK/IPA)';
      case FileCategory.raw:
        return 'Raw Files';
    }
  }

  static FileCategory fromFileNameAndMime(String fileName, String? mime) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.apk') || lower.endsWith('.ipa') || lower.endsWith('.dmg') || lower.endsWith('.exe')) {
      return FileCategory.apps;
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.heic') || lower.endsWith('.webp') || lower.endsWith('.gif')) {
      return FileCategory.photos;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.mkv') || lower.endsWith('.avi') || lower.endsWith('.webm')) {
      return FileCategory.videos;
    }
    if (lower.endsWith('.mp3') || lower.endsWith('.wav') || lower.endsWith('.m4a') || lower.endsWith('.flac') || lower.endsWith('.aac') || lower.endsWith('.ogg')) {
      return FileCategory.audio;
    }
    if (lower.endsWith('.pdf') || lower.endsWith('.docx') || lower.endsWith('.xlsx') || lower.endsWith('.pptx') || lower.endsWith('.txt') || lower.endsWith('.zip') || lower.endsWith('.tar.gz') || lower.endsWith('.7z')) {
      return FileCategory.documents;
    }
    return FileCategory.raw;
  }
}

/// Lifecycle status of an individual file transfer.
enum TransferStatus {
  pending,
  inProgress,
  paused,
  verifyingChecksum,
  completed,
  failed,
  canceled,
}

/// Metadata describing an uncompressed file to be transferred.
class FileManifestItem {
  final String fileId;
  final String fileName;
  final int fileSize; // in bytes (supports >4GB with 64-bit int)
  final String mimeType;
  final FileCategory category;
  final String? localFilePath;
  final String? expectedSha256;
  final String? actualSha256;
  final int chunkSize;
  final int totalChunks;
  final int confirmedChunks;
  final int transferredBytes;
  final TransferStatus status;
  final String? errorMessage;

  const FileManifestItem({
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.category,
    this.localFilePath,
    this.expectedSha256,
    this.actualSha256,
    required this.chunkSize,
    required this.totalChunks,
    this.confirmedChunks = 0,
    this.transferredBytes = 0,
    this.status = TransferStatus.pending,
    this.errorMessage,
  });

  /// Factory helper from file metadata.
  factory FileManifestItem.create({
    required String fileId,
    required String fileName,
    required int fileSize,
    String? localFilePath,
    String? sha256,
    int chunkSize = 2 * 1024 * 1024,
  }) {
    final mime = lookupMimeType(fileName) ?? 'application/octet-stream';
    final category = FileCategory.fromFileNameAndMime(fileName, mime);
    final totalChunks = fileSize == 0 ? 1 : ((fileSize + chunkSize - 1) ~/ chunkSize);

    return FileManifestItem(
      fileId: fileId,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mime,
      category: category,
      localFilePath: localFilePath,
      expectedSha256: sha256,
      chunkSize: chunkSize,
      totalChunks: totalChunks,
    );
  }

  double get progressFraction {
    if (fileSize == 0) return 1.0;
    return (transferredBytes / fileSize).clamp(0.0, 1.0);
  }

  int get progressPercent => (progressFraction * 100).toInt();

  bool get isCompleted => status == TransferStatus.completed;

  FileManifestItem copyWith({
    String? fileId,
    String? fileName,
    int? fileSize,
    String? mimeType,
    FileCategory? category,
    String? localFilePath,
    String? expectedSha256,
    String? actualSha256,
    int? chunkSize,
    int? totalChunks,
    int? confirmedChunks,
    int? transferredBytes,
    TransferStatus? status,
    String? errorMessage,
  }) {
    return FileManifestItem(
      fileId: fileId ?? this.fileId,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize ?? this.fileSize,
      mimeType: mimeType ?? this.mimeType,
      category: category ?? this.category,
      localFilePath: localFilePath ?? this.localFilePath,
      expectedSha256: expectedSha256 ?? this.expectedSha256,
      actualSha256: actualSha256 ?? this.actualSha256,
      chunkSize: chunkSize ?? this.chunkSize,
      totalChunks: totalChunks ?? this.totalChunks,
      confirmedChunks: confirmedChunks ?? this.confirmedChunks,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  Map<String, dynamic> toJson() => {
        'fileId': fileId,
        'fileName': fileName,
        'fileSize': fileSize,
        'mimeType': mimeType,
        'category': category.name,
        'expectedSha256': expectedSha256,
        'actualSha256': actualSha256,
        'chunkSize': chunkSize,
        'totalChunks': totalChunks,
        'confirmedChunks': confirmedChunks,
        'transferredBytes': transferredBytes,
        'status': status.name,
      };

  factory FileManifestItem.fromJson(Map<String, dynamic> json) => FileManifestItem(
        fileId: json['fileId'] as String,
        fileName: json['fileName'] as String,
        fileSize: (json['fileSize'] as num).toInt(),
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        category: FileCategory.values.firstWhere(
          (c) => c.name == json['category'],
          orElse: () => FileCategory.raw,
        ),
        expectedSha256: json['expectedSha256'] as String?,
        actualSha256: json['actualSha256'] as String?,
        chunkSize: (json['chunkSize'] as num?)?.toInt() ?? (2 * 1024 * 1024),
        totalChunks: (json['totalChunks'] as num?)?.toInt() ?? 1,
        confirmedChunks: (json['confirmedChunks'] as num?)?.toInt() ?? 0,
        transferredBytes: (json['transferredBytes'] as num?)?.toInt() ?? 0,
        status: TransferStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => TransferStatus.pending,
        ),
      );
}
