# Duman Messenger — Privacy Policy

**Status: draft, and not yet publishable.** Two things are missing that no engineering work can
supply: a **data controller** (there is no legal entity behind this repository yet) and a
**review by counsel**. GDPR Article 13 requires the identity and contact details of the
controller in the notice itself, so §2 below is a hole with the shape of the hole described,
not a placeholder email address invented to fill it. Until both exist, this document describes
the architecture; it is not a notice that can be linked from a store listing.

**What this document is.** Duman Messenger has no server, so it has no privacy practices in the
usual sense — there is nowhere for data to go and nobody to hand it to. That makes the policy
short, but it does not make it empty, because the radio is not a private channel: everything a
device says over the air is available to every other device in range, encrypted or not. The
interesting questions are therefore *what leaves the device*, *who can see it*, and *what cannot
be undone*, and those are the sections below.

**What every claim here rests on.** Each statement cites the engineering document that specifies
it, and the two simulators in this repository (`src/`, and the authoritative `sim/mesh_sim/`)
are runnable, so a reader can check a claim rather than accept it. Where a claim was measured
and the measurement came back empty, this document says so instead of implying protection that
was not demonstrated — see §4.3.

*Version 0.1 · 2026-10-26 · engineering draft, no counsel review*

---

## 1. The short version

| Question | Answer |
| --- | --- |
| Does the app collect personal data? | No. There is no server, no account, no upload path. |
| Does the developer see anything? | No. Nothing is transmitted to the developer by any route. |
| Are there analytics, crash reports, ads or trackers? | No. None exist in the design (§7). |
| Are messages encrypted end to end? | Yes, 1:1 and groups, with forward secrecy (`docs/04` §3, `docs/07`). |
| Can a relay node read them? | No. A relay sees headers only (`docs/04` §5). |
| Is your traffic unobservable? | **No.** Anyone in radio range can see that your device is present, that it relays, its battery level, its neighbour list as aliases, and who it forwards to (§4.2). |
| Is your SOS position private? | **No.** SOS is a broadcast on the public pager channel, by design (`docs/04` §6). |
| Can you delete a message everywhere? | No. Once a copy is carried in another device's queue, no server exists to recall it (§6.3). |
| Can you destroy your own data? | Yes — one tap, keys and history, in a fixed order (`docs/07` §7). |

---

## 2. Who is responsible (currently: nobody, which is the problem)

There is no operator, no company and no contact address behind this repository yet. The roadmap's
distribution and launch items are open (Phase 4–5), and until one of them creates a legal entity,
this policy has no controller to name.

Before publication, this section must state: the controller's identity and postal address, a
contact for privacy questions, the legal basis for any processing, and — if the app is
distributed in the EU — whether an Article 27 representative is required. What it must **not** do
is invent a mailbox. A privacy notice whose contact does not answer is worse than an unfinished
one, because it looks compliant and is not.

The honest position today: the only personal data this project touches is data a user's own device
holds about the user, and data a field-test operator holds about a volunteer's device (§9). No
third party processes either.

---

## 3. What stays on your device

Nothing leaves the device except over the radio (§4). Stored locally, and only locally:

* **Identity.** One Ed25519 signing key and one X25519 key agreement key, generated on the device,
  never exported, with no server copy and therefore no recovery path — lose the device and the
  identity is gone, which is the deliberate trade (`docs/04` §2). Contacts are added by scanning a
  QR code that carries the peer's public key.
* **Messages and history.** In local storage (SQLite with a CRDT for group history, so two devices
  can reconcile without a server).
* **The carry queue.** Up to **500 messages, expiring after 7 days**, held for peers that are not
  currently reachable (`docs/03` §8). This is store-and-forward: your device may be carrying
  somebody else's encrypted messages, and that is the mechanism that lets a message cross a gap in
  the mesh.
* **Session state.** Noise handshake state and ratchet keys, with a **7-day session TTL** after
  which a peer must re-handshake (`docs/07`).
* **Telemetry.** Battery drain per role, scans per second, relays per second and wake-lock time are
  computed on the device for the metrics dashboard (`docs/06` §10, §24). They are displayed, not
  uploaded.

---

## 4. What leaves your device, and who can see it

### 4.1 The intended recipient

Message payloads are encrypted end to end with Noise_XX, with a ratchet giving forward secrecy,
SAS verification so two people can confirm they are not being intercepted, and length padding to
256-byte blocks so a short message and a long one are not trivially distinguishable by size
(`docs/04` §3–§4, `docs/07` §4). Group channels use a shared key with the same treatment
(`docs/07` §5).

