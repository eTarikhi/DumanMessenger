#!/usr/bin/env python3
"""Freeze/evaluate source-local diagnostic logistic model. Never chooses a routing policy."""
import gzip,hashlib,json,math,statistics,sys,time
from pathlib import Path
from reliability_ml import evaluate,sigmoid
ROOT=Path(sys.argv[1]);mode=sys.argv[2]
KEYS=['duty','elapsed','peers','queue','battery','super','hasRoute','hops','tq','age']
def load():
 path=ROOT/'experiments.json';data=json.loads(path.read_text() if path.exists() else gzip.decompress((ROOT/'experiments.json.gz').read_bytes()))
 return data

def dataset(rows):
 result=[]
 for r in rows:
  if r['profile']!='baseline':continue
  for m in r['messages']:
   if set(m['features'])!=set(KEYS) or not all(math.isfinite(m['features'][k]) for k in KEYS):raise ValueError('Missing/invalid source snapshot')
   result.append(([1]+[m['features'][k] for k in KEYS],int(m['outcome']!='five-hop-delivery'),f"{r['scenario']}/{r['seed']}/{r['duty']}"))
 return result
rows=load()['rows'];model_path=ROOT/'local-feature-model.json'
if mode=='freeze':
 if any(r['split']=='final' for r in rows):raise ValueError('Final already opened; refusing fit')
 if model_path.exists():raise ValueError('Model frozen already; do not overwrite')
 train=dataset([r for r in rows if r['split']=='development' and r['seed']==4301]);val=dataset([r for r in rows if r['split']=='development' and r['seed']==4302])
 assert len(train)==300 and len(val)==300
 start=time.perf_counter();weights=[0.]*(1+len(KEYS))
 for _ in range(600):
  grad=[0.]*len(weights)
  for x,y,world in train:
   err=sigmoid(sum(a*b for a,b in zip(weights,x)))-y
   for j in range(len(weights)):grad[j]+=err*x[j]/len(train)
  weights=[w-.5*(g+(.01*w if j else 0)) for j,(w,g) in enumerate(zip(weights,grad))]
 prior=statistics.mean(y for x,y,w in train);pred=lambda x:sigmoid(sum(a*b for a,b in zip(weights,x)))
 metrics={'logistic':evaluate(val,pred),'constant':evaluate(val,lambda x:prior)}
 selected=min(metrics,key=lambda n:(metrics[n]['brier'],n))
 artifact={'schema':1,'purpose':'offline supervised failure prediction, NOT policy value','liveEligible':False,'featureKeys':KEYS,'weights':weights,'constant':prior,'selectedByValidationBrier':selected,'threshold':.5,'L2':.01,'iterations':600,'trainSeeds':[4301],'validationSeeds':[4302],'untouchedFinalSeeds':[7401,7402,7403,7404],'developmentHash':hashlib.sha256(json.dumps([r for r in rows if r['split']=='development'],sort_keys=True).encode()).hexdigest(),'validation':metrics,'trainingSeconds':time.perf_counter()-start,'preprocessing':'intercept; fixed ranges in runner: peers/128 queue/500 hops/6 age clipped30s elapsed/225s, others unit range; missing route indicator with zeros','limitations':['Only two worlds/train and validation, no robust calibration guarantee','All features observed before send, no future outcomes or diagnostic tags as input','Source route may not describe actual forwarding path; TQ not ETX','Predicted failure is not measured treatment benefit; no strategy switching justified']}
 model_path.write_text(json.dumps(artifact,indent=2,allow_nan=False)+'\n');print(selected,metrics)
elif mode=='evaluate':
 model=json.loads(model_path.read_text());predict=lambda x:sigmoid(sum(a*b for a,b in zip(model['weights'],x))) if model['selectedByValidationBrier']=='logistic' else model['constant']
 out=[]
 for split,scenario,duty in sorted(set((r['split'],r['scenario'],r['duty']) for r in rows if r['split'] in ['final','protected'])):
  data=dataset([r for r in rows if (r['split'],r['scenario'],r['duty'])==(split,scenario,duty)])
  out.append({'split':split,'scenario':scenario,'duty':duty,'selectedModel':evaluate(data,predict),'constantBaseline':evaluate(data,lambda x:model['constant'])})
 sample=dataset([r for r in rows if r['split']=='final'])[:1];start=time.perf_counter()
 for _ in range(10000):predict(sample[0][0])
 (ROOT/'local-ml-evaluation.json').write_text(json.dumps({'modelSha256':hashlib.sha256(model_path.read_bytes()).hexdigest(),'groups':out,'localPythonScoreMicroseconds':(time.perf_counter()-start)*100,'costCaveat':'Python sandbox scalar scores, not phone/Dart loading/inference/memory benchmark'},indent=2)+'\n')
else:raise ValueError('unknown mode')
