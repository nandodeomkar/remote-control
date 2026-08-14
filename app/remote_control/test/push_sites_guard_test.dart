// Task 2 (13-07) — the push-site guard (D-13-16). Proves every page route in
// the app is constructed through `pushGuarded` (lib/shell/summon_back_guard.
// dart) and never by hand. A future screen that types
// `Navigator.of(context).push(MaterialPageRoute(...))` instead of
// `pushGuarded(context, ...)` fails this test immediately.
//
// WHY THIS GUARD EXISTS AND NOT JUST A CONVENTION. SUM-04 fails SILENTLY on an
// un-guarded page route: back keeps popping the screen with the summon surface
// still raised, and there is no error, no assert and no log to notice it by.
// Research found 8 push sites across 5 files, of which only the hub's central
// tile-open was covered — Settings, Device List, Updates, the QR scanner and
// the bubble's expand were all quietly outside the requirement, and nothing
// warned. A defect with no signal cannot be caught by review; it has to be
// caught by the build.
//
// Matching rule: `RegExp(r'(^|[^A-Za-z0-9_$])(MaterialPageRoute|'
// r'CupertinoPageRoute|PageRouteBuilder)\s*[(<]')`. The leading
// character-class (rather than a bare `contains`) keeps a hypothetical
// `MyMaterialPageRoute` from false-positiving, and the trailing `[(<]` matches
// both the bare constructor and the explicitly-typed `MaterialPageRoute<T>(`
// form. Modal routes (`showDialog` / `showModalBottomSheet`) are deliberately
// NOT banned — with one open it is the topmost route, so back closes it first
// and the raised surface is untouched. That is intended behaviour.
//
// Doc/line comments (lines whose trimmed content starts with `//`) are skipped
// before scanning, mirroring the proven `icons_guard_test.dart` and
// `theme_tokens_guard_test.dart` — several files name `MaterialPageRoute` in
// prose while pushing correctly, and prose does not push a route.
//
// ALLOWLIST — non-empty by design, unlike the icons guard. `lib/shell/` is
// exempt by PATH PREFIX (never by line number, which drifts on the next edit
// to that file): it holds `pushGuarded` itself, and the helper is the one
// legitimate page-route construction site in the whole app. Every entry below
// carries its written reason. Widen this list only for a genuine framework
// constraint — never by loosening the RegExp, and never to make a new screen
// compile.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Directories under `lib/` exempt from the ban, each with the reason it is
/// exempt. Prefix-matched against the forward-slash-normalised path, so an
/// edit inside an exempt file can never invalidate the entry.
const Map<String, String> kPushSitesGuardExemptPrefixes = <String, String>{
  // The seam itself. `pushGuarded` constructs the one page route the app is
  // allowed to construct, and wraps it in `SummonBackGuard` — banning it here
  // would ban the fix. Scoped to the directory rather than to
  // `summon_back_guard.dart:<line>` so it survives the next edit to that file.
  'lib/shell/': 'holds pushGuarded — the one sanctioned construction site',
};

/// Individual `lib/…/foo.dart:<line>` exceptions, each with a written reason.
///
/// Intentionally empty: after 13-07's conversion every push outside
/// `lib/shell/` goes through the helper, so no line-level exception is needed.
/// A future entry MUST carry a comment naming the framework constraint that
/// forces a bare construction — "it was easier" is not one.
const Map<String, String> kPushSitesGuardAllowlist = <String, String>{};

/// Bans a bare page-route construction. Matches the bare constructor and the
/// explicitly-typed `<T>(` form; the leading character-class stops a
/// same-suffix identifier from tripping it.
final RegExp _barePageRoute = RegExp(
  r'(^|[^A-Za-z0-9_$])(MaterialPageRoute|CupertinoPageRoute|PageRouteBuilder)'
  r'\s*[(<]',
);

void main() {
  test('every page route in lib/ is built through pushGuarded (D-13-16)', () {
    // Relative to the package root, like the sibling guards — the suite runs
    // from `app/remote_control/`, so this resolves the same way for every
    // test in the run.
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib/ must exist');

    final offenders = <String>[];

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      // Windows hands back backslashes; normalise so the allowlist and the
      // exempt prefixes match on every platform.
      final normalized = entity.path.replaceAll('\\', '/');

      if (kPushSitesGuardExemptPrefixes.keys.any(normalized.startsWith)) {
        continue;
      }

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        // Prose about the banned construct is not the banned construct.
        if (trimmed.startsWith('//')) continue;

        if (_barePageRoute.hasMatch(lines[i])) {
          final location = '$normalized:${i + 1}';
          if (kPushSitesGuardAllowlist.containsKey(location)) continue;
          offenders.add('$location -> ${trimmed.isEmpty ? lines[i] : trimmed}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'A page route was constructed by hand instead of through '
          '`pushGuarded(context, screen)` (lib/shell/summon_back_guard.dart). '
          'This is a defect, not a style point: a route pushed without the '
          'guard silently loses back-dismiss — back keeps popping the screen '
          'with the summon surface still raised, with no error and no log '
          '(SUM-04, D-13-16). Use pushGuarded, or add a reasoned entry to '
          'kPushSitesGuardAllowlist — never loosen the pattern. Found:\n'
          '${offenders.join('\n')}',
    );
  });

  test('every guard exemption carries a written reason', () {
    // A bare exemption is how this guard rots: the next reader cannot tell a
    // deliberate carve-out from a silenced failure.
    for (final entry in kPushSitesGuardExemptPrefixes.entries) {
      expect(
        entry.value.trim(),
        isNotEmpty,
        reason: 'Exempt prefix ${entry.key} has no reason written beside it',
      );
    }
    for (final entry in kPushSitesGuardAllowlist.entries) {
      expect(
        entry.value.trim(),
        isNotEmpty,
        reason: 'Allowlist entry ${entry.key} has no reason written beside it',
      );
    }
  });
}
