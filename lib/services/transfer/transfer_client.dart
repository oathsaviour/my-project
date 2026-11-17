import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/discovered_device.dart';
import '../../core/models/file_manifest.dart';
import '../../core/utils/checksum_stream.dart';
import '../../core/utils/speed_calculator.dart';

typedef ClientProgressCallback = void Function(
  String fileId,
  int transferredBytes,
  int totalBytes,
  double speedMbPerSec,
  Duration? eta,
  TransferStatus status,
);

/// Chunked streaming file sender capable of transferring multi-gigabyte files
/// with bounded memory consumption and real-time speed/ETA metrics.
class TransferClient {
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = AppConstants.connectTimeout;

  final SpeedCalculator _speedCalculator = SpeedCalculator();
  bool _isPaused = false;
  bool _isCanceled = false;

  ClientProgressCallback? onProgress;
  void Function(String fileId, String error)? onError;
  void Function(String fileId)? onFileCompleted;

  bool get isPaused => _isPaused;
  bool get isCanceled => _isCanceled;

  void pause() {
    _isPaused = true;
  }

  void resume() {
    _isPaused = false;
  }

  void cancel() {
    _isCanceled = true;
  }

  /// Executes end-to-end file transfer session to target peer device.
  Future<bool> sendFiles({
    required DiscoveredDevice targetDevice,
    required String senderName,
    required String authPin,
    required List<FileManifestItem> filesToSend,
  }) async {
    _isPaused = false;
    _isCanceled = false;
    _speedCalculator.reset();

    final baseUrl = 'http://${targetDevice.ipAddress}:${targetDevice.port}';

    // Step 1: Handshake
    final handshakeOk = await _performHandshake(baseUrl, targetDevice.sessionToken, authPin);
    if (!handshakeOk) {
      throw const SocketException('Handshake rejected: invalid PIN or authentication token');
    }

    // Step 2: Send Manifest & Check Resume Offsets
    final resumeOffsets = await _sendManifest(baseUrl, senderName, authPin, filesToSend);

    // Step 3: Stream files chunk by chunk
    for (final fileItem in filesToSend) {
      if (_isCanceled) break;

      final startOffset = resumeOffsets[fileItem.fileId] ?? 0;
      await _streamSingleFile(baseUrl, fileItem, startOffset);
    }

    return !_isCanceled;
  }

  Future<bool> _performHandshake(String baseUrl, String token, String pin) async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/transfer/handshake');
      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;

      request.write(jsonEncode({
        'token': token,
        'pin': pin,
      }));

      final response = await request.close();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, int>> _sendManifest(
    String baseUrl,
    String senderName,
    String pin,
    List<FileManifestItem> files,
  ) async {
    final uri = Uri.parse('$baseUrl/api/v1/transfer/manifest');
    final request = await _httpClient.postUrl(uri);
    request.headers.contentType = ContentType.json;

    request.write(jsonEncode({
      'senderName': senderName,
      'pin': pin,
      'files': files.map((f) => f.toJson()).toList(),
    }));

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw SocketException('Receiver rejected transfer manifest: HTTP ${response.statusCode}');
    }

    final body = await utf8.decodeStream(response);
    final data = jsonDecode(body);
    final offsets = <String, int>{};

    final rawFiles = data['files'] as List<dynamic>? ?? [];
    for (final f in rawFiles) {
      final fileId = f['fileId'] as String;
      final offset = (f['resumeOffsetBytes'] as num?)?.toInt() ?? 0;
      offsets[fileId] = offset;
    }

