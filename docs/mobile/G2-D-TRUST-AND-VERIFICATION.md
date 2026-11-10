# G2-D peer trust and verification

**Status: the trust state machine is implemented in Dart and tested. No peer has ever been
authenticated or verified by this app, because no session protocol exists yet. Nothing here
establishes that a peer is who they claim to be.**

- **Date:** 2026-11-09
- **Code:** `mobile/app/lib/identity/trust_state.dart`
- **Tests:** `mobile/app/test/identity_trust_state_test.dart`
- **Companions:** [G2-D-IDENTITY-KEY-MANAGEMENT.md](G2-D-IDENTITY-KEY-MANAGEMENT.md),
  [G2-D-ARCHITECTURE-DECISION.md](G2-D-ARCHITECTURE-DECISION.md)

## 1. Seven states, never one boolean

| # | Axis | What it means | Who may set it | Code |
|---|---|---|---|---|
| 1 | `discovered` | a radio candidate matched the G2-C service UUID | scanner | `markDiscovered` |
| 2 | `connected` | a GATT link exists | Android | `markConnected` |
| 3 | `serviceReady` | expected characteristics present, notifications configured | Android | `markServiceReady` |
| 4 | `sessionEstablished` | a cryptographic handshake completed | crypto provider | `markSessionEstablished` |
| 5 | `identityAuthenticated` | the session is bound to a concrete peer identity key | crypto provider + pin comparison | `authenticateIdentity` |
| 6 | `userVerified` | a human compared the fingerprint out of band | **the user, explicitly** | `verifyIdentity` |
| 7 | disconnected / revoked | no link; or the peer is permanently refused | link teardown / user | `disconnect`, `revokePeer` |

Invariants enforced by the implementation:

- **Order is mandatory.** Recording axis *n* without every axis before it throws
  `G2dPeerTrustError`. There is no way to record "verified" without an authenticated
  identity, or "service ready" without a connection.
- **Discovery is not identity.** A candidate token, a service UUID and a Bluetooth address
  are routing facts.
- **A connection is not authentication.** Axes 1–3 never produce an identity fingerprint.
- **Verification is not automatic.** Axis 6 requires a method and a timestamp supplied at
  the moment of a user ceremony.

## 2. What each state may be called in the UI

The implementation owns these strings so that no future screen invents a friendlier, less
truthful wording:

| Record state | `statusLabel` |
|---|---|
| nothing observed | `Not discovered` |
| discovered | `Discovered — untrusted radio candidate, not identified` |
| connected | `Connected — transport only, identity not authenticated` |
| service ready | `Service ready — transport only, identity not authenticated` |
| session established | `Session established — peer identity not yet authenticated` |
| identity authenticated | `Identity authenticated — not verified by you` |
| user verified, connected | `Verified by you (out-of-band comparison)` |
| user verified, not connected | `Verified by you — not currently connected` |
| identity changed | `Peer identity changed — re-verification required` |
| verified axis without full evidence | `Verification evidence incomplete — not verified` |
| revoked | `Revoked — do not communicate` |

Every verified label is derived from `isUserVerified`, never from the `userVerified` axis
alone. A record that carries the axis without a method, a timestamp or a pin is labelled as
incomplete — that combination is also rejected outright by the codec, so the label is a
second line of defence rather than the only one.

None of these say "secure", "encrypted", "trusted" or "safe". A test asserts that the
connected state does not contain the word "secure"; that test exists to catch a future
"harmless" wording change.

## 3. First contact: the verification ceremony

A peer is unverified until a human compares its fingerprint on both devices.

1. The session establishes and the peer identity key is bound to the transcript (axis 5),
   producing a 64-character hex fingerprint: `SHA-256(domain || version || algorithm ||
   canonical_public_key)`.
2. Both devices display the fingerprint in 16 groups of 4 characters, with an explicit
   "compare all of it" instruction. Truncated or abbreviated display is not acceptable —
   the comparison must cover the whole value.
3. Either the user reads it aloud, or both screens show a QR code containing the same value.
4. On match, the user confirms **on both devices**; each device records method + timestamp
   (axis 6). There is no "confirm once, trust forever on the other side" shortcut.
5. On mismatch, the user must not confirm. Nothing on either device auto-trusts.

Later, once a handshake exists, a transcript-derived short authentication string (SAS) may
be added as a second, fresher check. Two different questions must not be conflated:

- the **fingerprint** answers "is this the long-term key I expect?";
- a **handshake SAS** answers "is the key I am talking to right now the one that key
  produced in this session?" — it catches an active relay at the moment of connection.

The current milestone implements neither computation; it implements the state machine and
the labels those computations will feed.

## 4. Changed identity: the pin is never overwritten

A peer record holds three distinct fingerprints, and confusing them is how messaging apps
get identity changes wrong:

| Field | Meaning | Who writes it |
|---|---|---|
| `identityFingerprint` | the **pin** — the identity the user was shown and, if verified, compared | only authentication of a matching key, or a completed ceremony |
| `observedIdentityFingerprint` | a different key seen on the wire | authentication of a different key |
| `previousIdentityFingerprint` | historical evidence — the key a pin replaced, or the key a revoked record refers to | a ceremony, or revocation |

If a pin already exists and a **different** fingerprint arrives:

