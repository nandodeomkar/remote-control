/// The Apps screen (APPS-01/02/03, D-01/D-02/D-07) — a favorites launch grid
/// over the live running-window list, with focus/close/pin/launch wired
/// through `sendReliable`.
///
/// Layout (06-UI-SPEC), top→bottom with xl top padding:
///   - App bar "Apps" + inherited header chip + reconnecting banner slot.
///   - Favorites section: header + a wrapping grid of ≥64px square tiles
///     (icon-over-name + a pinned-marker corner glyph). Tap → launch; long-press
///     → unpin. Empty → an inline hint.
///   - lg gap, then the Open-windows section: header + a vertical list of ≥56px
///     rows in server Z-order (NO client sort — D-07): leading icon, ellipsized
///     title, trailing close button. Tap row → focus; close → close; long-press
///     → pin (path!=null) or the non-pinnable toast (UWP). Empty (connected) →
///     an empty state.
///
/// Live (APPS-03): re-renders from the value-equal [AppsViewState] on every
/// `apps.changed` push — no spinner, no manual refresh. The client sends
/// `apps.list` once on screen-open to prime the list (06-01: apps.changed has
/// no after-auth snapshot). Server `err{windowGone|launchFailed}` frames
/// surface as transient toasts (operator-facing prose, never an HWND/path).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'apps_store.dart';

/// The Apps remote: favorites grid + live open-windows list (APPS-01/02/03).
class AppsScreen extends ConsumerStatefulWidget {
  /// Creates the Apps screen.
  const AppsScreen({super.key});

  @override
  ConsumerState<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends ConsumerState<AppsScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;
  StreamSubscription<void>? _sub;

  /// The last err instance already surfaced as a toast (identity-tracked — the
  /// value-equal view never rebuilds on err, so the screen watches `changes`
  /// directly to catch new errors).
  ErrMsg? _shownError;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    // WR-01: seed the "already seen" marker from whatever err is parked at
    // mount time WITHOUT surfacing it — the first post-mount `changes` ping
    // (primeList's apps.list reply lands within moments) must not re-toast a
    // stale error left from a previous visit. Mirrors the UipiBanner pattern.
    _shownError = _service.lastError;
    // Surface server err frames as toasts off the raw changes stream (the
    // AppsViewState is value-equal and would not rebuild on an err park).
    _sub = _service.changes.listen((_) => _maybeShowError());
    // Prime the open-windows list once on open (apps.changed has no after-auth
    // snapshot — the client pulls via apps.list, 06-01 decision).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(appsStateProvider.notifier).primeList();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    super.dispose();
  }

  void _maybeShowError() {
    final err = _service.lastError;
    if (err == null || identical(err, _shownError)) return;
    _shownError = err;
    if (!mounted) return;
    // err.msg is operator-facing prose (06-01) — carries no HWND/path (T-06-14).
    _toast(err.msg);
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

  Future<void> _pinWindow(WindowInfo window) async {
    final ok = await ref.read(appsStateProvider.notifier).pin(window);
    if (!mounted) return;
    _toast(ok ? 'Pinned ${window.title}' : 'This app can\'t be pinned yet.');
  }

  Future<void> _unpinFavorite(Favorite fav) async {
    await ref.read(appsStateProvider.notifier).unpin(fav.path);
    if (!mounted) return;
    _toast('Unpinned ${fav.name}');
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;
    final apps = ref.watch(appsStateProvider);
    final notifier = ref.read(appsStateProvider.notifier);

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          'Apps',
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
                    const _SectionHeader('Favorites'),
                    const SizedBox(height: 8),
                    _FavoritesSection(
                      favorites: apps.favorites,
                      enabled: authed,
                      onLaunch: notifier.launch,
                      onUnpin: _unpinFavorite,
                    ),
                    const SizedBox(height: 24),
                    const _SectionHeader('Open windows'),
                    const SizedBox(height: 8),
                    _OpenWindowsSection(
                      windows: apps.windows,
                      enabled: authed,
                      onFocus: notifier.focus,
                      onClose: notifier.close,
                      onPin: _pinWindow,
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

/// The favorites grid, or the inline hint when empty.
class _FavoritesSection extends StatelessWidget {
  final List<Favorite> favorites;
  final bool enabled;
  final void Function(Favorite fav) onLaunch;
  final Future<void> Function(Favorite fav) onUnpin;

  const _FavoritesSection({
    required this.favorites,
    required this.enabled,
    required this.onLaunch,
    required this.onUnpin,
  });

  @override
  Widget build(BuildContext context) {
    if (favorites.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Long-press an open window below to pin it here.',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: kMuted),
        ),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final fav in favorites)
          _FavoriteTile(
            favorite: fav,
            enabled: enabled,
            onLaunch: () => onLaunch(fav),
            onLongPress: () => onUnpin(fav),
          ),
      ],
    );
  }
}

