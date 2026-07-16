/// The Shortcuts tool screen (KEY-03, 10-02) — a registry-driven catalog of
/// 25 one-tap Windows shortcut buttons across 4 sections, each labeled by its
/// effect ("Show desktop") with the chord as subtext ("Win+D"), firing ONE
/// `key {action: tap, mods: [...]}` over the existing reliable path.
///
/// [kShortcutCatalog] is the single ordered source of truth: sections +
/// entries drive BOTH the render and the vocabulary coverage test. Every
/// [ShortcutSpec.code] MUST be a member of the locked `kClientKeyCodes`
/// vocabulary (keymap.rs mirror — drift fails the build, T-10-03); unknown
/// codes drop silently server-side (T-04-02). The user-locked exclusions
/// (Alt+Tab, Win+L lock, Ctrl+Alt+Del) never appear.
///
/// [ShortcutButton] is the house press-DOWN pattern (media `_TransportButton`
/// twin): tap-down fires the send + `hapticTick()` + a 100ms accent flash,
/// then relaxes. Fire-and-forget — NEVER an optimistic/result state. Gated
/// (unauthed / disconnected): icon + labels render `kMuted`, the border stays
/// `kHairline`, and the press entry is null — muted-not-red, layout stable.
///
/// Chrome (10-UI-SPEC §Screen 2): the media/browser shell — app bar
/// "Shortcuts" 16/600 + [ConnectionHeaderChip] + [ReconnectingBannerSlot] over
/// a [SingleChildScrollView] (md edge padding, xl top padding). Sections read
/// top-to-bottom, each a left-aligned 16/600 header over a 2-column grid of
/// buttons (sm gaps); an odd tail renders half-width beside an empty slot.
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

/// App-bar title + tile label (house rule: no inline copy literals).
const String kShortcutsTitle = 'Shortcuts';

/// One shortcut: effect label + combo subtext + icon + the wire chord it fires
/// (`key {action: tap, mods}`). [code] MUST be in `kClientKeyCodes`; [mods]
/// entries are the wire vocabulary `ctrl`/`alt`/`shift`/`win`.
class ShortcutSpec {
  /// Effect copy — the button label ('Show desktop').
  final String label;

  /// Combo subtext, verbatim ('Win+D').
  final String combo;

  /// Button icon (10-UI-SPEC §Shortcut catalog — rounded axis).
  final IconData icon;

  /// The `key.code` sent on the wire — MUST be in `kClientKeyCodes`.
  final String code;

  /// Wire modifiers (`ctrl`|`alt`|`shift`|`win`), default `[]`.
  final List<String> mods;

  /// Creates a shortcut spec.
  const ShortcutSpec({
    required this.label,
    required this.combo,
    required this.icon,
    required this.code,
    this.mods = const [],
  });
}

/// A titled run of shortcuts.
class ShortcutSection {
  /// Left-aligned 16/600 section header.
  final String header;

  /// The section's shortcuts in reading order.
  final List<ShortcutSpec> items;

  /// Creates a section.
  const ShortcutSection({required this.header, required this.items});
}

