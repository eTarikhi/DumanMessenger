# G2-D Android Keystore adapter and persistent identity storage

**Status: implemented in Kotlin and Dart, compiled nowhere yet. Not device-verified. The
capability probe and every storage guarantee below are claims about code that has been
written and statically reviewed, not measurements taken on the SM-G610F.**

- **Date:** 2026-11-09
- **Commits:** `a4db820` (Keystore adapter and probe), `203414f` (encrypted storage),
  `21d076a` (tests), and the documentation commit that follows them
- **Kotlin:** `mobile/app/android/app/src/main/kotlin/com/example/duman_messenger/identity/`
  — `G2dIdentityKeyring.kt`, `G2dIdentityCapabilityProbe.kt`, `G2dIdentityStorage.kt`,
  `G2dIdentityChannelHandler.kt`
- **Dart:** `mobile/app/lib/identity/identity_channel.dart`,
  `identity_probe_capabilities.dart`, `identity_android_store.dart`,
  `identity_android_runtime.dart`
- **Tests:** `mobile/app/test/identity_probe_capabilities_test.dart`,
  `identity_android_store_test.dart`, `identity_android_runtime_test.dart`,
  `mobile/app/android/app/src/androidTest/kotlin/.../G2dIdentityKeystoreInstrumentedTest.kt`
- **Context:** [G2-D-IDENTITY-KEY-MANAGEMENT.md](G2-D-IDENTITY-KEY-MANAGEMENT.md) §7 (the
  design this implements), [G2-D-ARCHITECTURE-DECISION.md](G2-D-ARCHITECTURE-DECISION.md)

## 0. What changed relative to "designed, not implemented"

| Area | Before | Now |
|---|---|---|
| Wrapping key | Design only | AES-256-GCM key created in the Android Keystore, non-exportable |
| Identity record at rest | Nowhere | Encrypted envelope in one of two alternating slots under `files/identity/` |
| Atomicity | Contract, tested only against a double | Temporary file, `fsync`, `rename`; previous slot stays readable |
| Capability facts | Documented API-level expectations | Measured on the device, reported field by field |
| Hardware claim | Caller-provided flag | `KeyInfo.isInsideSecureHardware` of a key this process created |
| Recovery from a lost key | Undefined | Typed `key_missing`, never a regenerated key, explicit reset only |
| Backup | Undefined | Identity directory excluded from backup and device transfer |

Still **not** present: identity key generation, any signature or exchange operation, a crypto
provider, peer trust persistence, a UI. No key material of any kind is generated in this
milestone — which is why no record here claims `hardware_bound`.

## 1. Layers and who owns what

```text
Dart   G2dIdentityService  .... lifecycle and invariants (unchanged; its 224 owner-verified cases still apply)
       G2dKeystoreIdentityStore . validates before send, validates after receive
       G2dIdentityChannel ...... arguments and error-code translation
       G2dAndroidIdentityRuntime composition root: probe -> rules -> store -> service
──────────────────────────── platform channel `duman/identity` ────────────────────────────
Kotlin G2dIdentityChannelHandler . capabilities | load | save | delete
       G2dIdentityStorage ....... slots, index, atomic commit, recovery
       G2dIdentityKeyring ...... Keystore keys, AES-GCM seal/open, KeyInfo measurement
       G2dCapabilityProbe ...... what the device actually did
```

The state machine stays in Dart. The channel exposes **storage, not lifecycle**: an earlier
design sketch (§7.4 of the key-management doc) proposed `create`/`rotate`/`revoke` methods on
the platform side, which would have duplicated the tested state machine in untested Kotlin and
given two sources of truth for "what state is this identity in". It was not implemented that
way. The channel is `capabilities`, `load`, `save`, `delete` and nothing else.

Only the record payload and non-secret probe facts cross the channel. No key bytes, no iv, no
ciphertext, and no method returns secret material to Dart.

## 2. The wrapping key

```kotlin
KeyGenParameterSpec.Builder("g2d.identity.wrap.v1", PURPOSE_ENCRYPT or PURPOSE_DECRYPT)
    .setBlockModes(BLOCK_MODE_GCM)
    .setEncryptionPaddings(ENCRYPTION_PADDING_NONE)
    .setKeySize(256)
    .setRandomizedEncryptionRequired(true)   // the Keystore chooses every iv
    .setUserAuthenticationRequired(false)
```

