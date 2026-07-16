/// The Clipboard screen (CLIP-01/02/04, D-06) — one-tap Send to PC, Fetch from
/// PC, and a persistent last-5 history whose entries re-push to the PC.
///
/// Layout (06-UI-SPEC), top→bottom with xl top padding:
///   - App bar "Clipboard" + inherited header chip + reconnecting banner slot.
///   - Action row: two equal key-cap buttons — "Send to PC" (`arrow_upward`)
///     and "Fetch from PC" (`arrow_downward`), sm gap, ≥48px, pressed
///     accent-flash + haptic.
///   - Auto-sync row (CLIP-03, 06-06): "Auto-sync clipboard" label + a Material
///     Switch (accent on / inactive off, DEFAULT OFF, ALWAYS enabled — a local
///     preference exempt from connection gating, D-03), with the persistent
///     honesty note directly beneath (never hidden, D-08).
///   - History section: header "Recent", up to 5 entries most-recent-first,
///     tap → reuse (re-push to the PC, D-06) + snackbar. Empty → an empty state.
///
/// Send reads the phone clipboard (`Clipboard.getData`) and pushes `clip.set`;
/// Fetch pushes `clip.get` and the reply (a `clip.set` frame) is written to the
/// phone clipboard (`Clipboard.setData`). All wire-bound controls are gated on
/// connection (muted, never red — inherited rule); the fetch outcome surfaces as
/// a transient snackbar off the notifier's identity-tracked fetch event.
///
/// Auto-sync (06-06): when ON, a `clip.changed` push applies to the phone
/// clipboard live (client-gated, RESEARCH A4) and phone→PC syncs on app resume
/// (Android 10+ background-read limit, D-08) — an [AppLifecycleListener] drives
/// the resume hook. Echo suppression lives in the store (D-05).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'clip_store.dart';

/// The Clipboard remote: Send/Fetch action row + last-5 history (CLIP-01/02/04).
class ClipboardScreen extends ConsumerStatefulWidget {
  /// Creates the Clipboard screen.
  const ClipboardScreen({super.key});

  @override
  ConsumerState<ClipboardScreen> createState() => _ClipboardScreenState();
}

class _ClipboardScreenState extends ConsumerState<ClipboardScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;
  StreamSubscription<void>? _sub;

  /// The D-08 resume hook: on `AppLifecycleState.resumed` the notifier reads the
  /// phone clipboard and (when auto-sync is on) syncs it to the PC. Disposed
  /// with the screen.
  AppLifecycleListener? _lifecycle;

  /// The last fetch event already surfaced (identity-tracked — the value-equal
  /// view does not rebuild on an empty-PC Fetch, so the screen watches the raw
  /// `changes` stream to catch each fresh outcome exactly once).
  ClipFetchEvent? _shownFetch;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    // Build the ClipNotifier NOW (it subscribes to `changes` in build) so on a
    // Fetch-reply ping it consumes the reply before our listener runs and we
    // see the fresh lastFetchEvent on the same ping.
    ref.read(clipStateProvider.notifier);
    // WR-01: seed the "already seen" marker from whatever fetch event is
    // parked at mount time WITHOUT surfacing it — the first post-mount
    // `changes` ping must not re-toast a fetch outcome ("Copied to phone.")
    // from a previous visit minutes ago. Mirrors the UipiBanner pattern.
    _shownFetch = ref.read(clipStateProvider.notifier).lastFetchEvent;
    _sub = _service.changes.listen((_) => _maybeShowFetch());
    // phone→PC on foreground only (Android 10+ blocks background reads, D-08).
    _lifecycle = AppLifecycleListener(
      onResume: () =>
          unawaited(ref.read(clipStateProvider.notifier).syncOnResume()),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    super.dispose();
  }

  void _maybeShowFetch() {
    final ev = ref.read(clipStateProvider.notifier).lastFetchEvent;
    if (ev == null || identical(ev, _shownFetch)) return;
    _shownFetch = ev;
    if (!mounted) return;
    switch (ev.outcome) {
      case ClipFetchOutcome.copied:
        _toast('Copied to phone.');
      case ClipFetchOutcome.empty:
        _toast('Your PC clipboard is empty.');
    }
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message, style: const TextStyle(color: kText)),
          backgroundColor: kSurface,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // "Send to PC" (CLIP-01): read the phone clipboard, gate on empty / too-large,
  // else push clip.set + record to history via the notifier.
  Future<void> _onSend() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (!mounted) return;
    if (text == null || text.isEmpty) {
      _toast('Your phone clipboard is empty.');
      return;
    }
    final result = await ref.read(clipStateProvider.notifier).send(text);
    if (!mounted) return;
    switch (result) {
      case ClipSendResult.sent:
        _toast('Sent to PC.');
      case ClipSendResult.tooLarge:
        _toast('That\'s too large to send.');
    }
  }

  // "Fetch from PC" (CLIP-02): pull clip.get; the reply outcome surfaces async
  // through _maybeShowFetch on a later `changes` ping.
  void _onFetch() => ref.read(clipStateProvider.notifier).fetch();

  // History reuse (D-06): re-push the entry to the PC clipboard + snackbar.
  Future<void> _onReuse(String entry) async {
    await ref.read(clipStateProvider.notifier).reuse(entry);
    if (!mounted) return;
    _toast('Sent to PC.');
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;
    final clip = ref.watch(clipStateProvider);

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          'Clipboard',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: ConnectionHeaderChip.forService(_service)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: SingleChildScrollView(
                // md edge padding, xl top padding (UI-SPEC).
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Action row: Send / Fetch, sm gap, equal widths.
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: Symbols.arrow_upward_rounded,
                            label: 'Send to PC',
                            enabled: authed,
                            onPress: _onSend,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionButton(
                            icon: Symbols.arrow_downward_rounded,
                            label: 'Fetch from PC',
                            enabled: authed,
                            onPress: _onFetch,
                          ),
                        ),
                      ],
                    ),
                    // lg gap → auto-sync row (CLIP-03), then the persistent
                    // honesty note directly beneath (D-03/D-08).
                    const SizedBox(height: 24),
                    _AutoSyncRow(
                      value: clip.autoSyncOn,
                      onChanged: (v) =>
                          ref.read(clipStateProvider.notifier).setAutoSync(v),
                    ),
                    const SizedBox(height: 8),
                    const _HonestyNote(),
                    const SizedBox(height: 24),
                    const _SectionHeader('Recent'),
                    const SizedBox(height: 8),
                    _HistorySection(
                      history: clip.history,
                      enabled: authed,
                      onReuse: _onReuse,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A 16/600 section header (UI-SPEC typography role: Title).
class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
      );
}

