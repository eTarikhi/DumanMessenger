# Routing benchmark summary

Generated from `reports/routing/2026-10-28/ood-summary.json`. Raw per-seed counts, configs and full stats accompany this table.

Intervals are unadjusted seed-paired 95% t intervals, n=3. All strategies remain unpromoted.

| Split / scenario / power | Strategy | ≤5 % | Delivery % | ≤3 % | Mean/p95 hops | Relays | p95 ms | Retry/exhausted | NORMAL/SUPER %/h | Flap/node/min | Δ≤5 pp [95% CI] |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| ood / festival_crowd / always | ack-2000-v1 | 63.33 | 67.56 | 54.44 | 2.09/4.7 | 47424 | 2632 | 144.0/60.7 | 2.858/6.543 | 0.092 | +1.11 [-1.42, +3.64] |
| ood / festival_crowd / always | ack-6000-v1 | 63.56 | 68.00 | 54.00 | 2.10/4.7 | 44770 | 4911 | 129.0/56.3 | 2.949/6.695 | 0.096 | +1.33 [-3.05, +5.71] |
| ood / festival_crowd / always | baseline-v1 | 62.22 | 68.22 | 53.33 | 2.17/4.7 | 44730 | 4627 | 132.3/58.0 | 2.880/6.651 | 0.092 | +0.00 [+0.00, +0.00] |
| ood / festival_crowd / always | community-carrier-v1 | 62.22 | 68.22 | 53.33 | 2.17/4.7 | 44730 | 4627 | 132.3/58.0 | 2.880/6.651 | 0.092 | +0.00 [+0.00, +0.00] |
| ood / festival_crowd / always | route-flood-v1 | 63.56 | 68.00 | 54.22 | 2.12/5.0 | 111481 | 3669 | 132.0/57.3 | 2.887/6.946 | 0.089 | +1.33 [-5.89, +8.55] |
| ood / festival_crowd / always | super-carrier-v1 | 62.22 | 68.00 | 54.00 | 2.13/4.7 | 45142 | 4664 | 130.7/57.3 | 2.880/6.853 | 0.093 | -0.00 [-1.66, +1.66] |
| ood / festival_crowd / duty | ack-2000-v1 | 64.44 | 68.00 | 55.11 | 2.09/4.3 | 48089 | 2688 | 143.7/59.7 | 1.379/6.494 | 0.073 | +0.44 [-1.47, +2.36] |
| ood / festival_crowd / duty | ack-6000-v1 | 64.22 | 68.00 | 54.89 | 2.07/4.7 | 44773 | 5039 | 129.0/54.7 | 1.521/6.407 | 0.089 | +0.22 [-0.73, +1.18] |
| ood / festival_crowd / duty | baseline-v1 | 64.00 | 67.78 | 54.22 | 2.09/4.3 | 44939 | 3676 | 132.0/58.3 | 1.439/6.739 | 0.082 | +0.00 [+0.00, +0.00] |
| ood / festival_crowd / duty | community-carrier-v1 | 64.00 | 67.78 | 54.22 | 2.09/4.3 | 44939 | 3676 | 132.0/58.3 | 1.439/6.739 | 0.082 | +0.00 [+0.00, +0.00] |
| ood / festival_crowd / duty | route-flood-v1 | 64.22 | 68.22 | 54.44 | 2.11/4.7 | 109633 | 2421 | 123.3/56.7 | 1.428/6.517 | 0.102 | +0.22 [-2.31, +2.75] |
| ood / festival_crowd / duty | super-carrier-v1 | 64.89 | 68.00 | 54.67 | 2.08/4.7 | 45653 | 4779 | 133.0/57.3 | 1.435/6.465 | 0.067 | +0.89 [-1.02, +2.80] |
| ood / campus_quad / always | ack-2000-v1 | 82.89 | 83.33 | 75.78 | 1.90/3.7 | 3489 | 18744 | 215.3/84.7 | 2.637/6.481 | 0.185 | -3.11 [-9.80, +3.58] |
| ood / campus_quad / always | ack-6000-v1 | 86.00 | 86.67 | 77.78 | 1.95/4.0 | 3449 | 31105 | 173.0/60.0 | 2.645/6.189 | 0.090 | +0.00 [-4.97, +4.97] |
| ood / campus_quad / always | baseline-v1 | 86.00 | 86.44 | 77.33 | 1.96/3.7 | 3719 | 27184 | 201.3/74.7 | 2.820/4.706 | 0.167 | +0.00 [+0.00, +0.00] |
| ood / campus_quad / always | community-carrier-v1 | 84.67 | 84.89 | 75.33 | 1.95/4.0 | 3589 | 28305 | 200.0/72.0 | 2.612/5.841 | 0.137 | -1.33 [-8.55, +5.89] |
| ood / campus_quad / always | route-flood-v1 | 79.11 | 80.44 | 71.33 | 1.93/4.3 | 4090 | 33888 | 212.7/79.0 | 2.625/5.960 | 0.133 | -6.89 [-14.72, +0.94] |
| ood / campus_quad / always | super-carrier-v1 | 86.22 | 87.11 | 76.89 | 1.96/4.3 | 3801 | 27915 | 198.0/71.0 | 2.629/5.716 | 0.163 | +0.22 [-7.43, +7.87] |
| ood / campus_quad / duty | ack-2000-v1 | 87.56 | 88.22 | 80.67 | 1.95/4.0 | 3421 | 21248 | 206.7/81.7 | 1.214/5.957 | 0.142 | +5.78 [-7.61, +19.16] |
| ood / campus_quad / duty | ack-6000-v1 | 84.00 | 84.67 | 74.44 | 1.95/4.3 | 3778 | 33909 | 183.3/65.7 | 1.332/4.829 | 0.133 | +2.22 [-5.95, +10.39] |
| ood / campus_quad / duty | baseline-v1 | 81.78 | 82.89 | 73.56 | 1.93/4.0 | 3615 | 31513 | 202.7/71.7 | 1.223/5.906 | 0.146 | +0.00 [+0.00, +0.00] |
| ood / campus_quad / duty | community-carrier-v1 | 85.78 | 86.22 | 77.78 | 1.95/4.7 | 3751 | 27477 | 202.3/74.7 | 1.426/4.929 | 0.146 | +4.00 [-6.86, +14.86] |
| ood / campus_quad / duty | route-flood-v1 | 75.33 | 76.00 | 66.22 | 1.94/4.3 | 4170 | 32968 | 218.0/80.0 | 1.316/5.564 | 0.142 | -6.44 [-23.84, +10.95] |
| ood / campus_quad / duty | super-carrier-v1 | 82.67 | 83.11 | 74.44 | 1.92/4.0 | 3672 | 30161 | 207.7/77.0 | 1.410/6.698 | 0.133 | +0.89 [-15.70, +17.48] |

