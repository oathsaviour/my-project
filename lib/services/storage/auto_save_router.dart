import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/file_manifest.dart';

/// Routes received payloads to native OS destinations (Gallery vs. Downloads/UniversalShare).
class AutoSaveRouter {
  static const MethodChannel _channel = MethodChannel('com.universal.filetransfer/native');

  /// Resolves the dedicated target directory for incoming files.
  static Future<String> getTargetDirectory(FileCategory category) async {
    try {
      if (Platform.isAndroid) {
        final customPath = await _channel.invokeMethod<String>('getUniversalShareDirectory');
        if (customPath != null && customPath.isNotEmpty) {
          return customPath;
        }
      }
    } catch (_) {}

    // Fallback using path_provider
    try {
      Directory? baseDir;
      if (Platform.isAndroid) {
        baseDir = await getExternalStorageDirectory();
      } else {
        baseDir = await getApplicationDocumentsDirectory();
      }

      final targetDir = Directory('${baseDir?.path}/${AppConstants.universalShareFolder}');
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      return targetDir.path;
    } catch (_) {
      final tempDir = await getTemporaryDirectory();
      return tempDir.path;
    }
  }

  /// Automatically moves a successfully received file to its final destination
  /// and registers it with the OS (Camera Roll / MediaStore).
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

  /// Invokes native platform channels to register media with Camera Roll / MediaScanner.
  static Future<void> _notifySystemMedia(
    String filePath,
    FileCategory category,
    String mimeType,
  ) async {
    try {
      if (Platform.isIOS) {
        if (category == FileCategory.photos) {
          await _channel.invokeMethod('saveImageToGallery', {'path': filePath});
        } else if (category == FileCategory.videos) {
          await _channel.invokeMethod('saveVideoToGallery', {'path': filePath});
        }
      } else if (Platform.isAndroid) {
        await _channel.invokeMethod('scanMediaFile', {
          'path': filePath,
          'mimeType': mimeType,
        });
      }
    } catch (_) {
      // Graceful fallback if running in unit test or web sandbox
    }
  }
}
