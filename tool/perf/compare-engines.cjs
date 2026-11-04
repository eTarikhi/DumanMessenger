// Compare a separately compiled immutable source reference with the current build.
// Usage after npm run golden and compiling a reference: node ... REFERENCE_MODULE
const {resolve}=require('node:path');
const {createHash}=require('node:crypto');
const assert=require('node:assert/strict');
const old=require(resolve(process.argv[2]));
const current=require('../../tool/.build/src/simulation.js');
const scenarios=require('../../tool/.build/src/scenarios.js');
function canonical(value){return JSON.stringify(value,(_,v)=>v instanceof Map?{map:[...v]}:v instanceof Set?{set:[...v]}:v);}
for(const name of scenarios.scenarioNames()){
 for(const dutyCycle of [false,true]){
  const cfg={...scenarios.buildScenario(name,42),warmupMs:0,dutyCycle,captureLog:true};
  const a=new old.MeshSimulation(cfg),b=new current.MeshSimulation(cfg);
  for(const ms of [12000,25000,45000]){
   for(const s of [a,b]){s.runFor(ms);s.injectTraffic(6,4000);s.runFor(6000);s.refresh();}
   assert.equal(canonical(b),canonical(a),`${name}/${dutyCycle}/${ms}: complete enumerable state`);
  }
  assert.deepEqual(Array.from({length:16},()=>a.rng()),Array.from({length:16},()=>b.rng()));
  console.log(JSON.stringify({name,dutyCycle,completeStateAndRngEqual:true,sha256:createHash('sha256').update(canonical(b)).digest('hex')}));
 }
}
// Exercise the high-density branch and receipt-history cap without a long benchmark.
const cfg={...scenarios.festivalCrowd(7),warmupMs:0,nodeCount:200,obstacles:[],enableMobility:false,captureLog:false};
const a=new old.MeshSimulation(cfg),b=new current.MeshSimulation(cfg);
for(const s of [a,b]){s.runFor(12000);s.injectTraffic(6,3000);s.runFor(10000);s.refresh();}
assert.equal(canonical(b),canonical(a),'dense200 complete state');
assert.deepEqual(Array.from({length:16},()=>a.rng()),Array.from({length:16},()=>b.rng()));
console.log(JSON.stringify({name:'dense200',completeStateAndRngEqual:true}));