- `KeyGenParameterSpec` is API 23, so this is available on the API 27 floor.
- The key is not exportable, has no `getEncoded()`, and never leaves the Keystore.
- User-authentication binding is **not** used: identity use is not an interactive ceremony, and
  a biometric-gated key would make background rotation impossible. The cost is recorded in §9:
  a compromised *unlocked* device can use the key.
- Randomized encryption is required, so a caller cannot cause iv reuse.
- StrongBox is never used for the wrapping key implicitly. It is attempted only by the probe,
  only on API 28+, and only its *measurement* is reported.

## 3. The envelope

```text
"G2DID1" | version=1 (1) | generation (8) | keyIdLen=16 (1) | keyId (16)
         | ivLen=12 (1) | iv (12) | ctLen (4) | ciphertext || GCM tag (16)
```

Associated data is `"g2d.identity.record.v1" || generation || keyId`. Consequences, each of
which is a test:

- editing the generation, the key id or the version in place makes the tag fail;
- replaying an older blob over a newer slot either fails the tag (different generation bound)
  or is caught by the generation check in §5;
- a blob from another device fails because the key id and the Keystore key differ.

The payload inside is the record JSON, unchanged: `recordVersion 1`, fingerprint, key handle,
state, timestamps. No key material exists in it, because no key material is generated in this
milestone.

## 4. Write protocol and crash safety

1. `generation = max(index.generation, highest slot generation) + 1`.
2. Encrypt under the wrapping key with a fresh Keystore iv.
3. Write slot `generation % 2` to `identity.<slot>.bin.tmp`, `flush`, `fd.sync()`, close.
4. `rename` the temporary file onto `identity.<slot>.bin` — atomic within one directory.
5. Update the index (best effort; see §5).

The other slot still holds generation `n-1`. A crash before the rename leaves the previous
record untouched and a stray `.tmp` that is never read. A crash after the rename leaves the new
record complete. No half-written record is observable, and the payload is never written in
place.

Directory `fsync` is not performed: the Java API has no portable way to sync a directory, and
the failure it guards against (the rename itself lost on power failure) degrades to "the
previous generation is still current", which is consistent.

## 5. The index and rollback detection

`files/identity/keyring.meta` holds `{v, keyId, generation}` — plaintext, non-secret, not
authoritative. It exists for two reasons:

- **key identity**: the key id names which wrapping key produced the data, so a device whose
  Keystore was reset can say `key_id_mismatch` instead of guessing;
- **rollback**: an authenticating record older than the last committed generation is
  `stale_record` rather than an accepted rollback.

It is written after the record commits, so a crash between the two leaves `index < record`,
which is harmless. If the index is missing, the key id is taken from the envelope header (it is
authenticated) and rollback detection is skipped for that read. **A local attacker who can write
app-private files can delete the index and defeat rollback detection.** Without a trusted
monotonic counter outside the app sandbox there is no way around that, and this document does
not pretend otherwise.

## 6. Error codes and the recovery matrix

| Code | Meaning | Dart maps to | Destructive reset allowed? |
|---|---|---|---|
| `keystore_unavailable` | no usable Keystore provider | unavailable | no |
| `key_generation_failed` | Keystore refused to create a key | unavailable | no |
| `io_unavailable` | a file could not be read | unavailable | **no** — an IO error is not corruption |
| `key_unusable` | key exists but cannot be used | unavailable | no |
| `auth_failed` | GCM tag failed: tampered or wrong key | corrupt | yes, explicitly |
| `key_missing` | data exists, wrapping key does not | corrupt | yes, explicitly |
| `key_invalidated` | key no longer recoverable (OS invalidated it) | corrupt | yes, explicitly |
| `key_id_mismatch` | data belongs to a different wrapping key | corrupt | yes, explicitly |
| `ciphertext_malformed` | bytes are not a G2-D envelope | corrupt | yes, explicitly |
| `stale_record` | older than the last committed generation | corrupt | yes, explicitly |
| `write_failed` | a write did not commit | write failed | n/a |
| `internal_error`, or any unknown code | unrecognised | **unavailable** | **no** |

