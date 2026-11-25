import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_file_transfer/core/models/discovered_device.dart';
import 'package:universal_file_transfer/core/models/file_manifest.dart';
import 'package:universal_file_transfer/core/security/qr_payload.dart';
import 'package:universal_file_transfer/services/discovery/discovery_service.dart';
import 'package:universal_file_transfer/services/storage/auto_save_router.dart';
import 'package:universal_file_transfer/services/transfer/transfer_client.dart';
import 'package:universal_file_transfer/services/transfer/transfer_server.dart';

void main() {
  group('Hybrid P2P Discovery & Radio State Tests', () {
    test('RadioStates parses disabled radios cleanly', () {
      final states = RadioStates.fromMap({
        'wifi': true,
        'bluetooth': false,
        'location': true,
      });
      expect(states.wifiEnabled, isTrue);
      expect(states.bluetoothEnabled, isFalse);
      expect(states.locationEnabled, isTrue);
      expect(states.allEnabled, isFalse);
    });

    test('DiscoveryManager handles P2P, BLE, and NSD peers with transport badges', () async {
      final manager = DiscoveryManager();
      final emitted = <List<DiscoveredDevice>>[];
      final sub = manager.discoveredDevicesStream.listen(emitted.add);

      manager.handleNativeP2pPeer({
        'name': 'Pixel 8 Pro',
        'address': 'aa:bb:cc:dd:ee:ff',
      });
      manager.handleNativeBlePeer({
        'name': 'Galaxy S24',
        'address': '11:22:33:44:55:66',
        'rssi': -52,
      });
      manager.handleNativeNsdPeer({
        'name': 'iPhone 15',
        'ip': '192.168.1.42',
        'port': 52840,
      });

      await Future.delayed(const Duration(milliseconds: 50));
      expect(manager.currentDevices.length, 3);
      expect(
        manager.currentDevices.where((d) => d.transport == DiscoveryTransport.nearbyP2p).length,
        2,
      );
      expect(
        manager.currentDevices.firstWhere((d) => d.ipAddress == '192.168.1.42').transport,
        DiscoveryTransport.localWifi,
      );

      await sub.cancel();
      manager.dispose();
    });

    test('QrPairingPayload encodes and decodes offline hotspot SSID and passphrase', () {
      const payload = QrPairingPayload(
        ip: '192.168.43.1',
        port: 52840,
        token: 'tok123',
        pin: '4821',
        deviceName: 'OfflineHost',
        os: DeviceOS.android,
        wifiSsid: 'AndroidShare_9911',
        wifiPassword: 'secret-passphrase',
      );

      final parsed = QrPairingPayload.parse(payload.toUriString());
      expect(parsed, isNotNull);
      expect(parsed!.wifiSsid, 'AndroidShare_9911');
      expect(parsed.wifiPassword, 'secret-passphrase');
      expect(parsed.toDiscoveredDevice().transport, DiscoveryTransport.nearbyP2p);
    });
  });

  group('Mutual Session & Back-to-Back Single-File Transfer Tests', () {
    late Directory tempDir;
    late Directory saveDir;
    late TransferServer server;
    late TransferClient client;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ushare_sess_tmp_');
      saveDir = await Directory.systemTemp.createTemp('ushare_sess_save_');
      AutoSaveRouter.overrideBaseDirectory = saveDir.path;
      server = TransferServer();
      client = TransferClient();
    });

    tearDown(() async {
      await server.stop();
      client.dispose();
      AutoSaveRouter.overrideBaseDirectory = null;
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      if (await saveDir.exists()) await saveDir.delete(recursive: true);
    });

    test('Mutual session approval skips per-file prompts & supports back-to-back single files', () async {
      int sessionPromptCount = 0;
      int perFilePromptCount = 0;

      server.onSessionRequested = (sessionId, peerName, peerOs, peerIp, peerPort, pin) async {
        sessionPromptCount++;
        return true;
      };
      server.onManifestReceived = (senderName, files, pin) async {
        perFilePromptCount++;
        return true;
      };

      final port = await server.start(
        sessionToken: 'server_tok',
        verificationPin: '1234',
        tempStorageDir: tempDir.path,
        initialPort: 52910,
      );

      final peer = DiscoveredDevice(
        id: 'peer_1',
        name: 'Receiver',
        os: DeviceOS.android,
        ipAddress: '127.0.0.1',
        port: port,
        sessionToken: 'server_tok',
        lastSeen: DateTime.now(),
      );

      const sessionId = 'mutual_sess_001';
      final token = await client.requestMutualSession(
        targetDevice: peer,
        sessionId: sessionId,
        localName: 'Sender',
        localOs: DeviceOS.android,
        localIp: '127.0.0.1',
        localPort: 52840,
        authPin: '1234',
      );

      expect(token, 'server_tok');
      expect(sessionPromptCount, 1);
      expect(server.isSessionTrusted(sessionId), isTrue);

      final file1 = File('${tempDir.path}/single1.bin');
      await file1.writeAsBytes(List.generate(64 * 1024, (i) => i % 256));
      final file2 = File('${tempDir.path}/single2.bin');
      await file2.writeAsBytes(List.generate(96 * 1024, (i) => (i * 3) % 256));

      final item1 = FileManifestItem.create(
        fileId: 'single_1',
        fileName: 'single1.bin',
        fileSize: await file1.length(),
        localFilePath: file1.path,
      );
      final item2 = FileManifestItem.create(
        fileId: 'single_2',
        fileName: 'single2.bin',
        fileSize: await file2.length(),
        localFilePath: file2.path,
      );

      final ok1 = await client.sendFiles(
        targetDevice: peer,
        senderName: 'Sender',
        authPin: '1234',
        filesToSend: [item1],
        sessionId: sessionId,
      );
      final ok2 = await client.sendFiles(
        targetDevice: peer,
        senderName: 'Sender',
        authPin: '1234',
        filesToSend: [item2],
        sessionId: sessionId,
      );

      expect(ok1, isTrue);
      expect(ok2, isTrue);
      expect(perFilePromptCount, 0);
    });
  });
}
