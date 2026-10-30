# Bounded evolutionary learning continuation

Starting source 709a2ec. The sandbox restored working files but rolled .git to82d967a;
compared the engine to origin, then repaired index/ref metadata without resetting or
changing working files. Tree clean after repair. No user changes discarded.

Target: strictly >90% five-hop ratio on NEW festival_crowd seeds, separately always-on
and duty-cycle, not just an aggregate or favorable training run. Campus already exceeds
90%; sparse/partitioned unreachable traffic must not disappear from the denominator.
No guarantee an algorithm can meet this target in a finite window; no infinite significance
fishing, release activation, threshold changes, flooding or extra RF range allowed.

Training seeds1101/1102. Four initial configurations: baseline, beacon1000/3000/5000ms
(other parameters baseline). Rank by worst training seed ratio, then mean ratio, then
lower relays. Per power context, mutate the best initial beacon configuration with
ACK3000 and ACK6000ms. Evaluate each unique offspring on both power contexts/training
seeds (at most eight configurations total). These are offline approved-primitive parameter
compositions, not arbitrary generated code. All profiles keep MPR, TTL, retry count,
transmit range, duty-cycle window, traffic and metric meaning unchanged.

Freeze two context policies (only feature: user power-mode flag) BEFORE validation seeds
2201/2202/2203 and final3301/3302/3303. No selection or refitting on either set. Baseline
and chosen policy both run. Protected scenarios campus_quad/sparse_village/partitioned_pair
use validation2201/2202 in both modes. Budget at most80 new worlds, each150 text messages,
1500ms spacing, no drain, same denominator and destination deduplication assertions.
Use independent common motion seed seed XOR0x1347 to avoid policy-induced movement drift.
Different loss/jitter event RNG consumption remains a limitation. Not directly comparable
to old default-mobility traces; matched baseline is regenerated here.

Per-seed rows retain all config/hash, delivery/hop/relay/latency/retry/queue/energy/stability
metrics. Report seed-paired t95 intervals only for n=3, descriptive/exploratory, not
packet-independent tests. Success requires both final power contexts >90%, positive
improvement lower bounds, and no unresolved protected-context/resource regressions.
Owner-approved non-inferiority and budget changes are still missing: activation remains OFF.

Before validation is opened: clarify the >90% target is required on **each final seed
and power context**, not merely a mean. The target is more stringent than a one-run score;
no claim of significance will be based on selecting a favorable seed.
