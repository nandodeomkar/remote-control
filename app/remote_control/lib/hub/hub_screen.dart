/// The Remote dashboard (D-08/D-09, finalized 07-13; Shortcuts added 10-02) —
/// the app's home screen and its final identity: 9 tools, one tile tap away.
///
/// [kHubTiles] is the ORDERED tile registry the grid renders from: Trackpad,
/// Keyboard, Shortcuts, Media, Apps, Clipboard, Power, Presenter, Browser
/// (Shortcuts inserted at position 3, 10-02). The grid is a UNIFORM 2-column
/// chunk (07-UI-SPEC §1, Pitfall 9): the legacy full-width Trackpad primary
/// row is gone — the floating trackpad bubble (`BubbleScaffold`, 08-06) now
/// carries Trackpad primacy on every tool screen. An odd tail (the 9th tile)
/// renders half-width beside an empty slot.
///
/// [HubTileGrid] is widget-only (the MouseButtonsBar callback pattern):
/// taps surface through the injected `onOpen(spec)` so widget tests never
/// touch the Navigator. [HubScreen] wires `onOpen` to a plain
/// `MaterialPageRoute` push of the spec's builder (house rule — no
/// go_router).
///
/// Offline-disabled tiles (D-08 / 07-UI-SPEC §2): when the chip status is
/// `disconnected`, every tool tile renders with `onTap: null` and a muted
/// label — visible (layout stays stable) but non-tappable, no ripple. The
/// app-bar settings gear and the add/switch-PC path (inside Settings) stay
/// reachable offline (D-11). While `reconnecting`, tiles stay tappable —
/// tool screens gate their own sends.
///
/// Chrome contract (07-UI-SPEC): app bar = connected device name (fallback
/// "Remote", 16/600) + inherited header chip + the settings gear (always
/// tappable); reconnecting banner slot under the app bar (D-02). Tile:
/// `#16181D` fill, `#2A2D34` 1px border, 16px radius, centered icon 32px
/// `#6B7280` + xs gap + label 16/600 `#E6E8EB`, Material InkWell ripple
/// (navigation, not state — no accent flash). Grid: md (16px) edge padding +
/// gaps, xl (32px) top padding.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../apps/apps_screen.dart';
import '../browser/browser_screen.dart';
import '../clipboard/clipboard_screen.dart';
import '../keyboard/keyboard_screen.dart';
import '../media/media_screen.dart';
import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../power/power_screen.dart';
import '../presenter/presenter_screen.dart';
import '../settings/settings_screen.dart';
import '../shortcuts/shortcuts_screen.dart';
import '../theme/tokens.dart';
import '../trackpad/trackpad_screen.dart';
import '../update/update_providers.dart';
import '../update/updates_screen.dart';
import '../widgets/bubble_scaffold.dart';
import '../widgets/connection_header.dart';

/// One hub tile: label + icon + the tool screen it opens.
class HubTileSpec {
  /// Tile label (UI-SPEC copy: "Trackpad", "Browser", …).
  final String label;

  /// Tile icon (UI-SPEC icon table), rendered 32px muted.
  final IconData icon;

  /// Builds the destination screen for the MaterialPageRoute push.
  final WidgetBuilder builder;

  /// Whether the pushed destination shows the floating trackpad bubble
  /// (D8-05). False ONLY for the Trackpad tile — no redundant shortcut to the
  /// screen you are on; the [BubbleScaffold] wrapper (and its UIPI banner)
  /// still applies.
  final bool showBubble;

  /// Creates a tile spec.
  const HubTileSpec({
    required this.label,
    required this.icon,
    required this.builder,
    this.showBubble = true,
  });
}

/// The ordered tile registry — LOCKED to the exact D-09 reading order:
/// Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser.
final List<HubTileSpec> kHubTiles = [
  HubTileSpec(
    label: 'Trackpad',
    icon: Symbols.touch_app_rounded,
    builder: (_) => const TrackpadScreen(),
    // D8-05: never a bubble shortcut to the screen you are on.
    showBubble: false,
  ),
  // 07-13: Keyboard promoted to a first-class screen at position 2 (D-09).
  HubTileSpec(
    label: 'Keyboard',
    icon: Symbols.keyboard_rounded,
    builder: (_) => const KeyboardScreen(),
  ),
  // 10-02: Shortcuts inserted at position 3 (after Keyboard, before Media) —
  // one-tap Windows shortcut buttons over the reliable key tap+mods path.
  HubTileSpec(
    label: 'Shortcuts',
    icon: Symbols.bolt_rounded,
    builder: (_) => const ShortcutsScreen(),
  ),
  // 05-07: Media inserted ahead of Power — the final UI-SPEC reading order is
  // now Trackpad, Media, Power, Presenter, Browser (D-01 complete at 5 tiles).
  HubTileSpec(
    label: 'Media',
    icon: Symbols.music_note_rounded,
    builder: (_) => const MediaScreen(),
  ),
  // 06-03: Apps inserted after Media, before Power (06-UI-SPEC placement).
  HubTileSpec(
    label: 'Apps',
    icon: Symbols.apps_rounded,
    builder: (_) => const AppsScreen(),
  ),
  // 06-05: Clipboard inserted after Apps, before Power (06-UI-SPEC placement) —
  // reading order Trackpad, Media, Apps, Clipboard, Power, Presenter, Browser.
  HubTileSpec(
    label: 'Clipboard',
    icon: Symbols.content_paste_rounded,
    builder: (_) => const ClipboardScreen(),
  ),
  // 05-06: Power sits between Media and Presenter.
  HubTileSpec(
    label: 'Power',
    icon: Symbols.power_settings_new_rounded,
    builder: (_) => const PowerScreen(),
  ),
  // 05-04: Presenter sits between Power and Browser.
  HubTileSpec(
    label: 'Presenter',
    icon: Symbols.slideshow_rounded,
    builder: (_) => const PresenterScreen(),
  ),
  HubTileSpec(
    label: 'Browser',
    icon: Symbols.public_rounded,
    builder: (_) => const BrowserScreen(),
  ),
];

