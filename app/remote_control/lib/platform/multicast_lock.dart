/// MethodChannel client for Android's WifiManager.MulticastLock.
///
/// Hand-written (~15 lines of Kotlin on the other side) instead of a
/// pub.dev dependency: the candidates are abandoned or low-adoption
/// (RESEARCH package audit). Channel: `remote_control/multicast`,
/// methods `acquire` / `release` — handled in MainActivity.kt.
///
/// The lock is OEM broadcast-filter insurance (RESEARCH Pattern 4): some
/// chipsets drop non-unicast frames unless it is held. It disables packet
/// filtering globally, so it must only be held while a listener actually
/// runs (Pitfall 8) — BeaconListener pairs it with the socket lifecycle.
library;

import 'package:flutter/services.dart';

class MulticastLock {
  static const MethodChannel _channel =
      MethodChannel('remote_control/multicast');

  /// Acquire the multicast lock. Silent no-op where the platform handler
  /// does not exist (unit tests, non-Android hosts) — the lock is
  /// insurance, not a requirement.
  Future<void> acquire() async {
    try {
      await _channel.invokeMethod<void>('acquire');
    } on MissingPluginException {
      // No handler registered (test / non-Android): nothing to hold.
    }
  }

  /// Release the multicast lock. Same silent no-op contract as [acquire].
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } on MissingPluginException {
      // No handler registered (test / non-Android): nothing to release.
    }
  }
}
