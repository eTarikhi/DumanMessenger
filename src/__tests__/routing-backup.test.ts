import {expect,it} from 'vitest';
import {makeNode} from './helpers';
import {sourceBackupDecision} from '../routing-backup';
import {MeshSimulation} from '../simulation';
import {FailureDiagnostics} from '../failure-diagnostics';
import {buildScenario} from '../scenarios';
import type {MeshMessage,OGM} from '../types';
const fixture=()=>{
 const node=makeNode('a',0,0);node.peerIds=['p','b','c'];
 for(const id of ['b','c']){
  node.nextHopTable[id]={bestNeighbor:id,tq:.9,lastSeq:1,hopCount:1,lastSeen:1000,window:[1],windowNeighbor:id};
  node.ogmTable[id]={nodeId:id,seq:1,score:1,isSuper:false,peerCount:1,batteryBucket:8,bestHopTo:{dest:2},hopCount:0,neighborIds:[],declinedRouter:false} satisfies OGM;
 }
 const msg={id:'synthetic',from:'a',to:'dest',type:'text',attempt:0,hopCount:0,carried:false} as MeshMessage;
 const decision={mode:'route' as const,targets:['p'],reason:'primary'};
 return {node,msg,decision,peers:new Set(['p','b','c'])};
};
it('adds only one observed alternative with deterministic ranking, without mutating inputs',()=>{
 const {node,msg,decision,peers}=fixture();
 expect(sourceBackupDecision(node,msg,decision,peers,2000).targets).toEqual(['p','b']);
 expect(decision.targets).toEqual(['p']);
 node.ogmTable.c.bestHopTo.dest=1;
 expect(sourceBackupDecision(node,msg,decision,peers,2000).targets).toEqual(['p','c']);
});
it('does not replicate retries, carried bundles, relay copies, ACKs, floods or missing/stale/unheard routes',()=>{
 const {node,msg,decision,peers}=fixture();
 for(const patch of [{attempt:1},{carried:true},{from:'other'},{type:'ack' as const},{hopCount:4}])
  expect(sourceBackupDecision(node,{...msg,...patch},decision,peers,2000)).toBe(decision);
 expect(sourceBackupDecision(node,msg,{...decision,mode:'flood'},peers,2000).targets).toEqual(['p']);
 expect(sourceBackupDecision(node,msg,decision,new Set(),2000)).toBe(decision);
 expect(sourceBackupDecision(node,msg,decision,peers,12000)).toBe(decision);
 node.nextHopTable.b.tq=.1;node.nextHopTable.c.bestNeighbor='indirect';
 expect(sourceBackupDecision(node,msg,decision,peers,2000)).toBe(decision);
});
it('diagnostic ON/OFF preserves the new arm exactly, including RNG',()=>{
 const cfg=buildScenario('festival_crowd',4301),d=new FailureDiagnostics();
 const a=new MeshSimulation(cfg,undefined,4301^0x1347,undefined,'source-backup-v1');
 const b=new MeshSimulation(cfg,undefined,4301^0x1347,d,'source-backup-v1');
 for(let i=0;i<12;i++)for(const s of [a,b]){s.sendMessage(s.nodes[i].id,s.nodes[(i+20)%s.nodes.length].id,'synthetic','text');s.runFor(1500);}
 a.refresh();b.refresh();expect(b.stats).toEqual(a.stats);expect(b.nodes).toEqual(a.nodes);expect(b.deliveries).toEqual(a.deliveries);expect(b.rng()).toBe(a.rng());
},60000);
