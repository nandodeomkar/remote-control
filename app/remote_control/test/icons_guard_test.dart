// Task 2 (09-09) — the Material Symbols Rounded no-regression guard. Proves
// every glyph the app renders comes from `material_symbols_icons`
// (`Symbols.<name>_rounded`) and NOT the classic filled Material `Icons.*`
// set. A future screen that types `Icon(Icons.foo)` instead of
// `Icon(Symbols.foo_rounded)` fails this test immediately.
//
// This enforces the 09-09 owner decision (2026-07-16): full Material Symbols
// Rounded fidelity, overriding 09-UI-SPEC line 28's original skew acceptance
// ("keep the Flutter Icons.* the app already uses"). The design prototype
// renders Material Symbols Rounded (opsz 24 / wght 400 / FILL 0 / GRAD 0), so
// classic `Icons.*` is now banned in lib/.
//
// Matching rule: `RegExp(r'(^|[^A-Za-z0-9_$])Icons\.')`. The leading
// character-class (rather than a bare `contains('Icons.')`) is what keeps
// `CupertinoIcons.` and `Symbols.` from false-positiving — a naive substring
// match would trip on `CupertinoIcons.`.
//
// Doc/line comments (lines whose trimmed content starts with `//`) are skipped
// before scanning, mirroring the proven `theme_tokens_guard_test.dart` — they
// document the design in prose, they don't render a glyph.
//
// Allowlist: EMPTY. Zero legitimate classic refs remain after the 09-09
// migration. Any future exception MUST be added to `kIconsGuardAllowlist`
// below as an explicit `path:line` entry WITH a written reason — never by
// loosening the RegExp.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Explicit, reasoned exceptions to the classic-`Icons.` ban, as
/// `lib/…/foo.dart:<line>` strings. Intentionally empty — the 09-09 migration
/// left zero legitimate classic references. Add an entry (with a comment
/// naming the reason) only if a genuine framework constraint forces a classic
/// `Icons.` reference back into `lib/`.
const List<String> kIconsGuardAllowlist = <String>[];

/// Bans a bare classic `Icons.` reference while leaving `CupertinoIcons.` and
/// the migrated `Symbols.` constants untouched.
final RegExp _classicIconsRef = RegExp(r'(^|[^A-Za-z0-9_$])Icons\.');

void main() {
  test('no lib file uses classic Icons.* (Material Symbols Rounded guard)', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib/ must exist');

    final offenders = <String>[];

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final normalized = entity.path.replaceAll('\\', '/');

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        // Skip doc/line comments — they may name `Icons.foo` in prose without
        // rendering a glyph (same exemption as the D-12 palette guard).
        if (trimmed.startsWith('//')) continue;

        if (_classicIconsRef.hasMatch(lines[i])) {
          final location = '$normalized:${i + 1}';
          if (kIconsGuardAllowlist.contains(location)) continue;
          offenders.add('$location -> ${trimmed.isEmpty ? lines[i] : trimmed}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Classic Material `Icons.*` is banned in lib/ (09-09 owner decision: '
          'full Material Symbols Rounded fidelity via material_symbols_icons, '
          'overriding 09-UI-SPEC line 28). Use `Symbols.<name>_rounded` '
          'instead, or add an explicit reasoned entry to '
          'kIconsGuardAllowlist — found:\n${offenders.join('\n')}',
    );
  });
}
