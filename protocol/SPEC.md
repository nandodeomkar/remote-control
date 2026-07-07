# Remote Control Wire Protocol — SPEC

**protoVersion:** `"1.0"`
**Status:** Locked contract. Both codecs (Rust `server-core`, Dart `remote_protocol`) are written against this document and proven byte-identical by the golden fixtures in `protocol/fixtures/`. No codec may adjust a fixture to match its own output.

Transport: a single WebSocket connection per session carrying two frame kinds — JSON text frames (everything) and 9-byte binary frames (mouse hot path only). Discovery is UDP broadcast (out of scope for this document; see design spec §4).

---

## 1. Envelope

Every JSON text frame is an object of the shape:

```json
{ "t": "<type string>", "seq": 41, "p": { } }
```

| Field | Type | Required | Semantics |
|-------|------|----------|-----------|
| `t`   | string | yes | Message type. Full registry in §7. |
| `seq` | integer | no | Client-assigned sequence number. Opaque to the server; the server never inspects, validates, or orders by it. Echoed nowhere except where a family explicitly says so. |
| `p`   | object | no | Type-specific payload. Absent `p` is equivalent to `{}` for types with no required payload fields. |

**Strictness (D-05):**

- Unknown fields anywhere — top level or inside `p` — are **IGNORED** on decode. This is the forward-compatibility rule: new minor protocol versions may add fields without breaking old peers. Decoders MUST NOT reject a message because it carries fields they do not know.
- **Missing required fields are hard decode errors.** A message whose family requires a field that is absent (e.g. `auth` without `p.mac`) MUST fail decoding; it is never silently coerced.
- The canonical decoded form of a message contains ONLY spec-defined fields. `encode(decode(wire))` must equal the canonical form when both are parsed as JSON (field order is insignificant).

## 2. Versioning (D-06)

- `protoVersion` is a `"major.minor"` string. Current version: `"1.0"`.
- `hello` carries `protoVersion`. The server parses only the **major** component.
- **Major mismatch:** the server replies `err` with `code:"versionMismatch"` and payload fields `serverVersion` and `clientVersion` (both `"major.minor"` strings), then closes the connection.
- **Minor mismatch:** accepted. Peers simply do not use features the other side does not know; unknown fields and unknown types are handled by the strictness rules (§1, §10).

## 3. Handshake FSM

Connection states, in order:

```
AwaitingHello  ──hello──▶  AwaitingAuth  ──pin/auth success──▶  Authed
```

1. **AwaitingHello.** The client sends `hello {p:{protoVersion, device}}`. On a valid hello (major version matches), the server replies `challenge {p:{nonce}}` where `nonce` is 64 lowercase hex characters encoding 32 bytes from a CSPRNG — **fresh per connection, never reused**. The state becomes AwaitingAuth.
2. **AwaitingAuth.** The client takes exactly one of two paths:
   - **(a) Pairing (first connect).** The client sends `pin {p:{pin:"NNNNNN"}}` — a 6-digit zero-padded **string** (leading zeros are significant; the value is never a JSON number). On success the server replies `pairOk {p:{token}}` where `token` is 64 lowercase hex characters encoding 32 random bytes, and the session becomes Authed. **This is the ONLY time the raw token crosses the wire** — an accepted v1 tradeoff, see §12.
   - **(b) Reconnect (every later session).** The client sends `auth {p:{mac}}` where `mac` is 64 lowercase hex characters (§4). The server verifies and replies `authOk {p:{}}` (state becomes Authed) or `authFail {p:{reason, ...}}` (§5).

## 4. Auth construction (LOCKED)

The design spec's literal text ("HMAC-SHA256(token, nonce), server verifies against its stored hash") is cryptographically unimplementable: a server holding only `SHA-256(token)` cannot compute an HMAC keyed by the raw token. The locked construction — the only one satisfying both constraints "tokens stored only as SHA-256 hashes" AND "raw token never crosses the wire after pairing" — is:

```
mac = HMAC-SHA256( key = SHA-256(raw token bytes), message = nonce bytes )
```

encoded as 64 lowercase hex characters.

**HMAC key = SHA-256(raw token).** The phone stores the raw token and derives the key locally at each connect. The server stores ONLY `SHA-256(token)` and uses that stored hash **directly** as the HMAC key for verification — it never needs (and never has) the raw token after pairing. Verification MUST be constant-time.

**Replay defense:** the nonce is 32 fresh CSPRNG bytes per connection, so a sniffed `mac` is bound to a dead nonce and is useless to a replaying attacker. A rogue (beacon-spoofing) server learns only `HMAC(hash, its_own_nonce)`, which it cannot replay to the real server.

**Residual risk (accepted, out of v1 threat model):** a live man-in-the-middle relaying the real server's challenge to the phone in real time can proxy one session. Defeating that requires TLS or channel binding — deferred to a future major/minor version. The v1 threat model is a private LAN.