/// The tile grid: ALL tiles chunked into uniform 2-column rows (07-UI-SPEC
/// §1 — the legacy full-width primary row is gone, Pitfall 9). Widget-only —
/// taps fire [onOpen] with the tapped spec.
class HubTileGrid extends StatelessWidget {
  /// Ordered tiles to render (normally [kHubTiles]).
  final List<HubTileSpec> tiles;

  /// Fired with the tapped tile's spec.
  final void Function(HubTileSpec spec) onOpen;

  /// False renders every tile disabled (D-08 offline: `onTap` null, muted
  /// label, no ripple) while keeping the layout stable.
  final bool enabled;

  /// Creates the grid.
  const HubTileGrid({
    super.key,
    required this.tiles,
    required this.onOpen,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];

    // Uniform 2-column reading order, md gaps. Handles any count — an odd
    // tail renders as a half-width tile beside an empty slot.
    for (var i = 0; i < tiles.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _halfTile(tiles[i])),
            const SizedBox(width: 16),
            Expanded(
              child: i + 1 < tiles.length
                  ? _halfTile(tiles[i + 1])
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 16),
          rows[r],
        ],
      ],
    );
  }

  /// Uniform tiles keep a ~1.4:1 cell shape (UI-SPEC §1 — applied to ALL 8).
  Widget _halfTile(HubTileSpec spec) => AspectRatio(
        aspectRatio: 1.4,
        child: _HubTile(spec: spec, onOpen: onOpen, enabled: enabled),
      );
}

/// One tile: `#16181D` fill, `#2A2D34` border, 16px radius, centered icon
/// 32px muted + label 16/600. InkWell ripple only — tiles are navigation,
/// not state, so there is no accent flash. Disabled (D-08 offline): `onTap`
/// null (no ripple), label muted, same fill/border so the layout is stable.
class _HubTile extends StatelessWidget {
  final HubTileSpec spec;
  final void Function(HubTileSpec spec) onOpen;
  final bool enabled;

  const _HubTile({
    required this.spec,
    required this.onOpen,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: kHairline),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: enabled ? () => onOpen(spec) : null,
        borderRadius: BorderRadius.circular(16),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 32, color: kMuted),
              const SizedBox(height: 4),
              Text(
                spec.label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: enabled ? kText : kMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The hub screen: device-name app bar + chip + banner over the tile grid.
class HubScreen extends ConsumerStatefulWidget {
  /// Creates the hub screen.
  const HubScreen({super.key});

  @override
  ConsumerState<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends ConsumerState<HubScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
  }

  /// Tile tap → plain MaterialPageRoute push (house rule, D-01), wrapped in
  /// [BubbleScaffold] CENTRALLY so every tool screen gets the floating
  /// trackpad bubble + UIPI banner (D8-05) — the Trackpad tile alone
  /// passes `showBubble: false` (no shortcut to the screen you are on).
  void _open(HubTileSpec spec) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => BubbleScaffold(
            showBubble: spec.showBubble,
            body: spec.builder(context),
          ),
        ),
      ),
    );
  }

  /// Gear tap → SettingsScreen. Always reachable, including offline (D-11).
  void _openSettings() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — rebuilds on lifecycle changes only, never
    // on the hot move path.
    final status = ref.watch(connectionStatusProvider);
    final deviceName = _service.target?.name ?? 'Remote';
    // D-08: disconnected disables every tool tile (visible, muted, onTap
    // null). Reconnecting keeps them tappable — tool screens gate their own
    // sends; the chip + banner carry the status.
    final offline = status.chip == ChipStatus.disconnected;
    // 12-15: reads the update CACHE, so it is correct offline and before the
    // Updates screen has ever been opened. Same provider as the Settings row —
    // one source of truth, two placements.
    final badge = ref.watch(updateBadgeProvider);

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: Text(
          deviceName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
        actions: [
          Center(child: ConnectionHeaderChip.forService(_service)),
          // D-11: the settings gear — ALWAYS tappable, offline included.
          //
          // 12-15: the update badge rides it as a Stack OVERLAY. The
          // IconButton's size, colour, icon and geometry are untouched and the
          // dot is never a layout participant, so the app bar cannot reflow
          // when an update lands. The tooltip carries the state for a screen
          // reader (IconButton surfaces tooltip as its semantics label, so
          // this costs no extra node and cannot desync from the dot).
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Stack(
              children: [
                IconButton(
                  tooltip: badge ? kSettingsWithUpdateTooltip : kSettingsTitle,
                  onPressed: _openSettings,
                  icon: const Icon(
                    Symbols.settings_rounded,
                    size: 24,
                    color: kText,
                  ),
                ),
                if (badge)
                  const Positioned(
                    right: 10,
                    top: 10,
                    child: UpdateBadgeDot(),
                  ),
              ],
            ),
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
                child: HubTileGrid(
                  tiles: kHubTiles,
                  onOpen: _open,
                  enabled: !offline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