### 4.2 Every device in radio range

This is the part users must understand, because it is where the design's privacy ends. To route
without a server, each device advertises itself roughly every two seconds. Anyone within range can
observe:

* **that your device exists and is participating**, and its node identifier — an 8-byte hash of its
  public key, not the key itself, but a stable pseudonym that lets one observer follow one device
  across time;
* **its role** (NORMAL or SUPER), **its coverage score** and **its battery level**, all in the
  beacon;
* **its neighbour list**, advertised as aliases for routing — so an observer learns the local
  topology, and with patience, which devices are usually near each other;
* **who it forwards to** and when, per message header, since relaying is visible by construction.

No IP addresses and no server metadata exist to be collected or subpoenaed (`docs/04` §5) — that
is a real advantage over an internet messenger. It is not anonymity. A radio-range observer gets a
pseudonymous social graph and a presence timeline, and this policy will not pretend otherwise.

### 4.3 What this design does **not** protect against

* **Traffic analysis.** Jitter of 50–200 ms before forwarding is applied, and dummy cover beacons
  are implemented, but the cover half was measured and **produced no benefit**: a burst of twelve
  messages from one node was already invisible in a dense mesh, because relaying dominates every
  node's transmission count, and tightening the cover interval cost 66 % more airtime for no
  measurable gain. The shipped default is therefore cover **off**, and no claim of
  sender-anonymity under observation is made (`docs/06` §23).
* **Presence.** A device that is on and scanning is discoverable. There is no mode in which the
  mesh works and the device is invisible.
* **Recall.** See §6.3.

### 4.4 Location

Location is used in exactly one feature: **SOS**. Enabling SOS broadcasts a GPS fix with a text
message, repeatedly, over every available transport, so that whoever is in range can come
(`docs/06` §11). That is a broadcast on the public pager channel — it is not addressed to one
recipient, so it cannot be confidential in the way a 1:1 message is, and any device with the SOS
channel enabled receives the fix. Listening to the SOS channel is opt-in for exactly this reason
(`docs/04` §6). Repeated SOS messages collapse into one alert per peer with the freshest fix,
which limits notification spam but does not limit who sees the position.

No location is recorded, stored or transmitted anywhere else. Note the platform constraint rather
than a design choice: Android requires a location permission for Bluetooth scanning at all, which
is why §8 lists it.

---

## 5. Permissions, and what breaks without them

| Permission | Why | If refused |
| --- | --- | --- |
| Nearby devices / Bluetooth (Android 12+) | Discovery, beacons and text transport | The app cannot work; there is no other transport for small payloads. |
| Bluetooth (legacy, Android ≤11) | The same, on older releases | The same. |
| Location (Android) | Required by the OS for BLE scanning, and used by SOS | Scanning fails on most Android versions; SOS cannot include a fix. |
| Wi-Fi / Wi-Fi Direct | Payloads above ~1 KB move to Wi-Fi Direct, because BLE cannot carry them (`docs/08` §8) | Media and voice fall back to BLE and are much slower, or fail. |
| Notifications | SOS alerts and incoming messages | Messages still arrive; the user is not alerted. |
| Foreground service / background mode | Keeps scanning while the screen is off | The device participates only while the app is open, and the mesh loses it as a relay. |

Every one of these is a radio or an OS requirement. None exists to support analytics, advertising
or a server, because there is no server.

---

## 6. Retention, deletion, and the limit of both

### 6.1 Automatic expiry

Carried messages expire after **7 days** and the queue is capped at **500** (`docs/03` §8).
Session keys expire after **7 days** (`docs/07`). Neighbour scores expire after 30 s of no
evidence. Nothing is retained indefinitely.

### 6.2 Panic wipe

One tap destroys the identity keys, session state and message history, in a fixed order that was
chosen so a wipe interrupted halfway cannot leave a key behind with the history that it decrypts
(`docs/07` §7, question 4). This is the user's deletion right, exercised locally, and it is
irreversible — there is no server copy to restore from.

### 6.3 What cannot be deleted

A message that has already been relayed may exist in three other places: the recipient's device,
the carry queue of any device that picked it up for an unreachable peer, and the local history of
group members. With no server there is no deletion endpoint, no tombstone and no way to reach
those copies. Encrypted copies expire on their own schedule (§6.1), and the keys needed to read
them can be destroyed by the *recipient's* ratchet state or by the sender's wipe — but a user
cannot recall a message from a stranger's queue, and this policy does not claim they can. Blocking
a peer is local: it filters what the blocker sees and, optionally, what the blocker forwards; it
does not remove that peer's messages from anyone else (`docs/04` §6, `docs/06` §22).