/// The 4-section / 25-button catalog (10-UI-SPEC §Shortcut catalog, verbatim).
/// Section item counts: 7 / 3 / 9 / 6. Labels, combos, codes, and mods are
/// BINDING (icons may substitute to the nearest rounded glyph — none needed).
const List<ShortcutSection> kShortcutCatalog = [
  ShortcutSection(
    header: 'Windows & Desktop',
    items: [
      ShortcutSpec(
        label: 'Show desktop',
        combo: 'Win+D',
        icon: Symbols.desktop_windows_rounded,
        code: 'D',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'Task view',
        combo: 'Win+Tab',
        icon: Symbols.grid_view_rounded,
        code: 'Tab',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'Snap left',
        combo: 'Win+Left',
        icon: Symbols.splitscreen_left_rounded,
        code: 'Left',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'Snap right',
        combo: 'Win+Right',
        icon: Symbols.splitscreen_right_rounded,
        code: 'Right',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'File Explorer',
        combo: 'Win+E',
        icon: Symbols.folder_rounded,
        code: 'E',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'Settings',
        combo: 'Win+I',
        icon: Symbols.settings_rounded,
        code: 'I',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'Task Manager',
        combo: 'Ctrl+Shift+Esc',
        icon: Symbols.monitor_heart_rounded,
        code: 'Esc',
        mods: ['ctrl', 'shift'],
      ),
    ],
  ),
  ShortcutSection(
    header: 'Screenshot',
    items: [
      ShortcutSpec(
        label: 'Snip tool',
        combo: 'Win+Shift+S',
        icon: Symbols.screenshot_region_rounded,
        code: 'S',
        mods: ['win', 'shift'],
      ),
      ShortcutSpec(
        label: 'Screenshot to file',
        combo: 'Win+PrtScn',
        icon: Symbols.screenshot_monitor_rounded,
        code: 'PrintScreen',
        mods: ['win'],
      ),
      ShortcutSpec(
        label: 'Screenshot to clipboard',
        combo: 'PrtScn',
        icon: Symbols.screenshot_rounded,
        code: 'PrintScreen',
        mods: [],
      ),
    ],
  ),
  ShortcutSection(
    header: 'Browser & App',
    items: [
      ShortcutSpec(
        label: 'Refresh',
        combo: 'F5',
        icon: Symbols.refresh_rounded,
        code: 'F5',
        mods: [],
      ),
      ShortcutSpec(
        label: 'Hard refresh',
        combo: 'Ctrl+Shift+R',
        icon: Symbols.autorenew_rounded,
        code: 'R',
        mods: ['ctrl', 'shift'],
      ),
      ShortcutSpec(
        label: 'New tab',
        combo: 'Ctrl+T',
        icon: Symbols.add_box_rounded,
        code: 'T',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Close tab',
        combo: 'Ctrl+W',
        icon: Symbols.tab_close_rounded,
        code: 'W',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Reopen tab',
        combo: 'Ctrl+Shift+T',
        icon: Symbols.history_rounded,
        code: 'T',
        mods: ['ctrl', 'shift'],
      ),
      ShortcutSpec(
        label: 'Find',
        combo: 'Ctrl+F',
        icon: Symbols.search_rounded,
        code: 'F',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Zoom in',
        combo: 'Ctrl+Plus',
        icon: Symbols.zoom_in_rounded,
        code: 'Plus',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Zoom out',
        combo: 'Ctrl+Minus',
        icon: Symbols.zoom_out_rounded,
        code: 'Minus',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Zoom reset',
        combo: 'Ctrl+0',
        icon: Symbols.restart_alt_rounded,
        code: '0',
        mods: ['ctrl'],
      ),
    ],
  ),
  ShortcutSection(
    header: 'Editing',
    items: [
      ShortcutSpec(
        label: 'Copy',
        combo: 'Ctrl+C',
        icon: Symbols.content_copy_rounded,
        code: 'C',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Cut',
        combo: 'Ctrl+X',
        icon: Symbols.content_cut_rounded,
        code: 'X',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Paste',
        combo: 'Ctrl+V',
        icon: Symbols.content_paste_rounded,
        code: 'V',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Undo',
        combo: 'Ctrl+Z',
        icon: Symbols.undo_rounded,
        code: 'Z',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Redo',
        combo: 'Ctrl+Y',
        icon: Symbols.redo_rounded,
        code: 'Y',
        mods: ['ctrl'],
      ),
      ShortcutSpec(
        label: 'Select all',
        combo: 'Ctrl+A',
        icon: Symbols.select_all_rounded,
        code: 'A',
        mods: ['ctrl'],
      ),
    ],
  ),
];

