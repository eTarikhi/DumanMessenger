# 12. CLI cheat sheet

Every command this repository uses, by task. Each entry gives the `make` target (or PowerShell
front end), what it actually runs, and when you would reach for it.

Conventions:
- `make X` on Linux/macOS/WSL/Git Bash · `.\make.ps1 X` on Windows PowerShell — same target, and
  the same *verdict*, but not always the same exit code: `make` reports `2` for any failure because
  that is GNU make's own code, while `make.ps1` runs the underlying script directly and so passes
  `1` through. See the note in `docs/10` §5 and `docs/11-windows-11-workflow.md`.
- The **runs** column is the real command. `make` targets are thin front ends onto `tool/ci/`, which
  copies its commands from `.github/workflows/ci.yml`. Nothing here is a paraphrase.
- Exit codes across the pipeline: `0` verified · `1` failed or could not run · `2` partial · `64` bad
  usage. Those are the *scripts'* codes; through `make`, `1` and `2` both arrive as `2`.

---

## 1. Development & Setup

Environment initialization, dependency management, and starting local servers.

### First contact with the repository

| Command | Runs | Use it when |
| --- | --- | --- |
| `make doctor` | `tool/ci/doctor.sh` | **Before anything else.** Compares your toolchain against the versions CI pins, probes `registry.npmjs.org` / `pub.dev` / `api.github.com`, and checks the pre-push hook is active. |
| `make install` | `npm ci --no-audit --no-fund` then `cd sim/mesh_sim && dart pub get` | After cloning, and whenever a lockfile changes. |
| `make install-hooks` | `git config core.hooksPath .githooks` | Once per clone. Puts the pre-push gate under version control instead of in `.git/hooks`. |
| `make help` | prints every target | You forgot a target name. |

### Dependencies

| Command | Runs | Notes |
| --- | --- | --- |
| `npm ci --no-audit --no-fund` | installs from `package-lock.json` | Reproducible; this is what CI runs. Deletes `node_modules` first. |
| `npm install` | resolves and **rewrites** the lockfile | Only when adding a dependency. Commit the lockfile — CI uses `npm ci` and will fail without it. |
| `cd sim/mesh_sim && dart pub get` | resolves Dart deps | The only dependency is `package:test`. Needs `pub.dev` reachable. |
| `npm ls --depth=0` | top-level tree | Checking what is actually installed. |
| `dart pub deps --style=compact` | Dart dependency tree | From `sim/mesh_sim`. |

> **Never trust a bare `npx tsc` with no `node_modules`.** `npx` silently downloads a package named
> `tsc` (version 2.0.4, unrelated to TypeScript) and you get nonsense errors. Run `npm ci` first.

### Local servers

| Command | Runs | Notes |
| --- | --- | --- |
| `make dev` | `ALLOW_ANY_DEV_HOST=1 npm run dev -- --port 5173` | The React mesh visualiser. `ALLOW_ANY_DEV_HOST` lets a proxied or non-localhost Host header through. |
| `npm run dev -- --host 0.0.0.0` | vite on all interfaces | To open it from a phone on the same Wi‑Fi. Also needs a firewall rule — `docs/11` §6. |
| `npm run preview` | `vite preview` | Serves the **built** output, not the dev server. Use it to check what you actually shipped. |

### Git and branch setup

| Command | Notes |
| --- | --- |
| `git config core.hooksPath .githooks` | What `make install-hooks` does. |
| `git config --system core.longpaths true` | **Windows only.** `node_modules` exceeds 260 chars; without this `npm ci` fails with `ENOENT`. |
| `git add --renormalize .` | Re-apply `.gitattributes` line endings to an existing clone. |
| `git switch -c fix/your-change` | New branch before starting work. |

---

## 2. Build Processes

Compiling, asset building, and the specialized scripts that generate this repository's evidence.

### TypeScript / React

| Command | Runs | Notes |
| --- | --- | --- |
| `make typecheck` | `npx tsc --noEmit -p tsconfig.json` | Type-check without emitting. Fast; run it constantly. |
| `make build` | `npm run build` → `tsc -b && vite build` | Production bundle into `dist/`. |
| `make golden` | `npm run golden` | Regenerates `test-fixtures/golden-vectors.json`, the cross-language contract. **Commit the result** when either engine's RNG, spawn order or scheduling changes. |
| `git diff --quiet -- test-fixtures/golden-vectors.json` | no output = unchanged | The check CI applies after regenerating. Nonzero exit means the vectors moved. |

The `golden`, `media`, `history` and `field:*` npm scripts all compile `tool/*.ts` through
`tool/tsconfig.golden.json` into `tool/.build/` first, then run the emitted JS. `tool/.build/` is
git-ignored.

### Dart

| Command | Runs | Notes |
| --- | --- | --- |
| `make dart-analyze` | `cd sim/mesh_sim && dart analyze` | **Errors and warnings fail; infos do not.** A `dead_code` warning will therefore break CI. |
| `dart format .` | reformats | Not a CI gate — formatting is left to contributors. |
| `dart compile exe bin/mesh_sim.dart` | native binary | Produces a standalone executable; useful for field testing without a SDK on the device. |
| `dart compile js` / `dart pub global activate` | other targets | Not used by this repository's CI. |

### Specialized evidence scripts

These generate the numbers in `docs/06`–`docs/09`. Each takes a section name so re-measuring one
lever does not mean re-measuring eleven others.