---

## 7. Third parties

None. There is no analytics SDK, no crash-reporting service, no advertising identifier, no
third-party server and no subprocessor, because there is no processing entity. Distribution
channels (Play, F-Droid, GitHub Releases, TestFlight) are a supply route, not a data recipient;
their own store policies govern whatever a store collects about an installation, and that is
outside this document's control and worth reading separately.

The roadmap contains one future item that could change this section: opt-in, local-first mesh
analytics (anonymous hop counts, to improve routing). If it is ever built, it must be opt-in,
must stay on the device or be shared only peer-to-peer, and must not turn this section into a
list of recipients. A change of that kind requires a version bump here.

---

## 8. Children

The app processes no personal data on any server, so there is no processing of children's data by
the project or by an operator. Two things are still worth saying to a parent, and they follow from
§4 rather than from any data practice: a device running Duman is discoverable by anyone in radio
range while it is on, and SOS broadcasts its position to whoever is listening. Those are properties
of a serverless mesh, not of this project's handling of data, and they are the reason the SOS
channel is opt-in.

---

## 9. Field tests

The first real-world test (`docs/09`) records radio and routing telemetry from participating
devices into a JSONL capture: per-transmission records with pseudonymous device ids, RSSI, hop
counts, role changes, a 30-second battery and peer-count series, and calibration readings that
include **measured distances and wall counts between two devices** (`docs/09` §4). A capture
therefore describes where each device was relative to the others over time, and the `meta` note
field can re-identify a device ("atrium phone is device-07").

That is data about volunteers, held by the operator of the walk, and it needs the things a
capture schema cannot supply: informed consent before the walk, a stated retention period and
deletion date for the captures, an agreement that the analysis is published only in aggregate, and
pseudonyms that are not reused across tests. None of that exists yet, because no field test has
been run (roadmap Phase 2 is open). It must exist before the first one, and this section is the
place that says so.

---

## 10. Cryptographic export note

The design's stated position is standard libraries and no custom crypto (`docs/04` §7). The
engineering reality, stated precisely because an export review will ask:

* The **primitives** are standard and widely deployed: X25519, Ed25519, AES-GCM, HKDF, SHA-256.
  No cipher, hash or key agreement scheme is invented here.
* The **protocol** is a documented standard — Noise_XX with a double ratchet — but the reference
  implementation in `src/crypto/` is hand-written over those primitives rather than taken from a
  vetted library, because the environment it was built in permitted no external dependency. That
  is a reason for the external audit in `docs/04`'s audit plan, and it is why this policy does not
  describe the cryptography as reviewed. It has not been.
* The shipped app must use its platform's vetted implementation (e.g. libsodium or an equivalent
  reviewed package). Whether that substitution is possible is currently unanswerable from the
  development environment: the Dart package registry is unreachable, so no dependency decision has
  been made or recorded.
* **Export classification is a legal question and is not answered here.** Publicly available source
  code of this kind is generally treated differently from a distributed binary product, but the
  classification depends on the shipped artefact, the jurisdiction and the distribution channel, and
  must be confirmed by counsel before any store submission. The only statement this document makes
  is the factual one: the source is public, in this repository, and the primitives are standard.

---

## 11. Takedown resilience

Store removal does not remove the software, and it should not remove this policy. The design
publishes the **APK directly, plus F-Droid and GitHub Releases, alongside any store listing**
(`docs/04` §7), and this document lives in the repository that those releases are built from, so
it travels with the artefact rather than depending on a store-hosted page.

Two consequences worth stating: a store takedown cannot be used to withdraw a privacy notice that
users still need, and equally, a notice updated only in a store listing will drift from the one in
the artefact. The repository copy is authoritative; anything published elsewhere is a mirror of it.

---

## 12. Changes to this policy

Because there is no server, there is no mechanism to notify users of a change — no email address,
no push channel, no account. Notification therefore has to happen where the software is obtained:
the version string above, the repository's release notes, and the copy bundled in the artefact.
Any change that adds a data recipient (§7) or weakens a claim in §1 is a breaking change and
requires a major version bump, not a footnote.

---

## 13. Verifying any of this

Every section above cites the document that specifies it. Those documents, the two simulators, and
the checks that keep them consistent are in this repository; `docs/10` §5 describes how to run the
whole verification locally in one command, and `docs/12` lists every command by task. If a claim
here cannot be traced to a specification, a measurement or a test, treat it as an error in this
document and report it against the repository — that is the only feedback channel this project
currently has, and §2 explains why.
