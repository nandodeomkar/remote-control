// Task 1 (07-10) — the D-12 no-regression guard. Proves every screen has
// migrated onto the single `theme/tokens.dart` palette source: no `.dart`
// file under `lib/` (other than tokens.dart itself) may re-declare one of the
// LOCKED palette hex literals. A future screen that copy-pastes a
// `const Color _bg = Color(0xFF0E0F12)` block instead of importing the
// tokens fails this test immediately.
//
// Doc-comment mentions of the hex values (e.g. `/// ... #16181D ...`) are
// exempt — they document the design, they don't redeclare it — so lines
// whose trimmed content starts with `//` are skipped before scanning.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The seven LOCKED D-12 palette literals (`lib/theme/tokens.dart`). Any
/// `.dart` file under `lib/` other than tokens.dart itself must never contain
/// one of these as a Dart hex-color literal.
const List<String> kLockedPaletteLiterals = [
  '0xFF0E0F12', // kBg
  '0xFF16181D', // kSurface
  '0xFF2A2D34', // kHairline
  '0xFFE6E8EB', // kText
  '0xFF6B7280', // kMuted
  '0xFF4C8DFF', // kAccent
  '0xFFFF6B6B', // kError
];

void main() {
  test('no screen re-declares a locked palette literal (D-12 guard)', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib/ must exist');

    final offenders = <String>[];

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      // The single source of truth is exempt from its own guard.
      final normalized = entity.path.replaceAll('\\', '/');
      if (normalized.endsWith('lib/theme/tokens.dart')) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        // Doc/line comments document the palette in prose (e.g. `#16181D`)
        // without redeclaring a Dart literal — skip them so they never
        // self-trip the guard.
        if (trimmed.startsWith('//')) continue;

        for (final literal in kLockedPaletteLiterals) {
          if (lines[i].contains(literal)) {
            offenders.add('$normalized:${i + 1} contains $literal');
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Locked palette literals must live ONLY in lib/theme/tokens.dart '
          '(D-12) — found:\n${offenders.join('\n')}',
    );
  });
}