| Command | Runs | Produces |
| --- | --- | --- |
| `make media` | `npm run media` | All eighteen sections: `docs/08` §7–§12 (file transfer, PTT, the retry timer, contention, backpressure, shedding, the capture effect) plus the five radio-and-power sections that answer `docs/06` §24 — `occupancy`, `beacon`, `reach`, `intervalMode`, `scanInterval`. **Measured at 13 min 52 s** end to end before the eighteenth was added, exit 0, which is why `make checks-evidence` is the slow tier and why every section can be run alone with `SECT=`. |
| `make media SECT=occupancy` | `npm run media occupancy` | `docs/06` §24.6 — what a radio is *busy* for against how long a packet takes to arrive. Ten arms: two scenarios × the three channel-access models (free, halfDuplex, csma) × the flat hop-latency charge and size-proportional airtime, three seeds. Reports the derived beacon sizes, the demanded-radio-time ratio and where `docs/08` §12's contention magnitudes move. ~7 min. |
| `make media SECT=beacon` | `npm run media beacon` | `docs/06` §24.7 — the control plane's two levers. Sweeps the OGM beacon interval over 2/5/12/25 s in both scenarios and compares the 32-byte public-key beacon against the 2-byte alias `docs/03` §4 prescribes. **Eight seeds, and it prints the per-seed spread beside every mean**, because `festival_crowd` is bimodal and three seeds published an ordering that eight reverse (§24.8). Includes route-expiry churn, which refutes the flap hypothesis. ~2 min. |
| `make media SECT=reach` | `npm run media reach` | `docs/06` §24.9–§24.10 — why the 60-node crowd has two modes, and the answer. Three hypotheses, eight seeds: partitioning from the graph at the *end* of the window (explains two rows of sixteen), MPR over-suppression tested against the "flood-all" relay policy (refuted — zero suppression and six times the overhead does not restore reach), and partitioning sampled **six times inside** the window, which confirms it: every seed connected for all six samples reaches 98 %, and seed 2024 at 12 s is connected 17 % of the time with a mean largest component of 72 % and reaches 55 % while still looking fully connected at the end. Also the first measurement of `skills/02`'s *"overhead ≤70 % of flood-all"* target in the densest scenario: MPR holds **13 %**. ~4 min. |
| `make media SECT=intervalMode` | `npm run media intervalMode` | `docs/06` §24.11–§24.12 — §24.7's follow-up, measured twice and shipped off. Derives each node's beacon interval from its peer count so the receptions it imposes stay constant, anchored so ten peers reproduces the specified 2 s. Four pairs × two modes, eight seeds — three scenarios plus `festival_crowd` with mobility off — and **each pair prints whether its topology is comparable** — because §24.10 showed reach tracks the largest in-window component, so two arms in different topologies are not a comparison of what changed between them. Where the topologies match it is readable and splits: `sparse_village` and `campus_quad` pay 3.11× and 1.20× the airtime for +1.6 and −0.7 points, while the **static** crowd — same graph in both arms, per seed — gives the derived interval 44 % less airtime and equal-or-better reach in seven of eight seeds, with delivery better on four and worse on three. The mobile crowd's arms land in different topologies, so that pair cannot be read at all. ~3 min. |
| `make media SECT=scanInterval` | `npm run media scanInterval` | `docs/06` §24.15 — `docs/05` §1.2's third mitigation row, built and measured. Three scenarios × duty cycle on/off × fixed/density, eight seeds, with a Δ row per pair. Two results: the rule does what §1.2 specifies (scans/s −70 % in `sparse_village`, +75 % in `festival_crowd`, −11 % on campus), and **the benefit it claims is not measurable here** — cutting scans by 70 % moves NORMAL drain from 1.331 to 1.331 %/h, identical to three decimals, because the engine's battery drain charges the duty-cycle window and not the scan events inside it. What it does buy is delivery, by *spending* wake-ups: +6.8 points in the crowd with the duty cycle on. ~2 min. |
| `make media SECT=captureEffect` | `npm run media captureEffect` | One section only. An unknown name exits `2` and lists the valid ones. |
| the thirteen sections | | `serialization`, `file`, `voice`, `retry`, `acceptance`, `contention`, `channel`, `priority`, `capture`, `backoff`, `shedding`, `captureEffect`, `captureMargin` |
| `make e2ee` | `npm run e2ee` | `docs/07` §2–§4 and §7 — what a Noise_XX handshake costs on this mesh: per-leg establishment latency, the leg lost at four hops in a crowd, how often a device meets a new peer, the padded packet sizing, and (since `src/crypto/` landed) the crypto itself. The first three sections implement **no cryptography**: they are crypto-shaped messages through the real engine, which is the part a protocol simulator can honestly answer. The fourth runs the reference protocol layer over OpenSSL. |
| `make e2ee SECT=churn` | `npm run e2ee churn` | One section: `latency` (§2.1, §2.2), `churn` (§3), `packet` (§4), `crypto` (§2.1 note 3, §4, §6, §7.2). An unknown name exits `2` and lists them. |
| `make e2ee SECT=crypto` | `npm run e2ee crypto` | Runs `src/crypto/` and reports measured numbers: handshake legs **32 / 96 / 64 B** against a 247 B GATT MTU (§7.2); a sealed packet at seven body sizes measured against the engine's own size model, including one whose code-unit count and byte count disagree (§4); **1 062 µs** of CPU for a whole handshake against §2.1's **675 ms** of radio, so 0.157 % (§2.1 note 3); and the capture test — a relay holding a legitimate message key from its own session with the sender reads the header and nothing else (§6). Fails if a sealed packet disagrees with the engine's model, if a leg exceeds the MTU, or if the CPU share passes 5 %. |
| `make rate` | `npm run rate` | `docs/06` §21–§22 — what `docs/04` §6's abuse controls cost and buy, on `campus_quad` over three seeds: the two rate caps and the local blocklist. `honest` asserts that a compliant network loses nothing (zero drops, delivery identical with the caps on and off); `flood` puts one node at 12× the broadcast cap and reports delivery, reach, overhead and transmissions in five arms — uncapped, capped by SUPERs only, capped by every node — cutting transmissions **19 %** then **62 %** while honest delivery stays 100 % in every arm — a null result reported as one rather than asserted away; `block` blocks a spammer at half the network and reports what each `--block-scope` costs and who pays. ~25 s. |
| `make rate SECT=block` | `npm run rate block` | One section: `honest`, `flood`, `block`. An unknown name exits `2` and lists them. |
| `make cover` | `npm run cover` | `docs/06` §23 — what `docs/04` §5's *"dummy beacons at low rate"* cost and buy, on `campus_quad` over three seeds. `inert` checks the knob is off and silent by default; `sweep` runs one node's 12-message burst against cover intervals of off / 60 s / 30 s / 10 s / 5 s and reports what a passive observer counting transmissions can learn. **The result is null and the row says so:** the observer names the burst's sender 0 times out of 3 with cover *off*, because relaying already dominates every node's count, and tightening the interval to 5 s moves the sender's z-score from 0.844 to 0.866 — no direction, no trend — while costing **66 %** more airtime. Ships off. ~15 s. |
| `make cover SECT=sweep` | `npm run cover sweep` | One section: `inert`, `sweep`. An unknown name exits `2` and lists them. |
| `make history` | `npm run history` | `docs/06` §17 — group-history anti-entropy against the same world with it off. |
| `npm run field:capture -- campus_quad 42 /tmp/cap.jsonl` | capture run | The field-test capture schema. Add `flood-all` as a 4th argument for the naive baseline. |
| `npm run field:report -- /tmp/cap.jsonl /tmp/base.jsonl` | compare two captures | Delivery, overhead and latency against the baseline. |

