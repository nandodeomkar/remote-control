/// The Remote dashboard (D-08/D-09, finalized 07-13) — the app's home screen
/// and its final identity: 8 tools, one tile tap away.
///
/// [kHubTiles] is the ORDERED tile registry the grid renders from, LOCKED to
/// the exact D-09 reading order: Trackpad, Keyboard, Media, Apps, Clipboard,
/// Power, Presenter, Browser. The grid is a UNIFORM 2×4 (07-UI-SPEC §1,
/// Pitfall 9): the legacy full-width Trackpad primary row is gone — the
/// persistent quick-bar (`QuickBarScaffold`, 07-13 Task 2) now carries
/// Trackpad primacy on every tool screen.
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
import '../theme/tokens.dart';
import '../trackpad/trackpad_screen.dart';
import '../widgets/connection_header.dart';

/// One hub tile: label + icon + the tool screen it opens.
class HubTileSpec {
  /// Tile label (UI-SPEC copy: "Trackpad", "Browser", …).
  final String label;

  /// Tile icon (UI-SPEC icon table), rendered 32px muted.
  final IconData icon;

  /// Builds the destination screen for the MaterialPageRoute push.
  final WidgetBuilder builder;

  /// Creates a tile spec.
  const HubTileSpec({
    required this.label,
    required this.icon,
    required this.builder,
  });
}

/// The ordered tile registry — LOCKED to the exact D-09 reading order:
/// Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser.
final List<HubTileSpec> kHubTiles = [
  HubTileSpec(
    label: 'Trackpad',
    icon: Icons.touch_app,
    builder: (_) => const TrackpadScreen(),
  ),
  // 07-13: Keyboard promoted to a first-class screen at position 2 (D-09).
  HubTileSpec(
    label: 'Keyboard',
    icon: Icons.keyboard,
    builder: (_) => const KeyboardScreen(),
  ),
  // 05-07: Media inserted ahead of Power — the final UI-SPEC reading order is
  // now Trackpad, Media, Power, Presenter, Browser (D-01 complete at 5 tiles).
  HubTileSpec(
    label: 'Media',
    icon: Icons.music_note,
    builder: (_) => const MediaScreen(),
  ),
  // 06-03: Apps inserted after Media, before Power (06-UI-SPEC placement).
  HubTileSpec(
    label: 'Apps',
    icon: Icons.apps,
    builder: (_) => const AppsScreen(),
  ),
  // 06-05: Clipboard inserted after Apps, before Power (06-UI-SPEC placement) —
  // reading order Trackpad, Media, Apps, Clipboard, Power, Presenter, Browser.
  HubTileSpec(
    label: 'Clipboard',
    icon: Icons.content_paste,
    builder: (_) => const ClipboardScreen(),
  ),
  // 05-06: Power sits between Media and Presenter.
  HubTileSpec(
    label: 'Power',
    icon: Icons.power_settings_new,
    builder: (_) => const PowerScreen(),
  ),
  // 05-04: Presenter sits between Power and Browser.
  HubTileSpec(
    label: 'Presenter',
    icon: Icons.slideshow,
    builder: (_) => const PresenterScreen(),
  ),
  HubTileSpec(
    label: 'Browser',
    icon: Icons.public,
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

  /// Tile tap → plain MaterialPageRoute push (house rule, D-01).
  void _open(HubTileSpec spec) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: spec.builder),
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
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: kSettingsTitle,
              onPressed: _openSettings,
              icon: const Icon(Icons.settings, size: 24, color: kText),
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
