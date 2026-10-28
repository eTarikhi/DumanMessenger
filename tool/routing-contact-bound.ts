import { writeFileSync } from "node:fs";
import { MeshSimulation } from "../src/simulation";
import { buildScenario } from "../src/scenarios";
import { canReach } from "../src/rf";
import { createRng } from "../src/rng";
import { trafficPlan } from "./routing/strategies";
import { expandContacts } from "./routing/contact_bound";
const seed=Number(process.argv[2]??1102),scenario=process.argv[3]??"festival_crowd";
const cfg=buildScenario(scenario,seed),sim=new MeshSimulation(cfg,undefined,(seed^0x1347)>>>0);
const plan=trafficPlan(seed,150,cfg.nodeCount,createRng), states:boolean[][]=[];
const possible=Array(plan.length).fill(false);
for(let t=0;t<=225000;t+=cfg.physicsIntervalMs) {
  if(t>0)sim.runFor(cfg.physicsIntervalMs);
  if(sim.nodes.some(n=>!n.isOnline))throw Error("Offline node: optimistic movement assumptions need review");
  if(t%1500===0&&t/1500<plan.length) {
    const state=Array(cfg.nodeCount).fill(false);state[plan[t/1500][0]]=true;states.push(state);
  }
  const component=Array(cfg.nodeCount).fill(-1);
  for(let a=0;a<cfg.nodeCount;a++)if(component[a]===-1) {
    component[a]=a;const queue=[a];
    for(let q=0;q<queue.length;q++)for(let b=0;b<cfg.nodeCount;b++)
      if(component[b]===-1&&canReach(sim.nodes[queue[q]],sim.nodes[b],sim.rf)) {component[b]=a;queue.push(b);}
  }
  for(let i=0;i<states.length;i++) {
    states[i]=expandContacts(states[i],component);
    if(states[i][plan[i][1]])possible[i]=true;
  }
}
const result={scenario,seed,motionSeed:(seed^0x1347)>>>0,windowMs:225000,sent:plan.length,
  optimisticReachable:possible.filter(Boolean).length,upperBound:possible.filter(Boolean).length/plan.length,
  assumptions:"all carriers; unlimited copies and hops; zero latency, loss, scheduling or energy costs; observe every piecewise-constant physics graph; carry through partitions",
  NOT_A_FIVE_HOP_DELIVERY_MEASUREMENT:true};
writeFileSync(process.argv[4]??"artifacts/contact-bound.json",JSON.stringify(result,null,2)+"\n");console.log(result);
