import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';

/// Utilities for streaming SHA-256 checksum calculation without buffering files into RAM.
class ChecksumStream {
  /// Computes the SHA-256 checksum of an entire file using a streamed file reader.
  /// Handles files of arbitrary size (>4GB) with bounded memory consumption (<64KB).
  static Future<String> computeFileSha256(
    String filePath, {
    void Function(int bytesRead, int totalBytes)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('File does not exist for checksumming', filePath);
    }

    final totalBytes = await file.length();
    int accumulatedBytes = 0;

    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);

    final stream = file.openRead();
    await for (final chunk in stream) {
      input.add(chunk);
      accumulatedBytes += chunk.length;
      if (onProgress != null && totalBytes > 0) {
        onProgress(accumulatedBytes, totalBytes);
      }
    }

    input.close();
    return output.events.single.toString();
  }

  /// Calculates SHA-256 for a discrete chunk in memory.
  static String computeChunkSha256(Uint8List chunk) {
    return sha256.convert(chunk).toString();
  }

  /// Verifies if a computed hash matches an expected hash (case-insensitive).
  static bool verifyChecksum(String actual, String expected) {
    return actual.trim().toLowerCase() == expected.trim().toLowerCase();
  }
}
