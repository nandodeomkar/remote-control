/// Single source of truth for every user-facing connection/pairing string
/// (03-UI-SPEC Copywriting Contract — copy is LOCKED verbatim).
///
/// Tone contract: plain, device-owner-directed, no jargon, no exclamation
/// marks. Every error names the problem AND the next step. Raw enum values
/// (`badMac`, `noPairing`) and exception strings NEVER reach the user
/// (T-03-24): [pairingErrorCopy] whitelists reasons and maps everything
/// unknown to a generic retry line.
///
/// Screens must reference these — no inline copy literals in widget files.
library;

import '../net/reconnect_fsm.dart' show kRevokedExplanation;

// -- CTAs & labels (Copywriting Contract rows 1-4) ---------------------------

/// Primary CTA on the PIN pairing sheet.
const String kPairCta = 'Pair';

/// Primary CTA on the Connect-by-IP sheet.
const String kConnectCta = 'Connect';

/// The device list's secondary affordance (D-03 — always a TextButton).
const String kConnectByIpLabel = 'Connect by IP';

/// The reconnecting banner's trailing action.
const String kRetryNowLabel = 'Retry now';

/// Device list app-bar title.
const String kDevicesTitle = 'Devices';

/// Connect-by-IP sheet heading (same words as the affordance, per UI-SPEC).
const String kConnectByIpHeading = 'Connect by IP';

/// IP field label on the Connect-by-IP sheet.
const String kServerIpLabel = 'Server IP';

/// IP field hint on the Connect-by-IP sheet.
const String kServerIpHint = '192.168.1.x';

/// Port field label on the Connect-by-IP sheet.
const String kPortLabel = 'Port';

// -- Empty state --------------------------------------------------------------

/// Empty-state heading while the beacon listener scans.
const String kEmptyStateHeading = 'Looking for your PC…';

/// Empty-state body (max 2 lines, centered).
const String kEmptyStateBody =
    'Start the Remote Control server on your PC and make sure both devices '
    'are on the same WiFi. Or connect by IP below.';

// -- PIN pairing sheet ---------------------------------------------------------

/// Pairing sheet body line.
const String kPinSheetBody = 'Enter the 6-digit PIN shown on your PC';

/// Pairing sheet heading for [deviceName].
String pairingSheetHeading(String deviceName) => 'Pair with $deviceName';

// -- Banner & connect errors ---------------------------------------------------

/// Non-blocking reconnect banner text (D-04).
const String kReconnectingBannerCopy = 'Reconnecting…';

/// A beacon proves the PC is up, but the ws connect timed out (CONN-05).
const String kFirewallBlockedCopy =
    'PC found but connection blocked — check Windows Firewall on your PC';

/// Manual entry failed local validation (not an IP, bad port).
const String kInvalidManualInputCopy = 'Enter a valid IP address and port';

/// The RFC1918 dial guard refused the address (D-10 code half).
const String kNonPrivateAddressCopy =
    'Only local network addresses work (like 192.168.x.x)';

/// Generic transport failure for a manual connect to [ip]:[port].
String transportFailedCopy(String ip, int port) =>
    "Couldn't reach $ip:$port — check the address and that the server is "
    'running';

// -- Trackpad hints (UI-SPEC Copywriting Contract rows) -------------------------

/// Trackpad surface hint while authed.
const String kTrackpadHintAuthed = 'Drag to move the cursor';

/// Trackpad surface hint while not authed (muted, no spinner on the surface).
const String kTrackpadHintNotConnected = 'Not connected';

// -- Device row metadata lines (UI-SPEC "Device list row" states) --------------

/// Metadata for a discovered, unpaired row.
String deviceMetaLive(String ip) => ip;

/// Metadata for a discovered, paired row.
String deviceMetaPaired(String ip) => '$ip · paired';

/// Metadata for the (single) currently-connected row.
String deviceMetaConnected(String ip) => '$ip · connected';

/// Metadata for a remembered-but-undiscovered (grayed) row.
String deviceMetaLastSeen(String ip, int port) => 'last seen at $ip:$port';

// -- authFail reason mapping (CONN-02) ------------------------------------------

/// Maps an `authFail` reason (or `versionMismatch`) to its exact UI-SPEC
/// copy. Whitelist semantics: an unknown [reason] renders a generic retry
/// line — the raw enum value never reaches the user (T-03-24).
String pairingErrorCopy(
  String reason, {
  int? attemptsRemaining,
  int? retryAfterSecs,
}) {
  switch (reason) {
    case 'pinInvalid':
      final n = attemptsRemaining;
      if (n == null) return 'Wrong PIN — try again';
      return n == 1 ? 'Wrong PIN — 1 attempt left' : 'Wrong PIN — $n attempts left';
    case 'pinExpired':
      return 'That PIN expired — check your PC for a new one';
    case 'lockedOut':
      return 'Too many attempts — try again in ${retryAfterSecs ?? 0}s';
    case 'noPairing':
    case 'badMac':
      // The D-05 string, single definition in reconnect_fsm.dart — imported,
      // never re-declared.
      return kRevokedExplanation;
    case 'versionMismatch':
      return 'This phone and the PC server need matching versions — update '
          'both, then try again';
    default:
      return "Couldn't pair — try again";
  }
}
