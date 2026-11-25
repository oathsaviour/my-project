import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/file_manifest.dart';
import '../../core/utils/checksum_stream.dart';
import '../storage/auto_save_router.dart';
import 'resume_manager.dart';
import 'wake_lock_manager.dart';

typedef ProgressCallback = void Function(
  String fileId,
  int transferredBytes,
  int totalBytes,
  int currentChunk,
  int totalChunks,
);

typedef ManifestReceivedCallback = Future<bool> Function(
  String senderName,
  List<FileManifestItem> files,
  String authPin,
);

/// Embedded high-speed streaming server running directly on the receiving mobile device.
class TransferServer {
  HttpServer? _server;
  int _port = AppConstants.defaultTransferPort;
  String _sessionToken = '';
  String _verificationPin = '';
  String _tempStorageDir = '';

  ResumeManager? _resumeManager;
  final Map<String, FileManifestItem> _activeFiles = {};
  final Map<String, RandomAccessFile> _openFileHandles = {};
  final Map<String, String> _tempFilePaths = {};

  ProgressCallback? onProgress;
  ManifestReceivedCallback? onManifestReceived;
  void Function(String fileId, String finalPath, String sha256)? onFileCompleted;

  int get port => _port;
  bool get isRunning => _server != null;

  /// Starts the embedded HTTP server.
  Future<int> start({
    required String sessionToken,
    required String verificationPin,
    required String tempStorageDir,
    int initialPort = AppConstants.defaultTransferPort,
  }) async {
    _sessionToken = sessionToken;
    _verificationPin = verificationPin;
    _tempStorageDir = tempStorageDir;
    _resumeManager = ResumeManager(storageDirectory: tempStorageDir);

    int attemptPort = initialPort;
    while (_server == null && attemptPort < initialPort + 50) {
      try {
        _server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          attemptPort,
          shared: true,
        );
        _port = attemptPort;
      } catch (_) {
        attemptPort++;
      }
    }

    if (_server == null) {
      throw const SocketException('Could not bind TransferServer to any available port');
    }

