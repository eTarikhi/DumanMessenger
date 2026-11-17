# Device persistence verification — conversations and messages

A reproducible procedure for checking, on a real Android device, that the two local
encrypted slots behave as their tests claim: conversations and messages survive the
process being killed, deletions are deletions, and a storage failure is reported
instead of being rendered as an empty screen.

This document describes **local storage only**. Nothing here sends a message, and a
pass says nothing about transport, delivery, sessions or end-to-end encryption —
none of which exist yet.

## 1. What a pass proves

| Claim | Where it is proved |
| --- | --- |
| Conversations survive process termination | V1 |
| Messages survive process termination, with their stored status and timestamp | V2 |
| The four slots are separate directories under separate Keystore aliases | V3 |
| Deleting a message is durable | V4 |
| Deleting a conversation removes its messages and only its messages | V5 |
| Stored bytes are not readable plaintext | V2 evidence step |
| A read failure is surfaced, not shown as an empty conversation | automated tests (§8) |

## 2. What a pass does not prove

* That anything is sent, delivered, read, or acknowledged. There is no transport and
  no recipient.
* That the message text is protected in transit. It is protected only at rest, by a
  Keystore-wrapped AES-256-GCM envelope, and only while the device is locked in the
  sense the Keystore defines.
* That the keys are hardware-backed. On the API 27 floor they are software keys,
  protected at rest by a non-exportable Keystore AES key and nothing stronger.
* That a peer exists. No contact, identity binding or session is involved.
* That corrupt data is handled by *this* run. Corruption handling is destructive to
  set up, so it is proved by automated tests, not by touching the device (§8).

## 3. Safety rules for this procedure

1. **No uninstall, no `pm clear`, no "clear storage", no Keystore wipe.** The app's
   saved data is the thing under test.
2. **Do not corrupt the slots on the owner's device.** The corruption cases are
   covered by tests; if they must be exercised physically, use a throwaway emulator
   (§9), never the handset.
3. Deleting conversations and messages **inside the app** is the intended operation
   of V4 and V5, not damage.
4. Keep the device unlocked and wired. A device that sleeps mid-run turns timing
   observations into noise.

## 4. Environment

* Branch `arena/94329f0d-dumanmessenger`, working tree clean.
* Handset: SM-G610F, Android 8.1 (API 27), USB debugging on.
* `adb` on `PATH`; app already installed. If it is not:

