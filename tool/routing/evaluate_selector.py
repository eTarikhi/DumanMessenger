#!/usr/bin/env python3
"""Evaluate frozen artifact once; distinguish homogeneous worlds from label replay."""
import csv
import hashlib
import json
import statistics as st
import sys
from pathlib import Path
from train_selector import estimates

root=Path(sys.argv[1])
metadata=json.loads((root/'model/metadata.json').read_text())
model_raw=(root/'model/model.experimental.json').read_bytes()
assert hashlib.sha256(model_raw).hexdigest()==metadata['modelSHA256']
model=json.loads(model_raw)
main=json.loads((root/'targeted.json').read_text())
# Preserve raw original labels/hash but never pool the exposed 606 set into holdout.
for row in main['rows']:
    if row['seed']==606 and row['split']=='holdout': row['split']='exposed-audit'
final=json.loads((root/'final-holdout.json').read_text())
assert {r['seed'] for r in final['rows']}=={909}
replay=estimates(final['rows'],model,'holdout')
(root/'model/final-evaluation.json').write_text(json.dumps(dict(status='not-approved',
    modelSHA256=metadata['modelSHA256'],label='OFFLINE_LABEL_REPLAY_NOT_LIVE_MIXED_POLICY',
    holdoutSeed=909,seedLevelCI=None,reason='one independent seed; missing owner-approved tolerances',
    estimates=replay),indent=2)+'\n')
rows=main['rows']+final['rows']+json.loads((root/'exogenous.json').read_text())['rows']
with (root/'per-seed.csv').open('w') as f:
    writer=csv.writer(f)
    writer.writerow(['split','scenario','seed','duty','static','strategy','sent','five','fiveRatio','deliveryRatio',
                     'threeRatio','hopsMean','hopsP95','relays','totalTx','p95Ms','retries','exhausted',
                     'undelivered','queueCopies','roleChanges','normalPercentPerHour','superPercentPerHour',
                     'connectedShare','meanLargestComponent'])
    for r in rows:
        s=r['stats'];writer.writerow([r[k] for k in ['split','scenario','seed','duty','staticWorld','strategy','sent','five']]+
            [r['five']/r['sent'],r['delivered']/r['sent'],r['three']/r['sent'],r['hopsMean'],r['hopsP95'],
             s['totalForwarded'],r['totalTx'],r['p95'],s['retriesSent'],s['retriesExhausted'],r['undelivered'],
             r['queueCopies'],s['roleChangesPerNodeMin'],s['batteryPercentPerHourNormal'],s['batteryPercentPerHourSuper'],
             s['connectedSampleShare'],s['meanLargestComponent']])

summary=[]
for split in ['train','tune','validation','exposed-audit','holdout']:
    for duty in [False,True]:
        subset=[r for r in rows if r['split']==split and r['scenario']=='festival_crowd' and r['duty']==duty]
        baseline={r['seed']:r for r in subset if r['strategy']=='baseline-v1'}
        arm=[r for r in subset if r['strategy']=='ack-6000-v1']
        delta=[r['five']/r['sent']-baseline[r['seed']]['five']/baseline[r['seed']]['sent'] for r in arm]
        if not delta:continue
        mean=st.mean(delta)
        half=4.30265273*st.stdev(delta)/3**.5 if len(delta)==3 else None
        summary.append(dict(split=split,duty=duty,seeds=sorted(baseline),deltaMean=mean,
            worst=min(delta),ci95=None if half is None else [mean-half,mean+half],
            baselineRatio=st.mean(r['five']/r['sent'] for r in baseline.values()),
            candidateRatio=st.mean(r['five']/r['sent'] for r in arm)))
(root/'summary.json').write_text(json.dumps(dict(primary='actual homogeneous ACK-6000 vs baseline; five-hop ratio',
    crowd=summary,modelDecision='baseline-only learned stump; no promotion',
    warning='one-seed tune/validation/final sets cannot yield seed-level CIs; label replay is not deployed routing'),indent=2)+'\n')
print(json.dumps(summary,indent=2))

# Nondominated homogeneous policy pairs: five-hop maximize; relays/p95/energy minimize.
pareto=[]
for r in rows:
    if r['strategy']!='baseline-v1':continue
    candidate=next(c for c in rows if all(c[k]==r[k] for k in ['split','scenario','seed','duty','staticWorld']) and c['strategy']=='ack-6000-v1')
    arms=[r,candidate]
    def vector(x):return [-x['five']/x['sent'],x['stats']['totalForwarded'],x['p95'] or 0,x['stats']['batteryPercentPerHourNormal']]
    def dominates(a,b):
        av,bv=vector(a),vector(b)
        return all(x<=y for x,y in zip(av,bv)) and any(x<y for x,y in zip(av,bv))
    pareto.append(dict(context={k:r[k] for k in ['split','scenario','seed','duty','staticWorld']},
                       frontier=[x['strategy'] for x in arms if not any(dominates(y,x) for y in arms)]))
(root/'pareto.json').write_text(json.dumps(pareto,indent=2)+'\n')
