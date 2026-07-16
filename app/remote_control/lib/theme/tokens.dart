/// The single source of truth for the app's dark-minimal palette and theme
/// (UI-02 / D-12).
///
/// Before this file the locked palette was copy-pasted as `const Color _bg/…`
/// blocks in every screen (`hub_screen.dart` L44-49 and its siblings) and the
/// [ThemeData] was declared inline in `main.dart`. D-12 consolidates BOTH into
/// one place: every screen imports these public consts, and the app shell calls
/// [buildAppTheme]. The accent is FIXED blue `#4C8DFF` — there is no picker.
///
/// This is consolidation ONLY: the hex values and the theme are lifted verbatim
/// from the existing sources (UI-SPEC "Do not redesign"). Migrating each screen
/// off its local block onto these consts lands in 07-10; this plan only
/// establishes the source.
library;

import 'package:flutter/material.dart';

/// Page background — `#0E0F12` (UI-SPEC "Color").
const Color kBg = Color(0xFF0E0F12);

/// Raised surface (cards, bars) — `#16181D`.
const Color kSurface = Color(0xFF16181D);

/// Hairline dividers / borders — `#2A2D34`.
const Color kHairline = Color(0xFF2A2D34);

/// Primary text — `#E6E8EB`.
const Color kText = Color(0xFFE6E8EB);

/// Muted / secondary text — `#6B7280`.
const Color kMuted = Color(0xFF6B7280);

/// Fixed blue accent (D-12) — `#4C8DFF`. No accent picker.
const Color kAccent = Color(0xFF4C8DFF);

/// Error / destructive state — `#FF6B6B`.
const Color kError = Color(0xFFFF6B6B);

/// The dark-minimal [ThemeData] for the whole app.
///
/// Lifted verbatim from the inline theme previously declared in `main.dart`
/// (Brightness.dark, [kBg] scaffold, an accent-seeded dark [ColorScheme]). The
/// app shell replaces its inline `ThemeData(...)` with a call to this.
ThemeData buildAppTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: kBg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: kAccent,
      brightness: Brightness.dark,
    ),
    // 09-09 gap closure: pin the prototype's Material Symbols Rounded axis tuple
    // app-wide. The prototype's Google Fonts request is
    // `Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,400,0,0`, i.e. optical
    // size 24, weight 400, fill 0 (outlined), grade 0. Without this pin the
    // material_symbols_icons font defaults to opsz 48, rendering visibly thinner
    // strokes than the prototype at the app's 12–32px icon sizes. Flutter's Icon
    // widget reads these four values from IconTheme and emits matching
    // FontVariations; per-call-site size:/color: overrides are unaffected.
    iconTheme: const IconThemeData(
      fill: 0,
      weight: 400,
      grade: 0,
      opticalSize: 24,
    ),
  );
}
