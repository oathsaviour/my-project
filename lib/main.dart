import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'core/models/discovered_device.dart';
import 'core/models/file_manifest.dart';
import 'core/models/transfer_session.dart';
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
  const UniversalTransferApp({Key? key}) : super(key: key);

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
  const MainAppShell({Key? key}) : super(key: key);

  @override
  State<MainAppShell> createState() => _MainAppShellState();
}

class _MainAppShellState extends State<MainAppShell> {
  final DiscoveryManager _discoveryManager = DiscoveryManager();
  final TransferServer _transferServer = TransferServer();
  final TransferClient _transferClient = TransferClient();
  TransferSession? _activeSession;

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

    _transferServer.onFileCompleted = (fileId, finalPath, sha256) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('File received & saved: $finalPath')),
      );
    };

    await _transferServer.start(
      sessionToken: _discoveryManager.sessionToken,
      verificationPin: '',
      tempStorageDir: tempDir.path,
      initialPort: 52840,
    );

    if (mounted) setState(() {});
  }

  Future<void> _requestRuntimePermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.nearbyWifiDevices,
        Permission.locationWhenInUse,
        Permission.camera,
        Permission.photos,
        Permission.videos,
        Permission.audio,
        Permission.storage,
      ].request();
    } else if (Platform.isIOS) {
      await [
        Permission.camera,
        Permission.photos,
      ].request();
    }
  }

  @override
  void dispose() {
    _discoveryManager.dispose();
    _transferServer.stop();
    _transferClient.dispose();
    super.dispose();
  }

  void _onSelectDevice(DiscoveredDevice device) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FilePickerHubScreen(
          targetDevice: device,
          onConfirmSend: (selectedFiles) {
            Navigator.of(context).pop();
            _startTransferSession(device, selectedFiles);
          },
        ),
      ),
    );
  }

  void _startTransferSession(DiscoveredDevice peer, List<FileManifestItem> files) {
    final session = TransferSession(
      sessionId: 'sess_${DateTime.now().millisecondsSinceEpoch}',
      peer: peer,
      direction: TransferDirection.outgoing,
      authPin: '',
      files: files,
      startTime: DateTime.now(),
    );

    setState(() {
      _activeSession = session;
    });

    _transferClient.onProgress = (fileId, transferred, total, speedMb, eta, status) {
      if (!mounted || _activeSession == null) return;
      final updatedFiles = _activeSession!.files.map((f) {
        if (f.fileId == fileId) {
          return f.copyWith(transferredBytes: transferred, status: status);
        }
        return f;
      }).toList();

      setState(() {
        _activeSession = _activeSession!.copyWith(
          files: updatedFiles,
        );
      });
    };

    _transferClient.sendFiles(
      targetDevice: peer,
      senderName: _discoveryManager.localDeviceName,
      authPin: '',
      filesToSend: files,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferQueueScreen(
          session: _activeSession!,
          onPause: () {
            _transferClient.pause();
            setState(() {
              _activeSession = _activeSession?.copyWith(isPaused: true);
            });
          },
          onResume: () {
            _transferClient.resume();
            setState(() {
              _activeSession = _activeSession?.copyWith(isPaused: false);
            });
          },
          onCancel: () {
            _transferClient.cancel();
            setState(() {
              _activeSession = null;
            });
            Navigator.of(context).pop();
          },
          onDone: () {
            setState(() {
              _activeSession = null;
            });
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  void _openQrPairing() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QrPairingModal(
        localPayload: _discoveryManager.getLocalQrPayload(),
        onPeerScanned: (payload) {
          final device = payload.toDiscoveredDevice();
          _discoveryManager.registerManualDevice(device);
          _onSelectDevice(device);
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
        );
      },
    );
  }
}
