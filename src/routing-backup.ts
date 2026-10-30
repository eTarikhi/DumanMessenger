import type { MeshMessage, MeshNode } from './types';
import type { ForwardDecision } from './routing';
/** Bounded OFFLINE first-hop diversity, not a claim of disjoint end-to-end paths.
 * Reads only this node's received advertisements and discovered direct-neighbor entries.
 * Caller intersects discoveries with current radio reachability, as baseline routing does.
 */
export function sourceBackupDecision(node: MeshNode, msg: MeshMessage, decision: ForwardDecision,
  reachable: ReadonlySet<string>, now: number): ForwardDecision {
  if(msg.type!=='text'||msg.from!==node.id||msg.attempt!==0||msg.carried||decision.mode!=='route'||decision.targets.length!==1)return decision;
  const candidates=node.peerIds.filter(id=>id!==decision.targets[0]&&id!==msg.from&&reachable.has(id)).map(id=>({id,
    link:node.nextHopTable[id],hops:node.ogmTable[id]?.bestHopTo[msg.to]})).filter(c=>
      c.link?.bestNeighbor===c.id&&c.link.hopCount===1&&c.link.tq>=.6&&
      now>=c.link.lastSeen&&now-c.link.lastSeen<=10000&&Number.isInteger(c.hops)&&c.hops>=1&&c.hops+1+msg.hopCount<=5);
  candidates.sort((a,b)=>a.hops-b.hops||b.link.tq-a.link.tq||(a.id<b.id?-1:a.id>b.id?1:0));
  if(!candidates.length)return decision;
  return {...decision,targets:[decision.targets[0],candidates[0].id],reason:`${decision.reason}; research bounded source backup ${candidates[0].id}`};
}
