import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../core/models/discovered_device.dart';
import '../../core/security/qr_payload.dart';
import '../../core/security/pin_generator.dart';
import 'mdns_discovery.dart';

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

class DiscoveryManager implements IDiscoveryService {
  static const int discoveryUdpPort = 52841;

  final _devicesController = StreamController<List<DiscoveredDevice>>.broadcast();
  final Map<String, DiscoveredDevice> _devices = {};

  RawDatagramSocket? _udpSocket;
  MdnsDiscoveryEngine? _mdnsEngine;
  Timer? _beaconTimer;
  Timer? _pruneTimer;

  String? _localIp;
  int _transferPort = 52840;
  String _sessionToken = '';
  String _verificationPin = '';
  String _localDeviceName = 'Device';
  String _localDeviceId = '';
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

  Future<String?> resolveLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        for (final addr in interface.addresses) {
          if (!addr.isLoopback &&
              (name.contains('wlan') ||
                  name.contains('wi-fi') ||
                  name.contains('wifi') ||
                  name.contains('swlan') ||
                  name.contains('ap') ||
                  name.contains('bridge') ||
                  name.contains('en0') ||
                  name.contains('eth'))) {
            _localIp = addr.address;
            return _localIp;
          }
        }
      }

      // Prefer private RFC1918 LAN addresses over virtual/tunnel interfaces
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && _isPrivateLanIp(addr.address)) {
            _localIp = addr.address;
            return _localIp;
          }
        }
      }

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
    _localDeviceId = '${localOs.name}_${DateTime.now().millisecondsSinceEpoch}';
    _isDiscovering = true;

    await resolveLocalIp();
    await _startUdpBeacon();
    await _startMdnsDiscovery();
    _notifyDevices();
  }

  bool _isPrivateLanIp(String ip) {
    return ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.').hasMatch(ip);
  }

  Future<void> _startMdnsDiscovery() async {
    _mdnsEngine?.stop();
    _mdnsEngine = MdnsDiscoveryEngine(
      onDeviceDiscovered: (device) {
        if (device.ipAddress != _localIp) {
          addOrUpdateDevice(device);
        }
      },
    );
    await _mdnsEngine!.start(
      localIp: _localIp ?? '127.0.0.1',
      localPort: _transferPort,
      deviceName: _localDeviceName,
      os: _localOs,
      sessionToken: _sessionToken,
    );
  }

  Future<void> _startUdpBeacon() async {
    try {
      _udpSocket?.close();
      try {
        _udpSocket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryUdpPort,
          reuseAddress: true,
          reusePort: true,
        );
      } catch (_) {
        try {
          // Windows and some Android versions do not support SO_REUSEPORT
          _udpSocket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            discoveryUdpPort,
            reuseAddress: true,
          );
        } catch (_) {
          // Fallback to ephemeral port so outbound hotspot unicast pings still work
          _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        }
      }
      _udpSocket!.broadcastEnabled = true;

      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket?.receive();
          if (datagram == null) return;
          _handleIncomingBeacon(datagram);
        }
      });

      // Broadcast our presence every 2 seconds
      _beaconTimer?.cancel();
      _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sendBeacon());
      _sendBeacon();

      // Remove offline peers after 10 seconds
      _pruneTimer?.cancel();
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        pruneStaleDevices(timeout: const Duration(seconds: 10));
      });
    } catch (_) {}
  }

  Future<void> refreshDiscovery() async {
    await resolveLocalIp();
    _sendBeacon();
  }

  Uint8List _buildBeaconBytes({bool isReply = false}) {
    final payload = jsonEncode({
      'magic': 'USHR_DISCOVERY_V1',
      'id': _localDeviceId,
      'name': _localDeviceName,
      'os': _localOs.name,
      'ip': _localIp ?? '127.0.0.1',
      'port': _transferPort,
      'token': _sessionToken,
      'pin': _verificationPin,
      'reply': isReply,
      'version': '1.0.0',
    });
    return Uint8List.fromList(utf8.encode(payload));
  }

  void _sendBeacon() async {
    if (_udpSocket == null || !_isDiscovering) return;
    await resolveLocalIp();

    final bytes = _buildBeaconBytes();

    // 1. Global broadcast & subnet broadcast (Shared Wi-Fi Router)
    try {
      _udpSocket!.send(bytes, InternetAddress('255.255.255.255'), discoveryUdpPort);
    } catch (_) {}

    final unicastTargets = <String>{
      '192.168.43.1', // Android Hotspot host
      '192.168.49.1', // Wi-Fi Direct / Android P2P host
      '172.20.10.1', // iPhone Personal Hotspot host
    };

    if (_localIp != null && _localIp!.contains('.')) {
      final parts = _localIp!.split('.');
      if (parts.length == 4) {
        final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
        final subnetGateway = '${parts[0]}.${parts[1]}.${parts[2]}.1';
        unicastTargets.add(subnetGateway);
        try {
          _udpSocket!.send(bytes, InternetAddress(subnetBroadcast), discoveryUdpPort);
        } catch (_) {}
      }
    }

    // 2. Unicast pings to Hotspot gateways (bypasses AP broadcast filtering)
    for (final targetIp in unicastTargets) {
      if (targetIp == _localIp) continue;
      try {
        _udpSocket!.send(bytes, InternetAddress(targetIp), discoveryUdpPort);
      } catch (_) {}
    }
  }

  void _handleIncomingBeacon(Datagram datagram) {
    try {
      final text = utf8.decode(datagram.data);
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['magic'] != 'USHR_DISCOVERY_V1') return;

      final senderId = data['id'] as String? ?? '';
      if (senderId.isEmpty || senderId == _localDeviceId) return;

      final senderIp = datagram.address.address;
      if (senderIp == _localIp) return;

      final osStr = (data['os'] as String? ?? 'android').toLowerCase();
      final os = osStr == 'ios' ? DeviceOS.ios : DeviceOS.android;

      final device = DiscoveredDevice(
        id: senderId,
        name: data['name'] as String? ?? 'Nearby Device',
        os: os,
        ipAddress: senderIp,
        port: (data['port'] as num?)?.toInt() ?? 52840,
        sessionToken: data['token'] as String? ?? '',
        version: data['version'] as String? ?? '1.0.0',
        lastSeen: DateTime.now(),
        rssi: -45,
      );

      addOrUpdateDevice(device);

      // Immediately reply unicast to the sender so Hotspot hosts/clients pair in <1s
      if (data['reply'] != true && _udpSocket != null) {
        try {
          _udpSocket!.send(
            _buildBeaconBytes(isReply: true),
            datagram.address,
            datagram.port,
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Future<void> stopDiscovery() async {
    _isDiscovering = false;
    _beaconTimer?.cancel();
    _pruneTimer?.cancel();
    _mdnsEngine?.stop();
    _mdnsEngine = null;
    _udpSocket?.close();
    _udpSocket = null;
    _devices.clear();
    _notifyDevices();
  }

  void addOrUpdateDevice(DiscoveredDevice device) {
    if (device.ipAddress == _localIp && device.port == _transferPort) return;
    _devices[device.id] = device;
    _notifyDevices();
  }

  @override
  void registerManualDevice(DiscoveredDevice device) {
    addOrUpdateDevice(device);
  }

  void pruneStaleDevices({Duration timeout = const Duration(seconds: 10)}) {
    final cutoff = DateTime.now().subtract(timeout);
    final before = _devices.length;
    _devices.removeWhere((_, dev) => dev.lastSeen.isBefore(cutoff));
    if (_devices.length != before) {
      _notifyDevices();
    }
  }

  void _notifyDevices() {
    if (!_devicesController.isClosed) {
      _devicesController.add(_devices.values.toList());
    }
  }

  void dispose() {
    _beaconTimer?.cancel();
    _pruneTimer?.cancel();
    _udpSocket?.close();
    _devicesController.close();
  }
}
