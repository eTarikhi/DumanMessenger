# G2-D identity and key management

**Status: the protocol-agnostic identity foundation is implemented in Dart and covered by
tests. The Android Keystore storage adapter is designed but NOT implemented. No key material
is generated anywhere in this milestone.**

- **Date:** 2026-11-09
- **Code:** `mobile/app/lib/identity/` — `identity_models.dart`, `identity_store.dart`,
  `identity_service.dart`, `platform_key_capabilities.dart`
- **Tests:** `mobile/app/test/identity_models_test.dart`, `identity_store_test.dart`,
  `identity_service_test.dart`, `identity_platform_capabilities_test.dart`
- **Context:** [G2-D-ARCHITECTURE-DECISION.md](G2-D-ARCHITECTURE-DECISION.md),
  [G2-D-TRUST-AND-VERIFICATION.md](G2-D-TRUST-AND-VERIFICATION.md)

## 1. Implemented versus designed

| Area | State | Where |
|---|---|---|
| Identity record model, strict codec, invariants | **Implemented** | `identity_models.dart` |
| Lifecycle: create, rotate, revoke, reset | **Implemented** (over an injected store) | `identity_service.dart` |
| Storage contract, fail-closed default store, corruption semantics | **Implemented** | `identity_store.dart` |
| Platform capability rules (what may be claimed per API level) | **Implemented** | `platform_key_capabilities.dart` |
| Test double with fault injection | **Implemented (test-only)** | `G2dInMemoryIdentityStore` |
| Android Keystore adapter (real persistence, real wrapping) | **Designed, not implemented** | §7 |
| Key generation, fingerprint computation | **Deferred to the crypto provider** | §3 |
| Session establishment, encryption, replay protection | **Out of scope** | security plan |

The app ships with `G2dUnavailableIdentityStore`: every identity operation fails closed with
`G2dIdentityStoreUnavailable`. There is no plaintext persistence path, no preferences
fallback, and no "temporary" key store.

## 2. Identity versus key material

The division is deliberate and is what keeps this milestone compatible with any provider:

```text
  identity RECORD (Dart, this milestone)          key MATERIAL (provider, later)
  ------------------------------------------      ---------------------------------
  identityId (random, local, never shared)        private key bytes (never in Dart)
  keyVersion, algorithm, timestamps               public key (provider encodes)
  publicKeyFingerprint (provider-computed)        signature / DH operations
  keyHandle{provider, alias, protection, probe}
  state, revocation data
```

Consequences:

- The Dart layer cannot leak a private key because it never holds one.
- A record without a live provider key is detectably useless: the provider must be able to
  answer "does alias X exist and match fingerprint Y" before any session is opened.
- Rotating the key changes the record's `keyVersion`, `publicKeyFingerprint`,
  `previousKeyFingerprint` and `keyHandle`, and nothing else about the installation.

## 3. Record schema (format version 1)

