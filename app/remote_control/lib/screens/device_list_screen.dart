/// The phase home (D-02): live GUID-merged device list fed by the beacon
/// listener, grayed remembered-offline rows at their last-known address,
/// empty state with live-scan hint, and the Connect-by-IP secondary
/// affordance (D-03, CONN-05).
///
/// Visual contract: 03-UI-SPEC.md, locked. 64px rows, 4-size/2-weight
/// typography, accent `#4C8DFF` reserved — in this file it appears ONLY on
/// the currently-connected row's leading icon (the sheet's FilledButton gets
/// it from the theme seed, never a literal). Every user-facing string comes
/// from connection_copy.dart — no inline copy.
///
/// Tap behavior (D-02): paired or remembered rows connect silently; an
/// unpaired live row starts the same connect and the pairing sheet opens
/// when the handshake reaches needPin (wired via the service `changes`
/// listener in this screen's state). Connect by IP reuses the SAME
/// [ConnectionService.connectTo] path with a `manual:<host>:<port>` key —
/// a successful manual connection is remembered like a discovered one.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus;
import '../net/handshake.dart';
import '../net/reconnect_fsm.dart';
import '../store/device_list_store.dart';
import '../store/device_store.dart';
import '../trackpad/trackpad_screen.dart';
import '../widgets/connection_header.dart';
import 'connection_copy.dart';
import 'pairing_dialog.dart';

// Theme tokens (03-UI-SPEC Color table; accent literal reserved — see the
// library doc).
const Color _bg = Color(0xFF0E0F12);
const Color _surface = Color(0xFF16181D);
const Color _text = Color(0xFFE6E8EB);
const Color _muted = Color(0xFF6B7280);
const Color _error = Color(0xFFFF6B6B);

// Typography (exactly the UI-SPEC roles used on this screen).
const TextStyle _title = TextStyle(
  fontSize: 16,
  fontWeight: FontWeight.w600,
  color: _text,
);
const TextStyle _body = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  color: _muted,
  height: 1.5,
);
const TextStyle _caption = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w400,
  color: _muted,
);
const TextStyle _errorLine = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w400,
  color: _error,
);

/// The device list screen — phase home.
class DeviceListScreen extends ConsumerStatefulWidget {
  /// Creates the device list screen.
  const DeviceListScreen({super.key});

