#!/usr/bin/env python3
"""Descriptive analysis only: no fitting, ranking or modifying policies."""
import csv, gzip, hashlib, json, math, statistics, sys
from collections import Counter
from pathlib import Path
root=Path(sys.argv[1] if len(sys.argv)>1 else 'reports/routing/2026-10-29-diagnosis')
baseline=json.loads((root/'baseline.json').read_text())
experiment=json.loads(gzip.decompress((root/'experiments.json.gz').read_bytes()) if (root/'experiments.json.gz').exists() else (root/'experiments.json').read_text())
assert len(baseline['rows'])==12 and len(experiment['rows'])==64
for data in [baseline,experiment]:
 for path,digest in data['sourceHashes'].items():
  assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest, path
 assert all(r['diagnosticOverflow']==0 for r in data['rows'])
assert all(r['priorFullStatsMatch'] for r in baseline['rows'])
def ci(values):
 n=len(values);mean=statistics.mean(values)
 if n<2:return [None,None]
 critical={2:12.7062047364,6:2.57058183564}[n]
 half=critical*statistics.stdev(values)/math.sqrt(n)
 return [mean-half,mean+half]
def label(m):
 tags=(m['observations'] or {}).get('counts',{})
 if not m['optimisticTemporalContactReachable']:return 'no-ideal-temporal-contact'
 if m['outcome']=='delivered-over-five':return 'first-delivery-over-five'
 for tag in ['route-reverse-to-sender','ttl-exhausted','mpr-physical-coverage-gap','source-retries-exhausted','radio-link-loss']:
  if tag in tags:return 'observed-'+tag+'-causality-unresolved'
 return 'unknown'
diagnosis=[]
for r in baseline['rows']:
 tags=Counter();classification=Counter()
 for m in r['failed']:
  m['strongestEvidence']=label(m);classification[m['strongestEvidence']]+=1
  tags.update((m['observations'] or {}).get('counts',{}).keys())
 diagnosis.append({k:r[k] for k in ['scenario','seed','duty','sent','five','overall','optimisticReachable']}|{'strongestEvidenceCounts':dict(classification),'overlappingMessageTagCounts':dict(tags),'messages':r['failed']})
(root/'failure-evidence.json').write_text(json.dumps(diagnosis,indent=2)+'\n')
rows=experiment['rows'];pairs=[]
for a in rows:
 if a['profile']!='baseline':continue
 b=next(r for r in rows if r['profile']=='ogm-epoch-v1' and all(r[k]==a[k] for k in ['split','scenario','seed','duty']))
 assert a['configHash']==b['configHash']
 p={k:a[k] for k in ['split','scenario','seed','duty']}
 for k in ['five','three','overall','relayTx','totalTx','p50','p95','modeledBatteryDrain','queueAtHorizon']:
  p[k+'Baseline']=a[k];p[k+'Candidate']=b[k];p[k+'Delta']=b[k]-a[k] if a[k] is not None and b[k] is not None else None
 for k in ['retriesSent','retriesExhausted','routeExpiries','totalQueued','channelDrops','rateRelayDrops','roleChangesPerNodeMin','wakeLockMs','lostTransmissions','controlOverhead','lostOgmTransmissions','radioDemandRatio']:
  p[k+'Baseline']=a['stats'][k];p[k+'Candidate']=b['stats'][k];p[k+'Delta']=b['stats'][k]-a['stats'][k]
 for suffix,r in [('Baseline',a),('Candidate',b)]:p['dataPlusOgmLinkAttemptsProxy'+suffix]=r['totalTx']+r['stats']['controlOverhead']
 p['dataPlusOgmLinkAttemptsProxyDelta']=p['dataPlusOgmLinkAttemptsProxyCandidate']-p['dataPlusOgmLinkAttemptsProxyBaseline']
 pairs.append(p)
