/// The extension-missing hint card, shared by BOTH Browser segments
/// (260716-oi2 tab section; phase-11 bookmarks section).
///
/// Lifted VERBATIM out of `browser_screen.dart`'s private `_InstallHintCard`
/// — same kSurface fill, kHairline border, radius 16, padding 16, muted
/// leading extension glyph, 14/600 title (grandfathered — deliberately not
/// re-sized to the 16/600 Heading role) and 12/400 muted body. Plain [Text]
/// only — url_launcher is NOT a dependency and none is added.
///
/// It lives in its own file because the Bookmarks segment renders the SAME
/// card with the SAME copy (11-UI-SPEC Copywriting Contract: "do not fork a
/// bookmarks-specific variant"). A stale bookmark tree next to a correct
/// install hint — or two hints that word the fix differently — is the phase's
/// most visible failure mode, and one widget with one copy home is the only
/// structural way the two segments cannot drift.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/tokens.dart';

/// Install-hint title (shipped copy, verbatim).
const String kInstallHintTitle = 'Install the browser extension';

/// Install-hint body (shipped copy, verbatim — including the
/// `extension/README.md` reference the owner follows).
const String kInstallHintBody =
    'See tabs here by loading the free Tab Bridge extension '
    'on your PC — the extension/README.md file in the '
    'Remote Control download walks through it.';

/// The extension-missing hint card: kSurface fill, kHairline border, radius
/// 16, padding 16, with a muted leading extension glyph.
class InstallHintCard extends StatelessWidget {
  /// Creates the card. It has no state and no parameters — the copy is fixed.
  const InstallHintCard({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: kSurface,
          border: Border.all(color: kHairline),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Symbols.extension_rounded, size: 24, color: kMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    kInstallHintTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: kText,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    kInstallHintBody,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: kMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}
