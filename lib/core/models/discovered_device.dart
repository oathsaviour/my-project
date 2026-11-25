/// Discovery transport mechanism used to locate a peer.
enum DiscoveryTransport {
  localWifi,
  hotspot,
  nearbyP2p,
  manual;

  String get badgeLabel {
    switch (this) {
      case DiscoveryTransport.localWifi:
        return 'Local Wi-Fi';
      case DiscoveryTransport.hotspot:
        return 'Hotspot';
      case DiscoveryTransport.nearbyP2p:
        return 'Nearby P2P';
      case DiscoveryTransport.manual:
        return 'Direct';
    }
  }
}

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
  final DiscoveryTransport transport;
  final String? p2pAddress; // MAC/device address for Wi-Fi Direct / Nearby P2P

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
    this.transport = DiscoveryTransport.localWifi,
    this.p2pAddress,
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
        'transport': transport.name,
        if (p2pAddress != null) 'p2pAddress': p2pAddress,
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
        transport: DiscoveryTransport.values.firstWhere(
          (t) => t.name == json['transport'],
          orElse: () => DiscoveryTransport.localWifi,
        ),
        p2pAddress: json['p2pAddress'] as String?,
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
    DiscoveryTransport? transport,
    String? p2pAddress,
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
      transport: transport ?? this.transport,
      p2pAddress: p2pAddress ?? this.p2pAddress,
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