```powershell
cd mobile\app
flutter build apk --debug
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

Use a **debug** build: `run-as` needs a debuggable package, and §5 uses it.

## 5. Evidence to capture

Start each run with a cleared log and a cold process:

```powershell
adb logcat -c
adb shell am force-stop com.example.duman_messenger
adb shell am start -n com.example.duman_messenger/.MainActivity
```

Collect the log afterwards, filtered to what can indicate a storage failure:

```powershell
adb logcat -d | Select-String -Pattern "G2d|Exception|internal_error|auth_failed|key_missing|stale_record"
```

Expected: nothing matching `G2d`, `Exception`, `internal_error`, `auth_failed`,
`key_missing` or `stale_record`. A line naming any of the last four is a real
finding — record it verbatim rather than restarting until it disappears.

Slot layout, without decrypting anything:

```powershell
adb shell run-as com.example.duman_messenger find files -maxdepth 2 -type f
```

Expected, once a conversation and a message exist:

```text
files/identity/keyring.meta
files/identity/identity.0.bin        (or identity.1.bin, alternating)
files/identity_keys/...
files/conversations/keyring.meta
files/conversations/identity.0.bin
files/messages/keyring.meta
files/messages/identity.0.bin
```

The record file name is `identity.N.bin` in every slot — the directory, not the
file name, is what separates them. If `messages/` is missing after V2, the message
never reached its slot and the pass is void regardless of what the UI showed.

Plaintext check, in-process, on the device:

```powershell
adb shell "run-as com.example.duman_messenger grep -ac PERSIST-CHECK-1 files/messages/identity.*.bin"
```

Expected: `0` (no line contains the marker). A non-zero count means message bodies
reached the disk unencrypted and is a stop-ship finding. Do not delete anything
before capturing the output.

## 6. Procedures

Use the marker strings exactly as written; §5 greps for them.

### V1 — conversation persistence

1. Launch, tap **Continue** on the first screen if shown, to reach the conversation
   list.
2. Tap the **+** action, type `PERSIST-A`, confirm.
3. Expect the card `PERSIST-A` in the list.
4. `adb shell am force-stop com.example.duman_messenger`, relaunch, reach the list
   again.
5. Expect `PERSIST-A` still present, with the same creation time.

Pass: the title is identical after restart, not merely a card that exists.
Fail: the list is empty, or the title differs. A card with the wrong title is worse
than a missing one — record it.

### V2 — message persistence and stored status

1. Open `PERSIST-A`.
2. Confirm the empty state reads *No messages yet* — not a spinner, not a blank area.
3. Type `PERSIST-CHECK-1`, tap **Save locally**.
4. Expect the tile to show the text, and its subtitle to read
   `Saved on this device · <date> <time>`. No "sent", "delivered" or "read" label
   may appear anywhere on this screen.
5. Capture the exact date and time shown.
6. Force-stop, relaunch, reopen `PERSIST-A`.
7. Expect the same text and the **same** timestamp.
8. Run the plaintext check from §5; expect `0`.

Pass: text and timestamp identical across the restart, and no plaintext on disk.
Fail: the message is missing; the timestamp moved (a re-created record, not a read);
or the marker appears in the slot files.

### V3 — slots are separate

1. After V2, run the slot listing from §5.
2. `files/identity/`, `files/identity_keys/`, `files/conversations/` and
   `files/messages/` must all exist, and `messages/` must be non-empty.
3. Optional, read-only: `adb shell run-as com.example.duman_messenger ls -la files/messages`
   to see the two alternating slots and `keyring.meta`.

Pass: four directories, message slot populated, identity slots untouched by the
message write.

### V4 — message deletion is durable

1. In `PERSIST-A`, tap the delete icon on the message, confirm the
   **Delete message?** dialog.
2. Expect the empty state to return and a snackbar `Message deleted.`
3. Force-stop, relaunch, reopen `PERSIST-A`.
4. Expect the empty state again — the deletion did not come back with the old slot.

Pass: still empty after restart.
Fail: the message returns after a restart, which would mean the deletion was written
over by a stale generation.

### V5 — conversation deletion cascades, and only to its own messages

1. Create `PERSIST-B`; open it, save `PERSIST-CHECK-2`.
2. Return to the list. Both conversations are present.
3. On `PERSIST-B`, open the row menu, choose **Delete**, confirm
   **Delete conversation?**, expect the snackbar `Conversation deleted.`
4. Expect `PERSIST-B` gone and `PERSIST-A` still listed.
5. Open `PERSIST-A`: its message is intact.
6. Force-stop, relaunch.
7. Expect `PERSIST-B` still gone, `PERSIST-A` and its message still present.

Pass: exactly one conversation and exactly its messages disappeared, and the result
survives a restart.

A snackbar reading *Conversation deleted, but its messages remain: …* is also a
correct outcome of a failed purge — it means the conversation record was removed but
the message slot refused the write. Record it as a finding rather than retrying;
it says the store failed, which is exactly what the label admits.

## 7. Reading a failure

A storage failure must never appear as an empty list. What the app does today:

| Platform code | Dart type | What the user sees |
| --- | --- | --- |
| `auth_failed`, `key_missing`, `key_invalidated`, `key_id_mismatch`, `ciphertext_malformed`, `stale_record` | `G2dIdentityStoreCorrupt` | `This conversation could not be read: …` and no composer |
| `keystore_unavailable`, `key_generation_failed`, `io_unavailable` | `G2dIdentityStoreUnavailable` | same message; the record is **not** treated as corrupt |
| `write_failed` | `G2dIdentityStoreWriteFailed` | the save is refused; nothing is reported as saved |
| anything else | `G2dIdentityStoreUnavailable` with the code in the text | same; unknown failures never claim corruption |

That last row is deliberate: only a named corruption state may justify offering to
discard a record, so an unrecognised failure is reported as unavailable.

## 8. Corruption: proved by tests, not by the device

The refusal paths are covered by automated tests and should be left alone on the
handset:

* `test/conversation_store_android_test.dart` — damaged conversation document is
  refused and never overwritten.
* `test/message_foundation_test.dart` — damaged message document is refused, the
  write count stays at zero, and the stored bytes are unchanged; a storage failure
  opening a conversation renders the failure state, not the empty state, with no
  composer.
* `test/identity_android_store_test.dart` — the envelope's behaviour against a
  platform double: authentication failure, missing key, stale generation. The
  envelope's real instrumented tests live under
  `android/app/src/androidTest/kotlin/com/example/duman_messenger/identity` and are
  optional for this procedure.

To re-run the Dart half:

```powershell
cd mobile\app
flutter test test\conversation_store_android_test.dart test\message_foundation_test.dart
```

## 9. If corruption must be exercised physically

Only on a disposable emulator that holds no real data, and only with the app's own
debug build:

```powershell
adb -e shell "run-as com.example.duman_messenger sh -c 'printf X > files/messages/identity.0.bin'"
```

Then launch and open the conversation: expect the failure state from §7, **not** an
empty message list, and expect the file to still be unreadable rather than replaced.
Restore by removing the emulator's data (`adb -e shell pm clear
com.example.duman_messenger`) — on the emulator only. Never run either command
against the handset.

## 10. Recording the result

| Step | Date/time | Device | Result | Evidence |
| --- | --- | --- | --- | --- |
| V1 | | SM-G610F | | log tail, screenshot |
| V2 | | SM-G610F | | log tail, `grep -ac` output, screenshot |
| V3 | | SM-G610F | | `find files` listing |
| V4 | | SM-G610F | | screenshot after restart |
| V5 | | SM-G610F | | screenshot after restart |

A run is only complete when the restart steps were actually performed. A screenshot
before the force-stop proves nothing about persistence.
