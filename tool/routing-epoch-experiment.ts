/** Exactly one predeclared candidate, seed-paired worlds; no selection/search loop. */
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync,readFileSync,writeFileSync } from 'node:fs';
import { MeshSimulation } from '../src/simulation';
import { FailureDiagnostics } from '../src/failure-diagnostics';
import { OGM_EPOCH_PROFILE, type RoutingResearchProfile } from '../src/routing-research';
import { buildScenario } from '../src/scenarios';
import { createRng } from '../src/rng';
import { trafficPlan,percentile } from './routing/strategies';
const out=process.argv[2]??'artifacts/epoch';mkdirSync(out,{recursive:true});
const sourceSha=execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim();
const sourceFiles=['src/simulation.ts','src/election.ts','src/routing.ts','src/failure-diagnostics.ts','src/routing-research.ts','src/rf.ts','src/scenarios.ts','src/rng.ts','src/types.ts','src/events.ts','tool/routing-epoch-experiment.ts'];
const sourceHashes=Object.fromEntries(sourceFiles.map(p=>[p,createHash('sha256').update(readFileSync(p)).digest('hex')]));
const rows:object[]=[];
function run(split:string,scenario:string,seed:number,duty:boolean,profile:RoutingResearchProfile){
 const config={...buildScenario(scenario,seed),dutyCycleEnabled:duty};
 const diagnostics=new FailureDiagnostics(),motionSeed=(seed^0x1347)>>>0,start=performance.now();
 const sim=new MeshSimulation(config,undefined,motionSeed,diagnostics,profile);
 const initialBattery=sim.nodes.map(n=>n.battery);
 const sent:Array<{id:string;at:number;from:string;to:string}>=[];
 for(const [i,[a,b]] of trafficPlan(seed,150,config.nodeCount,createRng).entries()){
  if(sim.nodes[a].isOnline&&sim.nodes[b].isOnline){const m=sim.sendMessage(sim.nodes[a].id,sim.nodes[b].id,`acc-${i}`,'text');if(m)sent.push({id:m.id,at:sim.now,from:m.from,to:m.to});}
  sim.runFor(1500);
 }
 sim.refresh();const stats=structuredClone(sim.stats),uni=sim.deliveries.filter(d=>d.type!=='ack'&&d.type!=='broadcast');
 if(sent.length!==stats.sentUnicast||new Set(uni.map(d=>d.msgId)).size!==uni.length)throw Error('Population drift');
 const messages=sent.map(m=>{const delivery=uni.find(d=>d.msgId===m.id);return {...m,
  outcome:delivery?(delivery.hops<=5?'five-hop-delivery':'delivered-over-five'):'not-delivered-at-horizon',delivery:delivery??null,
  queuedCopies:sim.nodes.filter(n=>n.oppQueue.some(q=>q.msg.id===m.id)).length,observations:diagnostics.messages.get(m.id)??null};});
 const tagCounts:Record<string,number>={};for(const m of messages)if(m.outcome!=='five-hop-delivery')for(const tag of Object.keys(m.observations?.counts??{}))tagCounts[tag]=(tagCounts[tag]??0)+1;
 const row={split,scenario,seed,duty,profile,config,motionSeed,configHash:createHash('sha256').update(JSON.stringify({config,motionSeed})).digest('hex'),
  sent:sent.length,five:uni.filter(d=>d.hops<=5).length,three:uni.filter(d=>d.hops<=3).length,overall:uni.length,
  totalTx:sim.nodes.reduce((s,n)=>s+n.txCount,0),relayTx:stats.totalForwarded,p50:percentile(uni.map(d=>d.latencyMs),.5),p95:percentile(uni.map(d=>d.latencyMs),.95),
  modeledBatteryDrain:sim.nodes.reduce((s,n,i)=>s+initialBattery[i]-n.battery,0),queueAtHorizon:sim.nodes.reduce((s,n)=>s+n.oppQueue.length,0),
  stats,messages,tagCounts,diagnosticOverflow:diagnostics.overflow,wallMs:performance.now()-start};
 rows.push(row);writeFileSync(`${out}/experiments.json`,JSON.stringify({sourceSha,sourceHashes,node:process.version,profile:OGM_EPOCH_PROFILE,rows}));
 console.error(split,scenario,seed,duty,profile,row.five,row.totalTx);
}
for(const [split,seeds] of Object.entries({development:[4301,4302],validation:[4303,4304],final:[5301,5302,5303,5304,5305,5306]}))
 for(const seed of seeds)for(const duty of [false,true])for(const p of ['baseline','ogm-epoch-v1'] as const)run(split,'festival_crowd',seed,duty,p);
for(const scenario of ['campus_quad','sparse_village','partitioned_pair'])for(const seed of [6301,6302])for(const duty of [false,true])for(const p of ['baseline','ogm-epoch-v1'] as const)run('protected',scenario,seed,duty,p);
