import 'package:test/test.dart';
import '../lib/core/models/discovered_device.dart';
import '../lib/core/security/qr_payload.dart';
import '../lib/services/discovery/ble_beacon.dart';

void main() {
  group('Discovery & Pairing Payload Parser Tests', () {
    test('Parses mDNS TXT attributes into DiscoveredDevice model', () {
      final txtAttributes = {
        'id': 'pixel-9-pro-uuid',
        'name': 'Pixel 9 Pro',
        'os': 'android',
        'port': '52840',
        'token': 'auth_sec_token_882',
        'version': '1.0.0',
      };

      final device = DiscoveredDevice.fromMdns(
        ip: '192.168.1.105',
        port: 52840,
        txtAttributes: txtAttributes,
      );

      expect(device.id, equals('pixel-9-pro-uuid'));
      expect(device.name, equals('Pixel 9 Pro'));
      expect(device.os, equals(DeviceOS.android));
      expect(device.ipAddress, equals('192.168.1.105'));
      expect(device.port, equals(52840));
      expect(device.sessionToken, equals('auth_sec_token_882'));
    });

    test('Encodes and decodes QR pairing URI payload for hotspot mode', () {
      final original = QrPairingPayload(
        ip: '172.20.10.1',
        port: 52840,
        token: 'ios_hotspot_token_99',
        pin: '5829',
        deviceName: "Alex's iPhone 16",
        os: DeviceOS.ios,
      );

      final uriString = original.toUriString();
      expect(uriString, contains('ushare://pair?'));
      expect(uriString, contains('ip=172.20.10.1'));
      expect(uriString, contains('pin=5829'));

      final parsed = QrPairingPayload.parse(uriString);
      expect(parsed, isNotNull);
      expect(parsed!.ip, equals('172.20.10.1'));
      expect(parsed.port, equals(52840));
      expect(parsed.pin, equals('5829'));
      expect(parsed.token, equals('ios_hotspot_token_99'));
      expect(parsed.deviceName, equals("Alex's iPhone 16"));
      expect(parsed.os, equals(DeviceOS.ios));
    });

    test('Encodes and decodes BLE beacon advertisement bytes', () {
      final bytes = BleBeaconSpec.encodeAdvertisementData(
        os: DeviceOS.ios,
        ipAddress: '192.168.43.1',
        port: 52840,
        pin: '7231',
        deviceName: 'iPhone 15 Pro',
      );

      final decoded = BleBeaconSpec.decodeAdvertisementData(bytes, rssi: -45);
      expect(decoded, isNotNull);
      expect(decoded!.os, equals(DeviceOS.ios));
      expect(decoded.ipAddress, equals('192.168.43.1'));
      expect(decoded.port, equals(52840));
      expect(decoded.name, equals('iPhone 15 Pro'));
      expect(decoded.sessionToken, equals('7231'));
      expect(decoded.rssi, equals(-45));
    });
  });
}
