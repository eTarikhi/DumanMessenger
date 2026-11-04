/** Bounded, deterministic evolutionary offline parameter learning. NEVER deployed automatically. */
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { MeshSimulation } from "../src/simulation";
import { buildScenario } from "../src/scenarios";
import { createRng } from "../src/rng";
import { percentile, trafficPlan } from "./routing/strategies";
type Policy={beacon:number;ack:number};
type Row={split:string;scenario:string;seed:number;duty:boolean;policy:Policy;sent:number;five:number;ratio:number;
  delivered:number;three:number;hopsMean:number|null;hopsP95:number|null;p95:number|null;totalTx:number;config:object;configHash:string;
  motionSeed:number;stats:MeshSimulation['stats'];wallMs:number};
const out=process.argv[2]??"artifacts/evolution";mkdirSync(out,{recursive:true});
const file=`${out}/runs.json`;let sourceSha=execFileSync("git",["rev-parse","HEAD"],{encoding:"utf8"}).trim();
const codeHash=createHash("sha256").update(readFileSync(__filename)).update(
  ["simulation","routing","election","rf","rng","scenarios","events","types"].map(n=>readFileSync(`src/${n}.ts`,"utf8")).join("\n")).digest("hex");
const rows:Row[]=[];
if(existsSync(file)) {const old=JSON.parse(readFileSync(file,"utf8"));if(old.codeHash!==codeHash||old.node!==process.version)throw Error("Checkpoint version mismatch");sourceSha=old.sourceSha;rows.push(...old.rows);}
const baseline:Policy={beacon:2000,ack:4000};
const id=(p:Policy)=>`${p.beacon}/${p.ack}`;
function save(){writeFileSync(`${file}.tmp`,JSON.stringify({sourceSha,codeHash,node:process.version,rows}));renameSync(`${file}.tmp`,file);}
function run(split:string,scenario:string,seed:number,duty:boolean,policy:Policy):Row {
  const prior=rows.find(r=>r.split===split&&r.scenario===scenario&&r.seed===seed&&r.duty===duty&&id(r.policy)===id(policy));if(prior)return prior;
  const cfg={...buildScenario(scenario,seed),dutyCycleEnabled:duty,ogmIntervalMs:policy.beacon,ackTimeoutMs:policy.ack};
  const motionSeed=(seed^0x1347)>>>0,start=performance.now(),sim=new MeshSimulation(cfg,undefined,motionSeed);
  let sent=0;
  for(const [i,[a,b]] of trafficPlan(seed,150,cfg.nodeCount,createRng).entries()) {
    if(sim.nodes[a].isOnline&&sim.nodes[b].isOnline&&sim.sendMessage(sim.nodes[a].id,sim.nodes[b].id,`acc-${i}`,"text"))sent++;
    sim.runFor(1500);
  }
  sim.refresh();const uni=sim.deliveries.filter(d=>d.type!=="ack"&&d.type!=="broadcast");
  if(sent!==sim.stats.sentUnicast||new Set(uni.map(d=>d.msgId)).size!==uni.length)throw Error("Population drift");
  const five=uni.filter(d=>d.hops<=5).length;
  const row:Row={split,scenario,seed,duty,policy:{...policy},sent,five,ratio:five/Math.max(1,sent),delivered:uni.length,
    three:uni.filter(d=>d.hops<=3).length,hopsMean:uni.length?uni.reduce((s,d)=>s+d.hops,0)/uni.length:null,
    hopsP95:percentile(uni.map(d=>d.hops),.95),p95:percentile(uni.map(d=>d.latencyMs),.95),
    totalTx:sim.nodes.reduce((s,n)=>s+n.txCount,0),config:cfg,
    configHash:createHash("sha256").update(JSON.stringify({cfg,motionSeed})).digest("hex"),motionSeed,stats:sim.stats,wallMs:performance.now()-start};
  rows.push(row);save();console.error(`${split} ${scenario} ${seed} duty=${duty} ${id(policy)} ${five}/${sent}`);return row;
}
function train(policy:Policy){for(const seed of [1101,1102])for(const duty of [false,true])run("train","festival_crowd",seed,duty,policy);}
function rank(a:Policy,b:Policy,duty:boolean):number {
  const score=(p:Policy)=>{const rs=rows.filter(r=>r.split==="train"&&r.duty===duty&&id(r.policy)===id(p));
    return [Math.min(...rs.map(r=>r.ratio)),rs.reduce((s,r)=>s+r.ratio,0),-rs.reduce((s,r)=>s+r.stats.totalForwarded,0)];};
  const av=score(a),bv=score(b);for(let i=0;i<av.length;i++)if(av[i]!==bv[i])return bv[i]-av[i];return id(a).localeCompare(id(b));
}
const population=[baseline,...[1000,3000,5000].map(beacon=>({beacon,ack:4000}))];
for(const p of population)train(p);
const initialBest=[false,true].map(duty=>population.slice().sort((a,b)=>rank(a,b,duty))[0]);
for(const parent of initialBest)for(const ack of [3000,6000]) {
  const child={beacon:parent.beacon,ack};if(!population.some(p=>id(p)===id(child))){population.push(child);train(child);}
}
const selected=[false,true].map(duty=>population.slice().sort((a,b)=>rank(a,b,duty))[0]);
const frozen={api:1,status:"offline-experimental-not-approved",feature:"user duty-cycle flag",trainingSeeds:[1101,1102],selected,population,
  sourceSha,codeHash,baseline,objective:"maximize worst training seed five-hop ratio, then mean, then lower relays"};
const serialized=JSON.stringify(frozen,null,2)+"\n";
if(existsSync(`${out}/policy.json`)&&readFileSync(`${out}/policy.json`,"utf8")!==serialized)throw Error("Frozen policy differs");
writeFileSync(`${out}/policy.json`,serialized);
writeFileSync(`${out}/policy.sha256`,createHash("sha256").update(serialized).digest("hex")+"\n");
// No feedback from validation or holdout reaches rank()/training after this point.
for(const [split,seeds] of Object.entries({validation:[2201,2202,2203],holdout:[3301,3302,3303]}))
  for(const seed of seeds)for(const duty of [false,true])for(const p of [baseline,selected[duty?1:0]])run(split,"festival_crowd",seed,duty,p);
for(const scenario of ["campus_quad","sparse_village","partitioned_pair"])
  for(const seed of [2201,2202])for(const duty of [false,true])for(const p of [baseline,selected[duty?1:0]])run("protected",scenario,seed,duty,p);
