import unittest
from analyze import summarize


class PromotionTests(unittest.TestCase):
    def row(self, seed, strategy, ratio):
        return dict(split='validation', scenario='sparse_village', duty=False,
                    seed=seed, strategy=strategy, fiveRatio=ratio, deliveryRatio=ratio,
                    threeRatio=ratio, hopsMean=1, hopsP95=1, latencyMeanMs=10,
                    latencyP95Ms=10, totalTx=20, undeliveredAtHorizon=10,
                    wallMs=1, stats=dict(totalForwarded=10, retriesSent=1, retriesExhausted=1,
                               totalQueued=1, batteryPercentPerHourNormal=1,
                               batteryPercentPerHourSuper=1, roleChangesPerNodeMin=0))

    def test_averages_cannot_hide_one_bad_seed(self):
        rows = [self.row(s, 'baseline-v1', .5) for s in [1, 2, 3]]
        rows += [self.row(s, 'candidate', v) for s, v in [(1,.9), (2,.9), (3,.4)]]
        result = summarize(dict(sourceSha='test', rows=rows))
        self.assertGreater(result['summaries'][1]['deltaFiveMean'], 0)
        self.assertIn('five-hop regression on a held-out seed/context', result['decisions'][0]['reasons'])
        self.assertEqual(result['decisions'][0]['status'], 'not-promoted')

    def test_even_perfect_reference_results_do_not_autopromote(self):
        rows = [self.row(s, 'baseline-v1', .5) for s in [1, 2, 3]]
        rows += [self.row(s, 'candidate', .6) for s in [1, 2, 3]]
        result = summarize(dict(sourceSha='test', rows=rows))
        self.assertEqual(result['decisions'][0]['status'], 'not-promoted')
        self.assertIn('authoritative Dart candidate/OOD/release gate verification required', result['decisions'][0]['reasons'])
        candidate = next(s for s in result['summaries'] if s['strategy'] == 'candidate')
        self.assertAlmostEqual(candidate['deltaFiveCI95'][0], .1)

    def test_smoke_is_not_validation(self):
        row = self.row(1, 'candidate', 1)
        baseline = self.row(1, 'baseline-v1', 1)
        for r in [row, baseline]:
            r['split'] = 'smoke'
        result = summarize(dict(sourceSha='test', rows=[row, baseline]))
        self.assertIsNone(result['summaries'][0]['deltaFiveCI95'])
        self.assertIn('no held-out validation', result['decisions'][0]['reasons'])


if __name__ == '__main__':
    unittest.main()
