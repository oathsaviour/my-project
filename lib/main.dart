import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'core/models/discovered_device.dart';
import 'core/models/file_manifest.dart';
import 'core/models/transfer_session.dart';
import 'core/security/qr_payload.dart';
import 'core/utils/formatters.dart';
import 'core/utils/speed_calculator.dart';
import 'services/discovery/discovery_service.dart';
import 'services/storage/auto_save_router.dart';
import 'services/transfer/transfer_client.dart';
import 'services/transfer/transfer_server.dart';
import 'services/transfer/wake_lock_manager.dart';
import 'ui/screens/file_picker_hub.dart';
import 'ui/screens/hotspot_guide_screen.dart';
import 'ui/screens/qr_pairing_modal.dart';
import 'ui/screens/radar_screen.dart';
import 'ui/screens/transfer_queue_screen.dart';
import 'ui/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.universal.filetransfer/native');
  WakeLockManager.nativeChannelInvoker = <T>(method, [args]) => channel.invokeMethod<T>(method, args);
  AutoSaveRouter.nativeChannelInvoker = <T>(method, [args]) => channel.invokeMethod<T>(method, args);
  DiscoveryManager.nativeChannelInvoker = <T>(method, [args]) => channel.invokeMethod<T>(method, args);

  runApp(const UniversalTransferApp());
}

class UniversalTransferApp extends StatelessWidget {
  const UniversalTransferApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal File Transfer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainAppShell(),
    );
  }
}

class MainAppShell extends StatefulWidget {
  const MainAppShell({super.key});

  @override
  State<MainAppShell> createState() => _MainAppShellState();
}

