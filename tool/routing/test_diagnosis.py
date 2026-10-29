import subprocess
"""Retained evidence contract tests; stdlib only, no simulations or fitting."""
import gzip
import hashlib
import json
import unittest
from pathlib import Path
ROOT=Path('reports/routing/2026-10-29-diagnosis')
class EvidenceTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.baseline=json.loads((ROOT/'baseline.json').read_text())
  cls.experiment=json.loads(gzip.decompress((ROOT/'experiments.json.gz').read_bytes()))
  cls.summary=json.loads((ROOT/'summary.json').read_text())
 def test_source_integrity_and_complete_pairs(self):
  self.assertEqual(len(self.experiment['rows']),64)
  for data in [self.baseline,self.experiment]:
   for path,digest in data['sourceHashes'].items():self.assertEqual(hashlib.sha256(subprocess.check_output(['git','show',f"{data['sourceSha']}:{path}"])).hexdigest(),digest)
  groups={}
  for r in self.experiment['rows']:
   key=tuple(r[k] for k in ['split','scenario','seed','duty']);groups.setdefault(key,[]).append(r)
  self.assertEqual(len(groups),32)
  for pair in groups.values():
   self.assertEqual({r['profile'] for r in pair},{'baseline','ogm-epoch-v1'})
   self.assertEqual(pair[0]['configHash'],pair[1]['configHash'])
 def test_primary_population_and_diagnostic_bounds(self):
  for r in self.experiment['rows']:
   self.assertEqual(r['sent'],150);self.assertEqual(len(r['messages']),150)
   self.assertEqual(r['five'],sum(m['outcome']=='five-hop-delivery' for m in r['messages']))
   self.assertLessEqual(r['three'],r['five']);self.assertLessEqual(r['five'],r['overall'])
   self.assertEqual(r['diagnosticOverflow'],0)
   for m in r['messages']:
    if m['observations']:
     self.assertLessEqual(len(m['observations']['examples']),8)
     self.assertTrue(all(len(e['detail'])<=240 for e in m['observations']['examples']))
     self.assertTrue(all(m['at']<=t<=r['stats']['simTimeMs'] for t in m['observations']['first'].values()))
 def test_old_population_not_claimed_new_final(self):
  self.assertTrue(all(r['priorFullStatsMatch'] for r in self.baseline['rows']))
  allowed={'development':{4301,4302},'validation':{4303,4304},'final':set(range(5301,5307)),'protected':{6301,6302}}
  for r in self.experiment['rows']:self.assertIn(r['seed'],allowed[r['split']])
 def test_negative_result_remains_disabled(self):
  self.assertFalse(self.summary['targetMet']);self.assertEqual(self.summary['promotion'],'rejected-offline-only')
  final=[g for g in self.summary['groups'] if g['split']=='final']
  self.assertEqual(len(final),2)
  for g in final:
   self.assertEqual(g['nSeeds'],6);self.assertEqual(g['candidateSeedsStrictlyAbove90'],0)
   self.assertFalse(g['benefitGatePass']);self.assertFalse(g['resourceScreenPass'])
if __name__=='__main__':unittest.main()
