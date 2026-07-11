/// The interim Remote hub (D-01/D-02, 05-02) — the Phase-7 dashboard
/// skeleton, NOT throwaway: device rows land here, and every tool screen is
/// one tile tap away.
///
/// [kHubTiles] is the ORDERED tile registry the grid renders from: Trackpad
/// is always FIRST and spans the full width (the primary tile, D-02);
/// everything after renders as half-width tiles in 2-column reading order.
/// Later plans grow the registry in place — 05-04 (Media), 05-06 (Power),
/// 05-07 (Presenter), Phase 7 (Apps/Clipboard/Settings) — with NO structural
/// change to the grid ([HubTileGrid] chunks whatever list it is given).
///
/// [HubTileGrid] is widget-only (the MouseButtonsBar callback pattern):
/// taps surface through the injected `onOpen(spec)` so widget tests never
/// touch the Navigator. [HubScreen] wires `onOpen` to a plain
/// `MaterialPageRoute` push of the spec's builder (house rule — no
/// go_router). Tiles stay tappable while disconnected (RESEARCH open
/// question 2): the header chip + banner carry the status, tool screens gate
/// their own sends.
///
/// Chrome contract (05-UI-SPEC): app bar = connected device name (fallback
/// "Remote", 16/600) + inherited header chip; reconnecting banner slot under
/// the app bar (D-02). Tile: `#16181D` fill, `#2A2D34` 1px border, 16px
/// radius, centered icon 32px `#6B7280` + xs gap + label 16/600 `#E6E8EB`,
/// Material InkWell ripple (navigation, not state — no accent flash). Grid:
/// md (16px) edge padding + gaps, xl (32px) top padding.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../apps/apps_screen.dart';
import '../browser/browser_screen.dart';
import '../clipboard/clipboard_screen.dart';
import '../media/media_screen.dart';
import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../power/power_screen.dart';
import '../presenter/presenter_screen.dart';
import '../trackpad/trackpad_screen.dart';
import '../widgets/connection_header.dart';

// UI-SPEC locked palette.
const Color _bg = Color(0xFF0E0F12);
const Color _surface = Color(0xFF16181D);
const Color _hairline = Color(0xFF2A2D34);
const Color _text = Color(0xFFE6E8EB);
const Color _muted = Color(0xFF6B7280);

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

/// The ordered tile registry. Trackpad FIRST (full-width primary — D-02).
/// 05-04/05-06/05-07 and Phase 7 insert tiles here; the grid needs no
/// structural change.
final List<HubTileSpec> kHubTiles = [
  HubTileSpec(
    label: 'Trackpad',
    icon: Icons.touch_app,
    builder: (_) => const TrackpadScreen(),
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

/// The tile grid: first tile full-width, the rest chunked into 2-column
/// rows. Widget-only — taps fire [onOpen] with the tapped spec.
class HubTileGrid extends StatelessWidget {
  /// Ordered tiles to render (normally [kHubTiles]).
  final List<HubTileSpec> tiles;

  /// Fired with the tapped tile's spec.
  final void Function(HubTileSpec spec) onOpen;

  /// Creates the grid.
  const HubTileGrid({super.key, required this.tiles, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    if (tiles.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[
      // The full-width primary tile (Trackpad — D-02).
      SizedBox(height: 96, child: _HubTile(spec: tiles.first, onOpen: onOpen)),
    ];

    // Remaining tiles: 2-column reading order, md gaps. Handles any count —
    // an odd tail renders as a half-width tile beside an empty slot.
    for (var i = 1; i < tiles.length; i += 2) {
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

  /// Half-width tiles keep a ~1.4:1 cell shape (UI-SPEC).
  Widget _halfTile(HubTileSpec spec) => AspectRatio(
        aspectRatio: 1.4,
        child: _HubTile(spec: spec, onOpen: onOpen),
      );
}

/// One tile: `#16181D` fill, `#2A2D34` border, 16px radius, centered icon
/// 32px muted + label 16/600. InkWell ripple only — tiles are navigation,
/// not state, so there is no accent flash.
class _HubTile extends StatelessWidget {
  final HubTileSpec spec;
  final void Function(HubTileSpec spec) onOpen;

  const _HubTile({required this.spec, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _surface,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: _hairline),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: () => onOpen(spec),
        borderRadius: BorderRadius.circular(16),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(spec.icon, size: 32, color: _muted),
              const SizedBox(height: 4),
              Text(
                spec.label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: _text,
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

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — rebuilds on lifecycle changes only, never
    // on the hot move path.
    final status = ref.watch(connectionStatusProvider);
    final deviceName = _service.target?.name ?? 'Remote';

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: Text(
          deviceName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: _text,
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
                child: HubTileGrid(tiles: kHubTiles, onOpen: _open),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
