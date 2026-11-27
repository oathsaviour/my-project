import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/discovered_device.dart';
import '../../core/models/file_manifest.dart';
import '../../core/utils/speed_calculator.dart';
import 'wake_lock_manager.dart';

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
    WakeLockManager.releaseWakeLock();
  }

  void resume() {
    _isPaused = false;
    WakeLockManager.acquireWakeLock(reason: 'Resumed Transfer');
  }

  void cancel() {
    _isCanceled = true;
    WakeLockManager.forceReleaseAll();
  }

  /// Requests a mutual one-time trusted session with a peer device.
  /// Returns the peer's session token if approved, or null if declined/failed.
  Future<String?> requestMutualSession({
    required DiscoveredDevice targetDevice,
    required String sessionId,
    required String localName,
    required DeviceOS localOs,
    required String localIp,
    required int localPort,
    required String authPin,
    String localToken = '',
  }) async {
    try {
      final baseUrl = 'http://${targetDevice.ipAddress}:${targetDevice.port}';
      final uri = Uri.parse('$baseUrl/api/v1/session/request');
      final request = await _httpClient.postUrl(uri);
      request.persistentConnection = false;
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({
        'sessionId': sessionId,
        'peerName': localName,
        'peerOs': localOs.name,
        'peerIp': localIp,
        'peerPort': localPort,
        'token': targetDevice.sessionToken,
        'localToken': localToken,
        'pin': authPin,
      }));
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode == HttpStatus.ok) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        return data['token'] as String? ?? '';
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Executes end-to-end file transfer session to target peer device.
  Future<bool> sendFiles({
    required DiscoveredDevice targetDevice,
    required String senderName,
    required String authPin,
    required List<FileManifestItem> filesToSend,
    String? sessionId,
  }) async {
    _isPaused = false;
    _isCanceled = false;
    _speedCalculator.reset();

    // Acquire screen and CPU wake lock to prevent Doze mode or screen auto-lock
    await WakeLockManager.acquireWakeLock(reason: 'Sending files to ${targetDevice.name}');

    bool hasError = false;
    try {
      final baseUrl = 'http://${targetDevice.ipAddress}:${targetDevice.port}';

      // Step 1: Handshake
      final handshakeOk = await _performHandshake(
        baseUrl,
        targetDevice.sessionToken,
        authPin,
        sessionId: sessionId,
      );
      if (!handshakeOk) {
        const msg = 'Handshake rejected: invalid PIN or authentication token';
        if (filesToSend.isNotEmpty) {
          onError?.call(filesToSend.first.fileId, msg);
        }
        throw const SocketException(msg);
      }

      if (_isCanceled) return false;

      // Step 2: Send Manifest & Check Resume Offsets (no pre-read hashing delay for 5GB+ files)
      final resumeOffsets = await _sendManifest(
        baseUrl,
        senderName,
        authPin,
        filesToSend,
        sessionId: sessionId,
      );

      // Step 3: Stream files chunk by chunk (with streaming SHA-256 + auto-reconnect on drop)
      for (final fileItem in filesToSend) {
        if (_isCanceled) break;

        final startOffset = resumeOffsets[fileItem.fileId] ?? 0;
        final ok = await _streamSingleFile(
          baseUrl: baseUrl,
          senderName: senderName,
          authPin: authPin,
          token: targetDevice.sessionToken,
          sessionId: sessionId,
          item: fileItem,
          resumeOffsetBytes: startOffset,
        );
        if (!ok) {
          hasError = true;
        }
      }

      return !_isCanceled && !hasError;
    } catch (e) {
      hasError = true;
      rethrow;
    } finally {
      await WakeLockManager.releaseWakeLock();
    }
  }

  Future<bool> _performHandshake(
    String baseUrl,
    String token,
    String pin, {
    String? sessionId,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/transfer/handshake');
      final request = await _httpClient.postUrl(uri);
      request.persistentConnection = false;
      request.headers.contentType = ContentType.json;

      request.write(jsonEncode({
        'token': token,
        'pin': pin,
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      }));

      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, int>> _sendManifest(
    String baseUrl,
    String senderName,
    String pin,
    List<FileManifestItem> files, {
    String? sessionId,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/transfer/manifest');
    final request = await _httpClient.postUrl(uri);
    request.persistentConnection = false;
    request.headers.contentType = ContentType.json;

    request.write(jsonEncode({
      'senderName': senderName,
      'pin': pin,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      'files': files.map((f) => f.toJson()).toList(),
    }));

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
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

  Future<bool> _streamSingleFile({
    required String baseUrl,
    required String senderName,
    required String authPin,
    required String token,
    String? sessionId,
    required FileManifestItem item,
    required int resumeOffsetBytes,
  }) async {
    if (item.localFilePath == null) {
      onError?.call(item.fileId, 'Local file path is missing');
      return false;
    }

    final localFile = File(item.localFilePath!);
    if (!await localFile.exists()) {
      onError?.call(item.fileId, 'File not found on device');
      return false;
    }

    final totalSize = await localFile.length();
    final chunkSize = item.chunkSize;
    final totalChunks = totalSize == 0 ? 1 : ((totalSize + chunkSize - 1) ~/ chunkSize);

    final raf = await localFile.open(mode: FileMode.read);
    int currentOffset = resumeOffsetBytes;
    int chunkIndex = (resumeOffsetBytes ~/ chunkSize);

    // Compute full-file SHA-256 incrementally while streaming (zero pre-read delay)
    _DigestSink? fullDigestSink;
    ByteConversionSink? fullShaSink;
    if (resumeOffsetBytes == 0 && (item.expectedSha256 == null || item.expectedSha256!.isEmpty)) {
      fullDigestSink = _DigestSink();
      fullShaSink = sha256.startChunkedConversion(fullDigestSink);
    }

    try {
      if (currentOffset > 0) {
        await raf.setPosition(currentOffset);
      }

      while (currentOffset < totalSize && !_isCanceled) {
        // Handle manual Pause state
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

        await raf.setPosition(currentOffset);
        final chunkData = await raf.read(bytesToRead);
        final chunkSha256 = sha256.convert(chunkData).toString();

        bool uploaded = false;
        try {
          uploaded = await _uploadChunk(
            baseUrl: baseUrl,
            fileId: item.fileId,
            chunkIndex: chunkIndex,
            totalChunks: totalChunks,
            chunkBytes: chunkData,
            chunkSha256: chunkSha256,
          );
        } on IOException {
          uploaded = false;
        } on TimeoutException {
          uploaded = false;
        }

        if (!uploaded) {
          // Connection dropped (e.g. Wi-Fi toggled): pause and wait up to 5 minutes to auto-resume
          final resumedOffset = await _waitForReconnectAndResumeOffset(
            baseUrl: baseUrl,
            senderName: senderName,
            authPin: authPin,
            token: token,
            sessionId: sessionId,
            item: item,
            currentOffset: currentOffset,
            totalSize: totalSize,
          );
          if (resumedOffset == null) {
            throw const SocketException('Connection lost and could not reconnect within 5 minutes');
          }
          // If server already has this chunk, advance offset; otherwise retry from resumedOffset
          if (resumedOffset != currentOffset) {
            // Recompute or disable incremental full hash if offset jumped
            if (resumedOffset > currentOffset && fullShaSink != null && resumedOffset <= currentOffset + chunkData.length) {
              fullShaSink.add(chunkData);
            } else {
              fullShaSink = null;
              fullDigestSink = null;
            }
            currentOffset = resumedOffset;
            chunkIndex = currentOffset ~/ chunkSize;
          }
          continue;
        }

        fullShaSink?.add(chunkData);
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
        String? computedFullSha256 = item.expectedSha256;
        if (fullShaSink != null && fullDigestSink != null) {
          fullShaSink.close();
          computedFullSha256 = fullDigestSink.value?.toString();
        }

        // Step 4: Finalize & Checksum Verification
        onProgress?.call(
          item.fileId,
          totalSize,
          totalSize,
          0.0,
          Duration.zero,
          TransferStatus.verifyingChecksum,
        );

        final finalizeOk = await _finalizeFile(
          baseUrl,
          item.fileId,
          expectedSha256: computedFullSha256,
        );
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
          return true;
        } else {
          onError?.call(item.fileId, 'Checksum validation failed at receiver');
          return false;
        }
      }
      return true;
    } catch (e) {
      try {
        await raf.close();
      } catch (_) {}
      onError?.call(item.fileId, e.toString());
      return false;
    }
  }

  /// Polls the receiver every 2 seconds until the connection recovers, then returns the
  /// exact byte offset to resume from. Returns null if canceled or timed out after 5 minutes.
  Future<int?> _waitForReconnectAndResumeOffset({
    required String baseUrl,
    required String senderName,
    required String authPin,
    required String token,
    String? sessionId,
    required FileManifestItem item,
    required int currentOffset,
    required int totalSize,
  }) async {
    const maxAttempts = 150; // 150 * 2s = 5 minutes
    for (int attempt = 0; attempt < maxAttempts && !_isCanceled; attempt++) {
      onProgress?.call(
        item.fileId,
        currentOffset,
        totalSize,
        0.0,
        null,
        TransferStatus.paused,
      );

      await Future.delayed(const Duration(seconds: 2));
      if (_isCanceled) return null;

      try {
        final statusUri = Uri.parse('$baseUrl/api/v1/transfer/status').replace(
          queryParameters: {'fileId': item.fileId},
        );
        final statusReq = await _httpClient.getUrl(statusUri).timeout(const Duration(seconds: 3));
        statusReq.persistentConnection = false;
        final statusRes = await statusReq.close().timeout(const Duration(seconds: 3));
        final body = await utf8.decodeStream(statusRes);

        if (statusRes.statusCode == HttpStatus.ok) {
          final data = jsonDecode(body) as Map<String, dynamic>;
          return (data['transferredBytes'] as num?)?.toInt() ?? currentOffset;
        }

        if (statusRes.statusCode == HttpStatus.notFound) {
          final ok = await _performHandshake(baseUrl, token, authPin, sessionId: sessionId);
          if (ok) {
            final offsets = await _sendManifest(baseUrl, senderName, authPin, [item], sessionId: sessionId);
            return offsets[item.fileId] ?? 0;
          }
        }
      } catch (_) {
        // Still offline; continue waiting
      }
    }
    return null;
  }

  Future<bool> _uploadChunk({
    required String baseUrl,
    required String fileId,
    required int chunkIndex,
    required int totalChunks,
    required Uint8List chunkBytes,
    required String chunkSha256,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/transfer/chunk').replace(
      queryParameters: {
        'fileId': fileId,
        'chunkIndex': chunkIndex.toString(),
        'totalChunks': totalChunks.toString(),
        'sha256': chunkSha256,
      },
    );

    final request = await _httpClient.postUrl(uri);
    request.headers.contentType = ContentType.binary;
    request.contentLength = chunkBytes.length;

    request.add(chunkBytes);
    final response = await request.close();
    await response.drain<void>();

    return response.statusCode == HttpStatus.ok;
  }

  Future<bool> _finalizeFile(String baseUrl, String fileId, {String? expectedSha256}) async {
    final uri = Uri.parse('$baseUrl/api/v1/transfer/finalize');
    final request = await _httpClient.postUrl(uri);
    request.persistentConnection = false;
    request.headers.contentType = ContentType.json;

    request.write(jsonEncode({
      'fileId': fileId,
      if (expectedSha256 != null && expectedSha256.isNotEmpty) 'expectedSha256': expectedSha256,
    }));
    final response = await request.close();
    await response.drain<void>();

    return response.statusCode == HttpStatus.ok;
  }

  void dispose() {
    _httpClient.close(force: true);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
