import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import '../lib/core/constants/protocol_magic.dart';
import '../lib/core/models/chunk_packet.dart';

void main() {
  group('ChunkPacket Wire Protocol Tests', () {
    test('Serializes and deserializes chunk frame accurately', () {
      final samplePayload = Uint8List.fromList(utf8.encode('Hello Universal File Transfer Stream'));
      final sessionUuid = '12345678-1234-1234-1234-123456789abc';

      final packet = ChunkPacket.create(
        sessionUuid: sessionUuid,
        fileId: 42,
        chunkIndex: 3,
        totalChunks: 10,
        payload: samplePayload,
      );

      final bytes = packet.toBytes();
      expect(bytes.length, equals(ProtocolMagic.headerLength + samplePayload.length));

      // Deserialize
      final decoded = ChunkPacket.fromBytes(bytes);
      expect(decoded.magic, equals(ProtocolMagic.magicHeader));
      expect(decoded.version, equals(ProtocolMagic.version1));
      expect(decoded.fileId, equals(42));
      expect(decoded.chunkIndex, equals(3));
      expect(decoded.totalChunks, equals(10));
      expect(decoded.payloadLength, equals(samplePayload.length));
      expect(utf8.decode(decoded.payload), equals('Hello Universal File Transfer Stream'));
    });

    test('Rejects frame when checksum is corrupted in transit', () {
      final samplePayload = Uint8List.fromList(utf8.encode('Protected Payload'));
      final packet = ChunkPacket.create(
        sessionUuid: 'test-session-uuid',
        fileId: 1,
        chunkIndex: 0,
        totalChunks: 1,
        payload: samplePayload,
      );

      final bytes = packet.toBytes();
      // Corrupt a single payload byte
      bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0xFF;

      expect(
        () => ChunkPacket.fromBytes(bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('Rejects frame with incorrect magic header', () {
      final fakeBytes = Uint8List(ProtocolMagic.headerLength + 10);
      fakeBytes[0] = 0xFF; // Invalid magic
      expect(
        () => ChunkPacket.fromBytes(fakeBytes),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