class _MainAppShellState extends State<MainAppShell> with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.universal.filetransfer/native');

  final DiscoveryManager _discoveryManager = DiscoveryManager();
  final TransferServer _transferServer = TransferServer();
  final TransferClient _transferClient = TransferClient();
  final ValueNotifier<TransferSession?> _activeSessionNotifier = ValueNotifier<TransferSession?>(null);
  final SpeedCalculator _incomingSpeedCalculator = SpeedCalculator();

  RadioStates? _radioStates;
  bool _isQueueScreenOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handleNativeCallback);
    _initServices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _discoveryManager.refreshDiscovery().then((_) async {
        final states = await _discoveryManager.checkRadioStates();
        if (mounted) setState(() => _radioStates = states);
      });
    }
  }

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    final args = call.arguments as Map<dynamic, dynamic>?;
    if (args == null) return;
    switch (call.method) {
      case 'onNsdPeerFound':
        _discoveryManager.handleNativeNsdPeer(args);
        break;
      case 'onP2pPeerFound':
        _discoveryManager.handleNativeP2pPeer(args);
        break;
      case 'onBlePeerFound':
        _discoveryManager.handleNativeBlePeer(args);
        break;
      case 'onP2pConnected':
        await _discoveryManager.handleNativeP2pConnected(args);
        break;
    }
  }

  Future<void> _initServices() async {
    await _requestRuntimePermissions();

    final tempDir = await getTemporaryDirectory();
    final localOs = Platform.isIOS ? DeviceOS.ios : DeviceOS.android;
    final deviceName = Platform.isIOS ? 'iPhone (Universal)' : 'Android (${Platform.localHostname})';

    await _discoveryManager.startDiscovery(
      localDeviceName: deviceName,
      localOs: localOs,
      transferPort: 52840,
    );

    final states = await _discoveryManager.checkRadioStates();

    _transferServer.onSessionRequested = _handleIncomingSessionRequest;
    _transferServer.onManifestReceived = _handleIncomingManifest;
    _transferServer.onTrustedManifestStarted = _handleTrustedManifestStarted;
    _transferServer.onProgress = _handleIncomingProgress;
    _transferServer.onFileCompleted = _handleIncomingFileCompleted;

    await _transferServer.start(
      sessionToken: _discoveryManager.sessionToken,
      verificationPin: _discoveryManager.verificationPin,
      tempStorageDir: tempDir.path,
      initialPort: 52840,
    );

    if (mounted) {
      setState(() => _radioStates = states);
    }
  }

  /// Mutual one-time approval on receiver when a peer initiates a session.
  Future<bool> _handleIncomingSessionRequest(
    String sessionId,
    String peerName,
    String peerOs,
    String peerIp,
    int peerPort,
    String authPin,
  ) async {
    if (!mounted) return false;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        title: const Text('Connection Request', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '$peerName ($peerIp) wants to establish a two-way file sharing session.\n\n'
          'Once accepted, both devices can send and receive files freely without repeated prompts.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Decline', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentNeon,
              foregroundColor: AppTheme.darkBackground,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (accepted == true && mounted) {
      final peerToken = _transferServer.getSessionPeerToken(sessionId) ?? '';
      final peer = DiscoveredDevice(
        id: 'trusted_$peerIp',
        name: peerName,
        os: DeviceOS.fromString(peerOs),
        ipAddress: peerIp,
        port: peerPort,
        sessionToken: peerToken,
        lastSeen: DateTime.now(),
      );
      _activeSessionNotifier.value = TransferSession(
        sessionId: sessionId,
        peer: peer,
        direction: TransferDirection.incoming,
        authPin: authPin,
        files: const [],
        startTime: DateTime.now(),
      );
      _openSessionWorkspace();
    }

    return accepted == true;
  }

  /// Updates the active trusted session UI immediately when an incoming batch begins.
  void _handleTrustedManifestStarted(
    String sessionId,
    String senderName,
    List<FileManifestItem> files,
  ) {
    if (!mounted) return;
    _incomingSpeedCalculator.reset();
    final existing = _activeSessionNotifier.value;
    if (existing != null) {
      _activeSessionNotifier.value = existing.copyWith(
        direction: TransferDirection.incoming,
        files: files,
        activeFileIndex: 0,
        currentSpeedBytesPerSec: 0,
        estimatedTimeRemaining: null,
        startTime: DateTime.now(),
      );
    } else {
      _activeSessionNotifier.value = TransferSession(
        sessionId: sessionId,
        peer: DiscoveredDevice(
          id: 'trusted_peer_$sessionId',
          name: senderName,
          os: DeviceOS.android,
          ipAddress: '',
          port: _transferServer.port,
          sessionToken: _transferServer.getSessionPeerToken(sessionId) ?? '',
          lastSeen: DateTime.now(),
        ),
        direction: TransferDirection.incoming,
        authPin: '',
        files: files,
        startTime: DateTime.now(),
      );
    }
    _openSessionWorkspace();
  }

  /// Fallback per-batch prompt only if sender did not establish a trusted session first.
  Future<bool> _handleIncomingManifest(
    String senderName,
    List<FileManifestItem> files,
    String authPin,
  ) async {
    if (!mounted) return false;

    final existing = _activeSessionNotifier.value;
    if (existing != null && _transferServer.isSessionTrusted(existing.sessionId)) {
      _incomingSpeedCalculator.reset();
      _activeSessionNotifier.value = existing.copyWith(
        direction: TransferDirection.incoming,
        files: files,
        startTime: DateTime.now(),
      );
      _openSessionWorkspace();
      return true;
    }

    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.fileSize);
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        title: const Text('Incoming File Transfer', style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$senderName wants to send ${files.length} file(s) (${Formatters.formatBytes(totalBytes)}):',
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            ...files.take(5).map(
                  (f) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• ${f.fileName} (${Formatters.formatBytes(f.fileSize)})',
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            if (files.length > 5)
              Text(
                '...and ${files.length - 5} more',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Decline', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentNeon,
              foregroundColor: AppTheme.darkBackground,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (accepted == true && mounted) {
      _incomingSpeedCalculator.reset();
      _activeSessionNotifier.value = TransferSession(
        sessionId: 'recv_${DateTime.now().millisecondsSinceEpoch}',
        peer: DiscoveredDevice(
          id: 'incoming_peer',
          name: senderName,
          os: DeviceOS.android,
          ipAddress: '',
          port: _transferServer.port,
          sessionToken: '',
          version: '1.0.0',
          lastSeen: DateTime.now(),
        ),
        direction: TransferDirection.incoming,
        authPin: authPin,
        files: files,
        startTime: DateTime.now(),
      );
      _openSessionWorkspace();
    }

    return accepted == true;
  }

  void _handleIncomingProgress(
    String fileId,
    int transferredBytes,
    int totalBytes,
    int currentChunk,
    int totalChunks,
  ) {
    final current = _activeSessionNotifier.value;
    if (!mounted || current == null || !current.files.any((f) => f.fileId == fileId)) return;

    int activeIdx = current.activeFileIndex;
    final updatedFiles = <FileManifestItem>[];
    for (int i = 0; i < current.files.length; i++) {
      final f = current.files[i];
      if (f.fileId == fileId) {
        activeIdx = i;
        updatedFiles.add(
          f.copyWith(
            transferredBytes: transferredBytes,
            confirmedChunks: currentChunk,
            status: TransferStatus.inProgress,
          ),
        );
      } else {
        updatedFiles.add(f);
      }
    }

    final totalTransferred = updatedFiles.fold<int>(0, (sum, f) => sum + f.transferredBytes);
    final totalRemaining = (current.totalBytes - totalTransferred).clamp(0, current.totalBytes);
    _incomingSpeedCalculator.recordProgress(totalTransferred);
    final speedMb = _incomingSpeedCalculator.getSpeedMegaBytesPerSecond();
    final eta = _incomingSpeedCalculator.calculateEta(totalRemaining);

    _activeSessionNotifier.value = current.copyWith(
      files: updatedFiles,
      activeFileIndex: activeIdx,
      currentSpeedBytesPerSec: speedMb * 1024 * 1024,
      estimatedTimeRemaining: eta,
    );
  }

  void _handleIncomingFileCompleted(String fileId, String finalPath, String sha256) {
    final current = _activeSessionNotifier.value;
    if (current != null && current.files.any((f) => f.fileId == fileId)) {
      final updatedFiles = current.files.map((f) {
        if (f.fileId == fileId) {
          return f.copyWith(
            transferredBytes: f.fileSize,
            confirmedChunks: f.totalChunks,
            status: TransferStatus.completed,
            actualSha256: sha256,
          );
        }
        return f;
      }).toList();
      _activeSessionNotifier.value = current.copyWith(
        files: updatedFiles,
        currentSpeedBytesPerSec: 0,
        estimatedTimeRemaining: Duration.zero,
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('File received & saved: $finalPath')),
    );
  }

  Future<void> _requestRuntimePermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.nearbyWifiDevices,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
        Permission.photos,
        Permission.videos,
        Permission.audio,
        Permission.notification,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.photos,
      ].request();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _activeSessionNotifier.dispose();
    _discoveryManager.dispose();
    _transferServer.stop();
    _transferClient.dispose();
    super.dispose();
  }

  /// Mutual one-time pairing flow before opening the bidirectional session workspace.
  Future<void> _onSelectDevice(DiscoveredDevice device, {String authPin = ''}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        title: const Text('Connection Request', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Connect to ${device.name} (${device.transport.badgeLabel}) for two-way file sharing?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentNeon,
              foregroundColor: AppTheme.darkBackground,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    DiscoveredDevice target = device;

    // If discovered via Wi-Fi Direct without an IP yet, form P2P group first
    if (target.ipAddress.isEmpty) {
      if (target.p2pAddress == null || target.p2pAddress!.isEmpty) {
        await _discoveryManager.refreshDiscovery();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Resolving Wi-Fi Direct address for ${target.name}. Tap again or use QR Code.')),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connecting via Wi-Fi Direct to ${target.name}...')),
      );
      final peerIp = await _discoveryManager.connectP2pPeer(target.p2pAddress!);
      if (!mounted) return;
      if (peerIp == null || peerIp.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wi-Fi Direct pairing failed. Try QR code or Hotspot.')),
        );
        return;
      }
      target = target.copyWith(ipAddress: peerIp);
    }

    final sessionId = 'sess_${DateTime.now().millisecondsSinceEpoch}';
    final peerToken = await _transferClient.requestMutualSession(
      targetDevice: target,
      sessionId: sessionId,
      localName: _discoveryManager.localDeviceName,
      localOs: _discoveryManager.localOs,
      localIp: _discoveryManager.localIp ?? '',
      localPort: _transferServer.port,
      authPin: authPin,
      localToken: _discoveryManager.sessionToken,
    );

    if (!mounted) return;
    if (peerToken == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Peer declined or could not be reached.')),
      );
      return;
    }

    _transferServer.trustSession(sessionId);
    final trustedTarget = peerToken.isNotEmpty ? target.copyWith(sessionToken: peerToken) : target;

    _activeSessionNotifier.value = TransferSession(
      sessionId: sessionId,
      peer: trustedTarget,
      direction: TransferDirection.outgoing,
      authPin: authPin,
      files: const [],
      startTime: DateTime.now(),
    );

    _openFilePickerForSession(trustedTarget, sessionId, authPin);
  }

  void _openFilePickerForSession(DiscoveredDevice peer, String sessionId, String authPin) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilePickerHubScreen(
          targetDevice: peer,
          onConfirmSend: (selectedFiles) {
            Navigator.of(context).pop();
            _startTransferBatch(peer, selectedFiles, sessionId: sessionId, authPin: authPin);
          },
        ),
      ),
    );
  }

  void _openSessionWorkspace() {
    if (_isQueueScreenOpen || !mounted) return;
    _isQueueScreenOpen = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ValueListenableBuilder<TransferSession?>(
              valueListenable: _activeSessionNotifier,
              builder: (context, session, __) {
                if (session == null) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                return TransferQueueScreen(
                  session: session,
                  onPause: () {
                    _transferClient.pause();
                    _activeSessionNotifier.value = session.copyWith(isPaused: true);
                  },
                  onResume: () {
                    _transferClient.resume();
                    _activeSessionNotifier.value = session.copyWith(isPaused: false);
                  },
                  onCancel: () {
                    _transferClient.cancel();
                    _activeSessionNotifier.value = null;
                    Navigator.of(context).pop();
                  },
                  onDone: () {
                    _transferServer.revokeSession(session.sessionId);
                    _activeSessionNotifier.value = null;
                    Navigator.of(context).pop();
                  },
                  onSendMore: session.peer.ipAddress.isNotEmpty
                      ? () => _openFilePickerForSession(
                            session.peer,
                            session.sessionId,
                            session.authPin,
                          )
                      : null,
                );
              },
            ),
          ),
        )
        .whenComplete(() {
      _isQueueScreenOpen = false;
    });
  }

  void _startTransferBatch(
    DiscoveredDevice peer,
    List<FileManifestItem> files, {
    required String sessionId,
    String authPin = '',
  }) {
    final session = TransferSession(
      sessionId: sessionId,
      peer: peer,
      direction: TransferDirection.outgoing,
      authPin: authPin,
      files: files,
      startTime: DateTime.now(),
    );

    _activeSessionNotifier.value = session;

    _transferClient.onProgress = (fileId, transferred, total, speedMb, eta, status) {
      final current = _activeSessionNotifier.value;
      if (!mounted || current == null) return;

      int activeIdx = current.activeFileIndex;
      final updatedFiles = <FileManifestItem>[];
      for (int i = 0; i < current.files.length; i++) {
        final f = current.files[i];
        if (f.fileId == fileId) {
          activeIdx = i;
          final chunks = f.chunkSize > 0 ? ((transferred + f.chunkSize - 1) ~/ f.chunkSize) : f.totalChunks;
          updatedFiles.add(
            f.copyWith(
              transferredBytes: transferred,
              confirmedChunks: chunks.clamp(0, f.totalChunks),
              status: status,
            ),
          );
        } else {
          updatedFiles.add(f);
        }
      }

      _activeSessionNotifier.value = current.copyWith(
        files: updatedFiles,
        activeFileIndex: activeIdx,
        currentSpeedBytesPerSec: speedMb * 1024 * 1024,
        estimatedTimeRemaining: eta,
      );
    };

    _transferClient.onError = (fileId, error) {
      final current = _activeSessionNotifier.value;
      if (!mounted || current == null) return;

      final updatedFiles = current.files.map((f) {
        if (f.fileId == fileId) {
          return f.copyWith(status: TransferStatus.failed, errorMessage: error);
        }
        return f;
      }).toList();

      _activeSessionNotifier.value = current.copyWith(
        files: updatedFiles,
        currentSpeedBytesPerSec: 0,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transfer error: $error')),
      );
    };

    _transferClient
        .sendFiles(
          targetDevice: peer,
          senderName: _discoveryManager.localDeviceName,
          authPin: authPin,
          filesToSend: files,
          sessionId: sessionId,
        )
        .catchError((Object e) {
      final current = _activeSessionNotifier.value;
      if (mounted && current != null) {
        final updatedFiles = current.files
            .map((f) => f.isCompleted
                ? f
                : f.copyWith(status: TransferStatus.failed, errorMessage: e.toString()))
            .toList();
        _activeSessionNotifier.value = current.copyWith(
          files: updatedFiles,
          currentSpeedBytesPerSec: 0,
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
      return false;
    });

    _openSessionWorkspace();
  }

  Future<QrPairingPayload?> _startOfflineHotspotForQr() async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>('startLocalOnlyHotspot');
      if (res == null) return null;
      final ssid = res['ssid'] as String? ?? '';
      final passphrase = res['passphrase'] as String? ?? '';
      final ip = res['ip'] as String? ?? (_discoveryManager.localIp ?? '192.168.43.1');
      return _discoveryManager.getLocalQrPayload(
        wifiSsid: ssid,
        wifiPassword: passphrase,
      ).let((p) => QrPairingPayload(
            ip: ip,
            port: p.port,
            token: p.token,
            pin: p.pin,
            deviceName: p.deviceName,
            os: p.os,
            wifiSsid: ssid,
            wifiPassword: passphrase,
          ));
    } catch (_) {
      return null;
    }
  }

  Future<void> _openQrPairing() async {
    await _discoveryManager.resolveLocalIp();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QrPairingModal(
        localPayload: _discoveryManager.getLocalQrPayload(),
        onStartOfflineHotspot: Platform.isAndroid ? _startOfflineHotspotForQr : null,
        onPeerScanned: (payload) async {
          if (payload.wifiSsid != null &&
              payload.wifiSsid!.isNotEmpty &&
              payload.wifiPassword != null &&
              payload.wifiPassword!.isNotEmpty &&
              Platform.isAndroid) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Joining offline hotspot ${payload.wifiSsid}...')),
            );
            try {
              await _channel.invokeMethod('connectToWifiHotspot', {
                'ssid': payload.wifiSsid,
                'passphrase': payload.wifiPassword,
              });
            } catch (_) {}
          }
          final device = payload.toDiscoveredDevice();
          _discoveryManager.registerManualDevice(device);
          await _onSelectDevice(device, authPin: payload.pin);
        },
      ),
    );
  }

  void _openHotspotGuide() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HotspotGuideScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<DiscoveredDevice>>(
      stream: _discoveryManager.discoveredDevicesStream,
      initialData: _discoveryManager.currentDevices,
      builder: (context, snapshot) {
        final devices = snapshot.data ?? [];

        return RadarScreen(
          discoveredDevices: devices,
          isScanning: _discoveryManager.isDiscovering,
          onSelectDevice: _onSelectDevice,
          onOpenQrPairing: _openQrPairing,
          onOpenHotspotGuide: _openHotspotGuide,
          onRefresh: _discoveryManager.refreshDiscovery,
          radioStates: _radioStates,
          onEnableRadio: _discoveryManager.openRadioSettings,
        );
      },
    );
  }
}

extension _LetExt<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
