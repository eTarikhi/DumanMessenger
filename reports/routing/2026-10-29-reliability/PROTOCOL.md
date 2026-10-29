# Frozen bounded-redundancy experiment

Starting actualHEAD dbd6e83, clean targetbranch; currentHEAD CI40848112462 and40848103808
both completed success. Local Node22.22.3, existing npm dependencies available, Dart absent.
Read engine/OGM/DTN/selector, skills, prior strategies/reports/goldens and shared Dart
selector. Historical studies reconciled by seed population in reconciliation.json.
CurrentHEAD exact12-world replay begun before any engine edits; no prior evidence edited.

Research/old diagnostic evidence suggests bad route first hops but does not prove they
cause every message miss. Offline logistic/stump analysis uses ONLY elapsed send time,
scenario and power flag: old logs lack source pre-decision link/queue snapshots. No
post-send diagnostic tags/labels/hops as predictors. New final seeds not yet simulated.
ML is diagnostic only, frozen before new outcomes; no runtime selector added.

## One candidate, no combinations or blind tuning

`source-backup-v1`: baseline routing plus at most ONE additional first-hop unicast for
initial-attempt, non-carried, source text messages with a known unicast route. Choose a
*different* locally observed/physically reachable peer whose own advertised bestHopTo
claims destination within remaining five-hop budget, whose direct neighbor entry has
hop1, TQ>=0.6, lastSeen within10s. Rank fewest advertised hops, then higher local TQ,
then stable peerID. No remote queue/position/live route oracle. Extra copy shares logical
ID/attempt; ordinary relay dedup/caps/TTL apply. No extra DTN sprays or retry copies.
Different FIRST hops are real; node/link-disjoint end-to-end paths NOT established.
TQ/lastSeen are explicitly proxies, not ETX or exact neighbor-list age.

Compare baseline, strongest previous route-epoch candidate `ogm-epoch-v1`, and this bounded
alternative separately. Neither old candidate proved a delivery win; no combination is
justified yet. Stop synthesis if new candidate fails. No MPR-disable or flood-all arm.

- Audit5301–5306, baseline only, both modes:12 worlds reproduce the other historical
baseline population. These are EXPOSED historical seeds, never a new final test.
- Development4301/4302 both modes×3 arms:12 worlds. Capture pre-send feature snapshots
and observational per-node TX fairness for future work; do not fit new policy on final.
- Final7401–7404, both modes×3 arms:24 worlds, untouched before declaration.
- Protected7501, three other scenarios×both modes×3 arms:18 worlds. One protected seed
is a low-cost regression sentinel, NOT statistical non-inferiority proof.
- Adverse7401 crowd baseline/backup both modes under channelAccess=csma,
channelCapture=overlap:4 diagnostic sensitivity worlds, provided those registered
config values exist; use actual supported values otherwise document blocked. No gate
relaxation. This estimates modeled shared-radio risk, not phone performance.
Total70 worlds plus12 replay; fixed finite design, no adaptive sample expansion/search.

Primary canonical unique first delivery<=5 / successful source unicast sends,150 planned
sends at1500ms,225-second traffic window after warmup, no extra drain or threshold change.
Motionseed XOR0x1347, traffic XOR0x5bf03635. RF loss/jitter share endogenous RNG; world
pairing does not guarantee per-packet common random loss draws after an intervention.

## Gates (research screen only; no owner-approved tolerances)

Both crowd power modes separately: aggregate>90%, every final seed strictly>90%, paired
95% seed-t lower bound>0 versus baseline AND no inferiority versus epoch. Protected no
negative five-hop paired delta; max existing data/ACK TX and modeled battery ratio1.05,
p95 ratio1.10; OGM attempts/wake/radio-demand reported separately. Missing owner approval
blocks promotion regardless. A single harmful sentinel is failure, not hidden by means.

n4 is an inexpensive falsification screen, not a powered promotion study. Prior epoch
paired t intervals included0; claiming narrow precision with4 would be unjustified.
Report t df3 (critical3.182446), individual deltas, seed-pass count, all resource metrics
and per-context Pareto dominance. Even4/4 passes give only47.3% one-sided95% lower bound
on seed-pass probability. No expansion/second policy after final. Owner tolerances and
future prepowered sample size require agreement before promotion; no agreement invented.

Expected added cost: at most1 source transmission per eligible initial route, but its
new downstream tree can add many relay transmissions; measure, do not bound total cost
by150. Relay/source/queue caps unchanged. Falsify if benefit CI includes0, target fails,
resource/regression gates fail, or radio sensitivity exposes collapse. Diagnostic runs
are not acceptance passes. Hard safety stop on metric drift, diagnostic overflow, hash
mismatch, or source-copy count>sent. All negative results retained.

Pre-execution clarification: ChannelCapture accepts none/first/strongest, not overlap;
adverse counter-model uses supported `strongest` with csma, recorded per config. No radio
model outcome was observed before this correction. Runner stages development/audit first,
then freezes a second offline-only supervised model on newly available source snapshots
(train4301, validate4302) BEFORE running final740x. Features: source observed peer count,
queue length, battery, role, destination route hops/TQ/age and presence, duty and elapsed
time. Missing route is an explicit indicator, zeros otherwise; no future tags/oracles.
Model type bounded logistic vs constant, standardized via fixed physical ranges, fixed
L2/iterations; threshold0.5, Brier selection on4302. No policy actuation; model error on
untouched740x baseline is independent from routing gates. New telemetry reads existing
state only, consumes no RNG. Protected7501 remains a sentinel; no statistical power claim.
