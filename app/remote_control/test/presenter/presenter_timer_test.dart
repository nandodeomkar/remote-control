// Task 1 (05-04) — RED: PresenterTimer pure FSM (PRES-02, D-08).
//
// The manual elapsed timer the presenter bar renders: starts on "Start
// show", tap pauses/resumes, reset (long-press in the widget) stops it.
// Client-local only — the FSM has no wire types, no Flutter, no IO, no
// Timer objects (the widget owns rendering cadence — Pitfall 13). All
// tests drive a manually-advanced fake clock: deterministic, zero sleeps
// (05-VALIDATION Wave 0 item).

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/presenter/presenter_timer.dart';

void main() {
  late int now;
  late PresenterTimer timer;

  setUp(() {
    now = 0;
    timer = PresenterTimer(nowMillis: () => now);
  });

  test('startShow runs; elapsed follows the clock', () {
    expect(timer.state, PresenterTimerState.stopped);
    expect(timer.elapsedMs(), 0);

    timer.startShow();
    expect(timer.state, PresenterTimerState.running);

    now += 5000;
    expect(timer.elapsedMs(), 5000);
    expect(timer.state, PresenterTimerState.running);
  });

  test('tap while running pauses — elapsed freezes at the captured value',
      () {
    timer.startShow();
    now += 5000;

    timer.tap();
    expect(timer.state, PresenterTimerState.paused);
    expect(timer.elapsedMs(), 5000);

    now += 3000;
    expect(timer.elapsedMs(), 5000,
        reason: 'paused time never accrues — the pause gap is excluded');
  });

  test('tap while paused resumes — the pause gap stays excluded', () {
    timer.startShow();
    now += 5000;
    timer.tap(); // paused at 5000
    now += 3000; // 3s pause gap

    timer.tap(); // resume
    expect(timer.state, PresenterTimerState.running);

    now += 1000;
    expect(timer.elapsedMs(), 6000,
        reason: '5000 before the pause + 1000 after — the 3000 gap excluded');
  });

  test('reset from running and from paused → stopped, elapsed 0', () {
    // From running.
    timer.startShow();
    now += 4000;
    timer.reset();
    expect(timer.state, PresenterTimerState.stopped);
    expect(timer.elapsedMs(), 0);

    // From paused.
    timer.startShow();
    now += 2000;
    timer.tap();
    expect(timer.state, PresenterTimerState.paused);
    timer.reset();
    expect(timer.state, PresenterTimerState.stopped);
    expect(timer.elapsedMs(), 0);
  });

  test('startShow while running restarts from 0 — always a fresh show', () {
    timer.startShow();
    now += 7000;
    expect(timer.elapsedMs(), 7000);

    timer.startShow();
    expect(timer.state, PresenterTimerState.running);
    expect(timer.elapsedMs(), 0,
        reason: 'Start show from ANY state begins a fresh show');

    now += 1500;
    expect(timer.elapsedMs(), 1500);
  });

  test('tap while stopped is a no-op', () {
    timer.tap();
    expect(timer.state, PresenterTimerState.stopped);
    expect(timer.elapsedMs(), 0);

    now += 2000;
    timer.tap();
    expect(timer.state, PresenterTimerState.stopped);
    expect(timer.elapsedMs(), 0);
  });
}
