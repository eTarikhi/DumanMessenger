#!/usr/bin/env python3
"""Analyze a frozen finite search, not an adaptive significance-stopping rule."""
import csv
import hashlib
import json
import statistics as st
import sys
from pathlib import Path

root=Path(sys.argv[1])
data=json.loads((root/'runs.json').read_text())
raw=(root/'policy.json').read_bytes()
assert hashlib.sha256(raw).hexdigest()==(root/'policy.sha256').read_text().strip()
policy=json.loads(raw)
rows=data['rows'];base=policy['baseline']

def selected(duty):return policy['selected'][int(duty)]

def block(split,scenario,duty):
    contexts=[r for r in rows if r['split']==split and r['scenario']==scenario and r['duty']==duty]
    baseline={r['seed']:r for r in contexts if r['policy']==base}
    candidates=[r for r in contexts if r['policy']==selected(duty)]
    deltas=[r['ratio']-baseline[r['seed']]['ratio'] for r in candidates]
    if not deltas:return None
    mean=st.mean(deltas)
    half=4.30265273*st.stdev(deltas)/len(deltas)**.5 if len(deltas)==3 else None
    metrics=['totalForwarded','controlOverhead','retriesSent','retriesExhausted','totalQueued',
             'batteryPercentPerHourNormal','batteryPercentPerHourSuper','roleChangesPerNodeMin','radioDemandRatio']
    return dict(split=split,scenario=scenario,duty=duty,n=len(deltas),
        baselineFive=st.mean(r['ratio'] for r in baseline.values()),five=st.mean(r['ratio'] for r in candidates),
        worstFive=min(r['ratio'] for r in candidates),delta=mean,worstPairedDelta=min(deltas),
        deltaCI95=None if half is None else [mean-half,mean+half],
        overall=st.mean(r['delivered']/r['sent'] for r in candidates),three=st.mean(r['three']/r['sent'] for r in candidates),
        p95=st.mean(r['p95'] for r in candidates if r['p95'] is not None),
        p95DeltaMax=max((r['p95'] or 0)-(baseline[r['seed']]['p95'] or 0) for r in candidates),
        totalTxRatioMax=max(r['totalTx']/max(1,baseline[r['seed']]['totalTx']) for r in candidates),
        stats={m:dict(mean=st.mean(r['stats'][m] for r in candidates),
                      maxPairedIncrease=max(r['stats'][m]-baseline[r['seed']]['stats'][m] for r in candidates)) for m in metrics})

summaries=[]
for split in ['validation','holdout','protected']:
    scenarios=sorted({r['scenario'] for r in rows if r['split']==split})
    for scenario in scenarios:
        for duty in [False,True]:
            b=block(split,scenario,duty)
            if b:summaries.append(b)
final=[r for r in summaries if r['split']=='holdout']
reasons=[]
if len(final)!=2 or any(r['n']!=3 for r in final):reasons.append('final evaluation incomplete')
if any(r['worstFive']<=.90 for r in final):reasons.append('not strictly above 90% on every final seed/power context')
if any(r['deltaCI95'] is None or r['deltaCI95'][0]<=0 for r in final):reasons.append('positive seed-paired improvement lower bound not established')
if any(r['worstPairedDelta']<0 for r in summaries):reasons.append('a held-out/protected context regresses')
if any(r['totalTxRatioMax']>1+1e-12 or r['p95DeltaMax']>1e-9 or
       any(r['stats'][m]['maxPairedIncrease']>1e-12 for m in ['totalForwarded','batteryPercentPerHourNormal','batteryPercentPerHourSuper']) for r in summaries):
    reasons.append('resource or latency increase requires review, not a free improvement')
reasons += ['owner-approved tolerances and release approval still absent','authoritative Dart evaluation of new profiles not completed']
result=dict(status='offline-only-not-promoted',policySHA256=hashlib.sha256(raw).hexdigest(),worlds=len(rows),
            targetMeasured=bool(final) and all(r['worstFive']>.90 for r in final),summaries=summaries,reasons=reasons)
(root/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
with (root/'per-seed.csv').open('w') as f:
    w=csv.writer(f);w.writerow(['split','scenario','seed','duty','beaconMs','ackMs','sent','five','ratio','overall','three',
                              'hopsMean','hopsP95','p95Ms','relays','controlTx','totalTx','retries','exhausted','undelivered','queued',
                              'normalPercentPerHour','superPercentPerHour','flaps','radioDemand'])
    for r in rows:
        s=r['stats'];w.writerow([r['split'],r['scenario'],r['seed'],r['duty'],r['policy']['beacon'],r['policy']['ack'],r['sent'],r['five'],r['ratio'],
            r['delivered']/r['sent'],r['three']/r['sent'],r['hopsMean'],r['hopsP95'],r['p95'],s['totalForwarded'],s['controlOverhead'],r['totalTx'],
            s['retriesSent'],s['retriesExhausted'],r['sent']-r['delivered'],s['totalQueued'],s['batteryPercentPerHourNormal'],
            s['batteryPercentPerHourSuper'],s['roleChangesPerNodeMin'],s['radioDemandRatio']])
print(json.dumps(result,indent=2))
