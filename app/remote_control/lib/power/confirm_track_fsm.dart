/// Pure slide-to-confirm FSM (PWR-01..03, D-05/D-06) — no Flutter, no IO.
///
/// One instance per power track (lock / sleep / restart / shutdown) in the
/// modifier_fsm/presenter_timer house style: events in, effects out, the
/// driver (the PowerScreen track widget) executes every effect. This class
/// holds no timers, no channel, no wire types, and imports nothing from
/// Flutter or the IO libraries — effects are plain sealed classes carrying the
/// action string; the SCREEN maps them onto PowerMsg/ConfirmMsg.
///
/// # The no-single-action-path invariant (T-05-12, roadmap SC3)
///
/// A power action fires ONLY from a COMPLETED slide — progress ≥
/// [kConfirmCompletionThreshold] (0.9) at [dragEnd]. There is deliberately no
/// tap/press path to any [SendPower] effect: the ≥0.9 gesture is the first
/// gate, the server's 10s `power`→`confirm` window is the authoritative second.
///
/// # Two completion shapes (D-05 vs D-06)
///
/// - Lock / Sleep (the SAFE pair, `isDestructive == false`) — a completed
///   slide is ONE deliberate gesture worth TWO wire messages: effects
///   `[SendPower(action), SendConfirm(action)]` in that strict order (D-05).
///   Low blast radius, so the slide alone is the whole confirmation.
/// - Restart / Shut down (the DESTRUCTIVE pair, `isDestructive == true`) — a
///   completed slide sends `power` ONLY and opens the red countdown dialog:
///   effects `[SendPower(action), OpenCountdown(action)]`. The FSM NEVER yields
///   a [SendConfirm] for these actions (D-06, PWR-03) — the dialog's confirm
///   button is the sole confirm sender, so there is no single-action reboot
///   path anywhere.
///
/// Release below threshold → `[SpringBack]`, nothing sent (T-05-13). The
/// widget renders the state table (thumb follows finger, action-color fill,
/// label fade, 200ms spring-back, full-fill flash + haptic on complete).
library;

/// The completion threshold: [dragEnd] at or above this progress completes the
/// slide; below it springs back. 0.9 = the thumb must reach ~90% of the track.
const double kConfirmCompletionThreshold = 0.9;

/// The destructive actions that gate behind the countdown dialog (D-06). Lock
/// and sleep (everything else) are the safe pair.
const Set<String> _kDestructiveActions = {'restart', 'shutdown'};

/// Slide-to-confirm track state (05-UI-SPEC state table).
enum ConfirmTrackState {
  /// At rest — thumb docked left, "Slide to {action}" label, nothing sent.
  idle,

  /// A drag is in progress; [ConfirmTrackFsm.progress] tracks the thumb.
  dragging,

  /// A slide completed (≥0.9). The widget renders the full-fill flash; the
  /// next [ConfirmTrackFsm.dragStart] begins a fresh gesture.
  completed,
}

/// An effect the driver (PowerScreen) must execute. Sealed so the widget's
/// switch is exhaustive; each carries only the action string — no wire types.
sealed class ConfirmTrackEffect {
  const ConfirmTrackEffect();
}

/// Send `power {action}` on the reliable path — a slide completed.
final class SendPower extends ConfirmTrackEffect {
  /// The action string (`lock`/`sleep`/`restart`/`shutdown`).
  final String action;

  /// Creates the effect.
  const SendPower(this.action);
}

/// Send `confirm {action}` on the reliable path, immediately after [SendPower].
/// Emitted ONLY for the safe pair (lock/sleep) — never restart/shutdown (D-05).
final class SendConfirm extends ConfirmTrackEffect {
  /// The action string (`lock`/`sleep`).
  final String action;

  /// Creates the effect.
  const SendConfirm(this.action);
}

/// Open the red countdown dialog for the destructive pair (D-06). The dialog's
/// confirm button — NOT this FSM — sends the `confirm {action}`.
final class OpenCountdown extends ConfirmTrackEffect {
  /// The action string (`restart`/`shutdown`).
  final String action;

  /// Creates the effect.
  const OpenCountdown(this.action);
}

/// Release below threshold — spring the thumb back, send nothing (T-05-13).
final class SpringBack extends ConfirmTrackEffect {
  /// Creates the effect.
  const SpringBack();
}

/// Pure per-track slide-to-confirm FSM. See the library doc for the model.
class ConfirmTrackFsm {
  /// The power action this track confirms (`lock`/`sleep`/`restart`/`shutdown`).
  final String action;

  /// Whether this action gates behind the countdown dialog (restart/shutdown).
  final bool isDestructive;

  ConfirmTrackState _state = ConfirmTrackState.idle;
  double _progress = 0.0;

  /// Creates a per-action track FSM, deriving [isDestructive] from [action].
  ConfirmTrackFsm({required this.action})
      : isDestructive = _kDestructiveActions.contains(action);

  /// Current FSM state.
  ConfirmTrackState get state => _state;

  /// Thumb progress 0.0..1.0 — meaningful while dragging (the widget renders
  /// the fill + thumb offset from this).
  double get progress => _progress;

  /// Begin a drag. From ANY state this starts a FRESH gesture (progress 0) —
  /// so a [dragStart] on a just-completed track (completed-resetting) simply
  /// begins again.
  void dragStart() {
    _state = ConfirmTrackState.dragging;
    _progress = 0.0;
  }

  /// Update thumb progress (clamped 0.0..1.0). A no-op unless a drag is active
  /// (an [dragUpdate] without a preceding [dragStart] leaves state untouched).
  void dragUpdate(double progress) {
    if (_state != ConfirmTrackState.dragging) return;
    _progress = progress.clamp(0.0, 1.0);
  }

  /// Release the drag, returning the effects to execute:
  /// - progress ≥ 0.9 → completion (state → completed): safe pair emits
  ///   `[SendPower, SendConfirm]`, destructive pair emits
  ///   `[SendPower, OpenCountdown]` (D-05/D-06).
  /// - below 0.9 → `[SpringBack]`, state → idle, nothing sent (T-05-13).
  /// - no active drag → no effects.
  List<ConfirmTrackEffect> dragEnd() {
    if (_state != ConfirmTrackState.dragging) return const [];

    if (_progress >= kConfirmCompletionThreshold) {
      _state = ConfirmTrackState.completed;
      _progress = 1.0;
      // SendPower ALWAYS first; the second effect diverges by pair.
      return [
        SendPower(action),
        if (isDestructive) OpenCountdown(action) else SendConfirm(action),
      ];
    }

    _state = ConfirmTrackState.idle;
    _progress = 0.0;
    return const [SpringBack()];
  }
}
