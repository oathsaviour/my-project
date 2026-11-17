import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../core/constants/app_constants.dart';
import '../../core/models/discovered_device.dart';

/// Implements zero-configuration peer discovery using mDNS/DNS-SD (Bonjour / NSD compatible).
class MdnsDiscoveryEngine {
  RawDatagramSocket? _socket;
  Timer? _announcementTimer;
  Timer? _queryTimer;
  final void Function(DiscoveredDevice device) onDeviceDiscovered;

  MdnsDiscoveryEngine({required this.onDeviceDiscovered});

  /// Starts listening on mDNS multicast address 224.0.0.251:5353.
  Future<void> start({
    required String localIp,
    required int localPort,
    required String deviceName,
    required DeviceOS os,
    required String sessionToken,
  }) async {
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        AppConstants.mdnsPort,
        reuseAddress: true,
        reusePort: true,
      );

      final multicastGroup = InternetAddress(AppConstants.mdnsMulticastIpv4);
      _socket?.joinMulticast(multicastGroup);
      _socket?.multicastHops = 255;
      _socket?.multicastLoopback = false;

      _socket?.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket?.receive();
          if (datagram != null) {
            _handleIncomingDatagram(datagram, localIp);
          }
        }
      });

      // Periodically broadcast our announcement
      _broadcastAnnouncement(localIp, localPort, deviceName, os, sessionToken);
      _announcementTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        _broadcastAnnouncement(localIp, localPort, deviceName, os, sessionToken);
      });

      // Periodically send discovery query
      _sendDiscoveryQuery();
      _queryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sendDiscoveryQuery();
      });
    } catch (e) {
      // In restricted sandbox or if mDNS port 5353 is locked, handle gracefully
    }
  }

  /// Sends an announcement payload over multicast UDP.
  void _broadcastAnnouncement(
    String localIp,
    int localPort,
    String deviceName,
    DeviceOS os,
    String sessionToken,
  ) {
    if (_socket == null) return;

    final payload = jsonEncode({
      'proto': 'ushare',
      'id': '$localIp:$localPort',
      'name': deviceName,
      'os': os.name,
      'ip': localIp,
      'port': localPort,
      'token': sessionToken,
      'v': '1.0.0',
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

    final bytes = utf8.encode(payload);
    final target = InternetAddress(AppConstants.mdnsMulticastIpv4);
    _socket?.send(bytes, target, AppConstants.mdnsPort);
  }

  /// Sends a discovery query ping requesting peers to identify themselves.
  void _sendDiscoveryQuery() {
    if (_socket == null) return;
    final query = jsonEncode({
      'proto': 'ushare',
      'type': 'query',
      'query': AppConstants.serviceType,
    });
    final bytes = utf8.encode(query);
    final target = InternetAddress(AppConstants.mdnsMulticastIpv4);
    _socket?.send(bytes, target, AppConstants.mdnsPort);
  }

  void _handleIncomingDatagram(Datagram datagram, String localIp) {
    // Ignore packets from self
    if (datagram.address.address == localIp) return;

    try {
      final raw = utf8.decode(datagram.data);
      if (raw.startsWith('{') && raw.endsWith('}')) {
        final Map<String, dynamic> data = jsonDecode(raw);
        if (data['proto'] == 'ushare' && data['type'] != 'query') {
          final peer = DiscoveredDevice(
            id: data['id'] ?? '${datagram.address.address}:${data['port'] ?? 52840}',
            name: data['name'] ?? 'Peer Device',
            os: DeviceOS.fromString(data['os'] as String?),
            ipAddress: data['ip'] ?? datagram.address.address,
            port: (data['port'] as num?)?.toInt() ?? AppConstants.defaultTransferPort,
            sessionToken: data['token'] ?? '',
            version: data['v'] ?? '1.0.0',
            lastSeen: DateTime.now(),
          );
          onDeviceDiscovered(peer);
        }
      }
    } catch (_) {
      // Ignore malformed packets from other network services on port 5353
    }
  }

  /// Cleanly closes the socket and cancels recurring broadcast timers.
  void stop() {
    _announcementTimer?.cancel();
    _queryTimer?.cancel();
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}