### The Dart CLI itself

| Command | Notes |
| --- | --- |
| `dart run bin/mesh_sim.dart --scenario campus_quad --seed 42` | **The gated acceptance run.** Asserts the criteria and exits nonzero if they fail. Scenarios: `campus_quad`, `sparse_village`, `festival_crowd`, `partitioned_pair`. |
| `... --policy mpr` | Routing policy: `mpr` (default), `route-flood` or `flood-all`. **`flood-all` is the naive baseline the overhead ratio is measured against.** |
| `... --nodes 20` | Override the scenario's node count. The acceptance criteria are specified at 20. |
| `... --messages 150` | How many messages to send. |
| `... --gap 250` | Simulated milliseconds between messages. |
| `... --help` | The CLI's own usage text, with the current defaults interpolated. |
| `... --no-check` | Report the numbers without asserting the gate. Every probe uses this. |
| `... --duty-cycle` | The `skills/07` power arm: NORMAL scans 3 s / sleeps 7 s, SUPER continuous. |
| `... --channel-access csma` | The medium when two radios talk at once: `free` (default), `half-duplex`, `csma` — carrier sense (`docs/08` §12.9–§12.10). |
| `... --channel-capture strongest` | A busy **receiver**: `none` (default, takes everything), `first` (pessimistic bound), `strongest` (the capture effect, `docs/08` §12.15). |
| `... --capture-ratio 12` | dB a newcomer must clear to take the receiver over. Default `6`. Read only under `strongest`. |
| `... --channel-queue 4` | Transmit queue depth, default `8`, so a busy radio buffers instead of dropping (`docs/08` §12.7). |
| `... --channel-priority ack-first` | Which queued packet a busy radio takes next: `fifo` (default), `ack-first`, `by-class` (`docs/08` §12.8). |
| `... --backoff binary` | Wait a random number of slots before taking a medium that just freed up: `none` (default), `binary` (`docs/08` §12.13). |
| `... --media-backpressure` | Off by default. Stop a transfer pumping chunks into a radio that is already full (`docs/08` §12.12). |
| `... --rate-limits` | Off by default. Enforce `docs/04` §6's abuse limits: 5 broadcasts/min per node, dropped by **SUPERs only** as the document specifies and by default (see `--broadcast-cap-scope`), and 30 relayed messages/min per source, enforced by every node. Control-plane traffic (`ogm`, `ack`, `sync`) is exempt — `docs/03` §1 beacons an OGM every 2 s, which is exactly 30/min, so counting beacons would leave a node's own routing protocol holding the entire budget and cut its sustained data rate from 300 messages per ten minutes to 29. SOS is exempt too: `docs/04` §6 gives it opt-in listening and §11's collapsing instead, and capping an emergency channel at 5/min would be a worse failure than the abuse it prevents. Reports `rateBroadcastDrops` and `rateRelayDrops`. |
| `... --broadcast-cap-scope super` | Only read with `--rate-limits`. Who enforces the broadcast cap: `super` (default) is what `docs/04` §6 says — SUPERs drop excess — and bounds how *far* a flood travels, not whether the flooder's own neighbours hear it; `all` makes every node enforce. An unknown name prints the valid set and exits `64`. `npm run rate flood` measures both: `all` cuts the flood's reach from 76.9 % to **21.2 %** and its airtime from 4 929 to **2 304** transmissions at no cost to honest traffic, so it is the better default on that evidence — but changing a specified security rule is left to `docs/04` (§6 note, `docs/06` §21.5). |
| `... --block-scope delivery` | How far a local block reaches (`docs/04` §6, *"Block/mute peer locally (ignore msgs from pubKey)"*). `delivery` (default) means the blocking node ignores the message and the mesh still carries it for everyone else; `relay` also refuses to forward — §6's *"ignore floods"* — which costs the blocked source a route wherever the blocker was a relay. Inert until something calls `blockPeer()`, and the CLI has no way to populate a blocklist, so this flag exists to be measured rather than run by hand (`docs/06` §22). An unknown name prints the valid set and exits `64`. Reports `blockedDrops`. |
| `... --cover-traffic` | Off by default. Emit dummy beacons at a low rate — `docs/04` §5's traffic-analysis mitigation, whose jitter half already ships unconditionally. A cover packet is one radio burst carrying nothing: it is counted where a real transmission is counted, creates no routing state, delivers nothing and is never acknowledged. Reports `coverTx`. It models **timing and count** cover only — this engine gives beacons no length, so a length-based observer is out of reach, and `docs/06` §23 says so rather than implying the mitigation is complete. |
| `... --cover-interval 30000` | Mean gap in ms between a node's dummy beacons. Read only with `--cover-traffic`, the way `--capture-ratio` is read only under `--channel-capture strongest`. A non-positive or unparseable number prints a usage message and exits `64`. `docs/06` §23 sweeps it, because §5 says *"low rate"* and not a number. |
| `... --radio-occupancy airtime` | How long a packet **holds a radio**, which is not the same question as how long it takes to arrive. `hop-latency` ships — the calibrated 120 ms BLE hop plus serialization of whatever exceeds a full packet, which is what `docs/08` §12's contention arms were measured under. `airtime` charges `bytes × 8 / kbps` for the whole packet, and sizes beacons from the fields an OGM actually carries (a typical one is 630 B ≈ 63 ms, not 120 ms). Delivery latency is unchanged either way, and under the shipped `free`/`none` radio only the wake-lock telemetry moves. Where contention *is* modelled the two diverge and **not uniformly**: under `csma` sizing packets halves crowd deferrals (12 649 → 6 707) and lifts `festival_crowd` delivery 68.5 % → 74.1 % over eight seeds, and takes `campus_quad` to **100 % on all eight** with broadcast reach 57.8 % → 81.6 %; under `half-duplex` the same crowd delivers about 2 points *worse*, though that arm is three-seed only and `docs/06` §24.8 explains why a three-seed `festival_crowd` magnitude should not be quoted. `docs/06` §24.6. |
| `... --ogm-alias-bytes 2` | How many bytes one *advertised* neighbour costs on air; read only with `--radio-occupancy airtime`, and inert without it. `32` ships because that is what this engine puts in an OGM — the neighbour's X25519 public key. `docs/03` §4 says a real deployment advertises 2-byte aliases instead, and the difference is not cosmetic: a fully loaded beacon is **1 270 B** on public keys (over the 1 024 B BLE ceiling) and **130 B** on aliases. The originator's own id stays 32 B either way, because an alias cannot identify a sender nobody has heard from yet. A non-positive or unparseable value prints a usage message and exits `64`. `docs/06` §24.7. |
| `... --connectivity-sample 5000` | How often to sample whether the radio graph is in one piece; `0` disables it. Reports `connectivitySamples`, `connectedSampleShare` and `meanLargestComponent`. **Read those beside delivery and reach in any mobile scenario**: `docs/06` §24.10 measured a 60-node crowd splitting and re-joins repeatedly inside a 60 s window, so `broadcastReach` reads as two modes (98 % against 54-79 %) unless you know how much of the window the network was in one piece — and the graph measured *after* the window cannot tell you, because a partition that healed looks like one that never happened. Sampling consumes no random numbers and schedules no events, so it cannot move a published number. A negative or unparseable value exits `64`. |
| `... --ogm-interval-mode density` | Whether a node beacons on the fixed interval `docs/03` §4 specifies, or on one derived from how many peers will hear it — stretched in proportion to peer count so the receptions a node imposes stay constant, anchored so ten peers reproduces the specified 2 s exactly, and clamped to `[ogmIntervalMs / 4, NEIGHBOR_SCORE_TTL_MS / 2]`. **Measured, and it ships off for a narrower reason than it first looked** (`docs/06` §24.11–§24.12). Where the topology can be held equal it is cheaper and does not cost reach — with `enableMobility: false` in `festival_crowd`, **44 % less demanded radio time and 44 % fewer beacons**, equal or better on reach in seven of eight seeds — but delivery is *not* a win: better on four seeds, worse on three, level on one, and the +2.5-point mean is mostly one seed. Where it cannot, it loses or cannot be read: `sparse_village` pays 3.11× the airtime for +1.6 points and `campus_quad` 1.20× for −0.7, both with comparable topologies, and the *mobile* crowd's two arms land in different topologies so that pair means nothing. It ships off because the shipped condition is the mobile one, and turning it on would change `docs/03` §4's 2 s on evidence from a network that is partitioned half the time. The flag exists so both tables are reproducible. |
| `... --scan-interval-mode density` | Scale each node's **scan** interval by its peer count — dense sooner, sparse later — anchored so ten peers reproduces the role's configured interval, and clamped to a quarter to four times it so a node with one peer does not stop scanning and a node in a crowd is not pinned awake. `docs/05` §1.2's third mitigation row, documented and never built until now. The direction is the **inverse** of `--ogm-interval-mode` and that is deliberate: a scan is this device waking to look, a beacon is every neighbour waking to listen, so the two costs scale with density in opposite ways and neither result is a verdict on the other. Saves wake-ups in a sparse world and spends them in a dense one, which is measured rather than assumed. |
| `... --json` | Machine-readable output. Names the arm it ran under a `radio` key. |
| `... --sos` | SOS flood reach (roadmap Phase 3). |
| `... --group 5` | Group delivery modes (`docs/06` §14). |
| `... --history` | Group-history anti-entropy (`docs/06` §17). |
| `... --media` | Media transport and push-to-talk (`docs/08`). |
| `... --trace` / `--capture` / `--capture-ogm` | Hop routes, pcap-like log, OGM capture. |