The cross-language proof for this construction is `protocol/fixtures/handshake/05-auth-proof.json`: a fixed token, a fixed nonce, and the expected mac computed by an independent third implementation (.NET crypto). Both codecs MUST reproduce it byte-identically.

## 5. PIN rules

- The PIN is 6 decimal digits, zero-padded, transmitted as a string.
- **Expiry:** a displayed PIN is valid for **60 seconds**.
- **Attempts:** **5** wrong attempts, then a **5-minute lockout per source IP**.
- **Global cap (discretionary hardening):** in addition to the per-IP rule, **20 total failed attempts** across all sources trigger lockout regardless of IP (LAN attackers rotate addresses freely).

`authFail` reasons (the `p.reason` string) are enumerated:

| Reason | Extra payload fields | Meaning |
|--------|---------------------|---------|
| `pinInvalid` | `attemptsRemaining` (integer) | Wrong PIN; attempts left before lockout |
| `pinExpired` | — | The 60-second window elapsed |
| `lockedOut` | `retryAfterSecs` (integer) | Source is locked out; seconds until retry allowed |
| `noPairing` | — | `auth` received but the server has no stored pairing |
| `badMac` | — | HMAC verification failed |

## 6. Auth gating

Before the session reaches **Authed**, the ONLY incoming message types the server processes are `hello`, `pin`, and `auth`. Everything else — including **binary frames** and `ping` — is **silently dropped** pre-auth. No `err` reply is sent for pre-auth drops (do not give an unauthenticated peer a probing oracle).

## 7. Message family registry

Direction: C→S (client to server), S→C (server to client), C↔S (both).

| Type | Direction | Required `p` fields | Optional `p` fields | Notes |
|------|-----------|--------------------|--------------------|-------|
| `hello` | C→S | `protoVersion` (string), `device` (string) | — | Opens handshake (§3) |
| `pin` | C→S | `pin` (string, 6 digits, zero-padded) | — | Pairing path |
| `pairOk` | S→C | `token` (string, 64 lowercase hex) | — | Only wire appearance of the raw token (§12) |
| `challenge` | S→C | `nonce` (string, 64 lowercase hex) | — | Fresh per connection |
| `auth` | C→S | `mac` (string, 64 lowercase hex) | — | §4 construction |
| `authOk` | S→C | — (`p` is `{}`) | — | Session becomes Authed |
| `authFail` | S→C | `reason` (string, §5 enum) | `attemptsRemaining`, `retryAfterSecs` | Reason-specific extras per §5 |
| `click` | C→S | `button` (`"left"`\|`"middle"`\|`"right"`) | — | Reliable path (JSON, not binary) |
| `drag` | C→S | `action` (`"start"`\|`"end"`), `button` (`"left"`\|`"middle"`\|`"right"`) | — | Held state tracked by server; released on session end (§11) |
| `key` | C→S | `code` (string), `action` (`"tap"`\|`"down"`\|`"up"`) | `mods` (array of `"ctrl"`\|`"alt"`\|`"shift"`\|`"win"`, default `[]`) | Single key with modifiers |
| `text` | C→S | `bs` (integer ≥ 0), `ins` (string) | — | Diff-ops, §8 |
| `media` | C→S | `action` (`"playpause"`\|`"next"`\|`"prev"`\|`"volup"`\|`"voldown"`\|`"mute"`\|`"setvol"`) | `value` (integer 0–100; **required iff** `action` is `"setvol"`) | |
| `power` | C→S | `action` (`"lock"`\|`"sleep"`\|`"restart"`\|`"shutdown"`) | — | Requires follow-up `confirm` |
| `confirm` | C→S | `action` (same enum as `power`) | — | Must match a pending `power` action within **10 seconds**, else server replies `err {code:"noPendingAction"}` |
| `apps.list` | C→S request / S→C reply | request: — (`p` is `{}`); reply: `windows` (array of `{id: integer, title: string}`) | — | |
| `apps.launch` | C→S | `path` (string) | — | |
| `apps.focus` | C→S | `id` (integer) | — | |
| `apps.close` | C→S | `id` (integer) | — | |
| `apps.changed` | S→C | `windows` (array of `{id: integer, title: string}`) | — | Server push |
| `clip.set` | C↔S | `text` (string) | — | Both directions |
| `clip.get` | C→S | — (`p` is `{}`) | — | Server replies with `clip.set` |
| `clip.changed` | S→C | `text` (string) | — | Server push (auto-sync) |
| `browser` | C→S | `action` (`"back"`\|`"forward"`\|`"newtab"`\|`"closetab"`\|`"refresh"`\|`"zoomin"`\|`"zoomout"`) | — | Key-macro based |
| `present` | C→S | `action` (`"next"`\|`"prev"`\|`"start"`\|`"end"`\|`"blank"`) | — | Presenter remote |
| `ping` | C→S | `ts` (integer) | — | Latency probe |
| `pong` | S→C | `ts` (integer, echoed from `ping`) | — | |
| `err` | S→C | `code` (string), `msg` (string) | code-specific fields | Human-readable `msg`; see codes below |