/// The auto-sync toggle row (CLIP-03 / D-03): "Auto-sync clipboard" label +
/// a Material [Switch] (accent `#4C8DFF` on / inactive `#2A2D34` off). Default
/// OFF, ≥48px. ALWAYS enabled — it is a local persisted preference, exempt from
/// the connection gating that mutes the wire-bound controls.
class _AutoSyncRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _AutoSyncRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Auto-sync clipboard',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: kText,
                ),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged, // never gated — local preference (D-03)
              activeThumbColor: kAccent,
              activeTrackColor: kAccent,
              inactiveThumbColor: kText,
              inactiveTrackColor: kHairline,
            ),
          ],
        ),
      );
}

/// The persistent Android-honesty note (D-08) — ALWAYS visible regardless of
/// the toggle: leading `Symbols.info_rounded` + 12/400 `#6B7280` copy explaining
/// the platform limit (phone→PC only on foreground, PC→phone live).
class _HonestyNote extends StatelessWidget {
  const _HonestyNote();

  @override
  Widget build(BuildContext context) => const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Symbols.info_rounded, size: 16, color: kMuted),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Phone → PC syncs when you open this app. PC → phone syncs live.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: kMuted,
              ),
            ),
          ),
        ],
      );
}

/// One key-cap action button (carried Phase-4/5 pressed pattern): `#16181D`
/// fill + `#2A2D34` border at rest; press-down flashes the accent border +
/// icon/label (`#4C8DFF`) and fires a haptic tick, then relaxes after 100ms.
/// Gated muted (`#6B7280`, never red) when disabled. ≥48px tall (UI-SPEC).
class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPress;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPress,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _pressed = false;

  // Press-down (Phase-4 rule): fire + haptic + accent flash immediately.
  void _fire() {
    widget.onPress();
    hapticTick();
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _pressed ? kAccent : kHairline;
    final fg = !widget.enabled
        ? kMuted
        : _pressed
            ? kAccent
            : kText;
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.enabled ? () {} : null,
        onTapDown: widget.enabled ? (_) => _fire() : null,
        child: SizedBox(
          height: 56,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 20, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The history list, or the empty state when there is nothing recorded yet.
class _HistorySection extends StatelessWidget {
  final List<String> history;
  final bool enabled;
  final Future<void> Function(String entry) onReuse;

  const _HistorySection({
    required this.history,
    required this.enabled,
    required this.onReuse,
  });

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const _EmptyState(
        heading: 'Nothing copied yet',
        body: 'Text you copy will show up here.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < history.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          // Most-recent-first (server of truth is the store — no client sort).
          _HistoryEntry(
            text: history[i],
            enabled: enabled,
            onReuse: () => onReuse(history[i]),
          ),
        ],
      ],
    );
  }
}

/// One history entry: ≥48px, text 14/400 up to 2 lines ellipsized. Tap →
/// reuse (re-push to the PC, D-06) with the Phase-4/5 pressed accent flash +
/// haptic. Gated muted when not connected.
class _HistoryEntry extends StatefulWidget {
  final String text;
  final bool enabled;
  final VoidCallback onReuse;

  const _HistoryEntry({
    required this.text,
    required this.enabled,
    required this.onReuse,
  });

  @override
  State<_HistoryEntry> createState() => _HistoryEntryState();
}

class _HistoryEntryState extends State<_HistoryEntry> {
  bool _pressed = false;

  void _fire() {
    widget.onReuse();
    hapticTick();
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _pressed ? kAccent : kHairline;
    final textColor = !widget.enabled
        ? kMuted
        : _pressed
            ? kAccent
            : kText;
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.enabled ? () {} : null,
        onTapDown: widget.enabled ? (_) => _fire() : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A centered empty state: 16/600 heading over 14/400 muted body copy.
class _EmptyState extends StatelessWidget {
  final String heading;
  final String body;

  const _EmptyState({required this.heading, required this.body});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Text(
              heading,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: kText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: kMuted,
              ),
            ),
          ],
        ),
      );
}