## Nondominated sets

Per context over mean five-hop delivery (maximize), relay transmissions, p95 latency and NORMAL energy (minimize). This exploratory Pareto set ignores worst-seed regressions; it is not permission to deploy.

* ('ood', 'festival_crowd', False): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('ood', 'festival_crowd', True): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, route-flood-v1, super-carrier-v1
* ('ood', 'campus_quad', False): ack-2000-v1, ack-6000-v1, baseline-v1, community-carrier-v1, super-carrier-v1
* ('ood', 'campus_quad', True): ack-2000-v1

## Promotion screen

* **ack-2000-v1: not-promoted** — no held-out validation; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **ack-6000-v1: not-promoted** — no held-out validation; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **community-carrier-v1: not-promoted** — no held-out validation; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **route-flood-v1: not-promoted** — no held-out validation; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.
* **super-carrier-v1: not-promoted** — no held-out validation; no positive seed-paired 95% interval in any validation context; authoritative Dart candidate/OOD/release gate verification required.

## Equal-context aggregate (never substitutes for per-scenario safety)

| Split | Strategy | Mean ≤5 % | Worst context % | Worst paired Δ pp | Mean Δ pp [95% seed-block CI] | Relay sum |
|---|---|---:|---:|---:|---|---:|
| ood | ack-2000-v1 | 74.56 | 63.33 | -4.67 | +1.06 [-3.17, +5.28] | 307267 |
| ood | ack-6000-v1 | 74.44 | 63.56 | -2.00 | +0.94 [-2.05, +3.94] | 290311 |
| ood | baseline-v1 | 73.50 | 62.22 | +0.00 | +0.00 [+0.00, +0.00] | 291008 |
| ood | community-carrier-v1 | 74.17 | 62.22 | -4.67 | +0.67 [-3.54, +4.87] | 291026 |
| ood | route-flood-v1 | 70.56 | 63.56 | -13.33 | -2.94 [-7.17, +1.28] | 688120 |
| ood | super-carrier-v1 | 74.00 | 62.22 | -6.67 | +0.50 [-3.04, +4.04] | 294803 |