**`err` codes:**

| Code | Extra payload fields | When |
|------|---------------------|------|
| `versionMismatch` | `serverVersion`, `clientVersion` | Major protoVersion mismatch on `hello` (§2); connection then closes |
| `unknownType` | — | Unknown `t` post-auth (§10); connection stays alive |
| `noPendingAction` | — | `confirm` without a matching pending `power` action within 10s |
| `bsTooLarge` | — | `text` with `bs` exceeding the cap (§8) |
| `internal` | — | Server-side failure executing a valid request |

## 8. Diff-ops text semantics

The `text` payload is `{bs, ins}`: **delete `bs` graphemes at the end of the committed text, then insert `ins`**.

- `bs` counts **EXTENDED GRAPHEME CLUSTERS** (Unicode UAX #29) — **never** UTF-16 code units and **never** bytes. A single emoji with a skin-tone modifier (e.g. `👋🏽`, two code points, multiple UTF-8/UTF-16 units) counts as exactly **1**.
- The client computes, from the previous committed text `old` and the new committed text `new`:
  - `bs = graphemes(old) − graphemes(commonPrefix(old, new))`
  - `ins = suffix of new after the common prefix`
- This covers IME autocomplete revision (`"thw"` → `"the "` ⇒ `bs:1, ins:"e "`), rapid backspace (`bs:N, ins:""`), and any tail edit (worst case retypes the tail). Insert/delete position is implicitly end-of-committed-text.
- **Cap:** the server rejects `bs > 10000` with `err {code:"bsTooLarge"}`. The message is not executed.

## 9. Binary frames (mouse hot path)

Binary WebSocket frames are **exactly 9 bytes**:

```
[opcode u8][dx f32 LE][dy f32 LE]
```

| Opcode | Meaning |
|--------|---------|
| `0x01` | move (relative cursor delta) |
| `0x02` | scroll (relative scroll delta) |

`dx`/`dy` are IEEE-754 binary32 (f32), **little-endian**. Frames are sent at input rate (~60–120 Hz), fire-and-forget; the server never acknowledges them.

**Strict decode rules:**

- Length ≠ 9 bytes → decode error.
- Unknown opcode → decode error.
- Non-finite f32 (`NaN`, `+Inf`, `-Inf`) in `dx` or `dy` → decode error.
- Errored frames are **dropped and counted** (diagnostics), never routed to an executor, and never terminate the session.

The full byte layout is documented in `protocol/schema/mouse-binary.md`.

## 10. Unknown message type `t` (D-07)

- **Post-auth:** the server replies `err {code:"unknownType", msg:"unknown message type: <t>"}` (human-readable, naming the offending type) and the **connection stays alive**. Unknown types never kill a session.
- **Pre-auth:** silently dropped (§6).

## 11. Pause semantics and session cleanup

- While server-side **pause** is active, all executor-bound messages are **silently dropped**: binary frames, `click`, `drag`, `key`, `text`, `media`, `power`, `confirm`, `apps.launch`, `apps.focus`, `apps.close`, `clip.set`, `browser`, `present`. The handshake family (`hello`, `pin`, `auth`) and `ping`/`pong` continue to work — pause never breaks connectivity or liveness probing.
- **Activating pause immediately releases any held input** (buttons held via `drag start`, keys held via `key down`).
- **Session end for ANY reason** — clean close, socket error, auth revoke, server shutdown — **releases all held keys and buttons** (CONN-07). No phantom held input may survive a mid-drag disconnect.

## 12. Security notes

- **Token delivery tradeoff (accepted, v1):** `pairOk` carries the raw token in plaintext **once**, during pairing, on the LAN. Post-pairing, only HMAC proofs cross the wire (§4). PIN-derived token wrapping is a candidate for a future minor version; explicitly out of v1 scope.
- **Live MITM relay (accepted, v1):** see §4 residual risk. Needs TLS/channel binding — v2 territory.
- The server binds LAN interfaces only; never internet-exposed.
- Power actions require the two-step `power` → `confirm` sequence (§7); the confirm window is 10 seconds.
- Secrets are never logged: `pin`, `auth` macs, tokens, `text` payloads, and `clip.*` contents are redaction-mandatory in any logging implementation.

## 13. Transport limits

- WebSocket `max_message_size` = **65536 bytes (64 KB)**.
- WebSocket `max_frame_size` = **65536 bytes (64 KB)**.
- Both limits are enforced **pre- and post-auth** (pre-auth memory-DoS defense; the largest legitimate v1 message is a clipboard payload, well under the cap).

## 14. Fixtures

Golden fixtures live in `protocol/fixtures/` (format documented in `protocol/fixtures/README.md`). Every fixture scenario references a section of this SPEC; the strictness rules of §1 (ignore-unknown / missing-required), §2 (version reject), and §9 (binary strictness) are encoded as negative fixtures. Both codecs load the same files; per-language fixture copies are forbidden.
