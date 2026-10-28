#!/usr/bin/env python3
"""Render compact, reviewable tables from retained evidence, with no ranking by a hidden reward."""
import json
import sys
from pathlib import Path

summary = json.loads(Path(sys.argv[1]).read_text())
print('# Routing benchmark summary\n')
print('Generated from `' + sys.argv[1] + '`. Raw per-seed counts, configs and full stats accompany this table.\n')
print('Intervals are unadjusted seed-paired 95% t intervals, n=3. All strategies remain unpromoted.\n')
print('| Split / scenario / power | Strategy | ≤5 % | Delivery % | ≤3 % | Mean/p95 hops | Relays | p95 ms | Retry/exhausted | NORMAL/SUPER %/h | Flap/node/min | Δ≤5 pp [95% CI] |')
print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
for s in summary['summaries']:
    m, st = s['metrics'], s['stats']
    ci = s['deltaFiveCI95']
    interval = 'not estimated' if ci is None else f'{100*ci[0]:+.2f}, {100*ci[1]:+.2f}'
    print(f"| {s['split']} / {s['scenario']} / {'duty' if s['duty'] else 'always'} | {s['strategy']} | "
          f"{100*m['fiveRatio']:.2f} | {100*m['deliveryRatio']:.2f} | {100*m['threeRatio']:.2f} | "
          f"{m['hopsMean']:.2f}/{m['hopsP95']:.1f} | {st['totalForwarded']:.0f} | {m['latencyP95Ms']:.0f} | "
          f"{st['retriesSent']:.1f}/{st['retriesExhausted']:.1f} | "
          f"{st['batteryPercentPerHourNormal']:.3f}/{st['batteryPercentPerHourSuper']:.3f} | "
          f"{st['roleChangesPerNodeMin']:.3f} | {100*s['deltaFiveMean']:+.2f} [{interval}] |")
print('\n## Nondominated sets\n')
print('Per context over mean five-hop delivery (maximize), relay transmissions, p95 latency and NORMAL energy (minimize). This exploratory Pareto set ignores worst-seed regressions; it is not permission to deploy.\n')
groups = {}
for s in summary['summaries']:
    groups.setdefault((s['split'], s['scenario'], s['duty']), []).append(s)
for key, arms in groups.items():
    def vector(s):
        return [-s['metrics']['fiveRatio'], s['stats']['totalForwarded'],
                s['metrics']['latencyP95Ms'] or 0, s['stats']['batteryPercentPerHourNormal']]
    def dominates(a, b):
        av, bv = vector(a), vector(b)
        return all(x <= y for x, y in zip(av, bv)) and any(x < y for x, y in zip(av, bv))
    front = [s['strategy'] for s in arms if not any(dominates(a, s) for a in arms)]
    print(f"* {key}: " + ', '.join(front))
print('\n## Promotion screen\n')
for d in summary['decisions']:
    print(f"* **{d['strategy']}: {d['status']}** — " + '; '.join(d['reasons']) + '.')
