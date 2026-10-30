# Supplemental real-browser verification — simulator only

**NOT READY — BLOCKED.** This closes the previously unavailable browser-smoke evidence,
not the remaining ten 5000ms TypeScript failures or exact-tip green-CI requirement.

Tested the clean package sourced from **ef81a8e4891a538d05e803bdbd3f83d6ac14be51**,
archive SHA256 `fd026101cde00a06df3d1b531b65d30953f1e38d729b9db5c4f64e7af8b42ca6`.
HeadlessChrome/153.0.8010.0, Puppeteer25.16.0, npm Chromium package153.0.0;
1440x1000 viewport, actual DOM keyboard/mouse and canvas clicks. Not SSR or a mock DOM.
No root dependency/lockfile changes, browser binaries/libraries/artifacts committed,
external exposure, login, real data, microphone or camera access.

`tool/deploy/browser-smoke.cjs` passes:

- Explicit simulation/synthetic warning and nonempty real 2D canvas.
- Step changes clock; Run advances clock; Pause holds clock stable.
- Seed42→43 via actual keyboard input and Apply/rebuild.
- Canvas node selection using deterministic public-model positions, not React internals.
- Simulated group creation (5 members), key-epoch increment on rotation, invitation
  (6 members, another epoch increment). Does not prove real key distribution/encryption.
- Synthetic DM submission, delivery and actual clickable hop trace.
- File and streamed-voice **simulated transfer row creation**, not completed real file or
  audio transmission, codecs, OS transports or radio throughput.
- Reset removes inspector, transfer rows and hop trace.
- No page or console errors. Only three network requests: loopback HTML, JS and CSS;
  interception rejects any non-loopback/non-data request. No external site tested.

Browser runs on a sandboxed Linux host with Chromium's packaged launch flags. Do not
use this optional harness to browse untrusted sites or claim device/production security.
The canvas coordinate test depends on the current 640px physical-world UI and defaults;
intentional UI changes must update this diagnostic rather than weaken core tests.

## Reproduce (Node22+, Linux; repository root)

Use an immutable, clean-source package built as in PERFORMANCE.md. Compile the public
model with the same source, and install optional browser tooling only under ignored scratch:

```sh
npx tsc -p tool/tsconfig.golden.json
node -e 'require("fs").writeFileSync("tool/.build/package.json",JSON.stringify({type:"commonjs"}))'
mkdir -p tool/.build/browser-check
test -e tool/.build/browser-check/package.json || printf '{"private":true}\n' > tool/.build/browser-check/package.json
npm install --prefix tool/.build/browser-check --ignore-scripts --no-audit --no-fund --save-exact puppeteer-core@25.16.0 @sparticuz/chromium@153.0.0
```

If NSS/NSPR libraries are missing (as on this host), use the libraries bundled in the
pinned Chromium npm package; no repeated SDK downloads or system installation needed:

```sh
node -e 'const f=require("fs"),z=require("zlib");f.writeFileSync("tool/.build/browser-al2023.tar",z.brotliDecompressSync(f.readFileSync("tool/.build/browser-check/node_modules/@sparticuz/chromium/bin/al2023.tar.br")))'
mkdir -p tool/.build/browser-libs
tar -xf tool/.build/browser-al2023.tar -C tool/.build/browser-libs
```

In a separate terminal/process, serve the chosen verified package strictly on loopback:

```sh
HOST=127.0.0.1 PORT=4173 node tool/.build/staging-CHOSEN/serve.mjs tool/.build/staging-CHOSEN
```

Run and retain JSON output; stop that server afterwards:

```sh
LD_LIBRARY_PATH="$PWD/tool/.build/browser-libs/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" node tool/deploy/browser-smoke.cjs
```

This optional harness is outside Vitest discovery, is not the Node HTTP suite and does
not replace either mandatory runner or turn red CI green. Final follow-up commit/run and
its regenerated package checksum are recorded in PR3's handoff rather than asserting a
self-referential commit hash in this document. No public staging/TLS/access authorization
has been obtained; do not change the loopback boundary without that verification.
