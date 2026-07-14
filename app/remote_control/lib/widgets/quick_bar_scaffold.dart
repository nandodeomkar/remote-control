/// QuickBarScaffold (07-13, D-10) — the persistent Trackpad quick-bar +
/// UIPI-banner host every tool screen rides.
///
/// `HubScreen._open` wraps EVERY tile destination in this scaffold, so each
/// tool screen (Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser)
/// gets a bottom-anchored 56px shortcut bar (kSurface fill, 1px kHairline
/// top edge) with one centered `Icons.touch_app` + "Trackpad" button in
/// kAccent — the RESERVED accent affordance (07-UI-SPEC §3: accent's one job
/// here is signalling the primary always-available action). The tap fires
/// [hapticTick] then pushes the full Trackpad screen. The bar RESERVES its
/// 56px (a Column slot, never an overlay) so screen content is not covered.
///
/// The Trackpad screen itself passes `showQuickBar: false` — no redundant
/// shortcut to the screen you are on — but STILL gets the scaffold so the
/// UIPI advisory rides it too. The quick-bar's own push wraps the trackpad
/// the same way, keeping the banner contextual on every navigation path.
///
/// [UipiBanner] (07-11, SRV-05 client surface) is composed as a top-anchored
/// overlay mirroring the `ReconnectingBannerSlot` position: it appears on
/// whatever tool screen is active when `input.blocked` lands and — being
/// IgnorePointer-wrapped — never intercepts a touch on the body beneath it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../trackpad/trackpad_screen.dart';
import 'uipi_banner.dart';

/// Quick-bar button label (07-UI-SPEC copywriting: the primary CTA).
const String kQuickBarLabel = 'Trackpad';

/// The quick-bar's reserved height (07-UI-SPEC §3: a comfortable persistent
/// bar over the 48px Material minimum tap target).
const double kQuickBarHeight = 56;

/// Wraps a tool screen with the persistent Trackpad quick-bar (D-10) and the
/// contextual UIPI banner (D-07). See the library doc for the contract.
class QuickBarScaffold extends ConsumerWidget {
  /// The tool screen this scaffold hosts.
  final Widget body;

  /// False (the Trackpad screen) renders only [body] + the banner — no
  /// redundant shortcut to the screen you are on.
  final bool showQuickBar;

  /// Creates the scaffold.
  const QuickBarScaffold({
    super.key,
    required this.body,
    this.showQuickBar = true,
  });

  /// Quick-bar tap: haptic tick, then push the full Trackpad screen —
  /// wrapped with `showQuickBar: false` so the destination still hosts the
  /// UIPI banner but never a shortcut to itself.
  void _openTrackpad(BuildContext context) {
    hapticTick();
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const QuickBarScaffold(
            showQuickBar: false,
            body: TrackpadScreen(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // App-lifetime singleton — watching a plain Provider never rebuilds.
    final service = ref.watch(connectionServiceProvider);

    return Material(
      color: kBg,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: body),
                // The contextual UIPI advisory (07-UI-SPEC §8): top-anchored
                // over the active tool screen (the ReconnectingBannerSlot
                // position). UipiBanner is IgnorePointer-wrapped, so it
                // never steals a touch from the body.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    bottom: false,
                    child: UipiBanner.forService(service),
                  ),
                ),
              ],
            ),
          ),
          if (showQuickBar)
            _TrackpadQuickBar(onTap: () => _openTrackpad(context)),
        ],
      ),
    );
  }
}

/// The 56px bottom bar: kSurface fill, kHairline top edge, one centered
/// accent `Icons.touch_app` + "Trackpad" affordance (the reserved accent).
class _TrackpadQuickBar extends StatelessWidget {
  final VoidCallback onTap;

  const _TrackpadQuickBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kHairline)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          top: false,
          child: InkWell(
            onTap: onTap,
            child: const SizedBox(
              height: kQuickBarHeight,
              width: double.infinity,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.touch_app, size: 24, color: kAccent),
                  SizedBox(width: 8),
                  Text(
                    kQuickBarLabel,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: kAccent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
