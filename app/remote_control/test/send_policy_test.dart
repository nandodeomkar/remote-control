// Task 1 (TDD) — per-message-class send policy (design spec §8,
// 03-RESEARCH Pattern 6 send table).
//
// volatile (binary move/scroll): dropped unless authed — NEVER queued,
// because queued deltas teleport the cursor on reconnect.
// reliable (click/drag/key/text/media/power/confirm/clip.*/browser/present):
// queued up to 10 during blips (FIFO flush on auth), then dropped with an
// overflow signal.
//
// Pure and synchronous: no IO, no async — the driver supplies `send`.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/send_policy.dart';

void main() {
  group('SendPolicy — volatile', () {
    test('volatile frames are dropped when not authed (never queued)', () {
      final policy = SendPolicy();

      expect(policy.shouldSendVolatile(), isFalse,
          reason: 'design spec §8: queued deltas teleport the cursor — '
              'volatile is drop-only');
    });

    test('volatile frames flow when authed', () {
      final policy = SendPolicy()..authed = true;

      expect(policy.shouldSendVolatile(), isTrue);
    });
  });

  group('SendPolicy — reliable', () {
    test('sends immediately via the callback when authed', () {
      final sent = <Object>[];
      final policy = SendPolicy()..authed = true;

      policy.enqueueOrSendReliable('click', sent.add);

      expect(sent, ['click'], reason: 'no queueing while the session is up');
    });

    test('queues up to maxQueue (10) while not authed, sending nothing', () {
      final sent = <Object>[];
      var overflows = 0;
      final policy = SendPolicy(onOverflow: () => overflows++)..channelUp = true;

      for (var i = 0; i < 10; i++) {
        policy.enqueueOrSendReliable('msg-$i', sent.add);
      }

      expect(sent, isEmpty, reason: 'nothing hits the wire during a blip');
      expect(overflows, 0, reason: '10 fits exactly (design spec §8 bound)');
    });

    test('the 11th reliable frame overflows and is dropped', () {
      final sent = <Object>[];
      var overflows = 0;
      final policy = SendPolicy(onOverflow: () => overflows++)..channelUp = true;

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
      final policy = SendPolicy(maxQueue: 2, onOverflow: () => overflows++)
        ..channelUp = true;

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
      final policy = SendPolicy()..channelUp = true;
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
      final policy = SendPolicy()..channelUp = true;
      policy.enqueueOrSendReliable('stale', sent.add);

      policy.clear();
      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty,
          reason: 'clear discards (e.g. target switch / auth-stop)');
    });
  });

  // ── No socket means DROP, not defer (260812-uge) ─────────────────────────
  //
  // The queue used to accept a frame whenever !authed, with nothing bounding
  // how long it waited — so anything sent during an outage arrived late, into
  // whatever window was focused when the phone next authed. `channelUp` is
  // what separates the benign handshake window (socket up, auth pending,
  // milliseconds) from the harmful one (backoff, no socket, unbounded).

  group('SendPolicy — disconnected', () {
    test('a reliable frame sent with NO socket is dropped, never queued', () {
      final sent = <Object>[];
      final policy = SendPolicy(); // channelUp defaults to false

      policy.enqueueOrSendReliable('typed-during-outage', sent.add);

      expect(sent, isEmpty, reason: 'nothing goes out while disconnected');

      policy
        ..channelUp = true
        ..authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty,
          reason: 'and it must not reappear on the next auth — that late '
              'delivery IS the defect');
    });

    test('the no-socket drop does NOT fire onOverflow', () {
      var overflows = 0;
      final policy = SendPolicy(onOverflow: () => overflows++);

      for (var i = 0; i < 20; i++) {
        policy.enqueueOrSendReliable('msg-$i', (_) {});
      }

      expect(overflows, 0,
          reason: 'onOverflow means the queue is FULL; a disconnect drop is a '
              'different fact and must not borrow that signal');
    });

    test('losing the socket mid-handshake drops what was queued', () {
      final sent = <Object>[];
      final policy = SendPolicy()..channelUp = true;
      policy.enqueueOrSendReliable('queued-in-handshake', sent.add);

      // What _teardownChannel does.
      policy
        ..authed = false
        ..channelUp = false
        ..clear();

      policy
        ..channelUp = true
        ..authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, isEmpty,
          reason: 'a frame must never outlive the socket it was queued for');
    });

    test('the handshake window still queues and flushes — the queue is NOT '
        'dead code', () {
      final sent = <Object>[];
      final policy = SendPolicy()..channelUp = true;

      policy.enqueueOrSendReliable('first', sent.add);
      policy.enqueueOrSendReliable('second', sent.add);
      expect(sent, isEmpty, reason: 'not authed yet');

      policy.authed = true;
      policy.flushOnAuthed(sent.add);

      expect(sent, ['first', 'second'],
          reason: 'socket up + auth pending is the one window that still '
              'defers rather than drops');
    });
  });
}
