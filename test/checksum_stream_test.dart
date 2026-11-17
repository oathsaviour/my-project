import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import '../lib/core/utils/checksum_stream.dart';

void main() {
  group('ChecksumStream Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ushare_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('Computes streaming file SHA-256 without memory buffering', () async {
      final testFile = File('${tempDir.path}/test_large_payload.bin');
      final content = Uint8List(5 * 1024 * 1024); // 5MB payload
      for (int i = 0; i < content.length; i++) {
        content[i] = i % 256;
      }
      await testFile.writeAsBytes(content);

      final expectedSha = sha256.convert(content).toString();
      int progressUpdates = 0;

      final actualSha = await ChecksumStream.computeFileSha256(
        testFile.path,
        onProgress: (read, total) {
          progressUpdates++;
          expect(total, equals(content.length));
          expect(read, lessThanOrEqualTo(total));
        },
      );

      expect(actualSha, equals(expectedSha));
      expect(progressUpdates, greaterThan(1));
      expect(ChecksumStream.verifyChecksum(actualSha, expectedSha.toUpperCase()), isTrue);
    });

    test('Verifies chunk SHA-256 calculation', () {
      final sample = Uint8List.fromList(utf8.encode('Chunk data test 12345'));
      final expected = sha256.convert(sample).toString();
      final actual = ChecksumStream.computeChunkSha256(sample);

      expect(actual, equals(expected));
    });
  });
}
