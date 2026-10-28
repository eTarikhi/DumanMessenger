import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { MeshSimulation } from "../src/simulation";
import { buildScenario, scenarioNames } from "../src/scenarios";
import { createRng } from "../src/rng";
import { applyStrategy, trafficPlan, percentile } from "./routing/strategies";
const out = process.argv[2] ?? "reports/routing/2026-10-28-selector";
mkdirSync(out, {recursive:true});
const sourceSha = execFileSync("git", ["rev-parse", "HEAD"], {encoding:"utf8"}).trim();
const prior = JSON.parse(readFileSync("reports/routing/2026-10-28/benchmark.json", "utf8"));
const rows: any[] = [];
const exogenous=process.argv.includes("--exogenous");
const finalHoldout=process.argv.includes("--holdout");
function run(split:string, scenario:string, seed:number, duty:boolean, staticWorld=false) {
  const base = {...buildScenario(scenario, seed), dutyCycleEnabled:duty};
  if(staticWorld) base.enableMobility=false;
  for(const strategy of ["baseline-v1","ack-6000-v1"]) {
    const config=applyStrategy(base,strategy,true), sim=new MeshSimulation(config,undefined,exogenous?31415:undefined);
    const features=sim.nodes.map(n=>({neighbors:n.peerCount,duty:duty?1:0}));
    const origins=sim.nodes.map(()=>({sent:0,five:0}));
    const ids=new Map<string,number>();
    const plan=trafficPlan(seed,150,config.nodeCount,createRng);
    for(let i=0;i<plan.length;i++) {
      const [a,b]=plan[i];
      if(sim.nodes[a].isOnline && sim.nodes[b].isOnline) {
        const m=sim.sendMessage(sim.nodes[a].id,sim.nodes[b].id,`acc-${i}`,"text");
        if(m) {origins[a].sent++;ids.set(m.id,a);}
      }
      sim.runFor(1500);
    }
    sim.refresh();
    const uni=sim.deliveries.filter(d=>d.type!=="ack"&&d.type!=="broadcast");
    if(new Set(uni.map(d=>d.msgId)).size!==uni.length) throw Error("Duplicate population");
    for(const d of uni) if(d.hops<=5) {const a=ids.get(d.msgId);if(a===undefined)throw Error("Unplanned delivery");origins[a].five++;}
    const sent=origins.reduce((s,n)=>s+n.sent,0), five=origins.reduce((s,n)=>s+n.five,0);
    if(sim.stats.sentUnicast!==sent)throw Error("Denominator mismatch");
    const row={sourceSha,split,scenario,seed,duty,staticWorld,strategy,config,
      configHash:createHash("sha256").update(JSON.stringify(config)).digest("hex"),
      sent,five,delivered:uni.length,three:uni.filter(d=>d.hops<=3).length,
      hopsMean:uni.length?uni.reduce((s,d)=>s+d.hops,0)/uni.length:null,
      hopsP95:percentile(uni.map(d=>d.hops),.95),
      p95:percentile(uni.map(d=>d.latencyMs),.95),stats:sim.stats,
      totalTx:sim.nodes.reduce((s,n)=>s+n.txCount,0),features,origins,
      queueCopies:sim.stats.totalQueued,undelivered:sent-uni.length,
      positions:exogenous?sim.nodes.map(n=>({...n.pos})):undefined};
    if(split==="reproduce") {
      const old=prior.rows.find((r:any)=>r.scenario===scenario&&r.seed===seed&&r.duty===duty&&r.strategy===strategy);
      if(!old||old.withinFive!==five||old.stats.totalForwarded!==sim.stats.totalForwarded||old.stats.retriesSent!==sim.stats.retriesSent)
        throw Error("Historical reproduction failed");
    }
    rows.push(row);
    writeFileSync(`${out}/${exogenous?"exogenous":finalHoldout?"final-holdout":"targeted"}.json`,JSON.stringify({sourceSha,node:process.version,featureSchema:1,rows}));
    console.error(`${split} ${scenario} ${seed} duty=${duty} static=${staticWorld} ${strategy} ${five}/${sent}`);
  }
}
if(finalHoldout) {
  for(const scenario of scenarioNames())for(const duty of [false,true])run("holdout",scenario,909,duty);
} else if(exogenous) {
  for(const duty of [false,true])run("exogenous","festival_crowd",31415,duty);
} else {
run("reproduce","campus_quad",42,false);
run("reproduce","festival_crowd",31415,true);
for(const duty of [false,true])run("diagnosis","festival_crowd",31415,duty,true);
for(const [split,seeds] of Object.entries({train:[101,202,303],tune:[404],validation:[505],holdout:[606]}))
 for(const seed of seeds)for(const scenario of scenarioNames())for(const duty of [false,true])run(split,scenario,seed,duty);

}
