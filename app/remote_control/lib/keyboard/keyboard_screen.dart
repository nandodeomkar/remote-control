/// KeyboardScreen (07-13, D-09) — the first-class Keyboard tool screen.
///
/// Promotes the existing modular [KeyboardPanel] (04-05/04-06:
/// hidden_text_input + key_rows + modifier_fsm) from a trackpad-docked panel
/// to a dedicated screen behind the new Keyboard hub tile. NO new keyboard
/// logic lives here: the panel is mounted `expanded: true` (chrome open, IME
/// raised on entry) over the same service seams the trackpad wires —
/// [ImeDiffProducer] diffs ride the reliable path, chips/caps gate on auth,
/// and the panel's own changes subscription drives its D-12 disconnect reset.
///
/// Chrome (07-UI-SPEC §4): app bar `kBg`, title "Keyboard" (16/600 `kText`),
/// body = the panel docked at the bottom of a `kBg` canvas. The floating
/// trackpad bubble is NOT self-hosted — `HubScreen._open` wraps every tile
/// destination in `BubbleScaffold` centrally (08-06), so this screen gets
/// the persistent Trackpad shortcut without knowing about it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../theme/tokens.dart';
import 'diff_ops.dart';
import 'keyboard_panel.dart';

/// App-bar title (house rule: no inline literals).
const String kKeyboardTitle = 'Keyboard';

/// The Keyboard tool screen: the [KeyboardPanel] always-expanded on a `kBg`
/// canvas. See the library doc for the contract.
class KeyboardScreen extends ConsumerStatefulWidget {
  /// Creates the keyboard screen.
  const KeyboardScreen({super.key});

  @override
  ConsumerState<KeyboardScreen> createState() => _KeyboardScreenState();
}

class _KeyboardScreenState extends ConsumerState<KeyboardScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  /// Focus of the hidden IME field — focusing raises the system keyboard.
  final FocusNode _imeFocusNode = FocusNode(debugLabel: 'keyboard-screen-ime');

  /// KEY-01 committed-text diff producer (emit -> reliable path).
  late final ImeDiffProducer _imeProducer;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    _imeProducer = ImeDiffProducer(emit: _service.sendReliable);
  }

  @override
  void dispose() {
    _imeFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot: rebuilds on lifecycle changes only.
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    return Scaffold(
      // The raised system IME pushes the docked panel up (mirrors the
      // trackpad's D-07 behavior).
      resizeToAvoidBottomInset: true,
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          kKeyboardTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // The kBg canvas above the docked panel (the panel keeps its
            // trackpad-era bottom-docked shape; the empty area breathes).
            const Expanded(child: SizedBox.expand()),
            KeyboardPanel(
              // Always open on this screen: chrome visible, IME raised on
              // entry (the panel requests focus post-frame itself).
              expanded: true,
              imeFocusNode: _imeFocusNode,
              producer: _imeProducer,
              enabled: authed,
              send: _service.sendReliable,
              changes: _service.changes,
              isDisconnected: () =>
                  _service.chipStatus == ChipStatus.disconnected,
            ),
          ],
        ),
      ),
    );
  }
}
