/// The App Settings screen (UI-02 / D-11) — the SRV-03 client-side
/// management surface. Reached via the dashboard app-bar gear (wired in
/// 07-13); works offline (D-11: "reached offline").
///
/// Groups, in UI-SPEC §5 order (exact):
///   1. Paired PCs — rows from [deviceListProvider] filtered to `paired`,
///      each with a trailing destructive "Revoke" action (confirm dialog ->
///      [DeviceStore.removeDevice] + [DeviceStore.deleteToken], and
///      [ConnectionService.disconnect] if it is the connected target — the
///      LOCAL half of SRV-03 revoke; the server-side half is 07-08). Also
///      hosts the add/switch-PC entry (pushes the former device list, now
///      repurposed — see `device_list_screen.dart`).
///   2. Pointer sensitivity — reuses the existing `sensitivity.dart` seam
///      verbatim (same slider/provider the trackpad tune sheet edits).
///   3. Scroll direction — segmented Natural/Reversed bound to
///      `scroll_direction.dart`'s `scrollDirectionProvider`.
///   4. Haptic feedback — a `Switch` bound to `haptics.dart`'s
///      `hapticsEnabledProvider` (default ON).
///   5. Accent — a STATIC, non-interactive `#4C8DFF` "Blue" swatch chip
///      (D-12: no picker, ever).
///   6. About — the Updates entry (12-15: pushes `UpdatesScreen`, carries the
///      badge dot) above the running build's version, read from the package
///      via `app_version.dart`'s [appVersionProvider] (260729-42w). Display
///      only. Exists so a sideloaded build can be identified: every APK from
///      v1.0.0 through v1.3.0-rc1 reported itself as "1.0.0", which made
///      "which version are you on?" unanswerable.
///
/// Chrome: app bar `#0E0F12` / title "Settings" (16/600); body = scrollable
/// `#0E0F12` canvas of grouped `#16181D` surfaces separated by `#2A2D34`
/// hairlines (md row padding, lg between groups).
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../screens/connection_copy.dart' show deviceMetaPaired;
import '../screens/device_list_screen.dart';
import '../store/device_list_store.dart';
import '../theme/tokens.dart';
import '../trackpad/tuning.dart';
import '../update/update_providers.dart';
import '../update/updates_screen.dart';
import 'app_version.dart';
import 'haptics.dart';
import 'scroll_direction.dart';
import 'sensitivity.dart';

// -- Copy (house rule: no inline literals) -----------------------------------

/// App-bar title.
const String kSettingsTitle = 'Settings';

/// Paired-PCs group heading.
const String kPairedPcsHeading = 'Paired PCs';

/// Per-row destructive action label.
const String kRevokeLabel = 'Revoke';

/// The add/switch-PC entry inside the Paired PCs group.
const String kAddSwitchPcLabel = 'Add / switch PC';

/// Pointer-sensitivity row label.
const String kSensitivityLabel = 'Pointer sensitivity';

/// Scroll-direction row label.
const String kScrollDirectionLabel = 'Scroll direction';

/// Scroll-direction segment: Natural.
const String kScrollNaturalLabel = 'Natural';

/// Scroll-direction segment: Reversed.
const String kScrollReversedLabel = 'Reversed';

/// Haptics row label.
const String kHapticsLabel = 'Haptic feedback';

/// Accent row label.
const String kAccentLabel = 'Accent';

/// Accent swatch chip text.
const String kAccentValueLabel = 'Blue';

/// About group heading.
const String kAboutHeading = 'About';

/// Version row label.
const String kVersionLabel = 'Version';

/// Version row value when the package lookup fails. A missing version is a
/// nuisance; a Settings screen that fails to build would also cut off the only
/// route to Revoke.
const String kVersionUnavailable = 'Unavailable';

/// Destructive confirm dialog title.
const String kRevokeConfirmTitle = 'Revoke this PC?';

/// Destructive confirm dialog body.
const String kRevokeConfirmBody =
    'This phone will need to pair again to control it.';

/// Destructive confirm dialog confirm button (kError).
const String kRevokeConfirmConfirm = 'Revoke';

/// Destructive confirm dialog cancel button.
const String kRevokeConfirmCancel = 'Cancel';

// -- Typography (exactly the UI-SPEC "Settings" roles) -----------------------

const TextStyle _appBarTitle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  color: kText,
);
const TextStyle _groupHeading = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w600,
  color: kMuted,
);
const TextStyle _rowTitle = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w400,
  color: kText,
);
const TextStyle _rowSubtitle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  color: kMuted,
);

