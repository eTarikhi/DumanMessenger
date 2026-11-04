# Results: research-led reliability and safe-deployment decision

**Successful negative result. No reliable >90% policy or deployable learned selector.**
All70 preregistered worlds completed exit0, plus12 startingHEAD baseline replays. No
threshold/metric change, no discarded seed or follow-up tuning. Archive retains10500
synthetic outcomes (plus1800 replay source sends). Source3051774 captures frozen engine/
runner; second-stage resume preserved initial sourceSHA and exact per-file code hashes.
Model was committed55b74bf BEFORE740x execution. All prior report artifacts unchanged.

## Baseline reconciliation completed, not assumed

12/12 baseline530x audit worlds matched **every historical stats field**:746/900 always
and745/900 duty, reproducing82.89/82.78. The separate330x replay reproduced359/450 and
356/450=79.78/79.11, also fullstats-equal. Different seed sets explain the historical
baseline percentages; different experimental policies explain why experimental figures
cannot be compared across populations. No evidence that one prior report was wrong.

## Canonical five-hop final crowd outcomes (of150 per world)

| Seed | Always baseline / epoch / backup | Duty baseline / epoch / backup |
|---|---:|---:|
|7401|120 /118 /125|127 /123 /127|
|7402|109 /112 /109|112 /115 /112|
|7403|139 /142 /139|140 /142 /140|
|7404|106 /109 /109|106 /102 /105|

| Four seeds per mode | Always | Duty |
|---|---:|---:|
| Baseline five-hop |79.00%|80.83%|
| Epoch comparator five-hop |80.17%|80.33%|
| Bounded backup five-hop |80.33%|80.67%|
| Backup vs baseline,pp (95% seed-t CI) |+1.33 [−1.27,+3.93]|−0.17 [−0.70,+0.36]|
| Backup seeds strictly >90% |1/4|1/4|
| Backup worst seed |72.67%|70.00%|
| Baseline seeds strictly >90% |1/4|1/4|
| Maximum backup p95 latency ratio |1.187|1.147|
| Maximum backup dataTX ratio |1.048|1.039|
| Maximum modeled aggregate battery-drain ratio |1.021|1.021|

t intervals use4 independent seed pairs (df3), NOT600 independent messages. Small,
non-normal/heterogeneous seed samples make these exploratory; no reliable release power
or tail guarantee. Strict90% means135/150 does NOT pass. No favorable7403-only conclusion.

Backup vs epoch per-seed deltas are[+7,−3,−3,0] always and[+4,−3,−2,+3] duty: it is not
uniformly better than the resource-competitive comparator. Prior timing variants also
failed robust benefit/resource gates; there is no established unique strongest global
policy across the historically different populations. This study compares the latest
route-epoch alternative, not an asserted universal timing optimum. No learned combination
or second candidate is justified by these inconclusive individual effects.

## Multipath/load and fairness evaluation

The alternative really chooses distinct first-hop peer IDs, only from source-local
advertisements/discoveries. It is **not proven end-to-end path-diverse**: advertisements
lack full paths, so shared weak links/cut vertices and reconvergence cannot be excluded.
No independence-based success probability was calculated. Baseline relay duplicate
suppression/caps remain, and every added unicast enters the usual on-air accounting.

Only8 of600 always messages and6 of600 duty messages activated backup. This mechanism
is too narrow to address the many source no-route/MPR/DTN failures. Two eligible first
hops do not guarantee better reach, and changed transmissions shift endogenous RF/jitter
draws; don't assign the aggregate delta to specific copies without a matched loss oracle.
It is a limited replication alternative, not equal splitting or a proven load balancer.
No new relay replication, retry amplification rule, source rate cap or queue limit was
introduced. Lower activation or cost is not called a delivery improvement.

Mean backup dataTX delta+1412.5 (CI[−140.7,+2965.7]) always,−268 (CI[−2841,+2305]) duty.
Existing totalTx excludes OGM broadcasts; OGM per-link attempts, wake-lock/radio-demand,
queues and all other counters are separately retained. No dataTX→phone-energy conversion.
Jain dataTX fairness paired delta+0.00147 always (CI[−0.01784,+0.02078]),−0.00332 duty
(CI[−0.00778,+0.00113]); no credible fairness improvement. Per-node TX/max share, queue and
role churn are retained, not global remote features used by the policy. Full end-to-end
ETX, contemporaneous optimal route stretch and measured physical bytes/airtime are missing;
source hop/TQ estimates and first-arrival hop histogram do not substitute for them.