/// One shortcut button (media `_TransportButton` press-DOWN twin): `kSurface`
/// fill, 1px `kHairline` border → `kAccent` while flashing, radius 12, min
/// height 64, 12px inner padding. Content is a `Row[icon 24, 12 gap, Expanded
/// Column(effect 14/600, 2 gap, combo 12/400 kMuted)]`. Tap-DOWN fires
/// [onPress] + `hapticTick()` + a 100ms accent flash, then relaxes.
/// Fire-and-forget — never an optimistic/result state. Gated ([enabled]
/// false): icon + labels `kMuted`, border stays `kHairline`, press entry null.
class ShortcutButton extends StatefulWidget {
  /// The shortcut this button fires.
  final ShortcutSpec spec;

  /// False renders the gated muted state; the press entry is null.
  final bool enabled;

  /// Fired on tap-DOWN (the screen sends the KeyMsg + owns the wire).
  final VoidCallback onPress;

  /// Creates a shortcut button.
  const ShortcutButton({
    super.key,
    required this.spec,
    required this.enabled,
    required this.onPress,
  });

  @override
  State<ShortcutButton> createState() => _ShortcutButtonState();
}

class _ShortcutButtonState extends State<ShortcutButton> {
  bool _pressed = false;

  // Press-down (house rule): send + haptic + accent flash immediately.
  void _fire() {
    widget.onPress();
    hapticTick();
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final flashing = widget.enabled && _pressed;
    final borderColor = flashing ? kAccent : kHairline;
    final Color contentColor = !widget.enabled
        ? kMuted
        : flashing
            ? kAccent
            : kText;

    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.enabled ? () {} : null,
        onTapDown: widget.enabled ? (_) => _fire() : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(widget.spec.icon, size: 24, color: contentColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.spec.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: contentColor,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.spec.combo,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: kMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Shortcuts screen: header chrome over the sectioned 2-column catalog
/// grid. Every button rides `sendReliable(KeyMsg(code, action:'tap', mods))`
/// — nothing here touches the volatile move path. Buttons gate `enabled` on
/// the transition-only status watch (muted-not-red offline).
class ShortcutsScreen extends ConsumerStatefulWidget {
  /// Creates the shortcuts screen.
  const ShortcutsScreen({super.key});

  @override
  ConsumerState<ShortcutsScreen> createState() => _ShortcutsScreenState();
}

class _ShortcutsScreenState extends ConsumerState<ShortcutsScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
  }

  /// Press-down: the reliable chord + haptic tick (house rule — on press).
  void _fire(ShortcutSpec spec) {
    _service.sendReliable(
      KeyMsg(code: spec.code, action: 'tap', mods: spec.mods),
    );
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
          kShortcutsTitle,
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
                // md edge padding, xl top padding (10-UI-SPEC §Screen 2).
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var s = 0; s < kShortcutCatalog.length; s++) ...[
                      if (s > 0) const SizedBox(height: 24),
                      _SectionHeader(kShortcutCatalog[s].header),
                      const SizedBox(height: 8),
                      _SectionGrid(
                        section: kShortcutCatalog[s],
                        enabled: authed,
                        onFire: _fire,
                      ),
                    ],
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

/// A left-aligned 16/600 section header (browser `_SectionHeader` clone).
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

/// One section's 2-column button grid: equal `Expanded` pairs with sm (8px)
/// horizontal + vertical gaps; an odd tail renders half-width beside an empty
/// slot (the browser/hub odd-tail pattern).
class _SectionGrid extends StatelessWidget {
  final ShortcutSection section;
  final bool enabled;
  final void Function(ShortcutSpec spec) onFire;

  const _SectionGrid({
    required this.section,
    required this.enabled,
    required this.onFire,
  });

  @override
  Widget build(BuildContext context) {
    final items = section.items;
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _button(items[i])),
            const SizedBox(width: 8),
            Expanded(
              child: i + 1 < items.length
                  ? _button(items[i + 1])
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
          if (r > 0) const SizedBox(height: 8),
          rows[r],
        ],
      ],
    );
  }

  Widget _button(ShortcutSpec spec) => ShortcutButton(
        spec: spec,
        enabled: enabled,
        onPress: () => onFire(spec),
      );
}
