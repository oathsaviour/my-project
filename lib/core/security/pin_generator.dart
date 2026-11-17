import 'dart:math';

/// Secure generator for ephemeral pairing PINs and session tokens.
class PinGenerator {
  static final Random _secureRandom = Random.secure();

  /// Generates a human-friendly 4-digit verification PIN (e.g. "4829").
  static String generate4DigitPin() {
    final code = _secureRandom.nextInt(9000) + 1000;
    return code.toString();
  }

  /// Generates a 6-digit high-entropy PIN.
  static String generate6DigitPin() {
    final code = _secureRandom.nextInt(900000) + 100000;
    return code.toString();
  }

  /// Generates a random alphanumeric session token.
  static String generateSessionToken([int length = 24]) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(length, (_) => chars[_secureRandom.nextInt(chars.length)]).join();
  }
}
