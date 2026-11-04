# Predeclared selector experiment protocol

Starting revision c74b164, clean target branch verified, origin identical. No app/ directory,
Flutter or local Dart SDK; Node v22.22.3 available. Previous raw evidence and source metric
filters inspected. Existing strategies only patch ACK timer / DTN preferences / MPR mode;
none is wired into a live selector. Baseline is unchanged.

Primary comparison: a fixed offline-trained neighbor-count decision stump versus baseline,
selecting only baseline-v1 or ack-6000-v1. Features: source-local neighbor count at decision
window start and configured duty-cycle flag. No scenario name, seed, destination oracle,
message content, or post-outcome statistic is an inference input. Labels are per-source
five-hop successes from matched traffic in independently simulated baseline/ACK-6000 arms.
These are noisy whole-world counterfactual labels, NOT causal guarantees for mixed policies.

Before training reproduce campus seed42 148/150, crowd seed31415 duty baseline104 vs ACK91,
and compare retained per-arm relay/retry counts. Fail on discrepancy.
Targeted diagnosis: seed31415 mobile vs mobility-disabled, both power modes and both arms.
New data budget: seeds train101/202/303, tune404, validation505, final holdout606; all four
existing scenarios, both power modes, both arms = 96 runs. No tuning on validation or holdout.
Search only five thresholds [4,8,12,16,24]; nonpositive train gain selects baseline. Tune set
reports uncertainty, does not change the model. Final holdout is opened once after model
serialization, hash and parameters are frozen. One holdout seed is insufficient for a
seed-level confidence interval: this alone PRECLUDES promotion. Existing raw 360-run evidence
is historical discovery, not an untouched holdout for this model.

Promotion: existing >=90% campus five-hop gate and existing documented relay/power/role
requirements remain unchanged. No non-inferiority margin or extra resource budget is owner
approved. Require positive seed-level lower bound on unseen improvement and no unresolved
protected-context/resource regression. Missing tolerances, insufficient independent holdout
seeds, mixed-policy counterfactual uncertainty or untested Dart outcomes block promotion.
Do not test repeatedly until significant. Proposed future margins require owner approval.

Implementation may observe and score in shadow mode but must never change forwarding or
ACK timers. Canary controls must fail closed for unapproved experimental artifacts. Model
must be immutable in a run, local-only and version/schema/action validated. Any runtime
fault or drift latches baseline for the session; user power saver wins. No online learning,
new paid infrastructure, model dependencies, canary devices or production changes authorized.

## Protocol deviation recorded before fitting
A progress-log tail exposed seed606 crowd totals before model fitting. No model parameters
were chosen using those totals, but it cannot honestly remain untouched. Treat 606 as an
exploratory audit set. Reserve final seed909 (all four scenarios, both power modes, both arms)
now; fit and hash the model before starting those 16 final runs. No further holdout replacement
is permitted. One final seed still cannot support promotion. This is contamination management,
not a search for a favorable significant result.
