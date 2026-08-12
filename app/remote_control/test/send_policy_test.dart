// Task 1 (TDD) — per-message-class send policy (design spec §8,
// 03-RESEARCH Pattern 6 send table).
//
// volatile (binary move/scroll): dropped unless authed — NEVER queued,
// because queued deltas teleport the cursor on reconnect.
// reliable (click/drag/key/text/media/power/confirm/clip.*/browser/present):
// queued up to 10 while not authed (FIFO flush on auth), dropped with an
// overflow signal past the bound, and aged out at the TTL (260812-uq8).
//
// Synchronous and IO-free: the driver supplies `send` and the clock.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/send_policy.dart';

/// A hand-advanced clock. The TTL is time, so every policy under test owns
/// one — `SendPolicy` requires the seam rather than defaulting to the system
/// clock precisely so no test can accidentally depend on wall time.
class _Clock {
  int now = 0;
  int read() => now;
}

void main() {
  group('SendPolicy — volatile', () {
    test('volatile frames are dropped when not authed (never queued)', () {
      final policy = SendPolicy(nowMillis: _Clock().read);

      expect(policy.shouldSendVolatile(), isFalse,
          reason: 'design spec §8: queued deltas teleport the cursor — '
              'volatile is drop-only');
    });

    test('volatile frames flow when authed', () {
      final policy = SendPolicy(nowMillis: _Clock().read)..authed = true;

      expect(policy.shouldSendVolatile(), isTrue);
    });
  });

  group('SendPolicy — reliable', () {
    test('sends immediately via the callback when authed', () {
      final sent = <Object>[];
      final policy = SendPolicy(nowMillis: _Clock().read)..authed = true;

      policy.enqueueOrSendReliable('click', sent.add);

      expect(sent, ['click'], reason: 'no queueing while the session is up');
    });

    test('queues up to maxQueue (10) while not authed, sending nothing', () {
      final sent = <Object>[];
      var overflows = 0;
      final policy =
          SendPolicy(nowMillis: _Clock().read, onOverflow: () => overflows++);

      for (var i = 0; i < 10; i++) {
        policy.enqueueOrSendReliable('msg-$i', sent.add);
      }

      expect(sent, isEmpty, reason: 'nothing hits the wire during a blip');
      expect(overflows, 0, reason: '10 fits exactly (design spec §8 bound)');
    });

    test('the 11th reliable frame overflows and is dropped', () {
      final sent = <Object>[];
      var overflows = 0;
      final policy =
          SendPolicy(nowMillis: _Clock().read, onOverflow: () => overflows++);

      for (var i = 0; i < 11; i++) {
        policy.enqueueOrSendReliable('msg-$i', sent.add);
      }
      expect(overflows, 1, reason: 'design spec §8: drop with a toast seam');

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, hasLength(10),
          reason: 'the overflowing frame was dropped, not queued');
      expect(sent, isNot(contains('msg-10')));
    });

    test('a custom maxQueue bound is honored', () {
      var overflows = 0;
      final policy = SendPolicy(
        nowMillis: _Clock().read,
        maxQueue: 2,
        onOverflow: () => overflows++,
      );

      policy.enqueueOrSendReliable('a', (_) {});
      policy.enqueueOrSendReliable('b', (_) {});
      policy.enqueueOrSendReliable('c', (_) {});

      expect(overflows, 1);
    });
  });

  group('SendPolicy — flush & clear', () {
    test('flushOnAuthed delivers queued frames FIFO then empties the queue',
        () {
      final sent = <Object>[];
      final policy = SendPolicy(nowMillis: _Clock().read);
      policy.enqueueOrSendReliable('first', sent.add);
      policy.enqueueOrSendReliable('second', sent.add);
      policy.enqueueOrSendReliable('third', sent.add);

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, ['first', 'second', 'third'], reason: 'strict FIFO order');

      sent.clear();
      policy.flushOnAuthed(sent.add);
      expect(sent, isEmpty, reason: 'the first flush emptied the queue');
    });

    test('clear empties the queue without sending', () {
      final sent = <Object>[];
      final policy = SendPolicy(nowMillis: _Clock().read);
      policy.enqueueOrSendReliable('stale', sent.add);

      policy.clear();
      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty,
          reason: 'clear discards (target switch / auth-stop / disconnect)');
    });
  });

  // ── The queue is bounded in TIME, not by the socket (260812-uq8) ─────────
  //
  // The queue originally had no time bound at all, so anything sent during an
  // outage was delivered late into whatever window was focused when the phone
  // next authed. 260812-uge closed that by dropping outright whenever no
  // socket was up, which cost blip-tolerance entirely. The TTL keeps both:
  // reconnect backoff is 1/2/4/8s ±20%, so 5s covers a blip that recovers on
  // redial #1 (~0.8–1.25s) or #2 (~2.4–3.6s) and stops short of #3 (~5.6–8.4s).

  group('SendPolicy — TTL', () {
    test('a frame queued during a blip flushes when re-auth lands inside '
        'the TTL', () {
      final sent = <Object>[];
      final clock = _Clock();
      final policy = SendPolicy(nowMillis: clock.read);

      policy.enqueueOrSendReliable('typed-during-blip', sent.add);
      clock.now = 4999; // redial #2 re-auths well inside this

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, ['typed-during-blip'],
          reason: 'a sub-5s blip is lossless again — the phase-3 rule the '
              'no-socket drop had retired');
    });

    test('the same frame is dropped when re-auth lands past the TTL', () {
      final sent = <Object>[];
      final clock = _Clock();
      final policy = SendPolicy(nowMillis: clock.read);

      policy.enqueueOrSendReliable('typed-during-outage', sent.add);
      clock.now = 5001;

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty,
          reason: 'late delivery into whatever window is focused IS the '
              'defect — a power+confirm pair rode this same queue');
    });

    test('the TTL boundary is inclusive: exactly ttl old is expired', () {
      final sent = <Object>[];
      final clock = _Clock();
      final policy = SendPolicy(nowMillis: clock.read);

      policy.enqueueOrSendReliable('boundary', sent.add);
      clock.now = 5000;

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty,
          reason: 'age >= ttl expires, so "survives 5s" reads as strictly '
              'less than everywhere — pinned so it cannot drift');
    });

    test('only frames past the TTL are dropped; survivors keep FIFO order',
        () {
      final sent = <Object>[];
      final clock = _Clock();
      final policy = SendPolicy(nowMillis: clock.read);

      policy.enqueueOrSendReliable('oldest', sent.add);
      clock.now = 3000;
      policy.enqueueOrSendReliable('middle', sent.add);
      clock.now = 4000;
      policy.enqueueOrSendReliable('newest', sent.add);

      clock.now = 5500; // cutoff 500: only 'oldest' is past it
      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, ['middle', 'newest'],
          reason: 'expiry is per-frame, and the survivors stay in order');
    });

    test('a custom ttl is honored', () {
      final sent = <Object>[];
      final clock = _Clock();
      final policy = SendPolicy(
        nowMillis: clock.read,
        ttl: const Duration(seconds: 1),
      );

      policy.enqueueOrSendReliable('short-lived', sent.add);
      clock.now = 1500;

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty);
    });

    test('a TTL expiry does NOT fire onOverflow', () {
      var overflows = 0;
      final clock = _Clock();
      final policy =
          SendPolicy(nowMillis: clock.read, onOverflow: () => overflows++);

      for (var i = 0; i < 10; i++) {
        policy.enqueueOrSendReliable('msg-$i', (_) {});
      }
      clock.now = 6000;
      policy.authed = true;
      policy.flushOnAuthed((_) {});

      expect(overflows, 0,
          reason: 'onOverflow means the queue is FULL; an expiry is a '
              'different fact and must not borrow that signal');
    });

    test('expiry runs BEFORE the bound, so corpses cannot overflow a live '
        'frame', () {
      final sent = <Object>[];
      var overflows = 0;
      final clock = _Clock();
      final policy =
          SendPolicy(nowMillis: clock.read, onOverflow: () => overflows++);

      for (var i = 0; i < 10; i++) {
        policy.enqueueOrSendReliable('stale-$i', sent.add);
      }
      clock.now = 6000; // every one of those is now expired

      policy.enqueueOrSendReliable('live', sent.add);

      expect(overflows, 0,
          reason: 'a full queue of expired frames is really an empty one — '
              'checking the bound first would drop the live frame and '
              'report a full queue');

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, ['live'],
          reason: 'the stale ten aged out; only the live frame is delivered');
    });
  });
}