The last row is the important one. `corrupt` is the only state that permits
`resetCorruptIdentity`, so an unrecognised failure must never claim it: a transient adapter bug
would otherwise become a deleted identity. The mapping lives in one function,
`translatePlatformError`, and is tested code by code.

Recovery is always the same and is always explicit: `resetCorruptIdentity` deletes the slots,
the index and the Keystore key, returns a result that carries no record, and creates nothing.
The caller must then create a new identity deliberately — and a new identity means a new key
and re-verification of every peer.

## 7. The capability probe

`G2dCapabilityProbe` creates a transient key under `g2d.identity.probe.v1`, uses it, inspects it
and deletes it in a `finally` block. It reports, separately:

| Field | How it is obtained |
|---|---|
| `apiLevel` | `Build.VERSION.SDK_INT` |
| `keystoreProvider` | the provider that was used |
| `aesGcmSupported` | an AES `KeyGenerator` was actually obtained |
| `probeKeyGenerated` | a key was actually created |
| `roundTripVerified` | 32 bytes were encrypted and decrypted to the same bytes |
| `probeKeyHardwareBacked` | `KeyInfo.isInsideSecureHardware` for that key |
| `probeKeySizeBits` | `KeyInfo.keySize` |
| `strongBoxRequested` / `strongBoxKeyCreated` | API 28+ attempt, and whether a key resulted |
| `wrappingKeyPresent` / `wrappingKeyHardwareBacked` | the real wrapping key, when it exists |
| `notes`, `failure` | non-secret diagnostics |

What the probe deliberately does **not** do:

- it does not infer hardware backing from the API level, the device model, the presence of a
  Keystore, or the AES algorithm;
- it does not treat "the Keystore answered" as "protection verified" — that requires the round
  trip;
- it does not report StrongBox as available because the OS is new enough.

`G2dProbedKeyCapabilities` then combines these facts with the documented API rules:
`isHardwarePossible(algorithm)` is the documented rule **and** the measurement, so measurement
can only narrow a claim. A record that claims `hardware_bound` on a device that did not measure
hardware backing is a protection mismatch, exactly like a claim for an algorithm the API level
cannot hold.

### API 27 specifically

- AES-256-GCM in the Keystore works; the wrapping key and the record envelope are real there.
- Ed25519 is not a Keystore algorithm before API 33 and X25519 never is, so an identity key on
  this device is software-held and wrapped. The honest statement is: *"software key, encrypted
  at rest by a Keystore AES key; key bytes exist in app memory while in use"* — and whether
  that AES key sits inside the TEE is **measured, not assumed**.
- StrongBox is not attempted (it requires API 28); `strongBoxRequested` is `false` and that is
  reported as a fact about the platform version, not as a failure.

## 8. Backup, restore, migration, reinstall

- **Backup:** `files/identity/` is excluded from cloud backup and device transfer by
  `res/xml/g2d_backup_rules.xml` (`fullBackupContent`, Android 11 and older) and
  `res/xml/g2d_data_extraction_rules.xml` (`dataExtractionRules`, Android 12+). Keystore keys
  are never backed up, so a restored ciphertext would be permanently undecryptable — an
  identity that looks corrupt rather than one that is simply absent.
- **Restore onto another device:** no record, because it was excluded. The device has no
  identity and says so. Nothing is silently recreated.
- **Device migration:** the identity is not portable by design. A new device means a new
  identity and a new verification ceremony with every peer. Any future migration must move the
  *identity*, not the ciphertext, and must be an explicit ceremony — not a file copy.
- **Reinstall:** uninstall deletes app files and the app's Keystore keys together. The result is
  a clean absence, not corruption. A peer still pinned to the old fingerprint must be
  re-verified out of band; the retired-id tombstones from the previous milestone are still
  in-memory only, so a reinstall loses the "this id was retired" fact as well.
- **If exclusion is ignored** (an OEM backup agent that does not honour the rules): the restored
  ciphertext has no key, which is `key_missing`, which is corruption, which requires an explicit
  reset. Fail closed, never a silent new identity.