/// One favorite tile: ≥64px square, icon-over-name + a pinned-marker corner
/// glyph. Tap → launch (accent flash + haptic); long-press → unpin.
class _FavoriteTile extends StatefulWidget {
  final Favorite favorite;
  final bool enabled;
  final VoidCallback onLaunch;
  final VoidCallback onLongPress;

  const _FavoriteTile({
    required this.favorite,
    required this.enabled,
    required this.onLaunch,
    required this.onLongPress,
  });

  @override
  State<_FavoriteTile> createState() => _FavoriteTileState();
}

class _FavoriteTileState extends State<_FavoriteTile> {
  bool _pressed = false;

  void _fire() {
    widget.onLaunch();
    hapticTick();
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _pressed ? kAccent : kHairline;
    final labelColor = !widget.enabled
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
        onLongPress: widget.onLongPress,
        child: SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _AppIcon(iconB64: widget.favorite.icon, size: 32),
                    const SizedBox(height: 4),
                    Text(
                      widget.favorite.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: labelColor,
                      ),
                    ),
                  ],
                ),
              ),
              const Positioned(
                top: 4,
                right: 4,
                child: Icon(Symbols.push_pin_rounded, size: 12, color: kAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The open-windows list, or the empty state when there are none.
class _OpenWindowsSection extends StatelessWidget {
  final List<WindowInfo> windows;
  final bool enabled;
  final void Function(int id) onFocus;
  final void Function(int id) onClose;
  final Future<void> Function(WindowInfo window) onPin;

  const _OpenWindowsSection({
    required this.windows,
    required this.enabled,
    required this.onFocus,
    required this.onClose,
    required this.onPin,
  });

  @override
  Widget build(BuildContext context) {
    if (windows.isEmpty) {
      return const _EmptyState(
        heading: 'No open windows',
        body: 'Windows you open on your PC will show up here.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < windows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _WindowRow(
            // NO client sort — server Z-order preserved (D-07).
            window: windows[i],
            enabled: enabled,
            onFocus: () => onFocus(windows[i].id),
            onClose: () => onClose(windows[i].id),
            onLongPress: () => onPin(windows[i]),
          ),
        ],
      ],
    );
  }
}

/// One window row: ≥56px, leading icon, ellipsized title, trailing close
/// button. Tap → focus (accent flash + haptic); long-press → pin.
class _WindowRow extends StatefulWidget {
  final WindowInfo window;
  final bool enabled;
  final VoidCallback onFocus;
  final VoidCallback onClose;
  final VoidCallback onLongPress;

  const _WindowRow({
    required this.window,
    required this.enabled,
    required this.onFocus,
    required this.onClose,
    required this.onLongPress,
  });

  @override
  State<_WindowRow> createState() => _WindowRowState();
}

class _WindowRowState extends State<_WindowRow> {
  bool _pressed = false;

  void _fire() {
    widget.onFocus();
    hapticTick();
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _pressed ? kAccent : kHairline;
    final titleColor = !widget.enabled
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
        onLongPress: widget.onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                _AppIcon(iconB64: widget.window.icon, size: 24),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.window.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: titleColor,
                    ),
                  ),
                ),
                _CloseButton(
                  enabled: widget.enabled,
                  onClose: widget.onClose,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The trailing close button (≥48px hit area), graceful WM_CLOSE.
class _CloseButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onClose;

  const _CloseButton({required this.enabled, required this.onClose});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _pressed = false;

  void _fire() {
    widget.onClose();
    hapticTick();
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = !widget.enabled
        ? kMuted
        : _pressed
            ? kAccent
            : kMuted;
    return Tooltip(
      message: 'Close window',
      child: InkResponse(
        radius: 24,
        onTap: widget.enabled ? () {} : null,
        onTapDown: widget.enabled ? (_) => _fire() : null,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(Symbols.close_rounded, size: 20, color: color),
        ),
      ),
    );
  }
}

/// A decoded base64-PNG app icon, or the muted [Symbols.desktop_windows_rounded]
/// fallback (null icon OR a decode failure — never throws into the UI).
class _AppIcon extends StatelessWidget {
  final String? iconB64;
  final double size;

  const _AppIcon({required this.iconB64, required this.size});

  @override
  Widget build(BuildContext context) {
    final b64 = iconB64;
    if (b64 != null && b64.isNotEmpty) {
      try {
        final bytes = base64Decode(b64);
        return Image.memory(
          bytes,
          width: size,
          height: size,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => _fallback(),
        );
      } on FormatException {
        return _fallback();
      }
    }
    return _fallback();
  }

  Widget _fallback() =>
      Icon(Symbols.desktop_windows_rounded, size: size, color: kMuted);
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
