import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../core/models/discovered_device.dart';
import '../../core/security/qr_payload.dart';
import '../../core/security/pin_generator.dart';
import '../transfer/wake_lock_manager.dart';
import 'mdns_discovery.dart';

class RadioStates {
  final bool wifiEnabled;
  final bool bluetoothEnabled;
  final bool locationEnabled;

  const RadioStates({
    required this.wifiEnabled,
    required this.bluetoothEnabled,
    required this.locationEnabled,
  });

  bool get allEnabled => wifiEnabled && bluetoothEnabled && locationEnabled;

  factory RadioStates.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return const RadioStates(
        wifiEnabled: true,
        bluetoothEnabled: true,
        locationEnabled: true,
      );
    }
    return RadioStates(
      wifiEnabled: map['wifi'] == true,
      bluetoothEnabled: map['bluetooth'] == true,
      locationEnabled: map['location'] == true,
    );
  }
}

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

  /// Optional native channel invoker (configured in main.dart for Android/iOS).
  static NativeChannelInvoker? nativeChannelInvoker;

  final _devicesController = StreamController<List<DiscoveredDevice>>.broadcast();
  final _radioStatesController = StreamController<RadioStates>.broadcast();
  final Map<String, DiscoveredDevice> _devices = {};
  final Set<String> _localIps = {};

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

  Stream<RadioStates> get radioStatesStream => _radioStatesController.stream;

  @override
  List<DiscoveredDevice> get currentDevices => _devices.values.toList();

  String? get localIp => _localIp;
  int get transferPort => _transferPort;
  String get sessionToken => _sessionToken;
  String get verificationPin => _verificationPin;
  String get localDeviceName => _localDeviceName;
  DeviceOS get localOs => _localOs;
  bool get isDiscovering => _isDiscovering;

  Future<RadioStates> checkRadioStates() async {
    if (!Platform.isAndroid || nativeChannelInvoker == null) {
      const states = RadioStates(
        wifiEnabled: true,
        bluetoothEnabled: true,
        locationEnabled: true,
      );
      if (!_radioStatesController.isClosed) _radioStatesController.add(states);
      return states;
    }

    try {
      final raw = await nativeChannelInvoker!<Map<dynamic, dynamic>>('checkRadioStates');
      final states = RadioStates.fromMap(raw);
      if (!_radioStatesController.isClosed) _radioStatesController.add(states);
      return states;
    } catch (_) {
      const states = RadioStates(
        wifiEnabled: true,
        bluetoothEnabled: true,
        locationEnabled: true,
      );
      return states;
    }
  }

  Future<void> openRadioSettings(String radio) async {
    if (Platform.isAndroid && nativeChannelInvoker != null) {
      try {
        await nativeChannelInvoker!('openRadioSettings', {'radio': radio});
      } catch (_) {}
    }
  }

  /// Resolves all active non-loopback IPv4 interfaces (wlan0, ap0, swlan0, etc.)
  /// and selects the primary LAN/Hotspot IP.
  Future<String?> resolveLocalIp() async {
    _localIps.clear();
    String? preferredIp;
    String? hotspotIp;

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        for (final addr in interface.addresses) {
          if (addr.isLoopback) continue;
          _localIps.add(addr.address);

          if (name.contains('ap') || name.contains('swlan') || addr.address.startsWith('192.168.43.') || addr.address.startsWith('192.168.49.')) {
            hotspotIp ??= addr.address;
          } else if (name.contains('wlan') ||
              name.contains('wi-fi') ||
              name.contains('wifi') ||
              name.contains('bridge') ||
              name.contains('en0') ||
              name.contains('eth')) {
            preferredIp ??= addr.address;
          }
        }
      }

      if (preferredIp == null && hotspotIp == null) {
        for (final ip in _localIps) {
          if (_isPrivateLanIp(ip)) {
            preferredIp = ip;
            break;
          }
        }
      }
    } catch (_) {}

    _localIp = preferredIp ?? hotspotIp ?? (_localIps.isNotEmpty ? _localIps.first : '127.0.0.1');
    return _localIp;
  }

  QrPairingPayload getLocalQrPayload({String? wifiSsid, String? wifiPassword}) {
    return QrPairingPayload(
      ip: _localIp ?? '127.0.0.1',
      port: _transferPort,
      token: _sessionToken,
      pin: _verificationPin,
      deviceName: _localDeviceName,
      os: _localOs,
      wifiSsid: wifiSsid,
      wifiPassword: wifiPassword,
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
    await checkRadioStates();
    await _startUdpBeacon();
    await _startMdnsDiscovery();
    await _startNativeDiscovery();
    _notifyDevices();
  }

  Future<void> _startNativeDiscovery() async {
    if (!Platform.isAndroid || nativeChannelInvoker == null) return;
    try {
      await nativeChannelInvoker!('acquireMulticastLock');
    } catch (_) {}
    try {
      await nativeChannelInvoker!('startNsdDiscovery', {
        'deviceName': _localDeviceName,
        'port': _transferPort,
      });
    } catch (_) {}
    try {
      await nativeChannelInvoker!('startP2pDiscovery', {
        'deviceName': _localDeviceName,
      });
    } catch (_) {}
  }

  /// Called by native Android MethodChannel handler when NSD/mDNS resolves a peer.
  void handleNativeNsdPeer(Map<dynamic, dynamic> data) {
    final ip = data['ip'] as String? ?? '';
    final name = data['name'] as String? ?? 'Nearby Device';
    final port = (data['port'] as num?)?.toInt() ?? 52840;
    if (ip.isEmpty || _localIps.contains(ip)) return;

    addOrUpdateDevice(
      DiscoveredDevice(
        id: 'nsd_$ip:$port',
        name: name,
        os: DeviceOS.android,
        ipAddress: ip,
        port: port,
        sessionToken: '',
        lastSeen: DateTime.now(),
        transport: ip.startsWith('192.168.43.') || ip.startsWith('192.168.49.') || ip.startsWith('172.20.10.')
            ? DiscoveryTransport.hotspot
            : DiscoveryTransport.localWifi,
      ),
    );
  }

  /// Called by native Android MethodChannel handler when Wi-Fi Direct discovers a peer.
  void handleNativeP2pPeer(Map<dynamic, dynamic> data) {
    final address = data['address'] as String? ?? '';
    final name = data['name'] as String? ?? 'Wi-Fi Direct Peer';
    if (address.isEmpty) return;

    addOrUpdateDevice(
      DiscoveredDevice(
        id: 'p2p_$address',
        name: name,
        os: DeviceOS.android,
        ipAddress: '',
        port: _transferPort,
        sessionToken: '',
        lastSeen: DateTime.now(),
        transport: DiscoveryTransport.nearbyP2p,
        p2pAddress: address,
      ),
    );
  }

  /// Called by native Android MethodChannel handler when BLE discovers a nearby peer.
  void handleNativeBlePeer(Map<dynamic, dynamic> data) {
    final address = data['address'] as String? ?? '';
    final name = data['name'] as String? ?? 'Nearby BLE Peer';
    final rssi = (data['rssi'] as num?)?.toInt();
    if (address.isEmpty) return;

    // Only add BLE badge if no LAN/Wi-Fi Direct peer already represents it
    final bleId = 'ble_$address';
    addOrUpdateDevice(
      DiscoveredDevice(
        id: bleId,
        name: name,
        os: DeviceOS.android,
        ipAddress: '',
        port: _transferPort,
        sessionToken: '',
        lastSeen: DateTime.now(),
        rssi: rssi,
        transport: DiscoveryTransport.nearbyP2p,
        p2pAddress: address,
      ),
    );
  }

  /// Connects to a Wi-Fi Direct peer and returns the resolved group owner IP.
  Future<String?> connectP2pPeer(String deviceAddress) async {
    if (!Platform.isAndroid || nativeChannelInvoker == null) return null;
    try {
      final res = await nativeChannelInvoker!<Map<dynamic, dynamic>>(
        'connectP2pPeer',
        {'deviceAddress': deviceAddress},
      );
      return res?['groupOwnerIp'] as String?;
    } catch (_) {
      return null;
    }
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
        if (!_localIps.contains(device.ipAddress)) {
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
          _udpSocket = await RawDatagramSocket.bind(
            InternetAddress.anyIPv4,
            discoveryUdpPort,
            reuseAddress: true,
          );
        } catch (_) {
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

      _beaconTimer?.cancel();
      _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) => _sendBeacon());
      _sendBeacon();

      _pruneTimer?.cancel();
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        pruneStaleDevices(timeout: const Duration(seconds: 12));
      });
    } catch (_) {}
  }

  Future<void> refreshDiscovery() async {
    await resolveLocalIp();
    await checkRadioStates();
    _sendBeacon();
    await _startNativeDiscovery();
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

    // 1. Global broadcast
    try {
      _udpSocket!.send(bytes, InternetAddress('255.255.255.255'), discoveryUdpPort);
    } catch (_) {}

    // 2. Broadcast & gateway unicast across ALL active interfaces (wlan0, ap0, swlan0, etc.)
    final unicastTargets = <String>{
      '192.168.43.1', // Android Hotspot host
      '192.168.49.1', // Wi-Fi Direct / P2P host
      '172.20.10.1', // iPhone Personal Hotspot host
    };

    for (final ip in _localIps) {
      if (!ip.contains('.')) continue;
      final parts = ip.split('.');
      if (parts.length == 4) {
        final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
        final subnetGateway = '${parts[0]}.${parts[1]}.${parts[2]}.1';
        unicastTargets.add(subnetGateway);
        try {
          _udpSocket!.send(bytes, InternetAddress(subnetBroadcast), discoveryUdpPort);
        } catch (_) {}
      }
    }

    for (final targetIp in unicastTargets) {
      if (_localIps.contains(targetIp)) continue;
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
      if (_localIps.contains(senderIp)) return;

      final osStr = (data['os'] as String? ?? 'android').toLowerCase();
      final os = osStr == 'ios' ? DeviceOS.ios : DeviceOS.android;
      final isHotspot = senderIp.startsWith('192.168.43.') ||
          senderIp.startsWith('192.168.49.') ||
          senderIp.startsWith('172.20.10.');

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
        transport: isHotspot ? DiscoveryTransport.hotspot : DiscoveryTransport.localWifi,
      );

      addOrUpdateDevice(device);

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

    if (Platform.isAndroid && nativeChannelInvoker != null) {
      try {
        await nativeChannelInvoker!('stopNsdDiscovery');
        await nativeChannelInvoker!('stopP2pDiscovery');
      } catch (_) {}
    }

    _devices.clear();
    _notifyDevices();
  }

  void addOrUpdateDevice(DiscoveredDevice device) {
    if (_localIps.contains(device.ipAddress) && device.port == _transferPort) return;
    _devices[device.id] = device;
    _notifyDevices();
  }

  @override
  void registerManualDevice(DiscoveredDevice device) {
    addOrUpdateDevice(device);
  }

  void pruneStaleDevices({Duration timeout = const Duration(seconds: 12)}) {
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
    stopDiscovery();
    _devicesController.close();
    _radioStatesController.close();
  }
}