    _server?.listen(_handleRequest);
    return _port;
  }

  void _handleRequest(HttpRequest request) async {
    // Add CORS headers for testing / web clients
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (path == '/api/v1/transfer/handshake') {
        await _handleHandshake(request);
      } else if (path == '/api/v1/transfer/manifest') {
        await _handleManifest(request);
      } else if (path == '/api/v1/transfer/chunk') {
        await _handleChunk(request);
      } else if (path == '/api/v1/transfer/status') {
        await _handleStatus(request);
      } else if (path == '/api/v1/transfer/finalize') {
        await _handleFinalize(request);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('Endpoint not found');
        await request.response.close();
      }
    } catch (e) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(jsonEncode({'error': e.toString()}));
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Validates session token and 4-digit PIN.
  Future<void> _handleHandshake(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = jsonDecode(body);

    final clientToken = data['token'] as String? ?? '';
    final clientPin = data['pin'] as String? ?? '';

    // Strictly verify PIN or session token
    bool isValid = false;
    if (_verificationPin.isNotEmpty && clientPin.isNotEmpty) {
      isValid = (clientPin == _verificationPin);
    } else if (_sessionToken.isNotEmpty && clientToken.isNotEmpty) {
      isValid = (clientToken == _sessionToken);
    } else if (_verificationPin.isEmpty && _sessionToken.isEmpty) {
      isValid = true;
    }

    if (!isValid) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(jsonEncode({'error': 'Invalid PIN or session token'}));
      await request.response.close();
      return;
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'accepted',
      'supportedProtocols': ['chunked-http-v1', 'ushr-binary-v1'],
      'chunkSize': AppConstants.defaultChunkSize,
    }));
    await request.response.close();
  }

  /// Processes pre-flight file manifest and queries resume offsets.
  Future<void> _handleManifest(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = jsonDecode(body);

    final senderName = data['senderName'] as String? ?? 'Peer';
    final pin = data['pin'] as String? ?? '';
    final rawFiles = data['files'] as List<dynamic>? ?? [];

    final manifestItems = rawFiles.map((f) => FileManifestItem.fromJson(f)).toList();

    // Trigger receiver acceptance callback (skip prompt when resuming an already-accepted file)
    final isResume = manifestItems.isNotEmpty &&
        manifestItems.every((m) => _activeFiles.containsKey(m.fileId));
    if (onManifestReceived != null && !isResume) {
      final accepted = await onManifestReceived!(senderName, manifestItems, pin);
      if (!accepted) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(jsonEncode({'error': 'Transfer rejected by receiver'}));
        await request.response.close();
        return;
      }
    }

    // Keep CPU and screen awake while receiving chunks
    await WakeLockManager.acquireWakeLock(reason: 'Receiving incoming file batch');

    final responseFiles = <Map<String, dynamic>>[];

    for (final item in manifestItems) {
      final existingHandle = _openFileHandles.remove(item.fileId);
      if (existingHandle != null) {
        try {
          await existingHandle.close();
        } catch (_) {}
      }

      final tempPath = '$_tempStorageDir/${item.fileId}.part';
      _tempFilePaths[item.fileId] = tempPath;

      final file = File(tempPath);
      int confirmedBytes = 0;
      int confirmedChunks = 0;

      // Check for existing partial download for resume
      final checkpoint = await _resumeManager?.loadCheckpoint(item.fileId);
      if (checkpoint != null && await file.exists()) {
        final actualLength = await file.length();
        confirmedBytes = actualLength;
        confirmedChunks = checkpoint.confirmedChunks;
      } else {
        // Create or truncate fresh part file
        await file.create(recursive: true);
      }

      _activeFiles[item.fileId] = item.copyWith(
        transferredBytes: confirmedBytes,
        confirmedChunks: confirmedChunks,
      );

      final raf = await file.open(
        mode: confirmedBytes > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      _openFileHandles[item.fileId] = raf;

      responseFiles.add({
        'fileId': item.fileId,
        'resumeOffsetBytes': confirmedBytes,
        'confirmedChunks': confirmedChunks,
      });
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'ready',
      'files': responseFiles,
    }));
    await request.response.close();
  }

  /// Receives a discrete file chunk and writes it directly to disk via streaming I/O.
  Future<void> _handleChunk(HttpRequest request) async {
    final fileId = request.uri.queryParameters['fileId'];
    final chunkIndex = int.tryParse(request.uri.queryParameters['chunkIndex'] ?? '');
    final totalChunks = int.tryParse(request.uri.queryParameters['totalChunks'] ?? '');
    final expectedChunkSha256 = request.uri.queryParameters['sha256'];

    if (fileId == null || chunkIndex == null || !_activeFiles.containsKey(fileId)) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Invalid fileId or chunkIndex'}));
      await request.response.close();
      return;
    }

    final raf = _openFileHandles[fileId];
    if (raf == null) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write(jsonEncode({'error': 'File handle not open'}));
      await request.response.close();
      return;
    }

    // Read payload bytes from request stream
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    final chunkBytes = builder.takeBytes();

    // Verify chunk-level SHA256 if provided
    if (expectedChunkSha256 != null && expectedChunkSha256.isNotEmpty) {
      final actualHash = sha256.convert(chunkBytes).toString();
      if (!ChecksumStream.verifyChecksum(actualHash, expectedChunkSha256)) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'error': 'Chunk checksum mismatch'}));
        await request.response.close();
        return;
      }
    }

    final item = _activeFiles[fileId]!;
    final chunkOffset = chunkIndex * item.chunkSize;

    // Write directly to disk at exact chunk offset (idempotent on retry/resume)
    await raf.setPosition(chunkOffset);
    await raf.writeFrom(chunkBytes);
    await raf.flush();

    final endOffset = chunkOffset + chunkBytes.length;
    final updatedTransferred =
        endOffset > item.transferredBytes ? endOffset : item.transferredBytes;
    final updatedConfirmedChunks = chunkIndex + 1;

    _activeFiles[fileId] = item.copyWith(
      transferredBytes: updatedTransferred,
      confirmedChunks: updatedConfirmedChunks,
      status: TransferStatus.inProgress,
    );

    // Save checkpoint for resume safety
    await _resumeManager?.saveCheckpoint(ResumeCheckpoint(
      fileId: fileId,
      fileName: item.fileName,
      totalBytes: item.fileSize,
      transferredBytes: updatedTransferred,
      confirmedChunks: updatedConfirmedChunks,
      totalChunks: totalChunks ?? item.totalChunks,
      tempFilePath: _tempFilePaths[fileId] ?? '',
      expectedSha256: item.expectedSha256 ?? '',
    ));

    // Notify progress listener
    if (onProgress != null) {
      onProgress!(fileId, updatedTransferred, item.fileSize, updatedConfirmedChunks, totalChunks ?? item.totalChunks);
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'chunk_ack',
      'chunkIndex': chunkIndex,
      'receivedBytes': chunkBytes.length,
    }));
    await request.response.close();
  }

  /// Returns current confirmed transfer status for resume negotiation.
  Future<void> _handleStatus(HttpRequest request) async {
    final fileId = request.uri.queryParameters['fileId'];
    if (fileId == null || !_activeFiles.containsKey(fileId)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final item = _activeFiles[fileId]!;
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'fileId': item.fileId,
      'transferredBytes': item.transferredBytes,
      'confirmedChunks': item.confirmedChunks,
      'totalChunks': item.totalChunks,
      'status': item.status.name,
    }));
    await request.response.close();
  }

  /// Finalizes the transfer: verifies full-file SHA-256 and routes to auto-save location.
  Future<void> _handleFinalize(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = jsonDecode(body);
    final fileId = data['fileId'] as String?;

    if (fileId == null || !_activeFiles.containsKey(fileId)) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(jsonEncode({'error': 'Invalid fileId for finalize'}));
      await request.response.close();
      return;
    }

    final item = _activeFiles[fileId]!;
    final tempPath = _tempFilePaths[fileId]!;
    final raf = _openFileHandles[fileId];

    if (raf != null) {
      await raf.close();
      _openFileHandles.remove(fileId);
    }

    // Step 1: Compute full-file SHA-256 using bounded streaming
    final computedSha256 = await ChecksumStream.computeFileSha256(tempPath);

    // Step 2: Verify checksum if expected hash was provided
    final expectedSha256 = (data['expectedSha256'] as String?) ?? item.expectedSha256;
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      if (!ChecksumStream.verifyChecksum(computedSha256, expectedSha256)) {
        request.response.statusCode = HttpStatus.expectationFailed;
        request.response.write(jsonEncode({
          'error': 'File SHA-256 mismatch',
          'expected': expectedSha256,
          'actual': computedSha256,
        }));
        await request.response.close();
        return;
      }
    }

    // Step 3: Route file to Gallery or Downloads/UniversalShare
    final finalSavedPath = await AutoSaveRouter.routeReceivedFile(
      tempFilePath: tempPath,
      fileName: item.fileName,
      category: item.category,
      mimeType: item.mimeType,
    );

    // Step 4: Clean up checkpoint
    await _resumeManager?.deleteCheckpoint(fileId);

    _activeFiles[fileId] = item.copyWith(
      status: TransferStatus.completed,
      actualSha256: computedSha256,
    );

    if (onFileCompleted != null) {
      onFileCompleted!(fileId, finalSavedPath, computedSha256);
    }

    // Release wake lock if all files in the batch are finished
    if (_activeFiles.values.every((f) => f.status == TransferStatus.completed)) {
      await WakeLockManager.releaseWakeLock();
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'verified_and_saved',
      'fileId': fileId,
      'finalPath': finalSavedPath,
      'sha256': computedSha256,
    }));
    await request.response.close();
  }

  /// Shuts down the server and cleans up active handles.
  Future<void> stop() async {
    await WakeLockManager.forceReleaseAll();
    for (final raf in _openFileHandles.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _openFileHandles.clear();

    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }
}
