# Practical security review — not a formal audit

Scope: current simulator/CLI, Node reference crypto, staged static package and dependencies.
No claim of secure native messenger delivery, formal cryptographic audit, tamper-proof
wipe or production service penetration testing. No real credentials/messages used.

## Confirmed defects fixed

1. **Receive-state poisoning (high impact for future integration).** Ratchet.open and
DumanSession.receive previously called destructive keyFor before authenticating. A forged
packet could advance the chain/remove an existing skipped key, rejecting a subsequent
legitimate frame. Now use a bounded temporary receiving state, authenticate AND validate
packet, commit only on success, zero temporary keys on failure/provider exception. Replay
checks remain. Regression tests cover current key, skipped key and session-level forgery.
Wire protocol/crypto primitives unchanged. Low-level keyFor remains destructive/trusted
API for test tooling; production receive must never call it on unauthenticated input.
2. **Skipped-key accumulation.** MAX_SKIP limited each jump, not the entire skipped cache;
repeated legitimate gaps could grow retained keys without bound. Now evict/zero oldest
keys above64. Within64-key reorder window still works; older replay rejected. Tests
exercise repeated gaps, total cache bound and retained recent key.
3. **Predictable post-wipe encryption.** A wiped raw ratchet used a zero seed and could
still seal. Wipe is now terminal: sends throw, receives/key derivation return wiped.
Existing test strengthened to require rejection, not weakened/deleted. Session wipe
was already terminal. JS zeroization still best-effort, not a secure-enclave guarantee.
4. **Noncanonical headers.** NaN/fractional TTL/hop and short/long destination/digest fields
were silently masked/truncated. Exact lengths/integer bytes/known type now required.
Existing valid wire bytes/size fixtures unchanged. Malformed decoded packets still fail.

## Dependencies and supply chain

Starting npm audit:6 advisories (2critical,1high,3moderate), developer servers/tool workers:
Vite/esbuild, Vitest/mocker/tinypool/vite-node. Updated minimum compatible patched Vite6.4.5,
React plugin4.7.0 and Vitest4.1.12, pinned exactly with lockfile. Runtime React unchanged.
Vitest major upgrade justified by unauthenticated code/file access and worker advisories;
no architecture/framework change. npm10 resolver crashed (edgesOut) on optional peer set;
used npm11.6.2 CLI to resolve lock, then **npm10 npm ci and npm ls --all both succeeded**.
No legacy-peer-deps/force/audit suppression. npm audit after update:0 findings across
full tree (point-in-time advisory feed, not proof of vulnerability absence). CI enforces
npm audit --audit-level=low. Read-only repository workflow permissions added; no secrets.
Actions pinned to existing major tags, not immutable action SHAs: residual supply-chain
risk disclosed; package/archive SHA256 detects accidental corruption, not publisher trust.

## Deployment defenses and remaining limits

- Package allowlist only index + compiled assets, no .env, source maps, source or research
logs; rejects symlinks/unlisted files/path traversal/duplicate manifest entries, checks
sizes/hashes before serving. Running server snapshots verified bytes, avoiding file-change
TOCTOU; only GET/HEAD,404 unknown paths, no directory/SPA fallback, no API.
- CSP self-only scripts/connect, no objects/forms/base overrides; inline styles required
by React surface. nosniff/no-referrer, permissions disable real radio/media/location;
no external analytics. Default same-origin framing; explicit private-preview embed opt-in
removes that one constraint, never intended for public service. Loopback default.
- No TLS/auth implemented by the staging process. Remote operator must terminate TLS and
restrict access at their existing proxy; never expose Vite/Vitest developer servers.
No online backend/account auth endpoints exist to audit. No live user data should enter.
- UI shows simulation/plaintext/no persistence warning; React escapes text, no
unsafe HTML/eval/external fetch found in src inspection. Existing import graph test keeps
node:crypto out of browser. Simulator encryption flags model sizes, NOT encrypted UI.
- Node reference uses OpenSSL primitives, SAS/TOFU/ratchet tests; no native secure key
lifecycle/Dart crypto/persistent recovery. Signing/exchange identity binding and mutable
routing headers vs authenticated header integration must be resolved before phone use.
Groups simulate membership/epochs, not actual sender-key distribution/MLS.
- Persistence absent by design in this simulator: refresh/reset loses state. No production
message backups, migrations, durable ratchet counters or encrypted store. Exported
synthetic captures can include bodies/IDs, so no PII/secrets; browser downloads are not a
safe backup. Logging/memory/GC can retain copies; panic wipe is not forensic erasure.
- Bluetooth beacon pseudonyms/digests leak presence; no anonymity/jamming resistance claim.
Bounds/caps and radio failure tests do not replace real-device hostile-network tests.

Required before messenger rollout: maintained native crypto implementation, identity trust
review, durable encrypted storage with rollback-safe counters, native adapters, permission/
lifecycle behavior, device/interoperability/security review and approved privacy policy.
