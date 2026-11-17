import 'dart:async';

typedef NativeChannelInvoker = Future<T?> Function<T>(String method, [dynamic arguments]);

/// Manages CPU and screen wake locks during active file transfers
/// to prevent Android Doze mode and iOS screen auto-lock from dropping sockets.
class WakeLockManager {
  /// Injected native channel invoker (configured by Flutter in main.dart).
  static NativeChannelInvoker? nativeChannelInvoker;

  static int _activeLockCount = 0;
  static bool _isHeld = false;

  static bool get isHeld => _isHeld;

  /// Acquires a wake lock (keeps CPU running and screen on).
  /// Safe to call concurrently across multiple file transfers.
  static Future<void> acquireWakeLock({String reason = 'Active Transfer'}) async {
    _activeLockCount++;
    if (_activeLockCount == 1 && !_isHeld) {
      _isHeld = true;
      if (nativeChannelInvoker != null) {
        try {
          await nativeChannelInvoker!('acquireWakeLock', {'reason': reason});
        } catch (_) {}
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
      if (nativeChannelInvoker != null) {
        try {
          await nativeChannelInvoker!('releaseWakeLock');
        } catch (_) {}
      }
    }
  }

  /// Forcefully resets all wake locks (e.g. on user cancel or fatal socket error).
  static Future<void> forceReleaseAll() async {
    _activeLockCount = 0;
    if (_isHeld) {
      _isHeld = false;
      if (nativeChannelInvoker != null) {
        try {
          await nativeChannelInvoker!('releaseWakeLock');
        } catch (_) {}
      }
    }
  }
}
