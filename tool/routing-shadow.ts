import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { MeshSimulation } from "../src/simulation";
import { buildScenario, scenarioNames } from "../src/scenarios";
import { createRng } from "../src/rng";
import { RoutingSelector } from "../src/routing-selector";
import { loadSelector } from "./routing/load-selector";
import { trafficPlan, percentile } from "./routing/strategies";
const dir=process.argv[2]??"reports/routing/2026-10-28-selector", path=`${dir}/model/model.experimental.json`;
const raw=readFileSync(path), hash=createHash("sha256").update(raw).digest("hex");
const loadStart=performance.now(),model=loadSelector(path,hash),loadMs=performance.now()-loadStart;
if(!model)throw Error("Model load failed");
const controller=new RoutingSelector({mode:"shadow",model}),times:number[]=[];
for(let i=0;i<10000;i++) {
  const start=performance.now();controller.decide({neighbors:20,queue:0,duty:0,battery:.8,saver:false,observedAt:i},i);
  times.push(performance.now()-start);
}
const rows=[];
for(const scenario of scenarioNames())for(const duty of [false,true]) {
  const config={...buildScenario(scenario,505),dutyCycleEnabled:duty};
  const a=new MeshSimulation(config),b=new MeshSimulation(config,{mode:"shadow",model});
  for(const [i,[from,to]] of trafficPlan(505,150,config.nodeCount,createRng).entries()) {
    for(const sim of [a,b]) {sim.sendMessage(sim.nodes[from].id,sim.nodes[to].id,`acc-${i}`,"text");sim.runFor(1500);}
  }
  a.refresh();b.refresh();
  if(JSON.stringify(a.stats)!==JSON.stringify(b.stats)||JSON.stringify(a.deliveries)!==JSON.stringify(b.deliveries))throw Error("Shadow changed routing");
  rows.push({scenario,duty,seed:505,exactStatsAndDeliveriesEqual:true,stats:b.stats,
    decisionCounts:b.selectorDecisionCounts,tailDecisions:b.selectorDiagnostics.length});
}
const output=process.argv[3]??"artifacts/selector/shadow.json";
mkdirSync(dirname(output),{recursive:true});
writeFileSync(output,JSON.stringify({modelSHA256:hash,modelBytes:raw.length,loadMs,
  inferenceSamples:times.length,inferenceP50Ms:percentile(times,.5),inferenceP95Ms:percentile(times,.95),
  hardware:"shared sandbox Node "+process.version, memory:"artifact bytes measured, heap/phone footprint not isolated",
  rows},null,2)+'\n');
