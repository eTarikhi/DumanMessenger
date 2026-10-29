#!/usr/bin/env python3
"""Frozen seed-paired descriptive analysis. No policy fitting or parameter selection."""
import csv,gzip,hashlib,json,math,statistics,subprocess,sys
from collections import Counter
from pathlib import Path
ROOT=Path(sys.argv[1]);p=ROOT/'experiments.json'
data=json.loads(p.read_text() if p.exists() else gzip.decompress((ROOT/'experiments.json.gz').read_bytes()))
rows=data['rows'];assert len(rows)==70,len(rows)
for file,digest in data['sourceHashes'].items():assert hashlib.sha256(Path(file).read_bytes()).hexdigest()==digest,file
assert all(r['diagnosticOverflow']==0 and r['sent']==150 for r in rows)
assert len([r for r in rows if r['split']=='audit'])==12
assert all(r['priorStatsMatch'] for r in rows if r['split']=='audit')
METRICS=['five','three','overall','totalTx','relayTx','p50','p95','modeledBatteryDrain','queueAtHorizon','jainTx','maxTxShare','avgLatencyMs','retriesSent','retriesExhausted','routeExpiries','totalQueued','channelDrops','rateRelayDrops','roleChangesPerNodeMin','wakeLockMs','lostTransmissions','controlOverhead','radioDemandRatio']
def metric(r,k):return r.get(k,r['stats'].get(k))
def interval(v):
 if len(v)<2:return None
 crit={2:12.7062047364,4:3.18244630528}[len(v)];mean=statistics.mean(v);h=crit*statistics.stdev(v)/math.sqrt(len(v));return [mean-h,mean+h]
def ratio(a,b):return b/a if a else (1 if not b else math.inf)
def tags(r):return Counter(k for m in r['messages'] for k in (m['observations'] or {}).get('counts',{}))
groups=[];pairs=[];points=[]
for split,scenario,duty in sorted(set((r['split'],r['scenario'],r['duty']) for r in rows if r['split']!='audit')):
 rs=[r for r in rows if (r['split'],r['scenario'],r['duty'])==(split,scenario,duty)]
 points_here=[]
 for profile in sorted(set(r['profile'] for r in rs)):
  selected=[r for r in rs if r['profile']==profile]
  point={'split':split,'scenario':scenario,'duty':duty,'profile':profile,'seeds':[r['seed'] for r in selected],'fiveRatio':sum(r['five'] for r in selected)/sum(r['sent'] for r in selected),'seedsAbove90':sum(r['five']/r['sent']>.9 for r in selected),'worstFiveRatio':min(r['five']/r['sent'] for r in selected),'means':{k:statistics.mean(v) if (v:=[metric(r,k) for r in selected if metric(r,k) is not None]) else None for k in METRICS},'firstArrivalHopHistogram':dict(Counter(m['delivery']['hops'] for r in selected for m in r['messages'] if m['delivery'])),'overlappingMessageTags':dict(sum((tags(r) for r in selected),Counter()))}
  points_here.append(point)
  if profile=='baseline':continue
  deltas={k:[] for k in METRICS};ratios={k:[] for k in METRICS};dist=[]
  for r in selected:
   base=next(b for b in rs if b['seed']==r['seed'] and b['profile']=='baseline');assert r['configHash']==base['configHash']
   assert sum((m['observations'] or {}).get('counts',{}).get('source-backup',0) for m in r['messages'])<=r['sent']
   pair={k:r[k] for k in ['split','scenario','seed','duty','profile']}
   for k in METRICS:
    a,b=metric(base,k),metric(r,k);pair[k+'Baseline']=a;pair[k+'Candidate']=b;pair[k+'Delta']=None if a is None or b is None else b-a
    if pair[k+'Delta'] is not None:deltas[k].append(b-a);ratios[k].append(ratio(a,b))
   pairs.append(pair);dist.append(r['five']/r['sent'])
  stats={k:{'pairedMeanDelta':statistics.mean(v) if v else None,'paired95TInterval':interval(v) if len(v) in [2,4] else None,'availablePairs':len(v),'maxRatio':max(ratios[k]) if ratios[k] else None} for k,v in deltas.items()}
  g={'split':split,'scenario':scenario,'duty':duty,'profile':profile,'nSeeds':len(selected),'seeds':[r['seed'] for r in selected],'fiveDistribution':dist,'fiveMean':statistics.mean(dist),'seedsAbove90':sum(x>.9 for x in dist),'worstPairedFiveDelta':min(deltas['five'])/150,'metrics':stats}
  g['primaryTargetPass']=g['fiveMean']>.9 and g['seedsAbove90']==len(selected)
  ci=stats['five']['paired95TInterval'];g['benefitPass']=ci is not None and ci[0]>0
  g['resourcePass']=all(stats[k]['maxRatio'] is not None and stats[k]['maxRatio']<=v for k,v in [('totalTx',1.05),('modeledBatteryDrain',1.05),('p95',1.10)])
  g['noRegressionPass']=g['worstPairedFiveDelta']>=0
  if profile=='source-backup-v1' and split in ['development','final','protected']:
   against=[r['five']-next(b['five'] for b in rs if b['seed']==r['seed'] and b['profile']=='ogm-epoch-v1') for r in selected]
   g['vsEpochFiveDeltas']=against;g['vsEpoch95TInterval']=interval(against) if len(against)>1 else None
  groups.append(g)
 # Descriptive mean Pareto, not statistical dominance nor gate waiver.
 for point in points_here:
  vector=lambda p:[p['fiveRatio'],-p['means']['totalTx'],-p['means']['p95'] if p['means']['p95'] is not None else -math.inf,-p['means']['modeledBatteryDrain']]
  x=vector(point);point['meanParetoEfficient']=not any(all(a>=b for a,b in zip(vector(o),x)) and any(a>b for a,b in zip(vector(o),x)) for o in points_here if o is not point)
 points+=points_here
with (ROOT/'paired-per-seed.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=pairs[0].keys());writer.writeheader();writer.writerows(pairs)
final=[g for g in groups if g['split']=='final' and g['profile']=='source-backup-v1']
protected=[g for g in groups if g['split']=='protected' and g['profile']=='source-backup-v1']
passed=all(g['primaryTargetPass'] and g['benefitPass'] and g['resourcePass'] and min(g['vsEpochFiveDeltas'])>=0 for g in final) and all(g['noRegressionPass'] and g['resourcePass'] for g in protected)
summary={'groups':groups,'points':points,'screenPass':passed,'productionApproved':False,'decision':'offline-only; owner approval and Dart candidate parity absent','counterSemantics':'totalTx is existing data/ACK/cover counter, excludes OGM broadcasts; controlOverhead counts per-neighbor OGM attempts, not physical broadcast equivalence','uncertainty':'seed pairs, t df3 final/n4; n1 protected sentinel no CI; means Pareto descriptive only; RF/jitter not packet-paired','missingMetrics':['true end-to-end path diversity/cut vertices','route stretch against contemporaneous optimal schedule','directional end-to-end ETX','measured phone airtime/energy/CPU','per-message queue eviction and all-copy terminal cause']}
def clean(v):
 if isinstance(v,float) and not math.isfinite(v):return 'unbounded'
 if isinstance(v,dict):return {k:clean(x) for k,x in v.items()}
 if isinstance(v,list):return [clean(x) for x in v]
 return v
(ROOT/'summary.json').write_text(json.dumps(clean(summary),indent=2,allow_nan=False)+'\n')
for g in final:print(g['duty'],g['fiveDistribution'],g['metrics']['five'],g['resourcePass'])
