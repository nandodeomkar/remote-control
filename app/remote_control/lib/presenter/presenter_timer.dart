/// Pure client-local presenter elapsed timer FSM (PRES-02, D-08) — no
/// Flutter, no IO, no Timer objects.
///
/// The manual elapsed clock the presenter bar renders: it starts on "Start
/// show", tap pauses/resumes, long-press (in the widget) resets. In the
/// modifier_fsm house style — events in, state out — over an injected
/// `int Function() nowMillis` clock (the GestureClassifier seam). The class
/// owns NO rendering cadence: the widget drives a 1s `Timer.periodic` that
/// reads [elapsedMs] (Pitfall 13 — the FSM never holds a Timer). It is
/// client-local only: there are no wire types here, the timer is never a
/// message (D-08).
///
/// Elapsed accounting excludes paused gaps. While running, elapsed is the
/// accumulated total plus the live span since the last resume
/// (`accumulated + now - startedAt`); pausing folds that live span into
/// [_accumulated] and freezes; resuming re-anchors [_startedAt] to now so the
/// pause gap never accrues. `startShow` from ANY state is a fresh show —
/// accumulated cleared to 0 and running from now.
library;

/// The three presenter-timer states (UI-SPEC timer state table).
enum PresenterTimerState {
  /// No show running; elapsed reads 00:00 (`#6B7280`).
  stopped,

  /// Show running; elapsed ticks with the clock (`#4C8DFF`).
  running,

  /// Show paused; elapsed frozen at the captured value (`#E6E8EB`).
  paused,
}

/// Pure clock-injected presenter timer. Deterministic under a manually
/// advanced `nowMillis` clock; holds no timers, no IO, no Flutter.
class PresenterTimer {
  /// Injected millisecond clock (system clock in the widget, fake in tests).
  final int Function() nowMillis;

  PresenterTimerState _state = PresenterTimerState.stopped;

  /// Elapsed already banked from prior running spans (paused gaps excluded).
  int _accumulated = 0;

  /// Clock value at the last transition INTO running; only meaningful while
  /// [_state] is running.
  int _startedAt = 0;

  /// Creates a stopped timer over the given clock seam.
  PresenterTimer({required this.nowMillis});

  /// Current FSM state.
  PresenterTimerState get state => _state;

  /// Start (or restart) a fresh show from ANY state: accumulated cleared,
  /// running from now. "Start show" always begins a new show (D-08).
  void startShow() {
    _accumulated = 0;
    _startedAt = nowMillis();
    _state = PresenterTimerState.running;
  }

  /// The timer tap: running→paused (banking the live span) and
  /// paused→running (re-anchoring so the pause gap is excluded). A no-op
  /// while stopped.
  void tap() {
    switch (_state) {
      case PresenterTimerState.running:
        _accumulated += nowMillis() - _startedAt;
        _state = PresenterTimerState.paused;
      case PresenterTimerState.paused:
        _startedAt = nowMillis();
        _state = PresenterTimerState.running;
      case PresenterTimerState.stopped:
        break; // no-op: nothing to pause/resume
    }
  }

  /// Long-press reset from any state → stopped at 00:00.
  void reset() {
    _accumulated = 0;
    _startedAt = 0;
    _state = PresenterTimerState.stopped;
  }

  /// Elapsed milliseconds, paused gaps excluded. Running: accumulated plus
  /// the live span since the last resume; paused/stopped: the banked total.
  int elapsedMs() {
    if (_state == PresenterTimerState.running) {
      return _accumulated + (nowMillis() - _startedAt);
    }
    return _accumulated;
  }
}
