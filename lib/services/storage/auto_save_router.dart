import 'dart:io';
import '../../core/constants/app_constants.dart';
import '../../core/models/file_manifest.dart';
import '../transfer/wake_lock_manager.dart';

typedef MediaNotifyCallback = Future<void> Function(
  String filePath,
  FileCategory category,
  String mimeType,
);

/// Platform-agnostic Auto-Save Router with Scoped Storage MediaStore compliance.
/// Automatically routes files to native destinations:
/// - Android 10-16+: MediaStore.Downloads ("Download/UniversalShare") & MediaStore.Images/Video (Zero MANAGE_EXTERNAL_STORAGE needed).
/// - iOS: Photos framework (Camera Roll) & Documents directory ("UniversalShare").
class AutoSaveRouter {
  /// Injected native channel invoker (configured by Flutter in main.dart).
  static NativeChannelInvoker? nativeChannelInvoker;

  /// Test or environment override for target base directory.
  static String? overrideBaseDirectory;

  /// Optional platform-specific media indexing handler.
  static MediaNotifyCallback? platformMediaNotifier;

  /// Resolves the dedicated target directory for incoming files.
  static Future<String> getTargetDirectory(FileCategory category) async {
    if (overrideBaseDirectory != null && overrideBaseDirectory!.isNotEmpty) {
      final dir = Directory('$overrideBaseDirectory/${AppConstants.universalShareFolder}');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    }

    try {
      if ((Platform.isAndroid || Platform.isIOS) && nativeChannelInvoker != null) {
        final customPath = await nativeChannelInvoker!<String>('getUniversalShareDirectory');
        if (customPath != null && customPath.isNotEmpty) {
          return customPath;
        }
      }
    } catch (_) {}

    try {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
      final targetDir = Directory('$home/Downloads/${AppConstants.universalShareFolder}');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      return targetDir.path;
    } catch (_) {
      final tempDir = Directory.systemTemp;
      return tempDir.path;
    }
  }

  /// Automatically moves a successfully received file to its final destination
  /// via native MediaStore API (Android) or Photos framework / Documents (iOS).
  static Future<String> routeReceivedFile({
    required String tempFilePath,
    required String fileName,
    required FileCategory category,
    required String mimeType,
  }) async {
    final tempFile = File(tempFilePath);
    if (!await tempFile.exists()) {
      throw FileSystemException('Source temporary file does not exist', tempFilePath);
    }

    // 1. Android MediaStore Scoped Storage Routing (API 29-35+)
    if (Platform.isAndroid && overrideBaseDirectory == null && nativeChannelInvoker != null) {
      try {
        if (category == FileCategory.photos || category == FileCategory.videos) {
          final uri = await nativeChannelInvoker!<String>('saveMediaToGallery', {
            'tempPath': tempFilePath,
            'fileName': fileName,
            'mimeType': mimeType,
            'isVideo': category == FileCategory.videos,
          });
          if (uri != null && uri.isNotEmpty) {
            return uri;
          }
        } else {
          // Documents, APKs, Binaries to Downloads/UniversalShare via MediaStore.Downloads
          final uri = await nativeChannelInvoker!<String>('saveToDownloads', {
            'tempPath': tempFilePath,
            'fileName': fileName,
            'mimeType': mimeType,
          });
          if (uri != null && uri.isNotEmpty) {
            return uri;
          }
        }
      } catch (_) {}
    }

    // 2. iOS Camera Roll Routing
    if (Platform.isIOS && overrideBaseDirectory == null && nativeChannelInvoker != null) {
      try {
        if (category == FileCategory.photos) {
          await nativeChannelInvoker!('saveImageToGallery', {'path': tempFilePath});
        } else if (category == FileCategory.videos) {
          await nativeChannelInvoker!('saveVideoToGallery', {'path': tempFilePath});
        }
      } catch (_) {}
    }

    // 3. Filesystem fallback (Desktop, Unit Tests, iOS Documents)
    final targetDir = await getTargetDirectory(category);
    final targetFilePath = '$targetDir/$fileName';
    final targetFile = File(targetFilePath);

    if (await targetFile.exists()) {
      final dot = fileName.lastIndexOf('.');
      final base = dot != -1 ? fileName.substring(0, dot) : fileName;
      final ext = dot != -1 ? fileName.substring(dot) : '';
      final uniqueName = '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
      final finalTarget = File('$targetDir/$uniqueName');
      await tempFile.rename(finalTarget.path);
      await _notifySystemMedia(finalTarget.path, category, mimeType);
      return finalTarget.path;
    } else {
      await tempFile.rename(targetFile.path);
      await _notifySystemMedia(targetFile.path, category, mimeType);
      return targetFile.path;
    }
  }

  /// Invokes the platform-specific media scanner callback (if configured).
  static Future<void> _notifySystemMedia(
    String filePath,
    FileCategory category,
    String mimeType,
  ) async {
    if (platformMediaNotifier != null) {
      try {
        await platformMediaNotifier!(filePath, category, mimeType);
      } catch (_) {}
    }
  }
}
