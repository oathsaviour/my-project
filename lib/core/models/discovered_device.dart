import 'dart:convert';

/// Supported mobile operating systems for universal pairing.
enum DeviceOS {
  android,
  ios,
  desktop;

  String get label {
    switch (this) {
      case DeviceOS.android:
        return 'Android';
      case DeviceOS.ios:
        return 'Apple iOS';
      case DeviceOS.desktop:
        return 'Desktop';
    }
  }

  static DeviceOS fromString(String? val) {
    if (val == null) return DeviceOS.android;
    final lower = val.toLowerCase().trim();
    if (lower.contains('ios') || lower.contains('iphone') || lower.contains('ipad')) {
      return DeviceOS.ios;
    } else if (lower.contains('mac') || lower.contains('windows') || lower.contains('linux')) {
      return DeviceOS.desktop;
    }
    return DeviceOS.android;
  }
}

/// Represents a peer device discovered via mDNS/Bonjour, BLE, or QR code.
class DiscoveredDevice {
  final String id;
  final String name;
  final DeviceOS os;
  final String ipAddress;
  final int port;
  final String sessionToken;
  final String version;
  final DateTime lastSeen;
  final int? rssi; // Signal strength if discovered via BLE

  const DiscoveredDevice({
    required this.id,
    required this.name,
    required this.os,
    required this.ipAddress,
    required this.port,
    required this.sessionToken,
    this.version = '1.0.0',
    required this.lastSeen,
    this.rssi,
  });

  /// Factory from mDNS TXT record attributes and socket address.
  factory DiscoveredDevice.fromMdns({
    required String ip,
    required int port,
    required Map<String, String> txtAttributes,
  }) {
    return DiscoveredDevice(
      id: txtAttributes['id'] ?? ip,
      name: txtAttributes['name'] ?? 'Peer Device',
      os: DeviceOS.fromString(txtAttributes['os']),
      ipAddress: ip,
      port: int.tryParse(txtAttributes['port'] ?? '$port') ?? port,
      sessionToken: txtAttributes['token'] ?? '',
      version: txtAttributes['version'] ?? '1.0.0',
      lastSeen: DateTime.now(),
    );
  }

  /// Serialize to JSON for internal messaging and storage.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'os': os.name,
        'ipAddress': ipAddress,
        'port': port,
        'sessionToken': sessionToken,
        'version': version,
        'lastSeen': lastSeen.toIso8601String(),
        'rssi': rssi,
      };

  factory DiscoveredDevice.fromJson(Map<String, dynamic> json) => DiscoveredDevice(
        id: json['id'] as String,
        name: json['name'] as String,
        os: DeviceOS.fromString(json['os'] as String?),
        ipAddress: json['ipAddress'] as String,
        port: json['port'] as int,
        sessionToken: json['sessionToken'] as String? ?? '',
        version: json['version'] as String? ?? '1.0.0',
        lastSeen: DateTime.tryParse(json['lastSeen'] as String? ?? '') ?? DateTime.now(),
        rssi: json['rssi'] as int?,
      );

  DiscoveredDevice copyWith({
    String? id,
    String? name,
    DeviceOS? os,
    String? ipAddress,
    int? port,
    String? sessionToken,
    String? version,
    DateTime? lastSeen,
    int? rssi,
  }) {
    return DiscoveredDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      os: os ?? this.os,
      ipAddress: ipAddress ?? this.ipAddress,
      port: port ?? this.port,
      sessionToken: sessionToken ?? this.sessionToken,
      version: version ?? this.version,
      lastSeen: lastSeen ?? this.lastSeen,
      rssi: rssi ?? this.rssi,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredDevice &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          ipAddress == other.ipAddress;

  @override
  int get hashCode => id.hashCode ^ ipAddress.hashCode;
}
