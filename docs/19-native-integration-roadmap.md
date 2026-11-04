# Native integration roadmap — outside simulator CI stabilization

This is a prioritized implementation/acceptance roadmap, NOT a claim that a native app,
production-secure messenger, durable key store or real radio mesh exists. No native rewrite
is authorized by this task. Simulator staging and native delivery are separate milestones.
Dart remains authoritative for the existing simulated engine; Node crypto is reference only.

## P0 — agree interfaces and security invariants before integration

Owner decision: supported OS/version/device range, Flutter application ownership and first
platform, identity/trust UX, backup/recovery policy, data retention and acceptable battery/
radio overhead. Do not invent approved budgets, provider accounts or platform signing.
Record architecture decisions with threat model and explicit acceptance gates.

Define boundaries for a transport adapter (discovery, capabilities, send, inbound frames,
link/disconnect/error, cancellation), identity/key provider, transactional encrypted store,
clock/scheduler and lifecycle owner. Discovery must never imply authenticated identity.
Bind Ed25519 identity and X25519 exchange keys to the authenticated transcript/QR/SAS;
resolve the existing reference's two possible node-ID interpretations. Specify which
routing fields relays may change: immutable ciphertext authentication cannot simply be
reused for a mutable hop/TTL header. Validate outer routing data separately and bound it.
Freeze wire vectors and version/size limits before interoperating implementations ship.

Acceptance: threat-model review; malformed/tamper/replay/downgrade/unknown-key tests;
reference vectors shared with the maintained native cryptographic implementation;
no custom cryptographic primitives and no Node-crypto import into a handset/browser.

## P1 — durable key and message lifecycle

Choose a maintained, supported native crypto/FFI implementation and OS-keystore integration
only after compatibility/security review. Scope identity storage, key rotation/deletion,
user authentication and failure behavior; do not treat JS best-effort wiping as forensic
erasure. Keep unverified/TOFU versus verified peer state visible in UX.

Implement one serialized per-peer state machine and atomic storage of message acceptance,
replay state, receive-chain advancement, bounded skipped keys and message persistence.
Sending counters must never be reused after crash, cancellation, disk-full or rollback.
Define encrypted journal/schema/migration/integrity handling, bounded expiry/queues and
recovery from corruption. Store keys separately from encrypted database content.
Restoring a backup must NOT silently restore old send counters; require fresh session
incarnation/handshake if monotonicity cannot be proved. OS keystore alone is not proof
that database rollback cannot happen. Panic/clear behavior must cover pending tasks,
key handles, caches and retained logs, with honest residual limitations.

Acceptance: fault injection at each transaction boundary, force-stop/reboot, low storage,
corrupted/truncated records, migration/rollback, backup restoration, duplicate/concurrent
frames, forged then genuine packets, replay and cache exhaustion. No authenticated failure
may consume a legitimate receive key. No secret or plaintext body in diagnostic logs.

## P2 — actual Android/iOS radio adapters and lifecycle

Implement real BLE discovery/GATT and negotiated media transport (e.g. platform-supported
Wi-Fi mechanisms) behind the adapter, not a renamed simulated transport. Validate support
on chosen devices/OS versions before selecting APIs. Define MTU fragmentation/reassembly,
framing, integrity and size/time bounds, connection ownership, disconnect cancellation,
retry/backoff/jitter and offline fallback. Treat discovery beacons as untrusted input.
Ensure retries do not duplicate ratchet advancement or reuse ciphertext nonces.

Test version-specific permission denial/revocation, background restrictions, process death,
foreground-service/user-notification requirements where applicable, screen-off behavior,
network changes and user opt-out. OS scheduling may prevent the simulator's timing model
from being realizable; report measured behavior instead of claiming always-on reachability.
Bound reconnection, malformed-frame buffering and radio work to resist battery/memory DoS.
Keep platform-specific behavior out of core routing decisions and deterministic tests.

Acceptance: physical devices, real peer discovery/data transfer, mixed vendors/OS versions,
MTU and fragmentation boundaries, radio loss/partition/mobility, reconnect and simultaneous
open, adversarial frames, cancellation/cleanup and actual battery/thermal measurement.
No measured-phone claim may be inferred from modeled simulator energy.

## P3 — handset UI and end-to-end workflow

Create the actual application shell after P0 decisions. Connect lifecycle-safe state flows
for identity/trust verification, permission onboarding, contact discovery, delivery status,
offline queues and recovery. Clearly distinguish simulated examples from real messages.
Group membership/epoch distribution, history synchronization, file transfer and voice
need production key distribution/access-control designs; current flags are simulations.

Acceptance: accessibility and human trust/SAS flow; send/receive/retry/expiry across process
restart, clear/reset behavior, permission denial, blocked peers, group leave/rekey and
malformed media. Verify no stale subscription, unbounded task or key material leaks.

## P4 — device matrix, supply chain and staged native rollout

CI must cover native analysis/tests, shared protocol vectors, signing-free debug builds
and reviewed dependency/SBOM/license checks. Secure signing belongs to an owner-controlled
pipeline, never chat or committed credentials. Add platform-specific reproducible build
provenance, install/upgrade/rollback and crash diagnostics with synthetic data only.

Run independent device/interoperability/security review with declared topology/traffic,
per-context delivery uncertainty and approved overhead/energy constraints. Real-world
radio success and generalized >90% delivery are unproven; research models predict risk,
not causal routing benefits. Do not promote a learned/experimental strategy by default.
Only after these gates and explicit owner authorization consider limited external rollout;
public release/store publication is not part of simulator staging completion.