  @override
  ConsumerState<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends ConsumerState<DeviceListScreen> {
  StreamSubscription<void>? _changesSub;
  bool _sheetOpen = false;

  /// The device key of a USER-INITIATED connect awaiting auth: when it
  /// reaches authed, the trackpad is pushed (explicit tap = explicit
  /// navigation). Silent reconnects (D-01 launch kick, beacon/backoff)
  /// never set this — the user stays on the list per UI-SPEC.
  String? _pendingNavKey;

  // Previous-ping snapshots so the sheet opens on TRANSITIONS only (a
  // dismissed sheet must not reopen on unrelated pings).
  HandshakeStatus? _prevHandshake;
  ReconnectState? _prevFsm;

  @override
  void initState() {
    super.initState();
    final service = ref.read(connectionServiceProvider);
    _prevHandshake = service.handshakeStatus;
    _prevFsm = service.fsmState;
    _changesSub = service.changes.listen((_) => _onServiceChange());
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _changesSub = null;
    super.dispose();
  }

  /// Opens the pairing sheet on the two entry transitions (Task 3 wiring):
  /// the handshake reaching needPin (unpaired tap / manual connect), and
  /// auth-stop landing in needPairing WITH the revoked explanation (D-05 —
  /// the explanation renders on the sheet's reserved line, never a retry
  /// loop).
  void _onServiceChange() {
    if (!mounted) return;
    final service = ref.read(connectionServiceProvider);
    final handshake = service.handshakeStatus;
    final fsm = service.fsmState;

    final becameNeedPin = handshake == HandshakeStatus.needPin &&
        _prevHandshake != HandshakeStatus.needPin;
    final becameRevoked = fsm == ReconnectState.needPairing &&
        _prevFsm != ReconnectState.needPairing &&
        service.pairingExplanation != null;
    _prevHandshake = handshake;
    _prevFsm = fsm;

    // Explicit tap = explicit navigation: a user-initiated connect reaching
    // authed pushes the trackpad ONCE. Silent reconnects never set
    // _pendingNavKey, so the D-01 launch kick keeps the user on the list.
    if (service.isAuthed &&
        _pendingNavKey != null &&
        service.target?.key == _pendingNavKey) {
      _pendingNavKey = null;
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const TrackpadScreen()),
        ),
      );
      return;
    }

    if (_sheetOpen || (!becameNeedPin && !becameRevoked)) return;
    final target = service.target;
    if (target == null) return;

    _sheetOpen = true;
    unawaited(
      showPairingSheet(context, target).whenComplete(() {
        _sheetOpen = false;
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(deviceListProvider);
    // Transition-only snapshot (value-equal) — never pinged by the hot path.
    final status = ref.watch(connectionStatusProvider);
    final service = ref.read(connectionServiceProvider);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text(kDevicesTitle, style: _title),
        actions: [
          // The CONN-06 chip: status + p50 on its own 500ms poll.
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: ConnectionHeaderChip.forService(service)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // D-04: the non-blocking drop strip under the app bar.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: service.retryNow,
            ),
            Expanded(
              child: entries.isEmpty
                  ? _EmptyState(
                      onConnectByIp: () => _showConnectByIpSheet(context),
                    )
                  : Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            itemCount: entries.length,
                            itemBuilder: (context, i) => _DeviceRow(
                              entry: entries[i],
                              onTap: () => _onTapEntry(ref, entries[i]),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: _connectByIpButton(
                            () => _showConnectByIpSheet(context),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Row tap (D-02): every state funnels into the SAME connect path. Paired
  /// and remembered rows connect silently; an unpaired live row's handshake
  /// reaches needPin and the pairing sheet opens. A tap that reaches authed
  /// pushes the trackpad; the already-connected row pushes it directly.
  void _onTapEntry(WidgetRef ref, DeviceListEntry entry) {
    if (entry.connected) {
      // Already connected to this PC: straight to the trackpad.
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const TrackpadScreen()),
        ),
      );
      return;
    }
    final service = ref.read(connectionServiceProvider);
    _pendingNavKey = entry.key;
    unawaited(
      service.connectTo(
        DeviceTarget(
          key: entry.key,
          name: entry.name,
          host: entry.host,
          port: entry.port,
        ),
      ),
    );
  }

  void _showConnectByIpSheet(BuildContext context) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: _surface,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => const _ConnectByIpSheet(),
      ),
    );
  }
}

/// The D-03 secondary affordance: ALWAYS a TextButton (never FilledButton —
/// accent is reserved for primary CTAs), ≥48px touch target.
Widget _connectByIpButton(VoidCallback onPressed) {
  return TextButton.icon(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      foregroundColor: _text,
    ),
    icon: const Icon(Icons.lan, size: 20),
    label: const Text(kConnectByIpLabel, style: _body),
  );
}

/// One 64px device row per the UI-SPEC "Device list row" states table.
class _DeviceRow extends StatelessWidget {
  final DeviceListEntry entry;
  final VoidCallback onTap;

  const _DeviceRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Grayed remembered rows: ALL content at muted on the same surface.
    final contentColor = entry.live ? _text : _muted;
    // Accent literal: reserved for the (at most one) connected row's icon.
    final iconColor = entry.connected
        ? const Color(0xFF4C8DFF)
        : (entry.live ? _text : _muted);

    final String metaLine;
    if (entry.connected) {
      metaLine = deviceMetaConnected(entry.host);
    } else if (!entry.live) {
      metaLine = deviceMetaLastSeen(entry.host, entry.port);
    } else if (entry.paired) {
      metaLine = deviceMetaPaired(entry.host);
    } else {
      metaLine = deviceMetaLive(entry.host);
    }

