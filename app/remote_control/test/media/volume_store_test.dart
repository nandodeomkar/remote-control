/// VolumeSliderPolicy unit tests (05-07 Task 1, MED-01/02, D-04).
///
/// The finger-wins volume contract proven at the pure-policy level, IO-free
/// and deterministic with a fake clock + recording send:
///
/// - A push received while NOT dragging is authoritative (value, mute,
///   hasSnapshot); a push received DURING a drag is ignored WHOLE — the finger
///   always wins (D-04).
/// - Dragging emits `setvol` on a leading-edge [kSetvolThrottleMs] throttle;
///   the final value is flushed on release iff it was not already the last
///   sent value (no duplicate).
/// - After release the next push is authoritative again.
/// - While unauthed the policy DROPS setvol entirely — it never queues, so a
///   transport blip cannot replay a stale volume (Pitfall 12).
/// - Incoming values are clamped to 0..100.
///
/// The policy is pure Dart: clock, auth, and send are all injected. No
/// Flutter, no timers, no wire types here.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/media/volume_store.dart';

void main() {
  late int fakeNow;
  late bool authed;
  late List<int> sent;
  late VolumeSliderPolicy policy;

  VolumeSliderPolicy build() => VolumeSliderPolicy(
        nowMillis: () => fakeNow,
        isAuthed: () => authed,
        send: sent.add,
      );

  setUp(() {
    fakeNow = 0;
    authed = true;
    sent = <int>[];
    policy = build();
  });

  group('pushes (server-authoritative when not dragging)', () {
    test('no snapshot before the first push', () {
      expect(policy.hasSnapshot, isFalse);
    });

    test('onPush while not dragging sets value, muted, and hasSnapshot', () {
      policy.onPush(40, muted: false);
      expect(policy.value, 40);
      expect(policy.muted, isFalse);
      expect(policy.hasSnapshot, isTrue);
    });

    test('mute state follows the push (no optimistic flip)', () {
      policy.onPush(40, muted: true);
      expect(policy.muted, isTrue);
      policy.onPush(40, muted: false);
      expect(policy.muted, isFalse);
    });

    test('a push during a drag is ignored WHOLE — finger wins (D-04)', () {
      policy.onPush(40, muted: false);
      policy.dragStart();
      policy.onPush(80, muted: true); // ignored — value AND mute
      expect(policy.value, 40);
      expect(policy.muted, isFalse);
    });

    test('after dragEnd the next push is authoritative again', () {
      policy.dragStart();
      policy.dragUpdate(70);
      policy.dragEnd();
      policy.onPush(29, muted: false);
      expect(policy.value, 29);
    });

    test('incoming push values are clamped to 0..100', () {
      policy.onPush(150, muted: false);
      expect(policy.value, 100);
      policy.onPush(-10, muted: false);
      expect(policy.value, 0);
    });
  });

  group('drag throttle (D-04, kSetvolThrottleMs leading edge)', () {
    test('leading-edge send, mid-window suppressed, next window sends', () {
      policy.dragStart();
      fakeNow = 0;
      policy.dragUpdate(10); // leading edge → send 10
      fakeNow = 20;
      policy.dragUpdate(20); // 20 < 50 → suppressed
      fakeNow = 60;
      policy.dragUpdate(30); // 60 ≥ 50 → send 30
      fakeNow = 70;
      policy.dragEnd(); // final 30 == last sent 30 → no duplicate

      expect(sent, <int>[10, 30]);
    });

    test('dragEnd flushes the final value when it was throttled', () {
      policy.dragStart();
      fakeNow = 0;
      policy.dragUpdate(10); // send 10
      fakeNow = 60;
      policy.dragUpdate(30); // send 30
      fakeNow = 70;
      policy.dragUpdate(45); // 70 − 60 = 10 < 50 → suppressed, pending 45
      fakeNow = 80;
      policy.dragEnd(); // 45 != 30 → flush 45

      expect(sent, <int>[10, 30, 45]);
    });

    test('a fresh drag starts with its own leading-edge send', () {
      policy.dragStart();
      fakeNow = 0;
      policy.dragUpdate(10);
      policy.dragEnd();

      // A new drag much later: its first update must send even though the
      // previous drag's last send was recent in wall-clock terms.
      policy.dragStart();
      fakeNow = 5; // only 5ms after the previous send
      policy.dragUpdate(90);

      expect(sent, <int>[10, 90]);
    });

    test('dragUpdate values are clamped to 0..100 before sending', () {
      policy.dragStart();
      fakeNow = 0;
      policy.dragUpdate(200);
      expect(policy.value, 100);
      expect(sent, <int>[100]);
    });

    test('dragging reflects in the policy state flag', () {
      expect(policy.dragging, isFalse);
      policy.dragStart();
      expect(policy.dragging, isTrue);
      policy.dragEnd();
      expect(policy.dragging, isFalse);
    });
  });

  group('unauthed drop (Pitfall 12 — drop, never queue)', () {
    test('dragUpdate/dragEnd send NOTHING while unauthed', () {
      authed = false;
      policy.dragStart();
      fakeNow = 0;
      policy.dragUpdate(10);
      fakeNow = 60;
      policy.dragUpdate(30);
      policy.dragEnd();

      expect(sent, isEmpty);
    });

    test('nothing is queued: re-auth + a later push does not replay setvol', () {
      authed = false;
      policy.dragStart();
      fakeNow = 0;
      policy.dragUpdate(10);
      fakeNow = 60;
      policy.dragUpdate(30);
      policy.dragEnd();

      authed = true;
      policy.onPush(50, muted: false); // authoritative push, no replay

      expect(sent, isEmpty);
    });
  });
}
