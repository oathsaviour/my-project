import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'core/models/discovered_device.dart';
import 'core/models/file_manifest.dart';
import 'core/models/transfer_session.dart';
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

class _MainAppShellState extends State<MainAppShell> {
  final DiscoveryManager _discoveryManager = DiscoveryManager();
  final TransferServer _transferServer = TransferServer();
  final TransferClient _transferClient = TransferClient();
  final ValueNotifier<TransferSession?> _activeSessionNotifier = ValueNotifier<TransferSession?>(null);
  final SpeedCalculator _incomingSpeedCalculator = SpeedCalculator();

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    await _requestRuntimePermissions();

    const channel = MethodChannel('com.universal.filetransfer/native');
    try {
      await channel.invokeMethod('acquireMulticastLock');
    } catch (_) {}

    final tempDir = await getTemporaryDirectory();
    final localOs = Platform.isIOS ? DeviceOS.ios : DeviceOS.android;
    final deviceName = Platform.isIOS ? 'iPhone (Universal)' : 'Android (${Platform.localHostname})';

    await _discoveryManager.startDiscovery(
      localDeviceName: deviceName,
      localOs: localOs,
      transferPort: 52840,
    );

    _transferServer.onManifestReceived = _handleIncomingManifest;
    _transferServer.onProgress = _handleIncomingProgress;
    _transferServer.onFileCompleted = _handleIncomingFileCompleted;

    await _transferServer.start(
      sessionToken: _discoveryManager.sessionToken,
      verificationPin: _discoveryManager.verificationPin,
      tempStorageDir: tempDir.path,
      initialPort: 52840,
    );

    if (mounted) setState(() {});
  }

  Future<bool> _handleIncomingManifest(
    String senderName,
    List<FileManifestItem> files,
    String authPin,
  ) async {
    if (!mounted) return false;

    final totalBytes = files.fold<int>(0, (sum, f) => sum + f.fileSize);
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        title: const Text(
          'Incoming File Transfer',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
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
      final incomingSession = TransferSession(
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
      _activeSessionNotifier.value = incomingSession;
      _pushTransferQueueScreen();
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
    if (!mounted || current == null || current.direction != TransferDirection.incoming) return;

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
    if (current != null && current.direction == TransferDirection.incoming) {
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
    _activeSessionNotifier.dispose();
    _discoveryManager.dispose();
    _transferServer.stop();
    _transferClient.dispose();
    super.dispose();
  }

  void _onSelectDevice(DiscoveredDevice device, {String authPin = ''}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilePickerHubScreen(
          targetDevice: device,
          onConfirmSend: (selectedFiles) {
            Navigator.of(context).pop();
            _startTransferSession(device, selectedFiles, authPin: authPin);
          },
        ),
      ),
    );
  }

  void _pushTransferQueueScreen() {
    Navigator.of(context).push(
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
                _activeSessionNotifier.value = null;
                Navigator.of(context).pop();
              },
              onSendMore: session.direction == TransferDirection.outgoing
                  ? () {
                      final peer = session.peer;
                      final pin = session.authPin;
                      _activeSessionNotifier.value = null;
                      Navigator.of(context).pop();
                      _onSelectDevice(peer, authPin: pin);
                    }
                  : null,
            );
          },
        ),
      ),
    );
  }

  void _startTransferSession(
    DiscoveredDevice peer,
    List<FileManifestItem> files, {
    String authPin = '',
  }) {
    final session = TransferSession(
      sessionId: 'sess_${DateTime.now().millisecondsSinceEpoch}',
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

    _pushTransferQueueScreen();
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
        onPeerScanned: (payload) {
          final device = payload.toDiscoveredDevice();
          _discoveryManager.registerManualDevice(device);
          _onSelectDevice(device, authPin: payload.pin);
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
        );
      },
    );
  }
}
