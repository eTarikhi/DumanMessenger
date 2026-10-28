#!/usr/bin/env python3
"""Seed-paired summaries. Student-t CIs concern seeds, NOT independent packets."""
import json
import sys
import statistics as st
from pathlib import Path


def summarize(data):
    rows = data['rows']
    groups = {}
    for r in rows:
        groups.setdefault((r['split'], r['scenario'], r['duty']), []).append(r)
    summaries = []
    metrics = ['fiveRatio', 'deliveryRatio', 'threeRatio', 'hopsMean', 'hopsP95',
               'latencyMeanMs', 'latencyP95Ms', 'totalTx', 'undeliveredAtHorizon']
    for (split, scenario, duty), group in groups.items():
        baseline = {r['seed']: r for r in group if r['strategy'] == 'baseline-v1'}
        for strategy in sorted({r['strategy'] for r in group}):
            arm = [r for r in group if r['strategy'] == strategy]
            deltas = [r['fiveRatio'] - baseline[r['seed']]['fiveRatio'] for r in arm]
            mean = st.mean(deltas)
            # Predeclared benchmark has 3 seeds per split (df=2). A smoke run has no CI.
            half = 4.30265273 * st.stdev(deltas) / len(deltas)**.5 if len(deltas) == 3 else None
            relays = [r['stats']['totalForwarded'] / max(1, baseline[r['seed']]['stats']['totalForwarded']) for r in arm]
            resources = ['batteryPercentPerHourNormal', 'batteryPercentPerHourSuper', 'roleChangesPerNodeMin']
            s = dict(split=split, scenario=scenario, duty=duty, strategy=strategy,
                     n=len(arm), deltaFiveMean=mean,
                     deltaFiveCI95=None if half is None else [mean-half, mean+half],
                     worstPairedFiveDelta=min(deltas), relayRatioMean=st.mean(relays),
                     relayRatioMax=max(relays),
                     latencyDeltaMax=max((r['latencyP95Ms'] or 0) - (baseline[r['seed']]['latencyP95Ms'] or 0) for r in arm),
                     energyDeltaMax=max(r['stats']['batteryPercentPerHourNormal'] - baseline[r['seed']]['stats']['batteryPercentPerHourNormal'] for r in arm),
                     stabilityDeltaMax=max(r['stats']['roleChangesPerNodeMin'] - baseline[r['seed']]['stats']['roleChangesPerNodeMin'] for r in arm),
                     metrics={m: st.mean(r[m] for r in arm if r[m] is not None)
                              if any(r[m] is not None for r in arm) else None for m in metrics},
                     stats={m: st.mean(r['stats'][m] for r in arm) for m in resources +
                            ['totalForwarded', 'retriesSent', 'retriesExhausted', 'totalQueued']})
            summaries.append(s)
    # Conservative promotion screen; these are NEW screening rules, not weakened release gates.
    decisions = []
    for strategy in sorted({r['strategy'] for r in rows} - {'baseline-v1'}):
        arm = [s for s in summaries if s['strategy'] == strategy and s['split'] == 'validation']
        reasons = []
        if not arm:
            reasons.append('no held-out validation')
        if any(s['worstPairedFiveDelta'] < -1e-12 for s in arm):
            reasons.append('five-hop regression on a held-out seed/context')
        if any(s['relayRatioMax'] > 1 + 1e-12 for s in arm):
            reasons.append('increased relay budget requires owner review')
        if any(s['energyDeltaMax'] > 1e-12 for s in arm):
            reasons.append('increased NORMAL energy estimate requires owner review')
        if any(s['latencyDeltaMax'] > 1e-9 for s in arm):
            reasons.append('increased p95 latency needs release-budget evaluation')
        if any(s['stabilityDeltaMax'] > 1e-12 for s in arm):
            reasons.append('role instability increased')
        if not arm or not any(s['deltaFiveCI95'] and s['deltaFiveCI95'][0] > 0 for s in arm):
            reasons.append('no positive seed-paired 95% interval in any validation context')
        # Never automatically approve: Dart, OOD, acceptance and battery verification are separate gates.
        reasons.append('authoritative Dart candidate/OOD/release gate verification required')
        decisions.append(dict(strategy=strategy, status='not-promoted', reasons=reasons))
    return dict(schemaVersion=1, sourceSha=data['sourceSha'], summaries=summaries, decisions=decisions,
                warning='Unadjusted seed-level t intervals; three seeds give low power. Not packet-level CIs. No deployment authorization.')


if __name__ == '__main__':
    data = json.loads(Path(sys.argv[1]).read_text())
    print(json.dumps(summarize(data), indent=2))
