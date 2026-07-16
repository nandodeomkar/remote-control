/// The Browser tool screen (BROW-01, 05-02) — a 2-column macro grid that
/// drives the focused PC browser via the reliable path.
///
/// [kBrowserActions] is the single source of truth for the macro vocabulary:
/// each action string MUST byte-match the server router's `browser_macro`
/// table (`server-core/src/dispatch/router.rs` — back, forward, newtab,
/// closetab, refresh, zoomin, zoomout). Unknown actions are silently dropped
/// server-side, so drift here would be an invisible production no-op — the
/// vocabulary is pinned by test/browser/browser_screen_test.dart.
///
/// [BrowserMacroGrid] is widget-only and service-agnostic (the
/// MouseButtonsBar pattern): presses surface through the injected `onAction`
/// callback on tap-DOWN, so widget tests need no service fake. The screen
/// wires `onAction` to `sendReliable(BrowserMsg(...))` + the haptic tick and
/// gates `enabled` on the transition-only status watch (gated-muted
/// `#6B7280` when not connected — never red).
///
/// Chrome contract (05-UI-SPEC): app bar "Browser" + header chip;
/// reconnecting banner under the app bar (D-02); key-cap buttons — `#16181D`
/// fill, `#2A2D34` 1px border, 8px radius, ≥48px tall, icon + label 16/600
/// `#E6E8EB`; pressed = `#4C8DFF` border + accent icon/label flash
/// (momentary, no easing). Grid: md (16px) edge padding, sm (8px) gaps,
/// xl (32px) top padding. Rows: Back/Forward, New tab/Close tab, Refresh
/// (full-width), Zoom out/Zoom in.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';

/// One browser macro: UI label + icon + the router-vocabulary action string.
class BrowserActionSpec {
  /// Button label (UI-SPEC copy: "Back", "New tab", …).
  final String label;

  /// Button icon (UI-SPEC icon table).
  final IconData icon;

  /// The wire action string — MUST byte-match router.rs `browser_macro`.
  final String action;

  /// Creates a macro spec.
  const BrowserActionSpec({
    required this.label,
    required this.icon,
    required this.action,
  });
}

/// The 7 browser macros in grid reading order (UI-SPEC rows: Back/Forward,
/// New tab/Close tab, Refresh, Zoom out/Zoom in). Action strings are the
/// exact server vocabulary — see the library doc.
const List<BrowserActionSpec> kBrowserActions = [
  BrowserActionSpec(label: 'Back', icon: Symbols.arrow_back_rounded, action: 'back'),
  BrowserActionSpec(
    label: 'Forward',
    icon: Symbols.arrow_forward_rounded,
    action: 'forward',
  ),
  BrowserActionSpec(label: 'New tab', icon: Symbols.add_rounded, action: 'newtab'),
  BrowserActionSpec(label: 'Close tab', icon: Symbols.close_rounded, action: 'closetab'),
  BrowserActionSpec(label: 'Refresh', icon: Symbols.refresh_rounded, action: 'refresh'),
  BrowserActionSpec(label: 'Zoom out', icon: Symbols.zoom_out_rounded, action: 'zoomout'),
  BrowserActionSpec(label: 'Zoom in', icon: Symbols.zoom_in_rounded, action: 'zoomin'),
];

/// The 2-column macro grid. Widget-only: fires [onAction] with the spec's
/// action string on tap-down; [enabled] false renders the gated all-muted,
/// non-interactive state ("muted, not red").
class BrowserMacroGrid extends StatelessWidget {
  /// Fired on tap-down with the router action string.
  final void Function(String action) onAction;

  /// False renders the gated muted state; taps are inert.
  final bool enabled;

  /// Creates the grid over [kBrowserActions].
  const BrowserMacroGrid({
    super.key,
    required this.onAction,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    // UI-SPEC rows: pairs in reading order, Refresh full-width on its own
    // row. Built from the spec list — no per-button hardcoding.
    final rows = <Widget>[];
    var i = 0;
    while (i < kBrowserActions.length) {
      final spec = kBrowserActions[i];
      if (spec.action == 'refresh' || i + 1 >= kBrowserActions.length) {
        rows.add(_key(spec));
        i += 1;
      } else {
        final next = kBrowserActions[i + 1];
        rows.add(
          Row(
            children: [
              Expanded(child: _key(spec)),
              const SizedBox(width: 8),
              Expanded(child: _key(next)),
            ],
          ),
        );
        i += 2;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 8),
          rows[r],
        ],
      ],
    );
  }

  Widget _key(BrowserActionSpec spec) =>
      _BrowserKey(spec: spec, enabled: enabled, onAction: onAction);
}

/// One key-cap macro button: tap-down accent flash (momentary, no easing) +
/// onAction — the Phase-4 MouseButtonsBar press pattern.
class _BrowserKey extends StatefulWidget {
  final BrowserActionSpec spec;
  final bool enabled;
  final void Function(String action) onAction;

  const _BrowserKey({
    required this.spec,
    required this.enabled,
    required this.onAction,
  });

  @override
  State<_BrowserKey> createState() => _BrowserKeyState();
}

class _BrowserKeyState extends State<_BrowserKey> {
  bool _pressed = false;

  void _onTapDown(TapDownDetails _) {
    setState(() => _pressed = true);
    // Act on press-down (benchmark feel; haptic fires in the screen's
    // callback, so tick and send share the press instant).
    widget.onAction(widget.spec.action);
  }

  void _release() {
    if (_pressed) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && _pressed;
    final borderColor = active ? kAccent : kHairline;
    final contentColor =
        active ? kAccent : (widget.enabled ? kText : kMuted);

    return GestureDetector(
      onTapDown: widget.enabled ? _onTapDown : null,
      onTapUp: widget.enabled ? (_) => _release() : null,
      onTapCancel: widget.enabled ? _release : null,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.spec.icon, size: 20, color: contentColor),
            const SizedBox(width: 4),
            Text(
              widget.spec.label,
              style: TextStyle(
                color: contentColor,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Browser screen: header chrome + the macro grid wired to the reliable
/// path. Every macro rides `sendReliable(BrowserMsg(...))` — nothing here
/// touches the volatile move path or the hot-path invariant.
class BrowserScreen extends ConsumerStatefulWidget {
  /// Creates the browser screen.
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
  }

  /// Press-down: reliable macro + haptic tick (Phase-4 rule — on press,
  /// not release; SendPolicy owns the auth gating downstream).
  void _onAction(String action) {
    _service.sendReliable(BrowserMsg(action: action));
    hapticTick();
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — never pinged by the hot path.
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          'Browser',
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
            // D-02: the non-blocking drop strip under the app bar.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: SingleChildScrollView(
                // md edge padding, xl top padding (UI-SPEC grid contract).
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: BrowserMacroGrid(
                  onAction: _onAction,
                  enabled: authed,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