/// The App Settings screen. See the library doc for the group contract.
class SettingsScreen extends ConsumerWidget {
  /// Creates the settings screen.
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(kSettingsTitle, style: _appBarTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: const [
            _PairedPcsGroup(),
            SizedBox(height: 24),
            _SensitivityGroup(),
            SizedBox(height: 24),
            _ScrollDirectionGroup(),
            SizedBox(height: 24),
            _HapticsGroup(),
            SizedBox(height: 24),
            _AccentGroup(),
            SizedBox(height: 24),
            _AboutGroup(),
          ],
        ),
      ),
    );
  }
}

/// A `#16181D` surface wrapping [children] as hairline-separated rows, with
/// an optional muted group [heading] above it (only the Paired PCs group
/// uses one — every other group's single row already carries its own
/// UI-SPEC label as the row title).
class _GroupSurface extends StatelessWidget {
  final String? heading;
  final List<Widget> children;

  const _GroupSurface({this.heading, required this.children});

  @override
  Widget build(BuildContext context) {
    final heading = this.heading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (heading != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(heading, style: _groupHeading),
          ),
        Material(
          color: kSurface,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const Divider(height: 1, thickness: 1, color: kHairline),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Group 1: Paired PCs (+ Revoke) + the add/switch-PC entry.
class _PairedPcsGroup extends ConsumerWidget {
  const _PairedPcsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paired = ref.watch(deviceListProvider).where((e) => e.paired);

    return _GroupSurface(
      heading: kPairedPcsHeading,
      children: [
        for (final entry in paired) _PairedPcRow(entry: entry),
        _AddSwitchPcRow(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DeviceListScreen()),
          ),
        ),
      ],
    );
  }
}

/// One paired-PC row: name + `ip · paired` meta + a trailing destructive
/// "Revoke" action.
class _PairedPcRow extends ConsumerWidget {
  final DeviceListEntry entry;

