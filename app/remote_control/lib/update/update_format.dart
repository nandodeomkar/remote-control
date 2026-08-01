/// The two copy formatters the Updates screen renders: elapsed time and
/// download size. Deterministic, pure, no I/O, no clock.
///
/// **NO NEW PACKAGE, deliberately.** Both of these are short branch tables
/// whose exact output is fixed by the UI-SPEC — a dependency for either would
/// be a wrapper over work the SDK already does, which this project has now
/// rejected three times (the stale UDP package, the dead wakelock original,
/// the haptics-waveform wrapper). The values below are binding contract, not
/// suggestions: they are quoted from the UI-SPEC `{ago}` table and the
/// Copywriting Contract `{size}` rule, and the PC settings window quotes the
/// same sentences so the two surfaces never describe one state with two sets
/// of words.
///
/// **Every string is a named `const String` at file top** (the
/// `settings_screen.dart` house rule) — never an inline literal at the point
/// of use, so the whole user-visible vocabulary of this module is readable in
/// one place and reviewable against the copy table.
///
/// **Typography rule, recorded even though neither formatter emits them:** the
/// ellipsis is the single character `…` (U+2026), never three periods, and the
/// transition arrow is `→` (U+2192), never `->`. The strings that carry those
/// characters (`Checking…`, `{installed} → {latest} · {size}`) are assembled
/// by the screen; if a formatter ever grows one, it uses the real character.
library;

// -- Copy consts (UI-SPEC {ago} table) ---------------------------------------

/// Under one minute — the whole string, with no count.
const String kAgoJustNow = 'just now';

/// The suffix every counted elapsed string ends with.
const String kAgoSuffix = ' ago';

/// Unit word for exactly one minute.
const String kAgoUnitMinuteOne = 'minute';

/// Unit word for any minute count that is not one.
const String kAgoUnitMinuteMany = 'minutes';

/// Unit word for exactly one hour.
const String kAgoUnitHourOne = 'hour';

/// Unit word for any hour count that is not one.
const String kAgoUnitHourMany = 'hours';

/// Unit word for exactly one day.
const String kAgoUnitDayOne = 'day';

/// Unit word for any day count that is not one.
const String kAgoUnitDayMany = 'days';

// -- Copy consts (UI-SPEC Copywriting Contract {size} rule) ------------------

/// The size suffix — a space then the unit. Megabytes is the only unit this
/// phase renders: the three real assets span 13 KB to 70 MB, and a KB/GB
/// ladder would add branches nothing can reach.
const String kSizeSuffixMb = ' MB';

// -- Thresholds --------------------------------------------------------------

/// Bytes per megabyte — binary MB (1024 * 1024), the divisor the UI-SPEC
/// names explicitly.
const int kBytesPerMb = 1048576;

/// At and above this many megabytes the size renders as a rounded integer;
/// below it, with one decimal place.
const double kSizeDecimalCutoffMb = 10.0;

/// Formats [elapsed] as the UI-SPEC `{ago}` table renders it.
///
/// | Elapsed  | Renders                             |
/// |----------|-------------------------------------|
/// | < 60 s   | `just now`                          |
/// | < 60 min | `{n} minute ago` / `{n} minutes ago` |
/// | < 24 h   | `{n} hour ago` / `{n} hours ago`     |
/// | otherwise| `{n} day ago` / `{n} days ago`       |
///
/// Singular at exactly 1, plural everywhere else — including 0, which is not
/// reachable through the counted branches (anything under a minute is
/// [kAgoJustNow]) but is handled rather than left to chance.
///
/// A negative [elapsed] — a cache entry timestamped in the future after a
/// clock or timezone correction — renders as [kAgoJustNow] rather than a
/// nonsense `-3 hours ago`. The cache treats such an entry as stale
/// independently, so the wrong-looking line is transient by construction.
String formatAgo(Duration elapsed) {
  if (elapsed.inSeconds < 60) return kAgoJustNow;

  if (elapsed.inMinutes < 60) {
    return _counted(elapsed.inMinutes, kAgoUnitMinuteOne, kAgoUnitMinuteMany);
  }
  if (elapsed.inHours < 24) {
    return _counted(elapsed.inHours, kAgoUnitHourOne, kAgoUnitHourMany);
  }
  return _counted(elapsed.inDays, kAgoUnitDayOne, kAgoUnitDayMany);
}

/// `{n} {unit} ago`, picking [one] at exactly 1 and [many] otherwise.
String _counted(int n, String one, String many) =>
    '$n ${n == 1 ? one : many}$kAgoSuffix';

/// Formats [bytes] as the UI-SPEC `{size}` rule renders it: bytes divided by
/// [kBytesPerMb], one decimal place below [kSizeDecimalCutoffMb], a rounded
/// integer at and above it, then [kSizeSuffixMb].
///
/// Against the real release assets this yields `66 MB` for the APK
/// (69 630 935 B) and `4.9 MB` for the setup exe (5 177 240 B) — the two
/// magnitudes the download-size promise in D-08 exists for.
///
/// A negative [bytes] is clamped to zero. Sizes arrive from the release feed
/// and are therefore untrusted; `-1 MB` in the copy would be a defect
/// surfacing as user-visible nonsense, and zero is the honest floor.
String formatSize(int bytes) {
  final megabytes = (bytes < 0 ? 0 : bytes) / kBytesPerMb;
  final rendered = megabytes < kSizeDecimalCutoffMb
      ? megabytes.toStringAsFixed(1)
      : '${megabytes.round()}';
  return '$rendered$kSizeSuffixMb';
}
