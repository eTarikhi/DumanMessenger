/** Diagnostic replay, NOT a new benchmark/promotion or acceptance-threshold waiver.
 * Run npm run golden first to compile the shared CommonJS tool output.
 */
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
const require = createRequire(import.meta.url);
const { MeshSimulation } = require('../.build/src/simulation.js');
const { trafficPlan } = require('../.build/tool/routing/strategies.js');
const { createRng } = require('../.build/src/rng.js');
const reference = JSON.parse(readFileSync('reports/routing/2026-10-29-diagnosis/baseline.json'));
for (const duty of [false, true]) {
  const old = reference.rows.find(r => r.scenario === 'festival_crowd' && r.seed === 3301 && r.duty === duty);
  const sim = new MeshSimulation(old.config, undefined, (3301 ^ 0x1347) >>> 0);
  for (const [i,[a,b]] of trafficPlan(3301,150,sim.nodes.length,createRng).entries()) {
    if (sim.nodes[a].isOnline && sim.nodes[b].isOnline) sim.sendMessage(sim.nodes[a].id,sim.nodes[b].id,`acc-${i}`,'text');
    sim.runFor(1500);
  }
  sim.refresh();
  const five = sim.deliveries.filter(d => d.type !== 'ack' && d.type !== 'broadcast' && d.hops <= 5).length;
  if (JSON.stringify(sim.stats) !== JSON.stringify(old.stats) || five !== old.five) throw Error('Baseline regression');
  console.log(JSON.stringify({scenario:'festival_crowd',seed:3301,duty,sent:sim.stats.sentUnicast,five,fullHistoricalStatsEqual:true,statsSha256:createHash('sha256').update(JSON.stringify(sim.stats)).digest('hex')}));
}