Context-specific mean Pareto front: always baseline is dominated by epoch on the chosen
mean delivery/dataTX/p95/drain dimensions; epoch and backup are nondominated. Duty all
three remain nondominated. Pareto labels are descriptive and uncertain, not gate waivers.
The mean doesn't supersede worse seeds, missing actual wire-airtime, or owner budgets.

## Protected/adverse contexts, reported separately

Seed7501, each power mode:
- campus: baseline149/150, epoch150, backup149; backup duty dataTX ratio1.0634 fails the
provisional1.05 screen. Backup adds15/14 source copies always/duty without primary gain.
- sparse: all44/150 (29.33%), both modes; no backup activations.
- partitioned: all66/150 (44.00%), both modes; no backup activations.

n1 per context/mode is a regression sentinel, NOT proof of population non-inferiority.
No protected average used to hide context failures. Backup cannot invent missing contacts.

Adverse sensitivity: same7401, supported **csma + strongest** radio, baseline→backup
91→87/150 always (60.67→58.00%),90→87 duty (60.00→58.00%). Only2/1 messages activate
backup. Shared-radio outcomes materially differ from free/none; these are diagnostic
counter-model runs, not acceptance passes or real-phone throughput/collision validation.
They expose robustness risk but n1 does not estimate its population size/causal mechanism.

## Diagnostic ML: useful association, not a routing policy

Old-record context/time logistic had crowd validation AUC0.509, failure recall0 at0.5;
its retrospective all-context AUC0.780 was mainly context separation, not evidence of
live usefulness. Source-local snapshots enabled a separately frozen model:

| Untouched740x baseline evaluation | Always | Duty |
|---|---:|---:|
| ROC AUC |0.854|0.861|
| Failure precision at0.5 |0.526|0.527|
| Failure recall at0.5 |0.556|0.513|
| Brier |0.1235|0.1139|
| ECE (5 bins) |0.0484|0.0388|

Training only4301, validation4302, disjoint740x final; both power modes of a seed stay in
the same split. These probabilities predict canonical failure, not root cause or which
action helps. Source route availability/quality can identify risk but doesn't create a
working backup. Almost half positive predictions are false positives: unconditionally
replicating predicted failures would require a new experiment and likely costs more.

Protected sparse/partition AUC1.0 on single7501 is NOT robust generalization: calibration
is poor (ECE0.27–0.34), and exact separability is consistent with source route absence
versus obvious reachable pairs. Campus has only1 failure/mode: AUC near0.98 but recall0,
so no high-AUC reliability claim. Constant/stump comparisons, all calibration bins and
per-context errors are retained. No causal feature importance, SHAP, survival hazard or
neural/RL training fabricated. The tiny fitted Python score (~1.38us sandbox scalar)
and artifact size are offline evidence, not phone loading/latency/memory measurements.

## Acceptance, synthesis and rollout

Target, all-seed and benefit gates fail both modes; p95 cost gates fail; campus duty
TX gate fails; backup is inferior to epoch on some seeds and radio sensitivity declines.
Thus no policy combination or ML routing selector is promoted. No search after final,
no owner tolerance agreement invented. The single-mechanism intervention is the ablation;
compatible-benefit synthesis is inappropriate without individual credible wins.

Default baseline unchanged. Experimental profile remains TS-only, explicit offline opt-in.
Authoritative Dart parity, candidate goldens and actual devices/cohort remain absent.
Full existing Dart suite checks baseline, not these new mechanisms. Follow staged guide:
offline→shadow (not yet candidate-validated)→owner-approved real opt-in→promotion, with
latched fallback/rollback and offline operation. No actual app/device deployment claimed.
Next experiment: reliable neighbor-list age measurement and constrained temporal five-hop
feasibility, not larger replication or complex RL. Owner budgets and device priorities
are the unresolved decisions in DEPLOYMENT-AND-ROLLBACK.md.
