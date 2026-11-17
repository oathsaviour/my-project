import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../constants/protocol_magic.dart';

/// Represents a single discrete chunk packet adhering to the binary wire protocol.
class ChunkPacket {
  final int magic;
  final int version;
  final String sessionUuid;
  final int fileId;
  final int chunkIndex;
  final int totalChunks;
  final int payloadLength;
  final List<int> chunkSha256;
  final Uint8List payload;

  ChunkPacket({
    this.magic = ProtocolMagic.magicHeader,
    this.version = ProtocolMagic.version1,
    required this.sessionUuid,
    required this.fileId,
    required this.chunkIndex,
    required this.totalChunks,
    required this.payloadLength,
    required this.chunkSha256,
    required this.payload,
  });

  /// Factory that calculates SHA-256 for the payload chunk automatically.
  factory ChunkPacket.create({
    required String sessionUuid,
    required int fileId,
    required int chunkIndex,
    required int totalChunks,
    required Uint8List payload,
  }) {
    final digest = sha256.convert(payload);
    return ChunkPacket(
      sessionUuid: sessionUuid,
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      payloadLength: payload.length,
      chunkSha256: digest.bytes,
      payload: payload,
    );
  }

  /// Serializes the chunk packet into raw binary bytes for network transmission.
  Uint8List toBytes() {
    final totalLength = ProtocolMagic.headerLength + payload.length;
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    // 0..3: Magic uint32 (Big Endian)
    byteData.setUint32(0, magic, Endian.big);

    // 4..5: Version uint16 (Big Endian)
    byteData.setUint16(4, version, Endian.big);

    // 6..21: Session UUID (16 bytes fixed, padded or truncated)
    final uuidBytes = utf8.encode(sessionUuid.replaceAll('-', ''));
    for (int i = 0; i < 16; i++) {
      buffer[6 + i] = i < uuidBytes.length ? uuidBytes[i] : 0;
    }

    // 22..29: FileID uint64
    byteData.setUint64(22, fileId, Endian.big);

    // 30..37: ChunkIndex uint64
    byteData.setUint64(30, chunkIndex, Endian.big);

    // 38..45: TotalChunks uint64
    byteData.setUint64(38, totalChunks, Endian.big);

    // 46..53: PayloadLength uint64
    byteData.setUint64(46, payloadLength, Endian.big);

    // 54..85: Chunk SHA-256 (32 bytes)
    for (int i = 0; i < 32; i++) {
      buffer[54 + i] = i < chunkSha256.length ? chunkSha256[i] : 0;
    }

    // 86..End: Raw Payload
    buffer.setRange(86, totalLength, payload);

    return buffer;
  }

  /// Deserializes a binary chunk frame received over TCP.
  factory ChunkPacket.fromBytes(Uint8List bytes) {
    if (bytes.length < ProtocolMagic.headerLength) {
      throw FormatException(
        'Frame too short: expected at least ${ProtocolMagic.headerLength} bytes, got ${bytes.length}',
      );
    }

    final byteData = ByteData.sublistView(bytes);

    final magic = byteData.getUint32(0, Endian.big);
    if (magic != ProtocolMagic.magicHeader) {
      throw FormatException('Invalid magic header: 0x${magic.toRadixString(16)}');
    }

    final version = byteData.getUint16(4, Endian.big);
    final uuidBytes = bytes.sublist(6, 22);
    final sessionUuid = utf8.decode(uuidBytes.where((b) => b != 0).toList());

    final fileId = byteData.getUint64(22, Endian.big);
    final chunkIndex = byteData.getUint64(30, Endian.big);
    final totalChunks = byteData.getUint64(38, Endian.big);
    final payloadLength = byteData.getUint64(46, Endian.big);

    final chunkSha256 = bytes.sublist(54, 86);

    final expectedTotal = ProtocolMagic.headerLength + payloadLength;
    if (bytes.length < expectedTotal) {
      throw FormatException(
        'Incomplete payload: expected $expectedTotal bytes, got ${bytes.length}',
      );
    }

    final payload = bytes.sublist(ProtocolMagic.headerLength, expectedTotal);

    // Verify per-chunk SHA256 integrity
    final computedHash = sha256.convert(payload).bytes;
    for (int i = 0; i < 32; i++) {
      if (computedHash[i] != chunkSha256[i]) {
        throw const FormatException('Chunk SHA-256 checksum mismatch (corrupted frame)');
      }
    }

    return ChunkPacket(
      magic: magic,
      version: version,
      sessionUuid: sessionUuid,
      fileId: fileId,
      chunkIndex: chunkIndex,
      totalChunks: totalChunks,
      payloadLength: payloadLength,
      chunkSha256: chunkSha256,
      payload: payload,
    );
  }
}