> **Reproducing the contention arms.** `docs/08` §12.9's six-arm table is `--channel-access` ×
> `--channel-capture` over `free`/`half-duplex`/`csma` and `none`/`first`; §12.15 adds `strongest`
> and sweeps `--capture-ratio` over 0/3/6/12/20 dB. Compare `deliveryRatio` and `overheadRatio`
> between runs — `--json` carries the `radio` block saying which arm produced them, so six runs
> cannot be mixed up after the fact. An unknown name is a usage error printing the valid set and
> exiting `64`, never a silent fall back to the default, and a flag you do not pass changes
> nothing: the shipped combination is inert by construction (§12.7), which is what keeps the
> golden vectors where they are.

---

## 3. Testing & Debugging

Unit testing, linting, debugging tools, and error logging.

### Running tests

| Command | Runs | Notes |
| --- | --- | --- |
| `make test` | `npm test` → `vitest run` | The TypeScript suite: engine, components, acceptance. |
| `npm run test:watch` | `vitest` | Watch mode. **Use `timeout 120 npx vitest run …` in a script** — an unbounded watcher will hang an automated run. |
| `make dart-test` | `dart test --reporter expanded` | The authoritative engine. |
| `npx vitest run src/__tests__/channel.test.ts` | one file | Narrowing down. |
| `npx vitest run -t "capture effect"` | by test name | Narrowing further. |
| `dart test test/transport_test.dart` | one Dart file | From `sim/mesh_sim`. |
| `dart test --name "refuses"` | by name | |