with (root/'paired-per-seed.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=pairs[0].keys());writer.writeheader();writer.writerows(pairs)
groups=[]
for split,scenario,duty in sorted(set((p['split'],p['scenario'],p['duty']) for p in pairs)):
 ps=[p for p in pairs if (p['split'],p['scenario'],p['duty'])==(split,scenario,duty)]
 g={'split':split,'scenario':scenario,'duty':duty,'nSeeds':len(ps),'seeds':[p['seed'] for p in ps]}
 for metric in ['five','three','overall','relayTx','totalTx','p50','p95','modeledBatteryDrain','queueAtHorizon','retriesSent','retriesExhausted','routeExpiries','totalQueued','channelDrops','rateRelayDrops','roleChangesPerNodeMin','wakeLockMs','lostTransmissions','controlOverhead','lostOgmTransmissions','radioDemandRatio','dataPlusOgmLinkAttemptsProxy']:
  valid=[p for p in ps if p[metric+'Delta'] is not None]
  if len(valid)!=len(ps):g[metric]={'unavailableSeeds':len(ps)-len(valid)};continue
  values=[p[metric+'Delta'] for p in valid]
  g[metric]={'baselineMean':statistics.mean(p[metric+'Baseline'] for p in valid),'candidateMean':statistics.mean(p[metric+'Candidate'] for p in valid),'pairedDeltaMean':statistics.mean(values),'paired95TInterval':ci(values),'maxCandidateBaselineRatio':max(p[metric+'Candidate']/p[metric+'Baseline'] if p[metric+'Baseline'] else (1 if p[metric+'Candidate']==0 else math.inf) for p in valid)}
 g['baselineFiveDistribution']=[p['fiveBaseline']/150 for p in ps]
 g['candidateFiveDistribution']=[p['fiveCandidate']/150 for p in ps]
 g['candidateSeedsStrictlyAbove90']=sum(x>.9 for x in g['candidateFiveDistribution'])
 g['worstFivePairedDelta']=min(p['fiveDelta']/150 for p in ps)
 g['meanFiveGatePass']=g['five']['candidateMean']/150>.9
 g['allSeedsFiveGatePass']=g['candidateSeedsStrictlyAbove90']==len(ps)
 g['benefitGatePass']=g['five']['paired95TInterval'][0]>0
 g['resourceScreenPass']=g['totalTx']['maxCandidateBaselineRatio']<=1.05 and g['modeledBatteryDrain']['maxCandidateBaselineRatio']<=1.05 and (g['p95'].get('maxCandidateBaselineRatio',math.inf)<=1.1)
 g['protectedNoRegressionPass']=all(p['fiveDelta']>=0 for p in ps)
 groups.append(g)
summary={'groups':groups,'primaryTargetMet':all(g['meanFiveGatePass'] and g['allSeedsFiveGatePass'] for g in groups if g['split']=='final'),'protectedScreenPass':all(g['protectedNoRegressionPass'] and g['resourceScreenPass'] for g in groups if g['split']=='protected'),'targetMet':all(g['meanFiveGatePass'] and g['allSeedsFiveGatePass'] and g['benefitGatePass'] and g['resourceScreenPass'] for g in groups if g['split']=='final') and all(g['protectedNoRegressionPass'] and g['resourceScreenPass'] for g in groups if g['split']=='protected'),'promotion':'rejected-offline-only','DartCandidateValidation':'not implemented; disabled TS-only research profile','expiryObservation':'7-day bundle expiry cannot occur in this 225-second traffic window; routeExpiries are not bundle expiry','inferenceCost':'not applicable: no learner/model; one extra fixed route-epoch comparison per OGM','uncertainty':'seed paired t intervals; n2 protected/dev/validation and n6 final; no simultaneous or exact coverage guarantee; packets not independent'}
def standard_json(v):
 if isinstance(v,float) and not math.isfinite(v):return 'unbounded'
 if isinstance(v,dict):return {k:standard_json(x) for k,x in v.items()}
 if isinstance(v,list):return [standard_json(x) for x in v]
 return v
(root/'summary.json').write_text(json.dumps(standard_json(summary),indent=2,allow_nan=False)+'\n')
for g in groups:print(g['split'],g['scenario'],g['duty'],g['five'],g['candidateSeedsStrictlyAbove90'])
