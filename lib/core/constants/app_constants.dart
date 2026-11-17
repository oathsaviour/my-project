/// Core application constants for Universal File Transfer.
class AppConstants {
  /// Default TCP port for high-speed streaming transfers.
  static const int defaultTransferPort = 52840;

  /// Default UDP port for mDNS peer discovery.
  static const int mdnsPort = 5353;

  /// mDNS multicast IPv4 address.
  static const String mdnsMulticastIpv4 = '224.0.0.251';

  /// Standard Bonjour / mDNS service type for universal cross-platform discovery.
  static const String serviceType = '_universal-share._tcp.local';

  /// Legacy service alias for backward compatibility.
  static const String legacyServiceType = '_filetransfer._tcp.local';

  /// Streaming chunk size: 2MB (2,097,152 bytes) - balances socket throughput,
  /// low memory footprint, and low resume penalties.
  static const int defaultChunkSize = 2 * 1024 * 1024;

  /// Maximum in-memory read buffer size.
  static const int streamBufferSize = 64 * 1024; // 64KB

  /// Handshake and socket connection timeout.
  static const Duration connectTimeout = Duration(seconds: 10);

  /// Heartbeat interval between paired transfer endpoints.
  static const Duration heartbeatInterval = Duration(seconds: 3);

  /// Directory name inside Downloads / Documents for received raw files.
  static const String universalShareFolder = 'UniversalShare';

  /// Custom URL scheme for instant QR code pairing.
  static const String qrScheme = 'ushare';
}