1. the observation is returned as `G2dPeerIdentityChanged` with both values, so the UI can
   show them side by side;
2. `identityFingerprint` is **not** changed. The observed value is stored separately as
   `observedIdentityFingerprint`, and `previousIdentityFingerprint` is left untouched, so a
   second sighting cannot destroy history;
3. the user's verification stops counting: the `userVerified` axis, `verifiedAtMillis` and
   `verificationMethod` are cleared, because they refer to the pinned key;
4. `identityChangedAtMillis` is set once and preserved on later sightings;
5. `statusLabel` becomes `Peer identity changed — re-verification required`, and both
   `isUserVerified` and `hasAuthenticatedIdentity` are false while the change is unresolved;
6. seeing the disputed key again does **not** promote it — it stays an observation;
7. only an explicit ceremony (`verifyIdentity`) promotes the observation into the pin, and
   only that ceremony clears the change marker. On promotion the displaced pin becomes
   `previousIdentityFingerprint`.

A re-authentication of a *different* key still records the session-level
`identityAuthenticated` axis for that observed key, because the session really is bound to
it. That grants nothing: `hasAuthenticatedIdentity` refuses while a change is unresolved, and
the axis exists only so the ceremony has a subject.

### 4.1 Record format and migration

The trust record is now a versioned-by-shape map with a strict decoder; there is no
migration from an earlier peer format because **no peer store has ever been written**. When
one is added, old records must be decoded through `fromMap`, which rejects rather than
repairs: a record whose observation contradicts its pin, whose verification facts have no
axis, or whose revoked tombstone still carries trust facts is refused outright. Nothing in
this milestone silently trusts a legacy peer record, and no durability claim is made.

## 5. Revocation and disconnection

| | `disconnect` | `revokePeer` |
|---|---|---|
| Clears transport axes (connected/service/session) | yes | yes (record emptied) |
| Clears the pinned fingerprint | no | yes — the most recent evidence moves to `previousIdentityFingerprint` |
| Clears an observed identity / change marker | no | yes |
| Keeps user verification | yes — a pin is not a link property | no |
| Terminal | no — the peer may reconnect | **yes** — every later transition throws |
| Repeat call | idempotent | idempotent — returns the existing record, original time and reason preserved |
| Reason recorded | — | `user_requested`, `identity_changed`, `replaced_by_identity_rotation` |

Revocation preserves the most recent identity evidence — including a key that was observed
but never promoted — in `previousIdentityFingerprint`. Calling `revokePeer` again returns the
record unchanged: a second revocation cannot rewrite the timestamp, the reason or the
evidence.

A revoked peer cannot be rediscovered, re-authenticated or re-verified by any code path; the
store throws. Re-enabling a revoked peer requires a new pairing decision and, in a later
milestone, an explicit un-revoke ceremony.

## 6. Unverified peers: policy is an owner decision

The state machine makes the distinction available; it does not decide what the app *does*
with an unverified peer. Options:

- **block until verified** (recommended default: no message is accepted from or sent to an
  unverified peer);
- **permit with persistent labelling** (every screen and every message must say
  "unverified");
- **permit silently** — not acceptable, because it makes the ceremony optional in practice.

Whatever is chosen, the UI must never render an unverified peer with the same component and
wording as a verified one.

## 7. What must never be displayed or claimed

- A single green "trusted" or "secure" badge derived from a connection.
- "Verified" for a peer whose fingerprint was never compared, or whose verification was
  inherited from a previous identity.
- A fingerprint shortened to a prefix, or a "match" verdict computed from a prefix.
- Any label implying encryption before a session layer exists.
- Any automatic trust-on-first-use path, in any form, including "remember this device".

## 8. Implementation and test map

| Behaviour | Test |
|---|---|
| axis order enforced; no skipping | `axes cannot be skipped ahead` |
| connection is never authentication | `a connected link is never described as authenticated` |
| session ≠ authenticated identity | `an established session is not an authenticated identity` |
| authentication requires a session | `requires an established session` |
| first identity recorded but not verified | `first identity is recorded but not verified` |
| repeat authentication does not re-trust | `the same identity does not re-verify or re-trust` |
| verification requires authentication | `cannot be granted before the identity is authenticated` |
| verification records method + time | `records the method and time...` |
| changed fingerprint fails closed | `fails closed and demands re-verification` |
| re-verification clears the change | `a fresh ceremony clears the change...` |
| disconnect keeps pin, clears session | `disconnect clears session facts but keeps the pin...` |
| revocation is terminal | `revocation is terminal`, `a revoked peer stays revoked...` |
| identifier and timestamp validation | `rejects empty and oversized peer identifiers`, `rejects non-positive timestamps` |

All of it is Dart-level: no protocol, no radio, no storage. It proves the *rules*, not that
any real peer was ever authenticated.

## 9. Deferred

- Persistence of peer records (same Keystore-backed store as the identity; see
  [G2-D-IDENTITY-KEY-MANAGEMENT.md](G2-D-IDENTITY-KEY-MANAGEMENT.md) §7).
- The fingerprint/SAS computations themselves (provider milestone).
- Any UI. No screen was added, on purpose: a trust screen without a handshake would be a
  misleading placeholder.
- Un-revocation and key-transition proofs (rotation of a *peer* identity accepted by the
  user rather than treated as an attack).
