import 'dart:convert';
import '../constants/app_constants.dart';
import '../models/discovered_device.dart';

/// Handles encoding and decoding of pairing QR codes for offline manual connection.
class QrPairingPayload {
  final String ip;
  final int port;
  final String token;
  final String pin;
  final String deviceName;
  final DeviceOS os;
  final String version;

  const QrPairingPayload({
    required this.ip,
    required this.port,
    required this.token,
    required this.pin,
    required this.deviceName,
    required this.os,
    this.version = '1.0.0',
  });

  /// Serializes into a standard URI string for QR code generation.
  String toUriString() {
    final uri = Uri(
      scheme: AppConstants.qrScheme,
      host: 'pair',
      queryParameters: {
        'ip': ip,
        'port': port.toString(),
        'token': token,
        'pin': pin,
        'name': deviceName,
        'os': os.name,
        'v': version,
      },
    );
    return uri.toString();
  }

  /// Parses a scanned QR code URI string into a strongly-typed payload.
  static QrPairingPayload? parse(String rawUri) {
    try {
      final uri = Uri.parse(rawUri.trim());
      if (uri.scheme != AppConstants.qrScheme && uri.scheme != 'http' && uri.scheme != 'https') {
        return null;
      }

      final params = uri.queryParameters;
      final ip = params['ip'] ?? uri.host;
      final port = int.tryParse(params['port'] ?? '') ?? AppConstants.defaultTransferPort;
      final token = params['token'] ?? '';
      final pin = params['pin'] ?? '';
      final name = params['name'] ?? 'Discovered Peer';
      final os = DeviceOS.fromString(params['os']);
      final version = params['v'] ?? '1.0.0';

      if (ip.isEmpty) return null;

      return QrPairingPayload(
        ip: ip,
        port: port,
        token: token,
        pin: pin,
        deviceName: name,
        os: os,
        version: version,
      );
    } catch (_) {
      return null;
    }
  }

  /// Converts this payload to a DiscoveredDevice model.
  DiscoveredDevice toDiscoveredDevice() {
    return DiscoveredDevice(
      id: 'qr_$ip:$port',
      name: deviceName,
      os: os,
      ipAddress: ip,
      port: port,
      sessionToken: token,
      version: version,
      lastSeen: DateTime.now(),
    );
  }
}
