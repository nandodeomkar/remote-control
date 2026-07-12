/// The UIPI transient advisory banner (SRV-05 client surface / D-07).
///
/// Client surface for the `input.blocked` (proto 1.3) push: [ConnectionService]
/// parks a transient [InputBlockedSnapshot] (07-11 Task 1) whenever the
/// elevated foreground window silently drops our injected input, and this
/// widget renders the fixed advisory copy for ~4s before auto-dismissing.
///
/// LOCKED styling contract (07-UI-SPEC.md §8): surface fill + hairline edge +
/// muted info icon + primary text — this is an advisory, never a destructive
/// or accent-styled surface, and it never blocks a tap. The whole widget is
/// wrapped in [IgnorePointer] so a parent that overlays it on live content
/// (the 07-13 dashboard/quick-bar composition) never loses touches to it.
///
/// States are injected via constructor suppliers ([snapshot] + [changes]) —
/// mirrors [ConnectionHeaderChip]'s test seam (no Riverpod, no service
/// needed to unit-test the widget); [UipiBanner.forService] wires the real
/// [ConnectionService] for production use.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../net/connection_service.dart';
import '../theme/tokens.dart';

/// The locked D-07 advisory copy (07-UI-SPEC.md §8, verbatim).
const String kUipiBannerCopy =
    "Can't control this window — it's running as administrator";

/// How long the banner stays up after a snapshot lands before auto-dismissing.
/// A newer snapshot restarts this window.
const Duration kUipiBannerDismissDelay = Duration(seconds: 4);

/// Renders the D-07 UIPI advisory on a fresh `input.blocked` push and
/// auto-dismisses ~4s later.
class UipiBanner extends StatefulWidget {
  /// Supplies the current [InputBlockedSnapshot], or null before any push.
  final InputBlockedSnapshot? Function() snapshot;

  /// Pinged on every service state change; the banner re-reads [snapshot]
  /// and treats a new [InputBlockedSnapshot.at] as a fresh transition.
  final Stream<void> changes;

  /// Creates a banner over injected suppliers (test seam — no Riverpod).
  const UipiBanner({super.key, required this.snapshot, required this.changes});

  /// The providers-wired default: reads [ConnectionService.inputBlockedSnapshot]
  /// off the service's [ConnectionService.changes] stream.
  factory UipiBanner.forService(ConnectionService service, {Key? key}) {
    return UipiBanner(
      key: key,
      snapshot: () => service.inputBlockedSnapshot,
      changes: service.changes,
    );
  }

  @override
  State<UipiBanner> createState() => _UipiBannerState();
}

class _UipiBannerState extends State<UipiBanner> {
  StreamSubscription<void>? _sub;
  Timer? _timer;
  InputBlockedSnapshot? _visible;
  DateTime? _lastSeenAt;

  @override
  void initState() {
    super.initState();
    // Seed the "already seen" marker from whatever is parked at mount time
    // WITHOUT showing it — only a snapshot observed AFTER mount (a genuinely
    // new transition) opens the banner.
    _lastSeenAt = widget.snapshot()?.at;
    _sub = widget.changes.listen((_) => _onChange());
  }

  @override
  void didUpdateWidget(covariant UipiBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      _sub?.cancel();
      _sub = widget.changes.listen((_) => _onChange());
    }
  }

  void _onChange() {
    final snap = widget.snapshot();
    if (snap == null || snap.at == _lastSeenAt) {
      return; // no push, or an unrelated changes ping — not a new transition
    }
    _lastSeenAt = snap.at;
    _timer?.cancel();
    setState(() => _visible = snap);
    _timer = Timer(kUipiBannerDismissDelay, () {
      if (mounted) setState(() => _visible = null);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A plain conditional swap (no slide animation) — the D-07 contract is
    // appear-on-event + ~4s auto-dismiss + never-blocks-touch; an animated
    // transition is a cosmetic nicety, not a locked acceptance criterion, and
    // dropping it keeps the appear/dismiss timing deterministic to test.
    return IgnorePointer(
      child: _visible == null ? const SizedBox.shrink() : const _UipiBannerStrip(),
    );
  }
}

/// The advisory strip itself — surface fill, hairline edge, muted info icon,
/// primary text. No destructive or accent color (this is informational, not
/// an error or a call-to-action) and no action button (D-07).
class _UipiBannerStrip extends StatelessWidget {
  const _UipiBannerStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(
          top: BorderSide(color: kHairline),
          bottom: BorderSide(color: kHairline),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: kMuted, size: 16),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              kUipiBannerCopy,
              style: TextStyle(
                color: kText,
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
