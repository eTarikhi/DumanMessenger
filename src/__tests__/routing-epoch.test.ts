import { expect,it } from 'vitest';
import { receiveOGM } from '../election';
import { makeNode } from './helpers';
import type { OGM } from '../types';
import { validateResearchProfile,OGM_EPOCH_PROFILE } from '../routing-research';
it('fresh epoch replaces historical minimum and late old sequences cannot revert it',()=>{
 const base=makeNode('observer',0,0),fresh=makeNode('observer',0,0);
 const ogm=(seq:number,hopCount:number):OGM=>({nodeId:'dest',seq,hopCount,score:.5,isSuper:false,peerCount:1,batteryBucket:8,bestHopTo:{},neighborIds:[],declinedRouter:false});
 for(const n of [base,fresh])receiveOGM(n,ogm(10,1),'old',1000);
 receiveOGM(base,ogm(11,3),'new',2000);
 receiveOGM(fresh,ogm(11,3),'new',2000,'ogm-epoch-v1');
 expect(base.nextHopTable.dest.bestNeighbor).toBe('old');expect(base.nextHopTable.dest.lastSeen).toBe(2000);
 expect(fresh.nextHopTable.dest.bestNeighbor).toBe('new');expect(fresh.nextHopTable.dest.hopCount).toBe(4);
 receiveOGM(fresh,ogm(10,0),'old',2100,'ogm-epoch-v1');
 expect(fresh.nextHopTable.dest.bestNeighbor).toBe('new');
 receiveOGM(fresh,ogm(11,1),'shorter',2200,'ogm-epoch-v1');
 expect(fresh.nextHopTable.dest.bestNeighbor).toBe('shorter');
});
it('finite research registry rejects arbitrary and malformed profiles',()=>{
 expect(()=>validateResearchProfile('unbounded-flood')).toThrow();expect(()=>validateResearchProfile({id:'ogm-epoch-v1'})).toThrow();
 expect(OGM_EPOCH_PROFILE.productionEligible).toBe(false);expect(Object.isFrozen(OGM_EPOCH_PROFILE)).toBe(true);
});