## 9. What can become unrecoverable, and what that means

Encrypted identity data becomes permanently unrecoverable when the wrapping key disappears or
changes: Keystore reset, factory reset, key invalidation by the OS, or a restore that brings
back the file without the key. Corruption of both slots has the same effect.

That is accepted, and it is why the failure is surfaced as corruption with one recovery path
rather than as an error a caller might retry until it "works". There is no escrow, no
key-sharing, and no server. The identity is worth exactly what the device holds.

## 10. Compatibility notes

- **API 27 (the floor).** `KeyGenParameterSpec` (23), AES-GCM Keystore keys (23),
  `KeyInfo.isInsideSecureHardware` (23), `GCMParameterSpec` (19) are all available. StrongBox is
  guarded by an API check and never referenced below 28. `dataExtractionRules` is ignored by
  older platforms, which use `fullBackupContent` instead.
- **32-bit ARM.** No native code, no JNI, no NDK component was added: the adapter is JVM
  bytecode calling the platform Keystore, so `armeabi-v7a` and `arm64-v8a` behave identically.
  AES-GCM runs in the provider, not in our process.
- **Modern Android.** API 28+ adds the StrongBox attempt; API 31+ uses the extraction rules.
  Nothing in the adapter depends on being below or above any level other than the two guarded
  calls above (`setIsStrongBoxBacked`, `dataExtractionRules`).
- **Key invalidation.** No key is authentication-bound, so ordinary lock-screen changes do not
  invalidate it. If the platform does invalidate a key, `KeyPermanentlyInvalidatedException`
  becomes `key_invalidated` — corruption, never a regenerated key.

## 11. Software-generated Ed25519/X25519: the security implication, stated plainly

On API 27 (and for X25519 on every supported level) the identity key cannot live in the
Keystore. When a crypto provider is integrated, its private key will be software material that
is wrapped at rest by the AES key and exists in process memory while in use. Therefore:

- at rest the record is protected by an authenticated envelope whose key is non-exportable;
- in use, an attacker with code execution in this process, or with root while the app is
  running, can obtain the key;
- the difference between `software_keystore_wrapped` and `hardware_bound` is not cosmetic, and
  the app must never present the first as the second. `describeKeyProtection()` and
  `describeWrappingProtection()` are worded for that reason.

None of this is claimed as end-to-end encryption, forward secrecy, or device attestation. No
session exists.

## 12. Test map

| Behaviour | Where | Executed here? |
|---|---|---|
| Evidence decoding; missing/mistyped fields rejected | `identity_probe_capabilities_test.dart` (25) | no |
| Hardware claim needs a measurement; API 27 denies Ed25519 hardware | same | no |
| Store load/save/delete, payload shape, invalid record refused | `identity_android_store_test.dart` (34) | no |
| Every platform error code mapped; unknown code → unavailable | same | no |
| Persistence across service reconstruction; pending rotation across restart | same | no |
| Corruption reported, never repaired; reset then deliberate recreate | same | no |
| Runtime assembly, refusal when the wrap did not verify | `identity_android_runtime_test.dart` (11) | no |
| AES-GCM round trip on the real Keystore | `G2dIdentityKeystoreInstrumentedTest` (16) | no — needs the device |
| Wrong-key and corrupted-ciphertext tag failure | same | no — needs the device |
| Missing key reported and not regenerated | same | no — needs the device |
| Interrupted write, stale generation, plaintext absence, reconstructed storage | same | no — needs the device |
| Probe reports real API level, real round trip, measured hardware backing | same | no — needs the device |

The Dart tests replace the platform with a double. They prove the adapter's behaviour; they are
**not** evidence about Android, and this document does not treat them as such.

## 13. Not claimed

- Not device-verified: nothing in §2–§7 has been executed on the SM-G610F.
- Not hardware-backed: the wrapping key's backing is whatever the probe measures; no claim is
  made in advance of that measurement.
- Not end-to-end encryption, not a session, not attestation, not "production security".
- Not a migration path: identity data does not move between devices.
- Not a defence against root while the app is running and unlocked.
