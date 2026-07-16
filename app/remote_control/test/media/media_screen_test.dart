// Task 1 (09-04) — Media transport + volume-block visual contract (MED-01/02).
//
// A confirm-don't-rebuild suite pinning the 09-UI-SPEC "Media" row values on
// the shipped MediaScreen: the transport circles are Prev(48)/Play-Pause(64)/
// Next(48), and the pre-snapshot readout is a right-aligned "--" carrying
// FontFeature.tabularFigures() (the UI-SPEC tabular-figures rule).
//
// The screen depends on connectionServiceProvider (via connectionStatusProvider
// and volumeStateProvider), so we pump it under a ProviderScope that overrides
// the service with a recording fake — the same seam trackpad_core_test.dart
// uses. The fake reports disconnected + not-authed with no volume snapshot, so
// the controls render in their gated pre-snapshot state and the readout is "--".

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/media/media_screen.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_store.dart';

class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async => backing[key] = value;

  @override
  Future<void> delete(String key) async => backing.remove(key);
}

class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

/// A disconnected, not-authed service with no parked volume snapshot: the
/// Media screen renders its gated pre-snapshot state (inert slider + "--").
class _FakeService extends ConnectionService {
  _FakeService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<RemoteMessage> reliable = [];

  @override
  bool get isAuthed => false;

  @override
  ChipStatus get chipStatus => ChipStatus.disconnected;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

Widget _host(ConnectionService service) => ProviderScope(
      overrides: [
        connectionServiceProvider.overrideWith((ref) => service),
      ],
      child: const MaterialApp(home: MediaScreen()),
    );

void main() {
  testWidgets('renders the three transport icons', (t) async {
    await t.pumpWidget(_host(_FakeService()));

    expect(find.byIcon(Symbols.skip_previous_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.skip_next_rounded), findsOneWidget);

    // Unmount so the header chip's periodic ticker is cancelled (no pending
    // timer at teardown).
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('play-pause tappable region is 64x64; prev/next are 48x48',
      (t) async {
    await t.pumpWidget(_host(_FakeService()));

    Size sizeOf(IconData icon) {
      final box = find
          .ancestor(of: find.byIcon(icon), matching: find.byType(SizedBox))
          .first;
      return t.getSize(box);
    }

    expect(sizeOf(Symbols.play_arrow_rounded), const Size(64, 64));
    expect(sizeOf(Symbols.skip_previous_rounded), const Size(48, 48));
    expect(sizeOf(Symbols.skip_next_rounded), const Size(48, 48));

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('pre-snapshot readout is "--" with tabular figures', (t) async {
    await t.pumpWidget(_host(_FakeService()));

    final readout = find.text('--');
    expect(readout, findsOneWidget);

    final text = t.widget<Text>(readout);
    expect(text.textAlign, TextAlign.right);
    expect(
      text.style?.fontFeatures,
      contains(const FontFeature.tabularFigures()),
      reason: 'the volume readout must use tabular figures (UI-SPEC)',
    );

    await t.pumpWidget(const SizedBox());
  });
}