> **vitest ignores type errors.** A suite can be green while the code does not compile. Always run
> `make typecheck` alongside `make test`.

### Linting and static analysis

| Command | Runs | Notes |
| --- | --- | --- |
| `make typecheck` | `tsc --noEmit` | TypeScript. |
| `make dart-analyze` | `dart analyze` | Governed by `sim/mesh_sim/analysis_options.yaml`: `strict-casts`, `strict-raw-types`, `unused_import: error`, `dead_code: warning`, lint `avoid_print`. |
| `make check-docs` | `python3 tool/ci/check-docs.py` | Asks whether every command in `docs/` exists: CLI flags both directions, probe section names, `make` targets, `make.ps1`'s script table, the flags passed to `tool/ci/*.sh`, and — since a fifth job went into both lists the same day — whether `.github/workflows/ci.yml` and `run-pipeline.sh`'s `JOBS_ALL` still name the same jobs. Ten checks; `--self-test` injects one fault per check into a temporary copy and proves each is caught *and named*, because a drift checker that always passes is indistinguishable from one that is broken. |
| `make dart-balance` | `python3 tool/ci/check-dart-balance.py` | Delimiter balance across all 22 `sim/mesh_sim` Dart sources, **with no Dart SDK present**. Not a substitute for `dart analyze` — it answers one question (does every `(`, `[`, `{` and string opened outside a comment get closed, in order?) so a brace mistake costs one line here instead of a hundred unrelated analyzer errors on the first machine that can build. A state machine, not a parser: it strips comments, tracks '''-quoted blocks, and follows `${…}` interpolations including the strings nested inside them. |
| `python3 tool/ci/check-dart-balance.py --self-test` | same, on 19 built-in snippets | 12 clean snippets that must **not** alarm (a delimiter in a comment, in a string, in a raw string, inside an interpolation) and 7 broken ones that must. The negative cases are the point: this class of checker fails in practice by alarming on `mesh_sim.dart`'s usage text, and a false alarm on a 12 000-line engine is how a check gets deleted. The first version did exactly that — it held the string delimiter beside the stack instead of in the frame, so a `' | '` nested in `${…}` inside a ''' block was read as the end of the block. |
| `python3 tool/ci/check-dart-balance.py <file…>` | same, on named files | Defaults to every `.dart` file in the repository. Exit `0` balanced, `1` not, with `file:line:col` for the innermost unclosed frame. |
| `make parity` | `python3 tool/ci/check-parity.py` | Do the two engines still agree? Two questions. **(1) Constants:** pairs **57** by name across `src/*.ts` and `sim/mesh_sim/lib/src/*.dart` and requires the values to match — including module-private ones, since Dart's `_pdrWindow` and TypeScript's `PDR_WINDOW` are the same contract — then reads `docs/03` §3's coverage-score weight vector out of both engines and requires the five weights to match **and sum to 1**, because if they do not, the 0.60 promote and 0.50 demote thresholds mean something other than what §3 says. Needs no toolchain, which is the point: `make golden` catches a one-sided constant change on the TypeScript side and `dart test` on the Dart side, and neither runs where there is no Dart SDK. **(2) Type inventories:** requires both `SimConfig` (**83** fields) and `SimulationStats` (**80** fields) to be *identical* across the engines, none one-sided — because unlike the constants, which legitimately differ, a knob one engine has and the other ignores means an experiment that sets it silently configured half the contract, and a statistic only one engine reports means `--json` and the dashboard are not the same contract on both sides. `--json PATH` for machines, `--self-test` for **11** injected faults. |
| `make dart-sites` | `python3 tool/ci/check-dart-sites.py` | Are the Dart engine's **repeated** declarations all present? Needs no Dart SDK. Every `SimConfig` field lives at up to five sites and every `SimulationStats` field at four — declaration, `required this.` parameter, `toJson()` entry, and the construction site in `_computeStats` — plus one `case` per `EventKind` value, and the sites are hundreds of lines apart. Not every failure is loud: a stats field missing from `toJson()` compiles, runs, and simply never appears in `--json` output (commit `f18c5c6` found **32** of them), and a `copyWith` parameter with no body assignment compiles and *silently keeps the old value*, so an experiment that thinks it set a knob did not. Walks a comment-and-string-masked copy at identical offsets — doc comments inside a parameter list contain unbalanced parentheses — and handles all three member shapes used here: block bodies, bodyless `const` constructors, and expression bodies. It also resolves **every qualified reference in the package** (748 of them against 84 declared types): a receiver that is not a declared type, and an enum member that does not exist. Both are typos a compiler catches in a second and nothing else here could see, and both were typed into this package for real — `OgmiIntervalMode` for `OgmIntervalMode`, and a stub function referencing a `_Never` type — and found by hand, which is luck rather than a process. Five SDK types with static members are allowlisted by name; the failure message says to add a sixth deliberately rather than loosening the rule. `--self-test` breaks the real engine in memory 11 ways. |
| `python3 tool/ci/check-parity.py --self-test` | same, on a synthetic two-engine fixture | 8 cases: an integer, a float, an expression and a string changed on one side only, a coverage weight changed, a coverage weight renamed, and — the one that states a limit rather than a capability — a constant **deleted** from one side, which this check reports as a count and does not fail, because the two inventories are not supposed to match. |
| `make check-ps1` | `python3 tool/ci/check-ps1.py make.ps1` | Static check of the PowerShell front end: delimiter balance and PowerShell-7-only syntax, for machines that cannot run `pwsh`. |
| `python3 tool/ci/check-ps1.py --ps7-ok <file>` | same, allowing PS7 syntax | For scripts that are deliberately pwsh-only. |

