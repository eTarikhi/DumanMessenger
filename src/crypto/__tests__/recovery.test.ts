import { expect, it } from 'vitest';
import { nodePrimitives as p } from '../primitives';
import { MAX_SKIP, SymmetricRatchet } from '../ratchet';
import { DumanSession } from '../session';
import { generateIdentity } from '../identity';
import { encodeHeader, type PacketHeader } from '../packet';

it('rejects a forgery without consuming the genuine current or skipped message key',()=>{
 const seed=p.randomBytes(32),send=new SymmetricRatchet(p,seed),recv=new SymmetricRatchet(p,seed);
 const messages=Array.from({length:4},()=>send.seal(new Uint8Array([1,2,3])));
 const forged=Uint8Array.from(messages[2].sealed);forged[0]^=1;
 expect(recv.open(2,forged).ok).toBe(false);expect(recv.nextExpectedNum).toBe(0);
 expect(recv.open(2,messages[2].sealed).ok).toBe(true);
 expect(recv.open(0,forged).ok).toBe(false);
 expect(recv.open(0,messages[0].sealed).ok).toBe(true);
 expect(recv.open(0,messages[0].sealed).ok).toBe(false);
});
it('bounds skipped keys across multiple authenticated gaps, evicting the oldest',()=>{
 const seed=p.randomBytes(32),send=new SymmetricRatchet(p,seed),recv=new SymmetricRatchet(p,seed);
 const messages=Array.from({length:200},()=>send.seal(new Uint8Array([1])));
 for(const n of [64,129,194]){expect(recv.open(n,messages[n].sealed).ok).toBe(true);expect(recv.cachedSkips).toBeLessThanOrEqual(MAX_SKIP);}
 expect(recv.open(0,messages[0].sealed).ok).toBe(false);
 expect(recv.open(193,messages[193].sealed).ok).toBe(true);
});
it('rolls back candidate keys even if the crypto provider throws',()=>{
 const r=new SymmetricRatchet(p,p.randomBytes(32)),before=r.compromise();
 expect(()=>r.withReceiveKey(5,()=>{throw Error('provider failure');})).toThrow();
 expect(r.compromise()).toEqual(before);
});
it('session authentication failure cannot desynchronize the next legitimate packet',()=>{
 const alice=generateIdentity(p),bob=generateIdentity(p),context=new Uint8Array([7]);
 const a=new DumanSession(p,alice,'initiator',context),b=new DumanSession(p,bob,'responder',context);
 b.readLeg(a.writeLeg()!);a.readLeg(b.writeLeg()!);b.readLeg(a.writeLeg()!);
 const packet=a.send({msgId:'synthetic',type:'text',ttl:6,hop:0,nowMs:0,body:new Uint8Array([1])},bob.signing.publicKey)!;
 const forged=Uint8Array.from(packet);forged[forged.length-1]^=1;
 expect(b.receive(forged).ok).toBe(false);expect(b.receive(packet).ok).toBe(true);expect(b.receive(packet).ok).toBe(false);
});
it('rejects noncanonical/truncated header fields rather than silently truncating them',()=>{
 const good:PacketHeader={msgIdDigest:new Uint8Array(16),destHint:new Uint8Array(8),ttl:6,hop:0,type:'text'};
 for(const patch of [{ttl:NaN},{hop:1.5},{ttl:Infinity},{msgIdDigest:new Uint8Array(15)},{destHint:new Uint8Array(9)}])
  expect(()=>encodeHeader({...good,...patch})).toThrow(RangeError);
 expect(encodeHeader(good)).toHaveLength(27);
});

it('zeroizes a send key even when the crypto provider throws without reusing its number',()=>{
 let captured:Uint8Array|undefined;
 const broken={...p,seal:(key:Uint8Array)=>{captured=key;throw Error('provider failure');}};
 const r=new SymmetricRatchet(broken,p.randomBytes(32));
 expect(()=>r.seal(new Uint8Array([1]))).toThrow('provider failure');
 expect(captured).toBeDefined();expect(Array.from(captured!)).toEqual(Array(32).fill(0));expect(r.nextSendNum).toBe(1);
});