    return offsets;
  }

  Future<void> _streamSingleFile(
    String baseUrl,
    FileManifestItem item,
    int resumeOffsetBytes,
  ) async {
    if (item.localFilePath == null) {
      onError?.call(item.fileId, 'Local file path is missing');
      return;
    }

    final localFile = File(item.localFilePath!);
    if (!await localFile.exists()) {
      onError?.call(item.fileId, 'File not found on device');
      return;
    }

    final totalSize = await localFile.length();
    final chunkSize = item.chunkSize;
    final totalChunks = totalSize == 0 ? 1 : ((totalSize + chunkSize - 1) ~/ chunkSize);

    final raf = await localFile.open(mode: FileMode.read);
    int currentOffset = resumeOffsetBytes;
    int chunkIndex = (resumeOffsetBytes ~/ chunkSize);

    try {
      if (currentOffset > 0) {
        await raf.setPosition(currentOffset);
      }

      while (currentOffset < totalSize && !_isCanceled) {
        // Handle Pause state
        while (_isPaused && !_isCanceled) {
          onProgress?.call(
            item.fileId,
            currentOffset,
            totalSize,
            0.0,
            null,
            TransferStatus.paused,
          );
          await Future.delayed(const Duration(milliseconds: 300));
        }

        if (_isCanceled) break;

        final bytesToRead = (totalSize - currentOffset) < chunkSize
            ? (totalSize - currentOffset)
            : chunkSize;

        final chunkData = await raf.read(bytesToRead);
        final chunkSha256 = sha256.convert(chunkData).toString();

        // Transmit chunk with flow control
        final success = await _uploadChunk(
          baseUrl: baseUrl,
          fileId: item.fileId,
          chunkIndex: chunkIndex,
          totalChunks: totalChunks,
          chunkBytes: chunkData,
          chunkSha256: chunkSha256,
        );

        if (!success) {
          throw SocketException('Failed to upload chunk $chunkIndex');
        }

        currentOffset += chunkData.length;
        chunkIndex++;

        // Update speed & ETA metrics
        _speedCalculator.recordProgress(currentOffset);
        final speedMb = _speedCalculator.getSpeedMegaBytesPerSecond();
        final eta = _speedCalculator.calculateEta(totalSize - currentOffset);

        onProgress?.call(
          item.fileId,
          currentOffset,
          totalSize,
          speedMb,
          eta,
          TransferStatus.inProgress,
        );
      }

      await raf.close();

      if (!_isCanceled && currentOffset >= totalSize) {
        // Step 4: Finalize & Checksum Verification
        onProgress?.call(
          item.fileId,
          totalSize,
          totalSize,
          0.0,
          Duration.zero,
          TransferStatus.verifyingChecksum,
        );

        final finalizeOk = await _finalizeFile(baseUrl, item.fileId);
        if (finalizeOk) {
          onFileCompleted?.call(item.fileId);
          onProgress?.call(
            item.fileId,
            totalSize,
            totalSize,
            0.0,
            Duration.zero,
            TransferStatus.completed,
          );
        } else {
          onError?.call(item.fileId, 'Checksum validation failed at receiver');
        }
      }
    } catch (e) {
      try {
        await raf.close();
      } catch (_) {}
      onError?.call(item.fileId, e.toString());
    }
  }

  Future<bool> _uploadChunk({
    required String baseUrl,
    required String fileId,
    required int chunkIndex,
    required int totalChunks,
    required Uint8List chunkBytes,
    required String chunkSha256,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/transfer/chunk?fileId=$fileId&chunkIndex=$chunkIndex&totalChunks=$totalChunks&sha256=$chunkSha256',
    );

    final request = await _httpClient.postUrl(uri);
    request.headers.contentType = ContentType.binary;
    request.contentLength = chunkBytes.length;

    request.add(chunkBytes);
    final response = await request.close();

    return response.statusCode == HttpStatus.ok;
  }

  Future<bool> _finalizeFile(String baseUrl, String fileId) async {
    final uri = Uri.parse('$baseUrl/api/v1/transfer/finalize');
    final request = await _httpClient.postUrl(uri);
    request.headers.contentType = ContentType.json;

    request.write(jsonEncode({'fileId': fileId}));
    final response = await request.close();

    return response.statusCode == HttpStatus.ok;
  }

  void dispose() {
    _httpClient.close(force: true);
  }
}
