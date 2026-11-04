import { expect, it } from 'vitest';
import { TqHistory } from '../tq-history';
import { pruneStaleEntries, TQ_PAIR_MAX } from '../election';
import { createNodes, DEFAULT_CONFIG } from '../simulation';
import { createRng } from '../rng';
import type { NextHopEntry } from '../types';

function route(lastSeen = 0): NextHopEntry {
  return { bestNeighbor:'p0',tq:1,lastSeq:1,hopCount:1,lastSeen,window:[1],windowNeighbor:'p0' };
}
function node(indexed: boolean) {
  const n = createNodes(createRng(1), {...DEFAULT_CONFIG,nodeCount:1})[0];
  n.tqWindows = indexed ? new TqHistory() : new Map();
  return n;
}
it('keeps ordinary Map set/overwrite/delete/reinsert ordering and value identity',()=>{
  const map = new TqHistory(), plain = new Map();
  for (const key of ['a|b','c|d','a|b','unseparated','|empty','left|','a|b|c']) {
    const value={lastSeq:2,window:[1,0]};map.set(key,value);plain.set(key,value);
    expect(map.get(key)).toBe(value);
  }
  expect(map.delete('absent')).toBe(false);
  map.delete('a|b');plain.delete('a|b');
  map.set('a|b',{lastSeq:3,window:[1]});plain.set('a|b',{lastSeq:3,window:[1]});
  expect([...map]).toEqual([...plain]);expect(Object.keys(map)).toEqual([]);
});
it('matches plain-Map pruning after 2000 deterministic mutations, overwrites, expiry and clears',()=>{
  const fast=node(true), plain=node(false),rng=createRng(903);
  for(let step=0;step<2000;step++){
    const origin='o'+Math.floor(rng()*20),via='p'+Math.floor(rng()*10),key=origin+'|'+via;
    const action=Math.floor(rng()*7),seq=Math.floor(rng()*99);
    for(const n of [fast,plain]){
      if(action<3){n.tqWindows.set(key,{lastSeq:seq,window:[1,seq%2]});n.nextHopTable[origin]=route(step);}
      if(action===3)n.tqWindows.delete(key);
      if(action===4)delete n.nextHopTable[origin];
      if(action===5)n.peerIds=['p0','p2','p4','p6','p8'];
      if(action===6)n.peerIds=['p1','p3','p5','p7','p9'];
      if(step%251===0)n.tqWindows.clear();
    }
    expect(pruneStaleEntries(fast,step,37)).toBe(pruneStaleEntries(plain,step,37));
    expect([...fast.tqWindows]).toEqual([...plain.tqWindows]);
    expect(fast.nextHopTable).toEqual(plain.nextHopTable);
    expect(fast.ogmTable).toEqual(plain.ogmTable);
  }
});
it('evicts exactly the same oldest entries above the existing cap and releases cleared indexes',()=>{
  const fast=node(true),plain=node(false);
  for(const n of [fast,plain]){
    n.peerIds=['peer'];
    for(let i=0;i<TQ_PAIR_MAX+30;i++){
      n.nextHopTable['o'+i]=route();n.tqWindows.set('o'+i+'|peer',{lastSeq:i,window:[1]});
    }
    pruneStaleEntries(n,1,100);
  }
  expect(fast.tqWindows.size).toBe(TQ_PAIR_MAX);expect([...fast.tqWindows]).toEqual([...plain.tqWindows]);
  fast.tqWindows.clear();
  fast.tqWindows.set('new|peer',{lastSeq:1,window:[1]});
  expect(pruneStaleEntries(fast,1,100)).toBe(0);expect(fast.tqWindows.size).toBe(0);
  // Only implementation metadata is inspected: retained empty groups would leak.
  for(const key of ['origins','vias'])expect(Object.getOwnPropertyDescriptor(fast.tqWindows,key)!.value.size).toBe(0);
});