### The whole pipeline, locally

| Command | Runs | Notes |
| --- | --- | --- |
| `make ci` | `tool/ci/run-pipeline.sh` | All five jobs: `checks`, `web`, `dart`, `cli-matrix`, `probes`. `checks` runs first because it is the cheapest and the only one with no toolchain dependency — it needs python3 and nothing else, so it answers even when the Node or Dart setup fails. |
| `make ci-fast` | `… --fast` | Skips the production build, the CLI matrix and the probes. |
| `make web` / `make dart` / `make cli-matrix` / `make probes` | `… --job <name>` | One job. |
| `./tool/ci/run-pipeline.sh --list` | prints the mapping | Every step, and the workflow step it mirrors. |
| `./tool/ci/run-pipeline.sh --job dart,probes --keep-going` | several jobs | `--keep-going` runs everything even after a failure. |
| `./tool/ci/run-pipeline.sh --json out.json` | writes a verdict record | Includes the toolchain versions the verdict was produced with. |
| `./tool/ci/run-pipeline.sh --allow-missing-dart` | accepts exit `2` | For working without a Dart SDK. **Never** turns a missing job into a pass. |

A job that cannot run is a **failure**, not a silent skip: without a Dart SDK, `make ci` exits `1`
with three of five jobs `MISSING`, the other two being `checks` and `web`.

### Every check at once

`make ci` mirrors the workflow job for job, and that mapping is its whole value. `make checks` is
a deliberate **superset** of it: everything CI runs, plus the checks that only make sense locally,
plus one thing CI cannot tell you — which checks have never actually been run against this tree.

