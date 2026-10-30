import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { MeshSimulation } from "../src/simulation";
import { FailureDiagnostics } from "../src/failure-diagnostics";
import { buildScenario } from "../src/scenarios";
import { trafficPlan } from "./routing/strategies";
import { canReach } from "../src/rf";
import { expandContacts } from "./routing/contact_bound";
import { createRng } from "../src/rng";
const dir=process.argv[2]??"artifacts/diagnosis";mkdirSync(dir,{recursive:true});
const old=JSON.parse(readFileSync('reports/routing/2026-10-28-evolution/runs.json','utf8'));
const sourceFiles=['src/simulation.ts','src/election.ts','src/routing.ts','src/failure-diagnostics.ts','src/routing-research.ts','src/rf.ts','src/scenarios.ts','src/rng.ts','src/types.ts','src/events.ts','tool/routing-diagnose.ts'];
const sourceHashes=Object.fromEntries(sourceFiles.map(p=>[p,createHash('sha256').update(readFileSync(p)).digest('hex')]));
const rows:object[]=[];
for(const scenario of ['festival_crowd','campus_quad','sparse_village','partitioned_pair'])
for(const seed of scenario==='festival_crowd'?[3301,3302,3303]:[2201])for(const duty of [false,true]) {
 const config={...buildScenario(scenario,seed),dutyCycleEnabled:duty},diagnostics=new FailureDiagnostics();
 const sim=new MeshSimulation(config,undefined,(seed^0x1347)>>>0,diagnostics);
 const carriers:boolean[][]=[],possible:boolean[]=[];
 const sent:Array<{id:string;at:number;from:string;to:string}>=[];
 function observeContacts(){
   const component=sim.nodes.map(()=>-1);
   for(let a=0;a<sim.nodes.length;a++)if(component[a]===-1){component[a]=a;const q=[a];
    for(let k=0;k<q.length;k++)for(let b=0;b<sim.nodes.length;b++)if(component[b]===-1&&canReach(sim.nodes[q[k]],sim.nodes[b],sim.rf)){component[b]=a;q.push(b);}}
   for(let k=0;k<carriers.length;k++){carriers[k]=expandContacts(carriers[k],component);const dst=sim.nodes.findIndex(n=>n.id===sent[k].to);possible[k] ||=carriers[k][dst];}
 }
 for(const [i,[a,b]] of trafficPlan(seed,150,config.nodeCount,createRng).entries()) {
  if(sim.nodes[a].isOnline&&sim.nodes[b].isOnline) {
   const m=sim.sendMessage(sim.nodes[a].id,sim.nodes[b].id,`acc-${i}`,'text');if(m){sent.push({id:m.id,at:sim.now,from:m.from,to:m.to});carriers.push(sim.nodes.map(n=>n.id===m.from));possible.push(false);}
  }
  for(let t=0;t<1500;t+=config.physicsIntervalMs) {
   observeContacts();
   sim.runFor(config.physicsIntervalMs);
  }
 }
 observeContacts();
 sim.refresh();const uni=sim.deliveries.filter(d=>d.type!=='ack'&&d.type!=='broadcast');
 if(sent.length!==sim.stats.sentUnicast||new Set(uni.map(d=>d.msgId)).size!==uni.length)throw Error('Population mismatch');
 const five=uni.filter(d=>d.hops<=5).length;
 const prior=old.rows.find((r:any)=>r.scenario===scenario&&r.seed===seed&&r.duty===duty&&r.policy.beacon===2000&&r.policy.ack===4000);
 if(!prior||prior.five!==five||JSON.stringify(prior.stats)!==JSON.stringify(sim.stats))throw Error('Baseline mismatch');
 const failed=sent.filter(m=>!uni.some(d=>d.msgId===m.id&&d.hops<=5)).map(m=>{
  const delivery=uni.find(d=>d.msgId===m.id);return {...m,outcome:delivery?'delivered-over-five':'not-delivered-at-horizon',
    deliveredHops:delivery?.hops??null,optimisticTemporalContactReachable:possible[sent.findIndex(s=>s.id===m.id)],observations:diagnostics.messages.get(m.id)??null,
    queuedCopies:sim.nodes.filter(n=>n.oppQueue.some(q=>q.msg.id===m.id)).length};
 });
 const tagCounts:Record<string,number>={};for(const m of failed)for(const k of Object.keys(m.observations?.counts??{}))tagCounts[k]=(tagCounts[k]??0)+1;
 rows.push({scenario,seed,duty,config,motionSeed:(seed^0x1347)>>>0,configHash:createHash('sha256').update(JSON.stringify({config,motionSeed:(seed^0x1347)>>>0})).digest('hex'),
  sent:sent.length,five,overall:uni.length,three:uni.filter(d=>d.hops<=3).length,stats:sim.stats,failed,tagCounts,
  diagnosticOverflow:diagnostics.overflow,optimisticReachable:possible.filter(Boolean).length,priorFullStatsMatch:true});
 writeFileSync(`${dir}/baseline.json`,JSON.stringify({sourceSha:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),node:process.version,sourceHashes,rows}));
 console.error(scenario,seed,duty,five,'failed',failed.length,tagCounts);
}
