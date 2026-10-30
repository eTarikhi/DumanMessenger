#!/usr/bin/env python3
"""Finite supervised policy fit. No validation/holdout selection; no deployment approval."""
import hashlib
import json
import sys
import subprocess
from pathlib import Path


def pairs(rows, split):
    base = {(r['scenario'],r['seed'],r['duty'],r['staticWorld']):r for r in rows
            if r['split']==split and r['strategy']=='baseline-v1'}
    for other in rows:
        if other['split']!=split or other['strategy']!='ack-6000-v1': continue
        b=base[(other['scenario'],other['seed'],other['duty'],other['staticWorld'])]
        for f, before, after in zip(b['features'],b['origins'],other['origins']):
            if before['sent'] != after['sent']: raise ValueError('Unmatched denominator')
            if before['sent']:
                yield dict(features=f,baseline=before['five'],candidate=after['five'],
                           sent=before['sent'],seed=b['seed'],scenario=b['scenario'],duty=b['duty'])


def fit(rows):
    data=list(pairs(rows,'train'))
    if not data: raise ValueError('No training data')
    choices=[]
    for threshold in [4,8,12,16,24]:
        leaves=[]
        for side in [True,False]:
            subset=[r for r in data if (r['features']['neighbors']<=threshold)==side and not r['duty']]
            gain=sum(r['candidate']-r['baseline'] for r in subset)
            leaves.append('ack-6000-v1' if gain>0 else 'baseline-v1')
        gain=sum(r['candidate']-r['baseline'] for r in data if not r['duty'] and
                 leaves[0 if r['features']['neighbors']<=threshold else 1]=='ack-6000-v1')
        choices.append((gain,-threshold,leaves))
    gain, negative_threshold, leaves=max(choices,key=lambda x:(x[0],x[1]))
    threshold=-negative_threshold
    # Seed agreement is only a rough confidence signal, NOT a calibrated probability.
    per_seed=[sum(r['candidate']-r['baseline'] for r in data if r['seed']==seed and not r['duty'] and
                  leaves[0 if r['features']['neighbors']<=threshold else 1]=='ack-6000-v1')
              for seed in sorted({r['seed'] for r in data})]
    return dict(schema=1,api=1,experimental=True,threshold=threshold,left=leaves[0],right=leaves[1],
                confidence=sum(v>0 for v in per_seed)/len(per_seed)),gain


def estimates(rows, model, split):
    data=list(pairs(rows,split))
    results={}
    for name in ['baseline','ack-6000','rules','learned']:
        blocks={}
        for r in data:
            use=(name=='ack-6000' or (name=='rules' and not r['duty'] and r['features']['neighbors']>=12) or
                 (name=='learned' and not r['duty'] and model['confidence']>=.6 and
                  model['left' if r['features']['neighbors']<=model['threshold'] else 'right']=='ack-6000-v1'))
            k=f"{r['seed']}/{r['scenario']}/duty={r['duty']}"
            v=blocks.setdefault(k,dict(sent=0,five=0,baseline=0))
            v['sent']+=r['sent'];v['baseline']+=r['baseline'];v['five']+=r['candidate'] if use else r['baseline']
        results[name]=blocks
    return results


def main():
    source=Path(sys.argv[1]);out=Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=True)
    raw=source.read_bytes(); dataset=json.loads(raw)
    model,gain=fit(dataset['rows'])
    encoded=(json.dumps(model,sort_keys=True,separators=(',',':'))+'\n').encode()
    model_path=out/'model.experimental.json'
    if model_path.exists() and model_path.read_bytes()!=encoded:
        raise ValueError('Refusing to replace a different frozen model; choose a new artifact directory')
    model_path.write_bytes(encoded)
    metadata=dict(status='shadow-only-not-approved',datasetSHA256=hashlib.sha256(raw).hexdigest(),
                  modelSHA256=hashlib.sha256(encoded).hexdigest(),sourceSha=dataset['sourceSha'],
                  trainingCodeSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  trainingGitRevision=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
                  api=1,featureSchema=1,features=['neighbors/128','duty (0 or 1)','queue/500 (guard only)'],
                  trainingSeeds=[101,202,303],tuningSeeds=[404],validationSeeds=[505],exposedAuditSeeds=[606],finalHoldoutSeeds=[909],
                  trainGainCount=gain,confidenceMeaning='fraction of training seed blocks with positive estimated gain, not calibrated',
                  inference='immutable decision stump; no runtime dependency; user power and feature guards precede inference',
                  limitations=['source-level labels from homogeneous worlds are not causal mixed-policy outcomes',
                               'train features are warmup snapshots; live features change; no promotion',
                               'one holdout seed cannot establish seed-level significance',
                               'no approved non-inferiority tolerance or new resource budget'])
    (out/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
    # Freeze artifact before inspecting validation and holdout. This does NOT tune on either.
    evaluation={split:estimates(dataset['rows'],model,split) for split in ['train','tune','validation']}
    (out/'evaluation.json').write_text(json.dumps(dict(label='OFFLINE_LABEL_REPLAY_NOT_LIVE_DELIVERY',
        modelSHA256=metadata['modelSHA256'],estimates=evaluation),indent=2)+'\n')
    print(json.dumps(dict(model=model,metadata=metadata),indent=2))

if __name__=='__main__': main()
