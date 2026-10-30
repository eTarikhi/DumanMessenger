# Verification report

| | |
| --- | --- |
| Commit | `e45bd43` |
| Branch | `arena/ff85cb12-dumanmessenger` |
| Groups | `docs ts dart cli probes` |
| Date | 2026-10-26T00:37:21Z |
| Host | `Linux 6.18.54.1-microsoft-standard-WSL2 x86_64` |
| node | /mnt/c/Users/Administrator/Desktop/Git-Clones/DumanMessenger/tool/ci/lib.sh: line 58: /home/administrator/bin/node: Permission denied |
| npm | 11.19.0 |
| dart | 3.13.7 |
| python3 | 3.14.9 |
| Elapsed | 676s |

## Summary

**23 passed · 1 failed · 0 could not run.**

| group | check | result | verified before? | detail |
| --- | --- | --- | --- | --- |
| docs | `drift` | success | yes | — |
| docs | `dart-balance` | success | yes | — |
| docs | `parity` | success | yes | — |
| docs | `dart-sites` | success | yes | — |
| docs | `checker-self-test` | success | yes | — |
| ts | `npm-ci` | success | yes | — |
| ts | `typecheck` | success | yes | — |
| ts | `test` | success | yes | — |
| ts | `golden-regen` | success | yes | — |
| ts | `golden-diff` | success | yes | — |
| ts | `build` | success | yes | — |
| dart | `pub-get` | success | no | — |
| dart | `analyze` | success | no | — |
| dart | `test` | failure | no | +277 -1: Some tests failed |
| dart | `cli` | success | no | — |
| cli | `campus_quad-always-on` | success | no | — |
| cli | `campus_quad-duty-cycle` | success | no | — |
| cli | `sparse_village` | success | no | — |
| cli | `festival_crowd` | success | no | — |
| cli | `partitioned_pair` | success | no | — |
| probes | `sos` | success | no | — |
| probes | `group` | success | no | — |
| probes | `history` | success | no | — |
| probes | `media` | success | no | — |

## Failures, and checks that could not run

### dart / test

