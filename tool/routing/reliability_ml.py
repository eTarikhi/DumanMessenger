#!/usr/bin/env python3
"""Dependency-free offline diagnostic models. NO routing actuation or future-event features."""
import gzip, hashlib, json, math, statistics, sys
from pathlib import Path
OUT=Path(sys.argv[1] if len(sys.argv)>1 else 'reports/routing/2026-10-29-reliability');OUT.mkdir(parents=True,exist_ok=True)
DATA=Path('reports/routing/2026-10-29-diagnosis/experiments.json.gz')
def sigmoid(z):return 1/(1+math.exp(-max(-30,min(30,z))))
def features(r,m):
 # Elapsed traffic age is observable in this benchmark, not the future horizon.
 return [1,float(r['duty']),(m['at']-r['config']['warmupMs'])/225000]+[float(r['scenario']==s) for s in ['campus_quad','sparse_village','partitioned_pair']]
def records(rows):
 return [(features(r,m),int(m['outcome']!='five-hop-delivery'),f"{r['scenario']}/{r['seed']}/{r['duty']}") for r in rows if r['profile']=='baseline' for m in r['messages']]
def evaluate(data,predict):
 ys=[y for x,y,w in data];ps=[predict(x) for x,y,w in data];tp=sum(y==1 and p>=.5 for y,p in zip(ys,ps));fp=sum(y==0 and p>=.5 for y,p in zip(ys,ps));fn=sum(y==1 and p<.5 for y,p in zip(ys,ps));tn=len(ys)-tp-fp-fn
 bins=[]
 for i in range(5):
  ix=[j for j,p in enumerate(ps) if min(4,int(p*5))==i]
  if ix:bins.append({'bin':[i/5,(i+1)/5],'n':len(ix),'predicted':statistics.mean(ps[j] for j in ix),'observed':statistics.mean(ys[j] for j in ix)})
 pos=sum(ys);neg=len(ys)-pos;rank_sum=0;ordered=sorted(zip(ps,ys));a=0
 while a<len(ordered):
  b=a+1
  while b<len(ordered) and ordered[b][0]==ordered[a][0]:b+=1
  rank_sum+=sum(y for p,y in ordered[a:b])*((a+1+b)/2);a=b
 auc=(rank_sum-pos*(pos+1)/2)/(pos*neg) if pos and neg else None
 return {'n':len(ys),'worlds':len(set(w for x,y,w in data)),'failurePrevalence':pos/len(ys),'tp':tp,'fp':fp,'fn':fn,'tn':tn,'precision':tp/(tp+fp) if tp+fp else None,'recall':tp/(tp+fn) if tp+fn else None,'accuracy':(tp+tn)/len(ys),'brier':statistics.mean((p-y)**2 for p,y in zip(ps,ys)),'logLoss':statistics.mean(-y*math.log(max(1e-12,p))-(1-y)*math.log(max(1e-12,1-p)) for p,y in zip(ps,ys)),'auc':auc,'calibration':bins,'ece':sum(b['n']*abs(b['predicted']-b['observed']) for b in bins)/len(ys)}
def main():
 data=json.loads(gzip.decompress(DATA.read_bytes()));rows=data['rows']
 train=records([r for r in rows if r['seed'] in [4301,4302,6301]])
 val=records([r for r in rows if r['seed'] in [4303,4304]])
 audit=records([r for r in rows if r['seed'] in list(range(5301,5307))+[6302]])
 prior=statistics.mean(y for x,y,w in train);weights=[0.0]*6
 for epoch in range(600):
  grad=[0.0]*6
  for x,y,w in train:
   err=sigmoid(sum(a*b for a,b in zip(weights,x)))-y
   for j in range(6):grad[j]+=err*x[j]/len(train)
  weights=[w-.5*(g+(.002*w if j else 0)) for j,(w,g) in enumerate(zip(weights,grad))]
 # Bounded depth-one tree, choose split using train squared error only.
 stumps=[]
 for j in range(1,6):
  for threshold in ([.25,.5,.75] if j==2 else [.5]):
   bins=[[y for x,y,w in train if (x[j]>threshold)==b] for b in [False,True]]
   if all(bins):
    means=[statistics.mean(v) for v in bins];loss=statistics.mean((means[int(x[j]>threshold)]-y)**2 for x,y,w in train);stumps.append((loss,j,threshold,means))
 _,j,t,means=min(stumps)
 predictors={'constant':lambda x:prior,'logistic':lambda x:sigmoid(sum(a*b for a,b in zip(weights,x))),'stump':lambda x:means[int(x[j]>t)]}
 validation={name:evaluate(val,p) for name,p in predictors.items()};selected=min(validation,key=lambda n:(validation[n]['brier'],n))
 artifact={'schema':1,'purpose':'offline failure association only; NOT a routing selector','liveEligible':False,'dataSha256':hashlib.sha256(DATA.read_bytes()).hexdigest(),'features':['intercept','duty flag','elapsed traffic time /225000 ms','campus indicator','sparse indicator','partition indicator'],'missingContract':'all required; reject incomplete rows; no imputation','excluded':['eventual hops','delivery/latency','post-send diagnostic tags','retries/exhaustion','horizon/contact oracle','identity/seed'],'trainSeeds':[4301,4302,6301],'validationSeeds':[4303,4304],'exposedAuditSeeds':list(range(5301,5307))+[6302],'futureUntouchedBaselineSeeds':[7401,7402,7403,7404],'logisticWeights':weights,'logisticL2':.002,'gradientIterations':600,'constant':prior,'stump':{'feature':j,'threshold':t,'probabilities':means},'selectedByValidationBrier':selected,'validation':validation,'exposedAudit':{n:evaluate(audit,p) for n,p in predictors.items()},'limitations':['No pre-send topology/link/queue features retained in old records; no invented reconstruction.','Elapsed-time association is benchmark-specific, not a deployed signal schema.','6301/6302 provide only one seed per protected training/test context.','Seed groups disjoint; within-world packets dependent; no IID packet CIs.','Failure prediction is not policy value or causation. No SHAP, survival hazards or deep learner justified.']}
 (OUT/'diagnostic-model.json').write_text(json.dumps(artifact,indent=2,allow_nan=False)+'\n')
 # Seed-level error/calibration avoids hiding protected contexts in aggregate.
 per=[]
 for world in sorted(set(w for x,y,w in audit)):
  subset=[r for r in audit if r[2]==world];per.append({'world':world,**evaluate(subset,predictors[selected])})
 (OUT/'ml-per-world.json').write_text(json.dumps(per,indent=2)+'\n')
 print('selected',selected,'validation',validation[selected],'audit',artifact['exposedAudit'][selected])
if __name__=='__main__':main()
