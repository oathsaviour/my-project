import 'dart:io';
import '../../core/constants/app_constants.dart';
import '../../core/models/file_manifest.dart';

typedef MediaNotifyCallback = Future<void> Function(
  String filePath,
  FileCategory category,
  String mimeType,
);

/// Platform-agnostic Auto-Save Router.
/// Automatically moves files to the target destination and triggers media scan callbacks.
class AutoSaveRouter {
  /// Test or environment override for target base directory.
  static String? overrideBaseDirectory;

  /// Optional platform-specific media indexing handler (e.g. Flutter MethodChannel).
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
  /// and registers it with the OS (Camera Roll / MediaScanner).
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

    final targetDir = await getTargetDirectory(category);
    final targetFilePath = '$targetDir/$fileName';
    final targetFile = File(targetFilePath);

    // Overwrite or create unique name if target exists
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