```
00:56 +173: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) re-floods on the interval, every flood with a fresh id
00:56 +174: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) re-floods on the interval, every flood with a fresh id
00:56 +175: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) re-floods on the interval, every flood with a fresh id
00:56 +176: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) re-floods on the interval, every flood with a fresh id
00:56 +177: test/transport_test.dart: MeshTransport — bulk transfer carries a file in chunks, each sized on its own radio
00:56 +178: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) gives a single-flood arm to measure against
00:56 +179: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) gives a single-flood arm to measure against
00:56 +180: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) gives a single-flood arm to measure against
00:56 +181: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) gives a single-flood arm to measure against
00:57 +182: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) re-floods with a fresh fix, so a moving sender stays trackable
00:57 +183: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) reaches every radio-connected node — the roadmap exit criterion
00:58 +184: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) reaches all of a 60-node crowd, which TTL=5 cannot span
01:01 +185: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) collapses repeats into one alert per receiver, newest fix wins
01:02 +186: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) keeps a late copy from overwriting a newer fix
01:02 +187: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) floods to every peer whatever the relay policy says
01:02 +188: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) stops flooding when the sender goes dark
01:03 +189: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) logs every flood when capture is on
01:03 +190: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) buys reach with radio time, and the cost is visible
01:04 +191: test/engine_test.dart: SOS mode: repeated flood of GPS + text (docs/05, roadmap Phase 3) leaves the unicast metrics baseline alone
01:05 +192: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) records when each hop arrived, over what link, and what it decided
01:05 +193: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) recovers the route chain from the fan-out tree
01:06 +194: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) marks the relays MPR suppressed, with the reason
01:06 +195: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) traces hops always, and captures the log only when asked
01:07 +196: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) logs beacons too when captureOgm is set
01:07 +197: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) keeps the capture bounded and in time order
01:08 +198: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) does not perturb the run it is measuring
01:09 +199: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) drops the log when metrics are re-baselined
01:09 +200: test/engine_test.dart: hop traces and the capture log (roadmap Phase 4) logs the DTN last resort as a queue event
01:10 +201: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) never promotes a node the user opted out of
01:10 +202: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) never auto-promotes with battery saver on
01:11 +203: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) leaves duty cycling off by default
01:11 +204: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) scans 3 s out of every 10 s when duty cycling, never a SUPER
01:11 +205: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) spreads duty phases so a crowd does not sleep in lockstep
01:11 +206: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) measures the per-role battery rate against the skills/07 budget
01:12 +207: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) buys battery headroom by sleeping
01:13 +208: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) excludes charging nodes from the measured drain rate
01:13 +209: test/engine_test.dart: power policy and telemetry (skills/02, skills/07) buckets latency by hop for first-attempt routed traffic
01:14 +210: test/engine_test.dart: encrypted packet size (skills/03 Packet) is the documented layout: 95 bytes around the body, padded to 256
01:14 +211: test/engine_test.dart: encrypted packet size (skills/03 Packet) keeps a long text on BLE, where the documented packet still fits
01:14 +212: test/engine_test.dart: encrypted packet size (skills/03 Packet) sizes a created message from the packet layout
01:14 +213: test/engine_test.dart: encrypted packet size (skills/03 Packet) counts a body in UTF-8 bytes, not in UTF-16 code units
01:14 +214: test/engine_test.dart: encrypted packet size (skills/03 Packet) agrees with utf8.encode on every script the app will meet first
01:14 +215: test/engine_test.dart: encrypted packet size (skills/03 Packet) moves a non-ASCII body to the transport that can actually carry it
01:14 +216: test/engine_test.dart: encrypted packet size (skills/03 Packet) leaves every ASCII result exactly where wireSizeOf put it
01:14 +217: test/engine_test.dart: abuse limits (docs/04 §6) the caps are the numbers docs/04 §6 states
01:14 +218: test/engine_test.dart: abuse limits (docs/04 §6) admits exactly cap messages, then refuses
01:14 +219: test/engine_test.dart: abuse limits (docs/04 §6) refills continuously, so a rate is enforced rather than a tally
01:14 +220: test/engine_test.dart: abuse limits (docs/04 §6) never refills above the cap, so silence does not bank a burst
01:14 +221: test/engine_test.dart: abuse limits (docs/04 §6) keeps sources and enforcers apart
01:14 +222: test/engine_test.dart: abuse limits (docs/04 §6) treats a non-positive cap as no cap
01:14 +223: test/engine_test.dart: abuse limits (docs/04 §6) grants no refill when the clock goes backwards
01:14 +224: test/engine_test.dart: abuse limits (docs/04 §6) reports one token every 2 s at the relay cap
01:14 +225: test/engine_test.dart: abuse limits (docs/04 §6) exempts control-plane traffic from the relay cap
01:14 +226: test/engine_test.dart: abuse limits (docs/04 §6) counting beacons would cost a node 90% of its sustained data rate
01:14 +227: test/engine_test.dart: abuse limits (docs/04 §6) is off by default, so nothing a shipped run does changes
01:14 +228: test/engine_test.dart: broadcast cap enforcement scope defaults to docs/04 §6 — SUPERs only
01:14 +229: test/engine_test.dart: broadcast cap enforcement scope suppresses more when every node enforces than when only SUPERs do
01:14 +230: test/engine_test.dart: broadcast cap enforcement scope cuts the airtime a flood costs, which is what the cap is for
01:15 +231: test/engine_test.dart: broadcast cap enforcement scope still costs an honest network nothing under either scope
01:16 +232: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) isBlockableTraffic covers user traffic and exempts protocol and SOS
01:16 +233: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) defaults to delivery scope and is inert while empty
01:17 +234: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) blocks, unblocks, refuses a self-block, and reports the list sorted
01:17 +235: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) keeps a blocked peer out of the blocker inbox but not out of the mesh
01:17 +236: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) lets a blocked peer SOS through, and still lets the blocker send
01:18 +237: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) keeps the blocked peer in the routing table, because OGMs are not blockable
01:18 +238: test/engine_test.dart: local blocklist (docs/04 §6, bullet 1) relay scope costs the blocked source airtime that delivery scope spends
01:19 +239: test/engine_test.dart: cover traffic (docs/04 §5, dummy beacons) is off by default at a rate the document does not specify
01:19 +240: test/engine_test.dart: cover traffic (docs/04 §5, dummy beacons) emits nothing when off, which is what keeps every published number intact
01:19 +241: test/engine_test.dart: cover traffic (docs/04 §5, dummy beacons) emits at the rate it is told to, and faster when told to be faster
01:21 +242: test/engine_test.dart: cover traffic (docs/04 §5, dummy beacons) costs airtime in proportion to its rate
01:22 +243: test/engine_test.dart: cover traffic (docs/04 §5, dummy beacons) does not starve the network, which is the floor §23 asserts not an equality
01:23 +244: test/engine_test.dart: cover traffic (docs/04 §5, dummy beacons) counts cover separately from the routing protocol own beacons
01:24 +245: test/engine_test.dart: wake-lock accounting (skills/07, fourth telemetry item) counts under the shipped radio baseline, which maintains no busy-radio maps
01:25 +246: test/engine_test.dart: wake-lock accounting (skills/07, fourth telemetry item) reports per node what it reports in total
01:25 +247: test/engine_test.dart: wake-lock accounting (skills/07, fourth telemetry item) splits the radio demand between roles, and the shares sum to 100
01:26 +248: test/engine_test.dart: wake-lock accounting (skills/07, fourth telemetry item) reports the model over-subscription plainly instead of hiding it
01:26 +249: test/engine_test.dart: wake-lock accounting (skills/07, fourth telemetry item) measures the window, not the whole run
01:27 +250: test/engine_test.dart: wake-lock accounting (skills/07, fourth telemetry item) prices concentration on the neighbours who have to hear it
01:28 +251: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) derives a beacon from the fields docs/03 §4 says an OGM carries
01:28 +252: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) ties the literal widths to the named ones, which is what makes them safe
01:28 +253: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) puts a fully loaded beacon over the BLE ceiling
01:28 +254: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) ships on the model every published number was measured under
01:28 +255: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) charges airtime from the rate constants the engine already had
01:28 +256: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) changes telemetry and nothing else under the shipped radio baseline
01:29 +257: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) halves the demanded radio time without making it physical
01:30 +258: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) sizes the alias encoding docs/03 §4 prescribes
01:30 +259: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) defaults to the encoding the engine transmits
01:30 +260: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) cuts demanded radio time by beacon width, not by beacon count
01:31 +261: test/engine_test.dart: radio occupancy and the derived beacon size (docs/06 §24.6) samples connectivity in-window, which an end-of-window graph cannot
01:36 +262: test/engine_test.dart: connectivity sampling (docs/06 §24.10) reports the radio graph components, largest first, summing to the network
01:37 +263: test/engine_test.dart: connectivity sampling (docs/06 §24.10) samples the window at the configured interval, not the settle period
01:38 +264: test/engine_test.dart: connectivity sampling (docs/06 §24.10) can be disabled, and a disabled run reports trivially connected defaults
01:38 +265: test/engine_test.dart: connectivity sampling (docs/06 §24.10) splits what is out of range, largest piece first
01:38 +266: test/engine_test.dart: connectivity sampling (docs/06 §24.10) makes an offline node its own component rather than absorbing it
01:38 +267: test/engine_test.dart: connectivity sampling (docs/06 §24.10) is what componentSizes reports the sizes of, so metric and picture agree
01:39 +268: test/engine_test.dart: connectivity sampling (docs/06 §24.10) says a settled 20-node campus stays in one piece
01:39 +269: test/engine_test.dart: connectivity sampling (docs/06 §24.10) does not change the world it measures
01:41 +270: test/engine_test.dart: adaptive scan intervals (docs/05 §1.2, layer 3) ships fixed, so nothing published moves
01:41 +271: test/engine_test.dart: adaptive scan intervals (docs/05 §1.2, layer 3) scans less in a sparse world, which is the row claimed saving
01:41 +272: test/engine_test.dart: adaptive scan intervals (docs/05 §1.2, layer 3) scans more in a dense world, which is what the row says and what it costs
01:54 +273: test/engine_test.dart: adaptive scan intervals (docs/05 §1.2, layer 3) is anchored, so a reference-density node scans at the configured interval
01:55 +274: test/engine_test.dart: adaptive scan intervals (docs/05 §1.2, layer 3) clamps, so one peer does not stop a scan and a crowd does not pin a node awake
02:06 +275: test/engine_test.dart: density-derived beacon interval (docs/06 §24.11) ships on the fixed interval docs/03 §4 specifies
02:06 +276: test/engine_test.dart: density-derived beacon interval (docs/06 §24.11) spends more airtime in a sparse world, where the clamp floor bites
02:06 +277: test/engine_test.dart: density-derived beacon interval (docs/06 §24.11) costs a dense crowd fewer deferrals under csma, and buys it delivery
02:13 +277 -1: test/engine_test.dart: density-derived beacon interval (docs/06 §24.11) costs a dense crowd fewer deferrals under csma, and buys it delivery [E]
  Expected: a value less than <0>
    Actual: <0>
     Which: is not a value less than <0>
  
  package:matcher               expect
  test/engine_test.dart 2723:7  main.<fn>.<fn>
  
02:13 +277 -1: Some tests failed.

Failing tests:
  test/engine_test.dart: density-derived beacon interval (docs/06 §24.11) costs a dense crowd fewer deferrals under csma, and buys it delivery

Consider enabling the flag chain-stack-traces to receive more detailed exceptions.
For example, 'dart test --chain-stack-traces'.

```

