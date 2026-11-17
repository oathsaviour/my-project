import 'dart:io';
import 'package:flutter/services.dart';

/// Manages CPU and screen wake locks during active file transfers
/// to prevent Android Doze mode and iOS screen auto-lock from dropping sockets.
class WakeLockManager {
  static const MethodChannel _channel = MethodChannel('com.universal.filetransfer/native');
  static int _activeLockCount = 0;
  static bool _isHeld = false;

  static bool get isHeld => _isHeld;

  /// Acquires a wake lock (keeps CPU running and screen on).
  /// Safe to call concurrently across multiple file transfers.
  static Future<void> acquireWakeLock({String reason = 'Active Transfer'}) async {
    _activeLockCount++;
    if (_activeLockCount == 1 && !_isHeld) {
      _isHeld = true;
      try {
        await _channel.invokeMethod('acquireWakeLock', {'reason': reason});
      } catch (_) {
        // Graceful fallback in pure CLI test runners or web simulator
      }
    }
  }

  /// Releases the wake lock when all active transfers are completed, paused, or canceled.
  static Future<void> releaseWakeLock() async {
    if (_activeLockCount > 0) {
      _activeLockCount--;
    }

    if (_activeLockCount == 0 && _isHeld) {
      _isHeld = false;
      try {
        await _channel.invokeMethod('releaseWakeLock');
      } catch (_) {
        // Graceful fallback
      }
    }
  }

  /// Forcefully resets all wake locks (e.g. on user cancel or fatal socket error).
  static Future<void> forceReleaseAll() async {
    _activeLockCount = 0;
    if (_isHeld) {
      _isHeld = false;
      try {
        await _channel.invokeMethod('releaseWakeLock');
      } catch (_) {}
    }
  }
}
