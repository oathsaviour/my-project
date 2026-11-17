import 'dart:convert';
import 'dart:typed_data';
import '../../core/models/discovered_device.dart';

/// Bluetooth Low Energy (BLE) payload specification and encoder/decoder.
class BleBeaconSpec {
  /// Custom 128-bit UUID for Universal Transfer Service
  static const String serviceUuid = 'a3bd1415-af5f-4c1f-a92b-611b18e77a76';

  /// 16-bit Company Identifier / Custom Prefix for manufacturer data: 0x5553 ('US')
  static const int manufacturerId = 0x5553;

  /// Encodes BLE advertisement payload:
  /// [1 byte OS: 1=Android, 2=iOS] [4 bytes IPv4] [2 bytes Port uint16] [4 bytes PIN ASCII] [UTF8 DeviceName]
  static Uint8List encodeAdvertisementData({
    required DeviceOS os,
    required String ipAddress,
    required int port,
    required String pin,
    required String deviceName,
  }) {
    final ipParts = ipAddress.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (ipParts.length < 4) {
      ipParts.add(0);
    }

    final nameBytes = utf8.encode(deviceName);
    final pinBytes = utf8.encode(pin.padRight(4).substring(0, 4));

    final totalSize = 1 + 4 + 2 + 4 + nameBytes.length;
    final buffer = Uint8List(totalSize);
    final bd = ByteData.sublistView(buffer);

    // Byte 0: OS
    buffer[0] = os == DeviceOS.android ? 1 : (os == DeviceOS.ios ? 2 : 3);

    // Bytes 1..4: IPv4
    for (int i = 0; i < 4; i++) {
      buffer[1 + i] = ipParts[i];
    }

    // Bytes 5..6: Port uint16
    bd.setUint16(5, port, Endian.big);

    // Bytes 7..10: PIN (4 chars)
    for (int i = 0; i < 4; i++) {
      buffer[7 + i] = pinBytes[i];
    }

    // Bytes 11..End: Name
    buffer.setRange(11, totalSize, nameBytes);

    return buffer;
  }

  /// Decodes BLE advertisement payload into a DiscoveredDevice model.
  static DiscoveredDevice? decodeAdvertisementData(Uint8List data, {int? rssi}) {
    if (data.length < 11) return null;

    final bd = ByteData.sublistView(data);

    final osCode = data[0];
    final os = osCode == 1 ? DeviceOS.android : (osCode == 2 ? DeviceOS.ios : DeviceOS.desktop);

    final ip = '${data[1]}.${data[2]}.${data[3]}.${data[4]}';
    final port = bd.getUint16(5, Endian.big);
    final pin = utf8.decode(data.sublist(7, 11));

    String name = 'Nearby Peer';
    if (data.length > 11) {
      name = utf8.decode(data.sublist(11));
    }

    return DiscoveredDevice(
      id: 'ble_$ip:$port',
      name: name,
      os: os,
      ipAddress: ip,
      port: port,
      sessionToken: pin,
      version: '1.0.0',
      lastSeen: DateTime.now(),
      rssi: rssi,
    );
  }
}
