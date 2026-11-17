import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/models/discovered_device.dart';
import 'core/models/file_manifest.dart';
import 'core/models/transfer_session.dart';
import 'services/discovery/discovery_service.dart';
import 'services/storage/auto_save_router.dart';
import 'services/transfer/wake_lock_manager.dart';
import 'ui/screens/file_picker_hub.dart';
import 'ui/screens/hotspot_guide_screen.dart';
import 'ui/screens/qr_pairing_modal.dart';
import 'ui/screens/radar_screen.dart';
import 'ui/screens/transfer_queue_screen.dart';
import 'ui/theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize native platform channel bridges for MediaStore scoped storage & WakeLock
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
  TransferSession? _activeSession;

  // Sample peers for instant interaction & testing
  final List<DiscoveredDevice> _mockPeers = [
    DiscoveredDevice(
      id: 'mock_iphone_16_pro',
      name: "Alex's iPhone 16 Pro",
      os: DeviceOS.ios,
      ipAddress: '192.168.1.108',
      port: 52840,
      sessionToken: 'auth_ios_9421',
      version: '1.0.0',
      lastSeen: DateTime.now(),
      rssi: -52,
    ),
    DiscoveredDevice(
      id: 'mock_pixel_9_pro',
      name: 'Pixel 9 Pro XL',
      os: DeviceOS.android,
      ipAddress: '192.168.1.115',
      port: 52840,
      sessionToken: 'auth_android_7190',
      version: '1.0.0',
      lastSeen: DateTime.now(),
      rssi: -48,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  void _startDiscovery() async {
    await _discoveryManager.startDiscovery(
      localDeviceName: 'Pixel 9 / iPhone Device',
      localOs: DeviceOS.android,
      transferPort: 52840,
    );
  }

  @override
  void dispose() {
    _discoveryManager.dispose();
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
      authPin: '4829',
      files: files,
      startTime: DateTime.now(),
    );

    setState(() {
      _activeSession = session;
    });

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TransferQueueScreen(
          session: _activeSession!,
          onPause: () {
            setState(() {
              _activeSession = _activeSession?.copyWith(isPaused: true);
            });
          },
          onResume: () {
            setState(() {
              _activeSession = _activeSession?.copyWith(isPaused: false);
            });
          },
          onCancel: () {
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
      initialData: _mockPeers,
      builder: (context, snapshot) {
        final devices = snapshot.data?.isNotEmpty == true ? snapshot.data! : _mockPeers;

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
