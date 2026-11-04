import copy
import unittest
from train_selector import fit, pairs

class FitTests(unittest.TestCase):
    def rows(self):
        rows=[]
        for seed in [101,202,303]:
            for strategy,counts in [('baseline-v1',[2,2]),('ack-6000-v1',[1,3])]:
                rows.append(dict(split='train',scenario='synthetic',seed=seed,duty=False,staticWorld=False,
                    strategy=strategy,features=[dict(neighbors=2,duty=0),dict(neighbors=20,duty=0)],
                    origins=[dict(sent=4,five=n) for n in counts]))
        return rows
    def test_repeatable_bounded_fit(self):
        rows=self.rows();model,gain=fit(rows)
        self.assertEqual(fit(rows),fit(copy.deepcopy(rows)))
        self.assertEqual(model['left'],'baseline-v1')
        self.assertEqual(model['right'],'ack-6000-v1')
        self.assertEqual(gain,3)
        self.assertTrue(model['experimental'])
    def test_holdout_cannot_change_parameters(self):
        rows=self.rows();original=fit(rows)
        leaked=copy.deepcopy(rows)
        for row in leaked:
            row['split']='holdout'
            for node in row['origins']:node['five']=0
        self.assertEqual(fit(rows+leaked),original)
    def test_unmatched_denominator_rejected(self):
        rows=self.rows();rows[1]['origins'][0]['sent']=3
        with self.assertRaises(ValueError):list(pairs(rows,'train'))
    def test_no_training_data_never_fabricates_model(self):
        with self.assertRaises(ValueError):fit([])

if __name__=='__main__':unittest.main()