## Dart diagnostics, parsed

The same parser CI publishes as annotations, so locations are `file:line:col`.

```
dart analyze — 0 error(s), 0 warning(s), 0 info(s)
  (no analyzer issues with a location; raw output below if non-empty)

dart test — 277 passed, 1 failed, 0 skipped
  FAIL test/engine_test.dart: density-derived beacon interval (docs/06 §24.11) costs a dense crowd fewer deferrals under csma, and buys it delivery
       at test/engine_test.dart:2723:7
       Expected: a value less than <0>
           Actual: <0>
            Which: is not a value less than <0>
         
         package:matcher               expect

CLI acceptance (campus_quad, seed 42) — last 15 lines
  |   batteryPct8hSuper        55.65
  |   scansPerSec              33.2
  |   relaysPerSec             16.2311
  |   awakeRatio               1.0
  |   scansSkippedAsleep       0
  |   electionEvents           6
  |   latencyByHop             hops      n     avg     p95
  |                               1     62   247 ms   314 ms
  |                               2     38   646 ms   829 ms
  |                               3     27   902 ms  1127 ms
  |                               4     12  1066 ms  1550 ms
  |                               5      1  1257 ms  1257 ms
  |                               6      2  1746 ms  2026 ms
  | 
  | PASS — acceptance criteria met.

```

## Artifacts

`artifacts/ci/20261026T002605Z-1aaa8f5-checks`

Every check that ran has a `.txt` capture there, plus a `.exit` file with its status.
A group that could not run has a `.missing` file recording why.
