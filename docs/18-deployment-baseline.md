# Deployable baseline boundary, packaging and operations

## 1. Supported components and architecture

```
Browser → compiled React simulator → TypeScript reference engine (RAM only)
Dart CLI → authoritative pure-Dart simulator → JSON/text synthetic reports
Node probes/tests → reference crypto (OpenSSL) → no browser import or real transport
Future Flutter app → native radio + secure storage/keystore + Dart crypto (NOT BUILT)
```

No backend/database/API/TLS endpoint, cloud training or online routing is needed by the
current components. Do NOT deploy an ordinary website and call it the phone messenger.
Research performance is independently deferred; missing app/radio/storage/security is
what blocks the phone baseline. No framework replacement/unbuildable scaffold introduced.

## 2. Reproducible setup and verification

Node22/npm10, Python3.9+; `npm ci` uses committed lockfile. Tested exact tools in dated
verification. CI pins Dart3.13.7; committed lock requires>=3.13 (pubspec lower range alone
is not enough). Flutter is only for future app work; no pubspec/application exists today.

```sh
npm ci
npm run typecheck
npm run test:deployment
npm audit --audit-level=low
npm test
npm run golden
git diff --exit-code -- test-fixtures/golden-vectors.json
python3 tool/ci/check-docs.py
python3 tool/ci/check-parity.py
python3 tool/ci/check-dart-balance.py
python3 tool/ci/check-dart-sites.py
python3 -m unittest discover -s tool/routing -p test_diagnosis.py -v
python3 -m unittest discover -s tool/routing -p test_reliability.py -v
node tool/deploy/routing-smoke.mjs
npm run build
```

Crypto tests are real Node/OpenSSL, HTTP tests are real local sockets, UI component tests
are SSR (NOT interactive browser/device tests). Routing smoke reproduces seed3301 both
modes/full historical stats; not a new90% claim. Existing Dart acceptance matrix runs in
CI. To reproduce authoritative engine where SDK/package access exists:

```sh
cd sim/mesh_sim
dart --version
dart pub get --enforce-lockfile
dart analyze
dart test --reporter expanded
dart run bin/mesh_sim.dart --scenario campus_quad --seed 42
mkdir -p build
dart compile exe bin/mesh_sim.dart -o build/duman-mesh-sim
build/duman-mesh-sim --help
```

No Dart code changed for packaging/security. Baseline route/protocol goldens remain paired;
reference TS crypto and experimental routing are intentional one-engine gaps, NOT Dart
validated by source inspection. No local SDK, Flutter, native toolchains/devices here.
Don't repeat blocked downloads; use existing CI or a supported developer environment.

## 3. Package and verify

```sh
npm run build
npm run package:simulator -- artifacts/package-NEW
node artifacts/package-NEW/serve.mjs artifacts/package-NEW
```

Builder refuses existing destination, symlinks, secret/source-map/unexpected build files.
Manifest records sourceSHA/dirty flag, Node/package version, baseline profile, file hashes
and sizes. Never distribute a dirty-source package as a verified release. Build from
reviewed clean SHA. CI uploads an artifact per SHA with archive checksum and Linux-x64
Dart executable (platform-specific; Windows/macOS require own compile/toolchain). No
GitHub release, Pages, public hosting or store publication occurs. Artifacts expire14days;
retain reviewed ones in owner-controlled storage BEFORE expiry if approved.

Verify downloaded archive hash against CI/trusted channel before extraction. Internal
manifest is integrity, not a signature; an attacker replacing both manifest/files is not
detected without an independently trusted archive hash. Avoid extracting untrusted tars.
After extraction run server, which verifies the entire package before opening a socket.
License/instructions accompany artifact. Node staging runtime uses built-ins only.

## 4. Environment and private staging

`.env.example` contains NO credentials. It is documentation, not automatically loaded.
Defaults HOST127.0.0.1/PORT4173. Shell example for a private remote staging network:

```sh
HOST=0.0.0.0 PORT=4173 node artifacts/package-NEW/serve.mjs artifacts/package-NEW
```

Use your EXISTING approved TLS/access-control reverse proxy; host at origin root, restrict
operator network/authentication, proxy all asset paths unchanged. No new provider/accounts
chosen. Set security headers as implemented in server; keep CSP/no-store for simulation.
ALLOW_PREVIEW_EMBED=1 only for a private embedded development preview (removes framing
constraint); ALLOW_ANY_DEV_HOST=1 only for sandboxed Vite development, never public use.
No VITE_* secrets: those are compiled into browser bundles. Keep .env untracked.

## 5. Staging/post-deployment verification

- Confirm reviewed sourceSHA, clean manifest, Node version, externally verified archive
checksum, and verify startup fails on any tampered/unlisted file.
- GET /200, JS/CSS200 with correct MIME, HEAD returns no body; unknown assets404,
POST405, traversal400; CSP/nosniff/no-referrer/no-store present. Tests assert these.
- Browser manually confirm simulation warning, canvas, pause/step/reset, scenario/seed,
synthetic send/trace, group/file/voice simulation, no external network requests/errors.
These interactive checks require a browser; no claim based on HTTP/SSR alone.
- No real BLE, mic, camera or location permissions should be requested. Never test with
real conversations/keys. Reset/reload intentionally loses all simulation state.
- Observe process memory/CPU, HTTP errors, proxy availability; do not log query/body/PII.
No persistence backup required for synthetic RAM; preserve only reviewed package/config
and approved synthetic evidence. Mobile backup/recovery remains unimplemented.

## 6. Upgrade, rollback, shutdown and troubleshooting

Build NEW directory at reviewed SHA; verify separately; stop old process/repoint proxy to
new port only after smoke succeeds. Never overlay static files/manifest. SIGTERM/SIGINT
closes staging listener; existing package remains available. Rollback stops new version
and starts previous immutable package/proxy target. No database migration or secret
rotation is implied. Test accidental-corruption rollback in Node deployment tests.

- Output exists: choose a new path, don't recursively clean owner directories.
- Manifest mismatch: stop, obtain known-good artifact/trusted checksum, rebuild clean SHA.
- Missing asset404: proxy base/root mismatch or mixed-version upload; no SPA fallback.
- EADDRINUSE/invalid PORT: choose unused integer1–65535; no localhost backend URL needed.
- CSP embed block: private preview only can opt in; do not disable public CSP broadly.
- npm resolver edgesOut: use npm11.6.2 CLI to resolve ONLY when changing dependencies;
committed lock installs with npm10. No --force/legacy-peer-deps necessary.
- Audit fails later: investigate advisory/context, patch with regression/build checks;
do not disable audit or security constraints to turn CI green.
- Dart SDK/pub access missing: use successful current CI artifacts or SDK-enabled host;
local missing is BLOCKED, not a pass. Compiled Linux binary is not APK/IPA or portable
across OS/architecture; signing/native transports require actual mobile toolchains.

## 7. Release/rollout decision

**Simulator: NOT READY — BLOCKED** by strict TS test timeouts; private diagnostic staging
works but does not satisfy the full gate. **Phone messenger: NOT READY — BLOCKED**, independent of routing target. Milestone C requires owner approval for any
external/public rollout, infrastructure/signing/identity decisions and device validation.
See completion ledger/security review for precise owners and acceptance gates.
