import 'dart:async';
import 'dart:io';
import '../../core/models/discovered_device.dart';
import '../../core/security/qr_payload.dart';
import '../../core/security/pin_generator.dart';

/// Abstract discovery contract for peer detection.
abstract class IDiscoveryService {
  Stream<List<DiscoveredDevice>> get discoveredDevicesStream;
  List<DiscoveredDevice> get currentDevices;

  Future<void> startDiscovery({
    required String localDeviceName,
    required DeviceOS localOs,
    required int transferPort,
  });

  Future<void> stopDiscovery();

  void registerManualDevice(DiscoveredDevice device);
}

/// Central manager orchestrating local network IP resolution, mDNS discovery, and manual QR pairing.
class DiscoveryManager implements IDiscoveryService {
  final _devicesController = StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, DiscoveredDevice> _devices = {};

  String? _localIp;
  int _transferPort = 52840;
  String _sessionToken = '';
  String _verificationPin = '';
  String _localDeviceName = 'Device';
  DeviceOS _localOs = DeviceOS.android;
  bool _isDiscovering = false;

  @override
  Stream<List<DiscoveredDevice>> get discoveredDevicesStream => _devicesController.stream;

  @override
  List<DiscoveredDevice> get currentDevices => _devices.values.toList();

  String? get localIp => _localIp;
  int get transferPort => _transferPort;
  String get sessionToken => _sessionToken;
  String get verificationPin => _verificationPin;
  String get localDeviceName => _localDeviceName;
  DeviceOS get localOs => _localOs;
  bool get isDiscovering => _isDiscovering;

  /// Determines the active local IPv4 address (Wi-Fi or Hotspot interface).
  Future<String?> resolveLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        // Prioritize Wi-Fi and hotspot interfaces: wlan, ap, en0, etc.
        final name = interface.name.toLowerCase();
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            // Hotspot / Wi-Fi typical subnets: 192.168.*, 172.20.10.*, 10.*
            if (name.contains('wlan') || name.contains('ap') || name.contains('en0') || name.contains('eth')) {
              _localIp = addr.address;
              return _localIp;
            }
          }
        }
      }

      // Fallback: first non-loopback address
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            _localIp = addr.address;
            return _localIp;
          }
        }
      }
    } catch (_) {}

    _localIp = '127.0.0.1';
    return _localIp;
  }

  /// Generates the QR pairing payload for this device.
  QrPairingPayload getLocalQrPayload() {
    return QrPairingPayload(
      ip: _localIp ?? '127.0.0.1',
      port: _transferPort,
      token: _sessionToken,
      pin: _verificationPin,
      deviceName: _localDeviceName,
      os: _localOs,
    );
  }

  @override
  Future<void> startDiscovery({
    required String localDeviceName,
    required DeviceOS localOs,
    required int transferPort,
  }) async {
    _localDeviceName = localDeviceName;
    _localOs = localOs;
    _transferPort = transferPort;
    _sessionToken = PinGenerator.generateSessionToken(16);
    _verificationPin = PinGenerator.generate4DigitPin();
    _isDiscovering = true;

    await resolveLocalIp();
    _notifyDevices();
  }

  @override
  Future<void> stopDiscovery() async {
    _isDiscovering = false;
    _devices.clear();
    _notifyDevices();
  }

  /// Handles incoming device discovered via mDNS, BLE, or manual network ping.
  void addOrUpdateDevice(DiscoveredDevice device) {
    // Avoid discovering self
    if (device.ipAddress == _localIp && device.port == _transferPort) {
      return;
    }

    _devices[device.id] = device;
    _notifyDevices();
  }

  @override
  void registerManualDevice(DiscoveredDevice device) {
    addOrUpdateDevice(device);
  }

  /// Removes stale devices that haven't been seen recently.
  void pruneStaleDevices({Duration timeout = const Duration(seconds: 15)}) {
    final cutoff = DateTime.now().subtract(timeout);
    _devices.removeWhere((_, dev) => dev.lastSeen.isBefore(cutoff));
    _notifyDevices();
  }

  void _notifyDevices() {
    if (!_devicesController.isClosed) {
      _devicesController.add(_devices.values.toList());
    }
  }

  void dispose() {
    _devicesController.close();
  }
}
