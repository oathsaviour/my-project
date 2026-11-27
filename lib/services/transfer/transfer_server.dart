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

typedef SessionRequestCallback = Future<bool> Function(
  String sessionId,
  String peerName,
  String peerOs,
  String peerIp,
  int peerPort,
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
  final Set<String> _trustedSessions = {};
  final Map<String, String> _sessionPeerTokens = {};
  bool _wakeLockHeld = false;

  ProgressCallback? onProgress;
  ManifestReceivedCallback? onManifestReceived;
  void Function(String sessionId, String senderName, List<FileManifestItem> files)? onTrustedManifestStarted;
  SessionRequestCallback? onSessionRequested;
  void Function(String fileId, String finalPath, String sha256)? onFileCompleted;

  void trustSession(String sessionId) {
    if (sessionId.isNotEmpty) _trustedSessions.add(sessionId);
  }

  void revokeSession(String sessionId) {
    _trustedSessions.remove(sessionId);
    _sessionPeerTokens.remove(sessionId);
  }

  bool isSessionTrusted(String sessionId) => _trustedSessions.contains(sessionId);
  String? getSessionPeerToken(String sessionId) => _sessionPeerTokens[sessionId];

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
      if (path == '/api/v1/session/request') {
        await _handleSessionRequest(request);
      } else if (path == '/api/v1/transfer/handshake') {
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

  /// Handles mutual one-time session approval request.
  Future<void> _handleSessionRequest(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = jsonDecode(body) as Map<String, dynamic>;

    final sessionId = data['sessionId'] as String? ?? '';
    final peerName = data['peerName'] as String? ?? 'Nearby Peer';
    final peerOs = data['peerOs'] as String? ?? 'android';
    final declaredIp = data['peerIp'] as String? ?? '';
    final remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
    final peerIp = (declaredIp.isNotEmpty && declaredIp != '127.0.0.1')
        ? declaredIp
        : (remoteIp.isNotEmpty ? remoteIp : declaredIp);
    final peerPort = (data['peerPort'] as num?)?.toInt() ?? AppConstants.defaultTransferPort;
    final clientToken = data['token'] as String? ?? '';
    final peerToken = data['localToken'] as String? ?? '';
    final clientPin = data['pin'] as String? ?? '';

    bool authOk = _trustedSessions.contains(sessionId);
    if (!authOk) {
      if (_verificationPin.isNotEmpty && clientPin.isNotEmpty) {
        authOk = (clientPin == _verificationPin);
      } else if (_sessionToken.isNotEmpty && clientToken.isNotEmpty) {
        authOk = (clientToken == _sessionToken);
      } else if (clientPin.isEmpty && clientToken.isEmpty) {
        // Peer-initiated connection request from Radar / Wi-Fi Direct: rely on mutual user prompt
        authOk = true;
      }
    }

    if (!authOk) {
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.write(jsonEncode({'error': 'Invalid PIN or session token'}));
      await request.response.close();
      return;
    }

    if (sessionId.isNotEmpty && peerToken.isNotEmpty) {
      _sessionPeerTokens[sessionId] = peerToken;
    }

    if (!_trustedSessions.contains(sessionId) && onSessionRequested != null) {
      final accepted = await onSessionRequested!(
        sessionId,
        peerName,
        peerOs,
        peerIp,
        peerPort,
        clientPin,
      );
      if (!accepted) {
        _sessionPeerTokens.remove(sessionId);
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(jsonEncode({'error': 'Connection request declined'}));
        await request.response.close();
        return;
      }
    }

    if (sessionId.isNotEmpty) {
      _trustedSessions.add(sessionId);
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'status': 'trusted',
      'sessionId': sessionId,
      'token': _sessionToken,
    }));
    await request.response.close();
  }

  /// Validates session token, 4-digit PIN, or trusted sessionId.
  Future<void> _handleHandshake(HttpRequest request) async {
    final body = await utf8.decodeStream(request);
    final data = jsonDecode(body);

    final clientToken = data['token'] as String? ?? '';
    final clientPin = data['pin'] as String? ?? '';
    final sessionId = data['sessionId'] as String? ?? '';

    // Strictly verify trusted session, PIN, or session token
    bool isValid = false;
    if (sessionId.isNotEmpty && _trustedSessions.contains(sessionId)) {
      isValid = true;
    } else if (_verificationPin.isNotEmpty && clientPin.isNotEmpty) {
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
    final sessionId = data['sessionId'] as String? ?? '';
    final rawFiles = data['files'] as List<dynamic>? ?? [];

    final manifestItems = rawFiles.map((f) => FileManifestItem.fromJson(f)).toList();

    // Trigger receiver acceptance callback ONLY if not already trusted in this session and not resuming
    final isTrusted = sessionId.isNotEmpty && _trustedSessions.contains(sessionId);
    final isResume = manifestItems.isNotEmpty &&
        manifestItems.every((m) => _activeFiles.containsKey(m.fileId));
    if (isTrusted && !isResume) {
      onTrustedManifestStarted?.call(sessionId, senderName, manifestItems);
    } else if (onManifestReceived != null && !isTrusted && !isResume) {
      final accepted = await onManifestReceived!(senderName, manifestItems, pin);
      if (!accepted) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(jsonEncode({'error': 'Transfer rejected by receiver'}));
        await request.response.close();
        return;
      }
    }

    // Keep CPU and screen awake while receiving chunks
    if (!_wakeLockHeld) {
      _wakeLockHeld = true;
      await WakeLockManager.acquireWakeLock(reason: 'Receiving incoming file batch');
    }

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

      // Check for matching partial download for resume
      final checkpoint = await _resumeManager?.loadCheckpoint(item.fileId);
      if (checkpoint != null &&
          checkpoint.fileName == item.fileName &&
          checkpoint.totalBytes == item.fileSize &&
          await file.exists()) {
        final actualLength = await file.length();
        confirmedBytes = actualLength;
        confirmedChunks = checkpoint.confirmedChunks;
      } else {
        await _resumeManager?.deleteCheckpoint(item.fileId);
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
    final raf = _openFileHandles.remove(fileId);

    if (raf != null) {
      await raf.close();
    }

    // Step 1: Compute full-file SHA-256 using bounded streaming
    final computedSha256 = await ChecksumStream.computeFileSha256(tempPath);

    // Step 2: Verify checksum if expected hash was provided
    final expectedSha256 = (data['expectedSha256'] as String?) ?? item.expectedSha256;
    if (expectedSha256 != null && expectedSha256.isNotEmpty) {
      if (!ChecksumStream.verifyChecksum(computedSha256, expectedSha256)) {
        _activeFiles.remove(fileId);
        _tempFilePaths.remove(fileId);
        if (_openFileHandles.isEmpty && _wakeLockHeld) {
          _wakeLockHeld = false;
          await WakeLockManager.releaseWakeLock();
        }
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

    // Step 4: Clean up checkpoint & per-file active state so back-to-back sends stay clean
    await _resumeManager?.deleteCheckpoint(fileId);
    _activeFiles.remove(fileId);
    _tempFilePaths.remove(fileId);

    if (onFileCompleted != null) {
      onFileCompleted!(fileId, finalSavedPath, computedSha256);
    }

    // Release wake lock once no active incoming files remain open
    if (_openFileHandles.isEmpty && _wakeLockHeld) {
      _wakeLockHeld = false;
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
    _wakeLockHeld = false;
    await WakeLockManager.forceReleaseAll();
    for (final raf in _openFileHandles.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _openFileHandles.clear();
    _activeFiles.clear();
    _tempFilePaths.clear();
    _sessionPeerTokens.clear();

    try {
      await _server?.close(force: true);
    } catch (_) {}
    _server = null;
  }
}