| Command | Runs | Notes |
| --- | --- | --- |
| `make checks` | `tool/ci/collect-checks.sh` | Every check, one pass, one report. **Never stops at the first failure.** |
| `make checks-list` | `… --list` | What it would run, tagged `verified before` / `NEVER RUN` per check. Runs nothing. |
| `make checks-evidence` | `… --with-evidence` | Also re-runs the probes behind the published numbers in `docs/06`–`docs/09`. Minutes, not seconds. |
| `make daily` | `./tool/ci/daily.sh` | **The one command for a daily run.** Composes the CI mirror and the check collection into one dated artifact directory with one summary (`DAILY.md`) and one verdict. It exists because the two halves were separately interpretable and their exit codes meant different things: `run-pipeline.sh` exits `2` for *partial*, while `collect-checks.sh` exits `1` for both *failed* and *could not run*. `daily.sh` reads the collector's JSON to tell those apart and reports **GREEN** (`0`), **FAILED** (`1`) or **INCOMPLETE** (`2`) — and INCOMPLETE is not a pass, which on a machine without the Dart SDK is the expected verdict, because `sim/mesh_sim` is the authoritative engine and nothing in this repository can compile it. ~27 min. `DAILY.md` also reports how the run differs from the previous one — verdict, passed, failed, could-not-run, elapsed and sha as deltas — which is the part that makes a daily cadence worth having. `./tool/ci/daily.sh --prune N` reclaims all but the N most recent directories; nothing is deleted without it. |
| `make daily-fast` | `./tool/ci/daily.sh --fast` | The daily quick run: the CI mirror's fast subset plus every check, no evidence probes. **Measured at 11.5 min** on a machine without the Dart SDK — longer than it sounds because the two halves each do their own typecheck and test run, this script composing two complete tools rather than merging their work. Good daily; not good before a push. |
| `make daily-checks` | `./tool/ci/daily.sh --no-evidence` | The useful middle: the full CI mirror and every check, but no re-measuring of the numbers published in `docs/06`–`docs/09`. Roughly `daily-fast` plus the production build and the CLI acceptance matrix. |
| `./tool/ci/collect-checks.sh --only dart` | one group | Groups: `docs`, `ts`, `dart`, `cli`, `probes`, `evidence`. Comma-separated: `--only ts,dart`. |
| `./tool/ci/collect-checks.sh --report out.md --json out.json` | choose the outputs | The default report is `artifacts/ci/<run>/REPORT.md`. |

It produces three things: a console table; a Markdown report carrying the tail of every failing
capture plus parsed Dart diagnostics as `file:line:col`; and a **paste-back block** — the whole
result compacted into a few lines starting `DUMAN-CHECKS <sha> <date> node=… dart=…`, meant to be
copied into a message from a machine nobody else can inspect.

Exit `0` only when every check passed. A check that **could not run** exits `1`, because it did
not pass. There is deliberately no `partial` exit here, which is the real difference from
`run-pipeline.sh`: that script grades the machine as well as the code, this one only grades the
code and says plainly what it could not grade.

### Debugging a failure

| Command | Notes |
| --- | --- |
| `ls artifacts/ci/<run>/` | Every step's captured stdout, plus `<name>.exit` with its status. |
| `python3 tool/ci/diagnostics.py --format text` | The same parser CI uses, as readable text. `--format json` for machines, `--format github` for `::error file=…,line=…,col=…::` annotations. |
| `make diagnose` | Jobs and annotations for the newest failed remote run. |
| `make diagnose RUN=40020709332` | A specific run. |
| `./tool/ci/watch.sh --classify-run [RUN]` | Prints `billing`, `runner` or `none` — machine-readable, for scripts. |
| `gh api repos/<owner>/<repo>/check-runs/<jobId>/annotations --paginate` | The raw annotation channel. `$GITHUB_STEP_SUMMARY` is **not** readable through the API; annotations are the only machine-readable one. |
| `gh run view <run> --json jobs -q '.jobs[].databaseId'` | Find the `<jobId>` for the call above. |
| `gh run view <run> --log-failed` | Step logs — **when the log host is reachable.** If it returns empty, use annotations. |

---

## 4. Deployment & Maintenance

Build automation, containerization, and deployment workflows.

### Validated push

| Command | Runs | Notes |
| --- | --- | --- |
| `make push` | `tool/ci/validate-and-push.sh` | Full pipeline, then push. **Refuses on red and on partial.** |
| `make push-dry` | `… --dry-run` | Everything except the push. |
| `make push-force` | `… --force-partial` | Push after a PARTIAL run, and record that it was partial. The single escape hatch. |
| `make commit-push MSG="fix: …"` | `… --message "…"` | Commit the tree, validate, push. |
| `./tool/ci/validate-and-push.sh --job web` | scoped run | Verifies only `web`; logs `verification: scoped:web` so it cannot later be read as a full run. |
| `git push --no-verify` | bypasses the hook | Once, deliberately. The hook's fast subset is what you are skipping. |

Every push is appended to `artifacts/ci/verification-log.jsonl` (git-ignored) with the verdict, the
jobs that actually ran, which gate wrote it, and whether the push completed.

### Pull request automation

| Command | Runs | Notes |
| --- | --- | --- |
| `make pr` | `tool/ci/pr-flow.sh` | Validate → push → open PR → **merge only if every CI check passes.** |
| `make pr-dry` | `… --dry-run` | Every decision printed; no side effects at all. |
| `make pr-open` | `… --merge-on never` | Open the PR and stop. Leaves the merge to a human. |
| `make pr-local` | `… --merge-on local --yes` | Merge on the local run alone — the informed override for when CI cannot run. Records that CI never confirmed it. |
| `make pr-branch BRANCH=fix/thing` | `… --new-branch fix/thing` | Create the branch, then the whole flow. |
| `make pr-squash` | `… --squash --delete-branch` | Squash-merge and clean up. |
| `./tool/ci/pr-flow.sh --base main --title "…" --draft` | explicit control | Also `--rebase`, `--merge`, `--timeout`, `--interval`, `--force-partial`, `--skip-validate`. |

**Local validation gates *opening* the PR; it does not by itself justify *merging*.** A local run is
only as broad as the toolchain installed locally, so `--merge-on checks` is the default. When CI
cannot run at all — this repository has been refused for billing — the script says so and refuses,
rather than reading "no checks reported" as "checks passed".

