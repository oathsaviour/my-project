import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import '../lib/core/models/discovered_device.dart';
import '../lib/core/models/file_manifest.dart';
import '../lib/services/transfer/transfer_server.dart';
import '../lib/services/transfer/transfer_client.dart';

void main() {
  group('End-to-End P2P Streaming Transfer Integration Tests', () {
    late Directory tempDir;
    late TransferServer server;
    late TransferClient client;
    late int serverPort;

    const sessionToken = 'integration_sec_token_9918';
    const authPin = '8392';

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ushare_e2e_');
      server = TransferServer();
      serverPort = await server.start(
        sessionToken: sessionToken,
        verificationPin: authPin,
        tempStorageDir: tempDir.path,
        initialPort: 54100,
      );
      client = TransferClient();
    });

    tearDown(() async {
      await server.stop();
      client.dispose();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Successfully transfers multi-chunk file with verified SHA-256', () async {
      // Create a 6MB test file (spans 3 x 2MB chunks)
      final sourceFile = File('${tempDir.path}/source_video.mp4');
      final totalBytes = 6 * 1024 * 1024;
      final buffer = Uint8List(totalBytes);
      for (int i = 0; i < totalBytes; i++) {
        buffer[i] = (i ^ 0x5A) % 256;
      }
      await sourceFile.writeAsBytes(buffer);

      final expectedSha = sha256.convert(buffer).toString();

      final manifestItem = FileManifestItem.create(
        fileId: 'video_file_001',
        fileName: 'source_video.mp4',
        fileSize: totalBytes,
        localFilePath: sourceFile.path,
        sha256: expectedSha,
        chunkSize: 2 * 1024 * 1024,
      );

      final peer = DiscoveredDevice(
        id: 'receiver_device',
        name: 'Receiver iPhone',
        os: DeviceOS.ios,
        ipAddress: '127.0.0.1',
        port: serverPort,
        sessionToken: sessionToken,
        version: '1.0.0',
        lastSeen: DateTime.now(),
      );

      int progressReports = 0;
      bool completedReported = false;

      client.onProgress = (fileId, transferred, total, speed, eta, status) {
        progressReports++;
        expect(total, equals(totalBytes));
        if (status == TransferStatus.completed) {
          completedReported = true;
        }
      };

      final transferOk = await client.sendFiles(
        targetDevice: peer,
        senderName: 'Sender Pixel',
        authPin: authPin,
        filesToSend: [manifestItem],
      );

      expect(transferOk, isTrue);
      expect(completedReported, isTrue);
      expect(progressReports, greaterThan(2));
    });

    test('Rejects connection when invalid PIN is supplied', () async {
      final peer = DiscoveredDevice(
        id: 'receiver_device',
        name: 'Receiver iPhone',
        os: DeviceOS.ios,
        ipAddress: '127.0.0.1',
        port: serverPort,
        sessionToken: 'invalid_token',
        version: '1.0.0',
        lastSeen: DateTime.now(),
      );

      final manifestItem = FileManifestItem.create(
        fileId: 'doc_1',
        fileName: 'contract.pdf',
        fileSize: 1024,
        localFilePath: '${tempDir.path}/fake.pdf',
      );

      expect(
        () => client.sendFiles(
          targetDevice: peer,
          senderName: 'Attacker',
          authPin: '0000', // Wrong PIN
          filesToSend: [manifestItem],
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
