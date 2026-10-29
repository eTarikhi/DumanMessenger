# Single-hypothesis result and promotion decision

**Negative result. >90% crowd five-hop delivery is NOT achieved or verified.**
76 new worlds:12 exact baseline replays +64 targeted worlds (32 seed pairs), no model
training, evolutionary search, favorable-seed removal, metric change or default switch.
The earlier study is a separate frozen population. Its exposed3301–3303 seeds were used
only for diagnosis, never represented as new final seeds.

The sole deterministic candidate resets minimum-hop route competition on a newer
originator OGM sequence, excludes older sequences from route replacement and retains
shorter/TQ comparison within the current sequence. Direct neighbor handling, MPR coverage,
fanout, TTL, source retries, DTN bounds and sleep policy remain intact. Finite profile
`ogm-epoch-v1` is constructor-opt-in for offline TS runs only; unknown profiles throw.
No new policy is accepted by validateModel/live selector. No learner was justified.

## Untouched-at-declaration final crowd seeds (150 sends each)

| Seed | Always baseline→candidate | Duty baseline→candidate |
|---|---:|---:|
|5301|127→126|125→129|
|5302|137→135|134→132|
|5303|123→129|124→127|
|5304|114→115|114→118|
|5305|117→114|124→123|
|5306|128→129|124→124|

| Final summary | Always | Duty |
|---|---:|---:|
| Baseline five-hop |82.89%|82.78%|
| Candidate five-hop |83.11%|83.67%|
| Paired change,95% seed t CI (pp) |+0.22 [−2.02,+2.46]|+0.89 [−0.97,+2.75]|
| Candidate seeds strictly >90% |0/6|0/6|
| Candidate worst seed |76.00%|78.67%|
| Worst paired seed delta (pp) |−2.00|−1.33|
| Mean data/ACK TX change |−7,702.7|−7,116.3|
| Max per-seed data/ACK TX ratio |0.909|0.943|
| Max p95 latency ratio |1.612|2.634|
| Max modeled aggregate battery-drain ratio |1.040|1.079|

CIs use independent seed pairs, not900 independent packets; n6 is a feasibility screen,
not a reliable estimate of tail robustness. Ratios above are maxima over paired seeds,
not ratios of favorable means. Full p50/p95,three/overall, retries/expiry/queues/drops,
role stability, wake-lock, RF/OGM loss, per-seed deltas and intervals are in summary.json
and paired-per-seed.csv. Every synthetic message's outcome and bounded observations,
including successful messages, is retained in experiments.json.gz.

**Counter semantics matter:** existing `totalTx=sum(node.txCount)` equals relayTx in
these cover-off worlds; it counts data/ACK attempts, NOT all physical control broadcasts.
OGM `controlOverhead` counts per-peer OGM attempts, not broadcast on-air equivalents.
Always control mean815264.5→815268.3; duty816797.5→816231.3. A separately labeled
(data TX + OGM per-link attempt) proxy falls only about0.90%/0.90%, not18% in whole-radio
work. Do not call reduced dataTX a measured device-energy saving. BatteryDrain is a
role/duty model, not a per-transmission phone energy measurement. Wake-lock/radio demand
are proxies, and free/none worlds have no MAC contention. wallMs is retained but concurrent
process/load variability prevents a controlled inference-cost conclusion. There is no
inference/model, only a fixed OGM comparison; no cloud dependency.

## Hypothesis outcome

Across900 final messages/mode, any reverse-to-sender route observation falls252→181
(always) and241→192 (duty); TTL-exhausted branch111→73 and109→76. However any advertised
route beyond remaining five-hop budget rises392→427 and400→446. Fewer stale-route
symptoms and fewer data transmissions are NOT sufficient to deliver the remaining
messages within five hops. These are treatment-level descriptive observations, not
packet-level causal mediation: loss/jitter draws cease to align as routing changes.
No route-cost/parity/learning tuning was performed after opening final outcomes.

Development means:always112→107/150,duty109→108.5/150. Validation always131→134.5,
duty133→129.5. Both modes and all seeds retained; validation's isolated136/150 always
case was not selected as proof. No broad search or second candidate followed.

## Protected contexts (6301/6302, two seeds per mode)

- campus always150→150 mean; duty149.5→149.5 mean, but6302 loses150→149 while6301 gains
149→150. Thus no-regression per-seed gate fails even when the mean is unchanged.
Maximum p95 ratio3.764(always)/3.011(duty), duty modeled drain ratio1.339: gates fail.
- sparse both modes41.5→41.5/150, per-seed43/40; candidate and baseline statistics identical.
- partitioned both modes58.5→58.5/150, per-seed66/51; statistics identical.

No pooled protected average, no unchanged sparse/partitioned score presented as meeting
90%. These contexts may need longer windows/contact opportunities, not a route-only fix.

## Staged path (status, not a claim of deployment)

1. **Offline:** completed exact baseline and this one targeted negative experiment. Stop
promotion. Keep baseline independently selectable and the experimental constructor at
its default `baseline`. Prior timing selector remains unchanged, approval-gated.
2. **Shadow:** next only after a different evidence-supported hypothesis survives a
predeclared offline screen. Existing telemetry invariance tests are not candidate
shadow-benefit validation. No phone adapter/shadow cohort tested in this mission.
3. **Explicit opt-in:** BLOCKED. Would need authoritative Dart implementation plus shared
candidate route/OGM, retry, DTN, mobility and failure goldens; resources/non-inferiority
agreement; immutable compatible hashed manifest; drift/fault/power precedence and
session-latched fallback exercising this candidate. Current Dart344 suite checks existing
engine/default parity, NOT this TS-only profile. No production selector registration.
4. **Promotion:** BLOCKED on robust >90% both modes, per-context worst-case gates,
variance-powered untouched expansion, real-device validation and explicit owner approval.
No PR merge or main change performed. No device/canary deployment claimed.

## Next evidence-backed work and owner action list

- Independently test **coverage freshness**, not unrestricted flood/MPR removal: suppression
uses stale peerIds/twoHopView;32 discovery misses have geometric coverage gaps. Consider
age-limited coverage proof and bounded targeted repair only after a new protocol and
wire-format/Dart budget review. Do not reuse5301–5306 as untouched future holdout.
- Add a constrained temporal <=5-hop scheduler bound accounting for realistic latency and
retry budgets, alongside existing unlimited-hop optimism. This is research, not a score.
- Investigate right-censored late injections and retry timing using separately labeled
secondary drain windows, without modifying primary acceptance-window semantics. Current
analysis does not establish which physical cause kills every undelivered message.
- Owner must approve actual battery/TX/latency budgets and non-inferiority tolerances;
current5%/10% gates are explicitly provisional screens, not invented approvals.
- Owner/device resources needed for authoritative Dart candidate work, adapter and phone
cohort. No requirement for real-user content, permanent network, cloud or online learning.

This is a verified path for **deciding what not to promote**, plus the next bounded
hypotheses; it is NOT a verified implementation that already attains >90%.
