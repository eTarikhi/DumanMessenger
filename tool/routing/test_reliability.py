import gzip,hashlib,json,unittest
from pathlib import Path
from reliability_ml import evaluate,sigmoid
ROOT=Path('reports/routing/2026-10-29-reliability')
class ReliabilityTests(unittest.TestCase):
 def test_metrics_known_predictions(self):
  data=[([0],0,'world1'),([1],1,'world2')]
  m=evaluate(data,lambda x:float(x[0]));self.assertEqual(m['auc'],1);self.assertEqual(m['brier'],0);self.assertEqual(m['precision'],1);self.assertEqual(m['recall'],1)
  m=evaluate(data,lambda x:.5);self.assertEqual(m['auc'],.5);self.assertEqual(m['brier'],.25)
  self.assertTrue(0<sigmoid(-100)<sigmoid(0)<sigmoid(100)<1)
 def test_full_preserved_population(self):
  data=json.loads(gzip.decompress((ROOT/'experiments.json.gz').read_bytes()))
  self.assertEqual(len(data['rows']),70)
  for r in data['rows']:
   self.assertEqual(r['sent'],150);self.assertEqual(r['diagnosticOverflow'],0)
   self.assertEqual(r['five'],sum(m['outcome']=='five-hop-delivery' for m in r['messages']))
   self.assertEqual(len(set(m['id'] for m in r['messages'])),150)
   self.assertLessEqual(sum((m['observations'] or {}).get('counts',{}).get('source-backup',0) for m in r['messages']),150)
   if r['split']=='audit':self.assertTrue(r['priorStatsMatch'])
 def test_final_split_and_no_live_deployment(self):
  model=json.loads((ROOT/'local-feature-model.json').read_text());self.assertFalse(model['liveEligible'])
  self.assertFalse(set(model['trainSeeds']+model['validationSeeds'])&set(model['untouchedFinalSeeds']))
  s=json.loads((ROOT/'summary.json').read_text());self.assertFalse(s['productionApproved'])
  for g in s['groups']:
   if g['split']=='final':self.assertEqual(g['seeds'],[7401,7402,7403,7404])
 def test_locked_model_data_and_features(self):
  data=json.loads(gzip.decompress((ROOT/'experiments.json.gz').read_bytes()));model=json.loads((ROOT/'local-feature-model.json').read_text())
  dev=[r for r in data['rows'] if r['split']=='development'];self.assertEqual(hashlib.sha256(json.dumps(dev,sort_keys=True).encode()).hexdigest(),model['developmentHash'])
  excluded={'eventualHops','delivery','retries','contactOracle','outcome','seed'};self.assertFalse(excluded&set(model['featureKeys']))
if __name__=='__main__':unittest.main()