  const _PairedPcRow({required this.entry});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _rowTitle,
                  ),
                  const SizedBox(height: 2),
                  Text(deviceMetaPaired(entry.host), style: _rowSubtitle),
                ],
              ),
            ),
            TextButton(
              onPressed: () => _confirmRevoke(context, ref),
              child: const Text(
                kRevokeLabel,
                style: TextStyle(color: kError, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Opens the destructive confirm dialog (UI-SPEC copy, exact); on confirm,
  /// removes the device + deletes its token, and disconnects the live
  /// session when this row IS the connected target (SRV-03 local revoke).
  Future<void> _confirmRevoke(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          kRevokeConfirmTitle,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kText),
        ),
        content: const Text(kRevokeConfirmBody, style: _rowSubtitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              kRevokeConfirmCancel,
              style: TextStyle(color: kMuted),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: kError,
              foregroundColor: kBg,
              minimumSize: const Size(0, 48),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(kRevokeConfirmConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final store = ref.read(deviceStoreProvider);
    await store.removeDevice(entry.key);
    await store.deleteToken(entry.key);

    // The phone forgets the PC; if it was the live session, drop it now
    // rather than waiting for the next send to fail (server-side revoke —
    // the immediate force-disconnect — is 07-08's job).
    if (entry.connected) {
      ref.read(connectionServiceProvider).disconnect();
    }
  }
}

/// The add/switch-PC entry (pushes the repurposed device list).
class _AddSwitchPcRow extends StatelessWidget {
  final VoidCallback onTap;

  const _AddSwitchPcRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSurface,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: const [
                Icon(Symbols.add_rounded, color: kText, size: 20),
                SizedBox(width: 12),
                Text(kAddSwitchPcLabel, style: _rowTitle),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Updates entry (D-06): the [_AddSwitchPcRow] nav-row shape with a
/// trailing run of the badge dot and a chevron.
///
/// The dot is inline in the trailing run, so its appearance shifts the chevron
/// by 20px — acceptable inside a row the user is not mid-gesture on, and the
/// reason the hub's placement (an app bar, which must never reflow) is an
/// overlay instead.
///
/// The dot carries no visible text, so it is the one control in this phase that
/// needs an explicit semantics label: without it the state would be drawn and
/// never announced.
class UpdatesNavRow extends StatelessWidget {
  /// Whether at least one component with a KNOWN installed version is behind
  /// the cached latest (the badge truth rule — one provider, two placements).
  final bool badge;

  /// Pushes the Updates screen.
  final VoidCallback onTap;

  /// Creates the Updates nav row.
  const UpdatesNavRow({super.key, required this.badge, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSurface,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                const Icon(Symbols.system_update_rounded,
                    color: kText, size: 20),
                const SizedBox(width: 12),
                const Expanded(child: Text(kUpdatesTitle, style: _rowTitle)),
                if (badge) ...[
                  Semantics(
                    label: kUpdateBadgeSemantic,
                    child: const UpdateBadgeDot(),
                  ),
                  const SizedBox(width: 12),
                ],
                const Icon(Symbols.chevron_right_rounded,
                    color: kMuted, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Group 2: Pointer sensitivity — the existing `sensitivity.dart` seam,
/// verbatim (same slider bounds/provider the trackpad tune sheet edits).
class _SensitivityGroup extends ConsumerWidget {
  const _SensitivityGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _GroupSurface(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(kSensitivityLabel, style: _rowTitle),
              Slider(
                value: ref.watch(sensitivityProvider),
                min: kSensitivityMin,
                max: kSensitivityMax,
                activeColor: kAccent,
                inactiveColor: kHairline,
                onChanged: ref.read(sensitivityProvider.notifier).set,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Group 3: Scroll direction — segmented Natural/Reversed, accent marks the
/// selected value (D-11).
class _ScrollDirectionGroup extends ConsumerWidget {
  const _ScrollDirectionGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reversed = ref.watch(scrollDirectionProvider);
    return _GroupSurface(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(kScrollDirectionLabel, style: _rowTitle),
              const SizedBox(height: 8),
              _ScrollDirectionSegment(
                reversed: reversed,
                onChanged: ref.read(scrollDirectionProvider.notifier).set,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A two-option segmented control (Natural / Reversed) — hand-rolled house
/// widget mirroring `mouse_buttons.dart`'s bordered-button contract.
class _ScrollDirectionSegment extends StatelessWidget {
  final bool reversed;
  final ValueChanged<bool> onChanged;

  const _ScrollDirectionSegment({
    required this.reversed,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _SegmentButton(
            label: kScrollNaturalLabel,
            selected: !reversed,
            onTap: () => onChanged(false),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SegmentButton(
            label: kScrollReversedLabel,
            selected: reversed,
            onTap: () => onChanged(true),
          ),
        ),
      ],
    );
  }
}

/// One segment: accent border + accent label when selected, hairline/muted
/// otherwise (UI-SPEC "Active/ON control state" accent-reserved row).
class _SegmentButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? kAccent : kMuted;
    return Material(
      color: kBg,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: selected ? kAccent : kHairline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

/// Group 4: Haptic feedback — a `Switch` bound to `hapticsEnabledProvider`
/// (default ON), accent ON-state (mirrors `clipboard_screen.dart`'s
/// `_AutoSyncRow` Switch styling).
class _HapticsGroup extends ConsumerWidget {
  const _HapticsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(hapticsEnabledProvider);
    return _GroupSurface(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(kHapticsLabel, style: _rowTitle),
                ),
                Switch(
                  value: enabled,
                  onChanged: ref.read(hapticsEnabledProvider.notifier).set,
                  activeThumbColor: kAccent,
                  activeTrackColor: kAccent,
                  inactiveThumbColor: kText,
                  inactiveTrackColor: kHairline,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Group 5: Accent — a STATIC, non-interactive `#4C8DFF` "Blue" swatch chip.
/// No `onTap`, no picker (D-12) — display-only by construction.
class _AccentGroup extends StatelessWidget {
  const _AccentGroup();

  @override
  Widget build(BuildContext context) {
    return _GroupSurface(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(kAccentLabel, style: _rowTitle),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: kAccent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    kAccentValueLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kBg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Group 6: About — the Updates entry (12-15) above the running build's
/// version, read from the installed package. The version row is display only,
/// structurally a plain label/value row (the [_AccentGroup] shape without the
/// chip).
///
/// The Updates row lives HERE rather than in a seventh group because this
/// group is already the version-identity home — "which version are you on?" is
/// literally why it exists, and "am I current?" is the same question one step
/// further. No shipped row moves.
class _AboutGroup extends ConsumerWidget {
  const _AboutGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // loading -> empty rather than a placeholder: the lookup resolves in a
    // frame or two, and a row that flashes "..." before settling reads worse
    // than one that simply fills in.
    final version = ref.watch(appVersionProvider).when(
          data: (v) => v,
          loading: () => '',
          error: (_, _) => kVersionUnavailable,
        );
    final badge = ref.watch(updateBadgeProvider);

    return _GroupSurface(
      heading: kAboutHeading,
      children: [
        UpdatesNavRow(
          badge: badge,
          onTap: () {
            hapticTick();
            Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const UpdatesScreen()),
            );
          },
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(kVersionLabel, style: _rowTitle),
                ),
                Text(version, style: _rowSubtitle),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