| Field | Type | Rules |
|---|---|---|
| `recordVersion` | int | must equal 1; any other value is rejected, never migrated implicitly |
| `identityId` | string | 1–64 chars, random 16-byte hex by default, local only |
| `keyVersion` | int | ≥ 1; increases on rotation; ≥ 2 requires `rotatedAtMillis` |
| `algorithm` | enum | `curve25519_xeddsa`, `ed25519`, `x25519` |
| `publicKeyFingerprint` | string | 64 lowercase hex chars (SHA-256 of the provider's canonical public-key encoding) |
| `keyHandle` | object | `{provider, alias, protection, probeVerified}`; see §4 |
| `state` | enum | `active`, `rotation_pending`, `revoked` |
| `createdAtMillis` | int | > 0 |
| `rotatedAtMillis` | int? | required when `keyVersion ≥ 2`; must not precede creation |
| `previousKeyFingerprint` | string? | required while `rotation_pending`; must differ from the current fingerprint |
| `revokedAtMillis` | int? | required when revoked, forbidden otherwise |
| `revocationReason` | enum? | `user_requested`, `compromised`, `storage_compromised`, `rotated`; required when revoked |

Encoding rules: unknown fields are ignored on read, but unknown **enum values, versions or
inconsistent combinations are rejected** (`FormatException`) rather than repaired. A record
that fails these invariants is reported as corruption by the service, never patched.

Fingerprint presentation is `abcd ef01 …` in 16 groups; the comparison ceremony must use the
full value (see the trust document).

## 4. Key protection levels and the probe rule

| Level | Meaning | May appear on an active identity? |
|---|---|---|
| `hardware_bound` | private key never leaves secure hardware | yes, **only** when a device probe proved it |
| `software_keystore_wrapped` | software key, encrypted at rest by a non-exportable Keystore key; key bytes exist in app memory while in use | yes, when the wrapping key was actually created |
| `unknown` | no verified protection | **no** — creation and parsing both refuse it |

`G2dKeyHandle.probeVerified` must be `true` for any level other than `unknown`. Encoding a
handle that claims protection without a probe, or that claims `unknown` *and* a probe,
throws at parse time. This is the mechanism that stops an inference from becoming a stored
claim:

> Presence of Android Keystore, the Android version, or the algorithm name never justifies
> "hardware-backed". Only a probe result does.

### 4.1 What is actually true on Android (evidence, not aspiration)

| Fact | Consequence for Duman |
|---|---|
| The Android Keystore provider exists from API 18 and `KeyGenParameterSpec` from API 23, so an AES wrapping key is available at the API 27 floor | The **wrap** can be hardware-protected even on the oldest supported device |
| Ed25519 is not a Keystore key algorithm before Android 13 (API 33) | On API 27 an Ed25519 identity **cannot** be hardware-bound; it is a software key |
| X25519 is not a Keystore key algorithm across the supported range | An X25519 (or Curve25519/XEdDSA) identity is **always** software-held and wrapped |
| StrongBox is optional hardware; a 2016 mid-range handset is unlikely to have it | Never infer StrongBox from the OS version; probe and record |

So for the API 27 test device the honest statement is: *"software-protected, wrapped at rest
by a hardware-backed Keystore AES key; the private key exists in app memory while in use."*
That is materially better than plaintext and materially weaker than `hardware_bound`. The
identity code will not let anyone write the stronger claim.

`G2dAndroidKeyCapabilities.describeProtectionMismatch()` re-checks a loaded record against
the device's API level, so a restored, migrated or hand-edited record that claims
hardware binding for an algorithm the platform cannot hold is reported as a mismatch.

## 5. Lifecycle

```text
                createIdentity
   absent ───────────────────────▶ active ────────────────┐
      ▲                             │  ▲                  │ revoke
      │                    beginRotation│ completeRotation │
      │                             ▼  │                  ▼
      │                        rotation_pending ───────▶ revoked
      │                                                  │
      └──────────── resetRevokedIdentity ◀───────────────┘
                             (delete; a NEW identity may then be created)
```

| Transition | Allowed from | Refused with |
|---|---|---|
| `createIdentity` | no record | `identityExists` (active/pending), `revokedNeedsReset`, `unverifiedProtection`, `invalidFingerprint` |
| `beginRotation` | `active` | `noIdentity`, `notActive`, `fingerprintUnchanged`, `unverifiedProtection` |
| `completeRotation` | `rotation_pending` | `noIdentity`, `notRotationPending` |
| `revoke` | `active`, `rotation_pending` | `noIdentity`; revoking a revoked identity is idempotent success |
| `resetRevokedIdentity` | `revoked` | `noIdentity`, `notRevoked` |

Deliberate omissions:

- **No "abort rotation".** Once the provider may have replaced the old key, reverting would
  claim an identity the device might no longer hold. Complete the rotation or revoke.
- **No deletion of an active identity.** Otherwise a restart would look like a fresh install
  and silently discard a live identity.
- **No automatic identity creation** anywhere: creation is an explicit call with a
  provider-supplied fingerprint and a probed handle.

## 6. Failure behaviour

| Snapshot | Cause | App must |
|---|---|---|
| `G2dIdentityAbsent` | no record | offer identity creation |
| `G2dIdentityActive` | active record | allow use |
| `G2dIdentityRotationPending` | unfinished rotation | block session use; offer complete or revoke |
| `G2dIdentityRevoked` | revoked record | block use; offer reset only |
| `G2dIdentityStorageUnavailable` | no verified store / read failed | block everything; explain; **never** create a plaintext store |
| `G2dIdentityCorrupt` | unparsable or inconsistent record | block everything; require an explicit user-driven reset |

Every operation returns a typed `G2dIdentityActionResult`; expected failures are values, not
exceptions. Exceptions are reserved for programming errors.

### 6.1 Corruption and partial writes

- A record that fails parsing or an invariant is **corruption**, distinct from absence. The
  service never re-creates an identity on top of corruption.
- A failed write is reported as `storageWriteFailed` and the caller must not treat the new
  record as current. The test double models both a clean failure (previous record intact) and
  a destructive failure (previous record destroyed → subsequent read reports corruption),
  so both behaviours are exercised before a real adapter exists.
- The real adapter must be atomic (§7.3); the destructive case exists to prove the layer
  above it fails visibly rather than silently.

### 6.2 Restore and recovery

- There is **no private-key export** and no key recovery mechanism. A user who loses the
  device loses the identity, by design.
- Restoring app data onto a new device must not resurrect a revoked identity or a stale
  trust store; a generation counter in the adapter (§7.3) plus the record state is the
  mechanism, and it must be tested with a real adapter.
- A lost or invalidated Keystore key means the wrapped record cannot be decrypted → the
  adapter reports `G2dIdentityStoreUnavailable`/corruption → user-driven reset. No silent
  regeneration.

## 7. Android storage adapter (designed, not implemented)

Not implemented because it cannot be compiled, built or exercised in this environment, and
because writing a storage format before the provider is chosen risks re-doing it. The
following is the contract it must meet.

### 7.1 Wrapping

```text
KeyGenParameterSpec.Builder("g2d.identity.wrap.v1",
        PURPOSE_ENCRYPT | PURPOSE_DECRYPT)
    .setBlockModes(BLOCK_MODE_GCM)
    .setEncryptionPaddings(ENCRYPTION_PADDING_NONE)
    .setKeySize(256)
    .setRandomizedEncryptionRequired(true)   // Keystore generates the IV
    .build()
```

- The wrapping key is **non-exportable** and never leaves the Keystore.
- User-authentication binding is **not** required initially (identity use is not
  interactive); the trade-off is that a compromised unlocked device can use the key. This is
  an owner decision, recorded in §9.
- StrongBox (`setIsStrongBoxBacked`) is opt-in *only* after a probe confirms availability,
  with a documented fallback that is recorded as a lower protection level — never silently.

### 7.2 Stored payload

```text
ciphertext = AES-256-GCM(wrapKey, iv,
                 plaintext = record JSON bytes,
                 aad       = "g2d.identity.v1" || generation (8 bytes))
file       = magic "G2DID1" || generation (8) || iv (12) || ciphertext || tag
```

Associated data binds the format version and the generation, so a replayed older blob fails
authentication.

### 7.3 Atomic write protocol

1. Encrypt with `generation = current + 1`.
2. Write to slot `(generation % 2)`: file `identity.<gen%2>.bin.tmp`, `fsync`, rename to
   `identity.<gen%2>.bin`.
3. `fsync` the directory (where the platform allows it).
4. Keep the other slot as the previous good copy.

On load: read both slots, take the highest generation whose GCM tag verifies and whose
record parses. If neither verifies → `G2dIdentityStoreCorrupt`. If a record verifies but is
older than the highest generation seen on this installation → refuse (rollback attempt).

### 7.4 MethodChannel contract (proposed)

| Method | Request | Response |
|---|---|---|
| `load` | — | `{status: 'absent'\|'record'\|'corrupt'\|'unavailable', record?, reason?}` |
| `create` | `{algorithm, publicKeyFingerprint, keyHandle}` | `{status, record?, failure?, detail?}` |
| `beginRotation` / `completeRotation` | as the Dart service | same shape |
| `revoke` | `{reason}` | same shape |
| `reset` | — | same shape |
| `capabilities` | `{apiLevel}` | probe results: `{wrappingKey: bool, ed25519Keystore: bool, strongBox: bool}` |

Dart never sees private key bytes, IVs or ciphertext: only the record map and the probe
booleans. The channel must refuse to operate if the probe did not run.

## 8. Test coverage of the implemented foundation

| Behaviour | Test file |
|---|---|
| Fingerprint validation and display formatting | `identity_models_test.dart` |
| Handle round-trip; unprobed claim rejected; unknown protection rejected | `identity_models_test.dart` |
| Record round-trip; version rejection; malformed fields; every invariant | `identity_models_test.dart` |
| Store unavailable / corrupt / partial / failed write semantics | `identity_store_test.dart` |
| Creation, refusal paths, app-default fail-closed | `identity_service_test.dart` |
| Rotation transitions and refusals | `identity_service_test.dart` |
| Revocation, idempotence, reset-and-recreate | `identity_service_test.dart` |
| Storage failure surfacing (no phantom identity) | `identity_service_test.dart` |
| API-level protection rules and mismatch detection | `identity_platform_capabilities_test.dart` |

Tests are Dart-level. They do not exercise Android, the Keystore, JNI, or any provider.

## 9. Open decisions

1. Whether identity use requires user authentication (biometric/PIN) per operation.
2. StrongBox opt-in policy when available.
3. `PURPOSE_SIGN`-bound Ed25519 identity on API 33+ (hardware) versus one uniform
   software-wrapped path on all devices — uniformity is simpler, per-device capability is
   stronger.
4. Whether the Keystore adapter ships before or after the provider integration (before is
   cheaper; after risks designing the format twice).