    return SizedBox(
      height: 64, // 3xl row height — never shorter than the 48px target
      child: Material(
        color: _surface,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.computer, color: iconColor),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _title.copyWith(color: contentColor),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        metaLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _caption,
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

/// Centered empty state with the live-scanning hint (UI-SPEC inventory row).
class _EmptyState extends StatelessWidget {
  final VoidCallback onConnectByIp;

  const _EmptyState({required this.onConnectByIp});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.computer, size: 48, color: _muted),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(kEmptyStateHeading, style: _title),
                const SizedBox(width: 8),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              kEmptyStateBody,
              style: _body,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _connectByIpButton(onConnectByIp),
          ],
        ),
      ),
    );
  }
}

/// The Connect-by-IP modal sheet (D-03): validates locally, then reuses the
/// SAME connect path with a `manual:<host>:<port>` key. The inline error
/// line distinguishes parse failures, the RFC1918 guard refusal, a
/// firewall-shaped timeout (device currently LIVE in the list), and generic
/// transport failures.
class _ConnectByIpSheet extends ConsumerStatefulWidget {
  const _ConnectByIpSheet();

  @override
  ConsumerState<_ConnectByIpSheet> createState() => _ConnectByIpSheetState();
}

class _ConnectByIpSheetState extends ConsumerState<_ConnectByIpSheet> {
  final TextEditingController _ipCtrl = TextEditingController();
  final TextEditingController _portCtrl = TextEditingController(text: '17777');

  String? _errorCopy;
  bool _busy = false;

  @override
  void dispose() {
    _ipCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final host = _ipCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    final addr = InternetAddress.tryParse(host);
    if (addr == null || port == null || port < 1 || port > 65535) {
      setState(() => _errorCopy = kInvalidManualInputCopy);
      return;
    }

    setState(() {
      _busy = true;
      _errorCopy = null;
    });

    // D-03: the SAME connect path as a discovered row; on pairOk the
    // service remembers the device under this manual key (03-05), and the
    // store adopts the real GUID once a beacon identifies the PC.
    final service = ref.read(connectionServiceProvider);
    await service.connectTo(
      DeviceTarget(
        key: manualDeviceKey(host, port),
        name: host,
        host: host,
        port: port,
      ),
    );
    if (!mounted) return;

    final dialError = service.lastDialError;
    if (dialError == null) {
      // Socket is up, handshake in flight (needPin opens the pairing sheet;
      // a stored-token auth completes silently) — the sheet's job is done.
      Navigator.of(context).pop();
      return;
    }

    final String copy;
    if (dialError is ArgumentError) {
      // The RFC1918 guard refused the dial before any socket opened.
      copy = kNonPrivateAddressCopy;
    } else {
      // A CURRENTLY-LIVE device at this host means the PC is up but the ws
      // port is unreachable — the firewall explanation (CONN-05).
      final live = ref
          .read(deviceListProvider)
          .any((e) => e.live && e.host == host);
      copy = live ? kFirewallBlockedCopy : transportFailedCopy(host, port);
    }
    setState(() {
      _busy = false;
      _errorCopy = copy;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Ride above the numeric keyboard.
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(kConnectByIpHeading, style: _title),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _ipCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: _text),
                    decoration: const InputDecoration(
                      labelText: kServerIpLabel,
                      hintText: kServerIpHint,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portCtrl,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: _text),
                    decoration: const InputDecoration(labelText: kPortLabel),
                    onSubmitted: (_) => _busy ? null : _submit(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Reserved error line: fixed height so the sheet never jumps.
            SizedBox(
              height: 24,
              child: _errorCopy == null
                  ? const SizedBox.shrink()
                  : Text(
                      _errorCopy!,
                      style: _errorLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: const Text(kConnectCta),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
