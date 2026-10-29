/** Frozen three-arm bounded-source-diversity study; staged to lock diagnostic ML before holdout. */
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync,mkdirSync,readFileSync,writeFileSync } from 'node:fs';
import { MeshSimulation } from '../src/simulation';
import { FailureDiagnostics } from '../src/failure-diagnostics';
import { OGM_EPOCH_PROFILE, type RoutingResearchProfile } from '../src/routing-research';
import { buildScenario } from '../src/scenarios';
import { createRng } from '../src/rng';
import { trafficPlan,percentile } from './routing/strategies';
const phase=process.argv[3]??'development';if(!['development','final'].includes(phase))throw Error('Invalid phase');
const out=process.argv[2]??'artifacts/reliability';mkdirSync(out,{recursive:true});
const sourceSha=execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim();
const sourceFiles=['src/simulation.ts','src/election.ts','src/routing.ts','src/failure-diagnostics.ts','src/routing-research.ts','src/rf.ts','src/scenarios.ts','src/rng.ts','src/types.ts','src/events.ts','src/routing-backup.ts','tool/routing-reliability.ts','tool/routing/strategies.ts'];
const sourceHashes=Object.fromEntries(sourceFiles.map(p=>[p,createHash('sha256').update(readFileSync(p)).digest('hex')]));
const path=`${out}/experiments.json`;
const previous=existsSync(path)?JSON.parse(readFileSync(path,'utf8')):null;
if(previous&&(JSON.stringify(previous.sourceHashes)!==JSON.stringify(sourceHashes)||previous.node!==process.version))throw Error('Checkpoint source/toolchain mismatch');
const rows:any[]=previous?.rows??[];
function run(split:string,scenario:string,seed:number,duty:boolean,profile:RoutingResearchProfile,radio=false){
 if(rows.some(r=>r.split===split&&r.scenario===scenario&&r.seed===seed&&r.duty===duty&&r.profile===profile))return;
 const config={...buildScenario(scenario,seed),dutyCycleEnabled:duty,...(radio?{channelAccess:"csma" as const,channelCapture:"strongest" as const}:{})};
 const diagnostics=new FailureDiagnostics(),motionSeed=(seed^0x1347)>>>0,start=performance.now();
 const sim=new MeshSimulation(config,undefined,motionSeed,diagnostics,profile);
 const initialBattery=sim.nodes.map(n=>n.battery);
 const sent:Array<{id:string;at:number;from:string;to:string;features:Record<string,number>}>=[];
 for(const [i,[a,b]] of trafficPlan(seed,150,config.nodeCount,createRng).entries()){
  const src=sim.nodes[a],entry=src.nextHopTable[sim.nodes[b].id];
  const features={duty:Number(duty),elapsed:(sim.now-config.warmupMs)/225000,peers:src.peerIds.length/128,queue:src.oppQueue.length/500,battery:src.battery,super:Number(src.role==='SUPER'),hasRoute:Number(!!entry),hops:(entry?.hopCount??0)/6,tq:entry?.tq??0,age:entry?Math.min(1,(sim.now-entry.lastSeen)/30000):0};
  if(sim.nodes[a].isOnline&&sim.nodes[b].isOnline){const m=sim.sendMessage(sim.nodes[a].id,sim.nodes[b].id,`acc-${i}`,'text');if(m)sent.push({id:m.id,at:sim.now,from:m.from,to:m.to,features});}
  sim.runFor(1500);
 }
 sim.refresh();const stats=structuredClone(sim.stats),uni=sim.deliveries.filter(d=>d.type!=='ack'&&d.type!=='broadcast');
 if(sent.length!==stats.sentUnicast||new Set(uni.map(d=>d.msgId)).size!==uni.length)throw Error('Population drift');
 const messages=sent.map(m=>{const delivery=uni.find(d=>d.msgId===m.id);return {...m,
  outcome:delivery?(delivery.hops<=5?'five-hop-delivery':'delivered-over-five'):'not-delivered-at-horizon',delivery:delivery??null,
  queuedCopies:sim.nodes.filter(n=>n.oppQueue.some(q=>q.msg.id===m.id)).length,observations:diagnostics.messages.get(m.id)??null};});
 const tagCounts:Record<string,number>={};for(const m of messages)if(m.outcome!=='five-hop-delivery')for(const tag of Object.keys(m.observations?.counts??{}))tagCounts[tag]=(tagCounts[tag]??0)+1;
 const perNode=sim.nodes.map(n=>({id:n.id,tx:n.txCount,queue:n.oppQueue.length,roleChanges:n.roleTransitions,battery:n.battery}));
 const txs=perNode.map(n=>n.tx),total=txs.reduce((s,n)=>s+n,0),squares=txs.reduce((s,n)=>s+n*n,0);
 const prior=split==='audit'?JSON.parse(require('node:zlib').gunzipSync(readFileSync('reports/routing/2026-10-29-diagnosis/experiments.json.gz')).toString()).rows.find((r:any)=>r.scenario===scenario&&r.seed===seed&&r.duty===duty&&r.profile==='baseline'):null;
 if(split==='audit'&&(!prior||JSON.stringify(prior.stats)!==JSON.stringify(stats)))throw Error('Historical audit mismatch');
 const row={split,scenario,seed,duty,profile,config,motionSeed,configHash:createHash('sha256').update(JSON.stringify({config,motionSeed})).digest('hex'),
  sent:sent.length,five:uni.filter(d=>d.hops<=5).length,three:uni.filter(d=>d.hops<=3).length,overall:uni.length,
  totalTx:sim.nodes.reduce((s,n)=>s+n.txCount,0),relayTx:stats.totalForwarded,p50:percentile(uni.map(d=>d.latencyMs),.5),p95:percentile(uni.map(d=>d.latencyMs),.95),
  modeledBatteryDrain:sim.nodes.reduce((s,n,i)=>s+initialBattery[i]-n.battery,0),queueAtHorizon:sim.nodes.reduce((s,n)=>s+n.oppQueue.length,0),
  perNode,jainTx:squares?total*total/(txs.length*squares):1,maxTxShare:total?Math.max(...txs)/total:0,priorStatsMatch:split==='audit'?true:null,stats,messages,tagCounts,diagnosticOverflow:diagnostics.overflow,wallMs:performance.now()-start};
 rows.push(row);writeFileSync(path,JSON.stringify({sourceSha:previous?.sourceSha??sourceSha,sourceHashes,node:process.version,profiles:['baseline','ogm-epoch-v1','source-backup-v1'],experimental:true,productionEligible:false,rows}));
 console.error(split,scenario,seed,duty,profile,row.five,row.totalTx);
}
const profiles=['baseline','ogm-epoch-v1','source-backup-v1'] as const;
if(phase==='development') {
 for(const seed of [5301,5302,5303,5304,5305,5306])for(const duty of [false,true])run('audit','festival_crowd',seed,duty,'baseline');
 for(const seed of [4301,4302])for(const duty of [false,true])for(const p of profiles)run('development','festival_crowd',seed,duty,p);
} else {
 if(!existsSync(`${out}/local-feature-model.json`))throw Error('Freeze offline feature model before final');
 for(const seed of [7401,7402,7403,7404])for(const duty of [false,true])for(const p of profiles)run('final','festival_crowd',seed,duty,p);
 for(const scenario of ['campus_quad','sparse_village','partitioned_pair'])for(const duty of [false,true])for(const p of profiles)run('protected',scenario,7501,duty,p);
 for(const duty of [false,true])for(const p of ['baseline','source-backup-v1'] as const)run('radio-sensitivity','festival_crowd',7401,duty,p,true);
}
