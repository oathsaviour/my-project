import 'dart:typed_data';

/// Binary wire framing constants for the raw TCP streaming engine.
class ProtocolMagic {
  /// 4-byte Magic signature: ASCII "USHR" (0x55, 0x53, 0x48, 0x52)
  static const int magicHeader = 0x55534852;

  /// Protocol Version 1.0 (0x0001)
  static const int version1 = 0x0001;

  /// Header fixed length in bytes:
  /// Magic (4) + Version (2) + SessionUUID (16) + FileID (8) + ChunkIndex (8) +
  /// TotalChunks (8) + PayloadLength (8) + ChunkSHA256 (32) = 86 bytes
  static const int headerLength = 86;

  /// Packet types
  static const int typeHandshakeRequest = 0x01;
  static const int typeHandshakeResponse = 0x02;
  static const int typeManifest = 0x03;
  static const int typeManifestAccept = 0x04;
  static const int typeChunkData = 0x05;
  static const int typeChunkAck = 0x06;
  static const int typeFileFinalize = 0x07;
  static const int typeFileFinalizeAck = 0x08;
  static const int typePause = 0x09;
  static const int typeResumeRequest = 0x0A;
  static const int typeResumeResponse = 0x0B;

  /// Magic bytes as a Uint8List
  static final Uint8List magicBytes = Uint8List.fromList([0x55, 0x53, 0x48, 0x52]);
}