### Containerization and running the real workflow

| Command | Runs | Notes |
| --- | --- | --- |
| `make act` | `act` | Runs the actual `ci.yml` in Docker: container images, `needs:` edges, `continue-on-error`, the gate. The most faithful local run. |
| `make act JOB=dart` | `act -j dart` | One job. |
| `act -l` | list the workflow's jobs | Sanity-check what `act` sees. |
| `docker run --rm -v "$PWD":/w -w /w node:22 bash -c "npm ci && npm test"` | the `web` job by hand | When `act` is unavailable but Docker is not. |

`act` needs Docker, and `setup-node`/`setup-dart` need network access from inside the container. On a
restricted network, native `make ci` is the path that works; `act` is the path that is most faithful.

### Monitoring remote CI

| Command | Runs | Notes |
| --- | --- | --- |
| `make watch` | `tool/ci/watch.sh` | Recent runs on this branch. |
| `make watch-all` | `… --all` | Every branch. |
| `make follow` | `… --follow` | Poll until the newest run finishes, then explain it. |
| `make diagnose` | `… --diagnose [RUN]` | Jobs, annotations, and **why** it failed — including distinguishing a billing refusal from a red build. |
| `gh run list --limit 8` | raw | |
| `gh run rerun <run>` | retry | Fails with "cannot be rerun" when the account is billing-blocked. |
| `gh pr checks <n>` | PR check status | |

### Maintenance

| Command | Notes |
| --- | --- |
| `make clean` | Removes `dist/`, `tool/.build/`, `sim/mesh_sim/build/` and the CI artifacts. |
| `make clean-artifacts` | Removes only `artifacts/ci/`. |
| `git status --porcelain` | Must be empty before pushing. |
| `tail -1 artifacts/ci/verification-log.jsonl` | What the last push actually verified. |
| `npm audit --audit-level=high` | Dependency advisories. |
| `dart pub outdated` | From `sim/mesh_sim`. |

---

## 5. Sequences worth memorising

**Starting a change**

```bash
make doctor && make install && make install-hooks
```

**Iterating**

```bash
make typecheck && make test          # fast, run constantly
make dart-analyze && make dart-test  # if you touched sim/mesh_sim
```

**Touched either engine's RNG, spawn order or scheduling**

```bash
make golden && git diff -- test-fixtures/golden-vectors.json
# changed  -> mirror the change in the other engine, or revert
# unchanged -> commit and carry on
```

**Finishing**

```bash
make ci && make push          # or: make pr  to open a pull request instead
make watch                    # then confirm remote CI agrees
```

**Something is red and you do not know why**

```bash
make diagnose                 # remote: jobs, annotations, and billing-vs-build
ls artifacts/ci/<run>/        # local: every step's captured output
python3 tool/ci/diagnostics.py --format text
```

---

## 6. The full sequence: clean tree → new branch → validated push → merged PR

### The one-liner

```bash
make pr-branch BRANCH=fix/retry-timer
```

Creates the branch, validates locally, pushes, opens the PR, and merges it when CI passes. It stops
at the first step that fails rather than carrying a problem forward.

Add `--dry-run` the first time you use it, to see every decision without any of the side effects:

```bash
./tool/ci/pr-flow.sh --new-branch fix/retry-timer --dry-run
```

### The explicit version, worth reading once

```bash
# 1. Start from a clean, current tree.
git switch main && git pull --ff-only
git switch -c fix/retry-timer

# 2. Make the change, then verify it — types first, they are the cheapest signal.
make typecheck && make test
make ci                       # every job; exits 1 if a toolchain is missing

# 3. Commit. Read what you are about to commit before you commit it.
git add -A && git status --short
git commit -m "fix: the retry timer measured silence from the wrong moment"

# 4. Push, gated. Refuses on a red or partial run.
make push
# …or push by hand and let the pre-push hook gate it:
git push -u origin fix/retry-timer

# 5. Open the PR, and merge only when the evidence supports it.
make pr                       # merge when every CI check passes
make pr-open                  # open it and leave the merge to a human
make pr-local                 # CI cannot run: merge on local evidence, recorded as such

# 6. Confirm what the remote thinks.
make watch
make diagnose                 # if it is red — and it says whether that is billing or a real failure
```

### The same sequence on Windows 11

`.\make.ps1` replaces `make`; `git` and `gh` are already native executables.

```powershell
.\make.ps1 doctor
git switch -c fix/retry-timer
.\make.ps1 ci
git add -A; git status --short
git commit -m "fix: the retry timer measured silence from the wrong moment"
.\make.ps1 push
.\make.ps1 pr
.\make.ps1 watch
```

If PowerShell will not run the script, that is the execution policy, not the script:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### What each gate is for

| Gate | Runs | Refuses when |
| --- | --- | --- |
| `pre-push` hook | the fast subset, on every `git push` | the build is actually red. Warns but allows a *partial* run. |
| `make push` | the full pipeline, before pushing | red, **or** partial without `--force-partial` |
| `make pr` | the full pipeline, then CI's checks | local red, or remote checks failed for a reason that is not an infrastructure refusal |

Three gates is not redundancy. The hook catches the bare `git push` that skipped the script; the
script catches the push that skipped the hook; CI catches what neither machine could verify. Each one
says plainly which of them is speaking, so a refusal tells you where to look.
