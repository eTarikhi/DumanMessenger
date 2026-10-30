/** Opt-in bounded observations, not causal labels. Never calls RNG or changes forwarding. */
export interface DiagnosticRecord {
  counts: Record<string,number>;
  first: Record<string,number>;
  examples: Array<{at:number;kind:string;detail:string}>;
}
export class FailureDiagnostics {
  readonly messages = new Map<string,DiagnosticRecord>();
  overflow = 0;
  private readonly incoming = new Map<string,string>();
  constructor(readonly maxMessages=1000, readonly exampleLimit=8, readonly maxIncoming=50000) {}
  record(id:string,at:number,kind:string,detail=""):void {
    let row=this.messages.get(id);
    if(!row) {
      if(this.messages.size>=this.maxMessages){this.overflow++;return;}
      row={counts:{},first:{},examples:[]};this.messages.set(id,row);
    }
    row.counts[kind]=(row.counts[kind]??0)+1;
    if(row.first[kind]===undefined)row.first[kind]=at;
    if(row.examples.length<this.exampleLimit)row.examples.push({at,kind,detail:detail.slice(0,240)});
  }
  receive(id:string,attempt:number,node:string,via:string):void {
    // Explicit hard cap even with arbitrary attempt/node identifiers.
    const key=`${id}/${attempt}/${node}`;
    if(this.incoming.has(key)||this.incoming.size<this.maxIncoming) {
      if(this.messages.has(id)||this.messages.size<this.maxMessages)this.incoming.set(key,via);
    } else this.overflow++;
  }
  decision(id:string,at:number,attempt:number,node:string,targets:string[],mode:string,detail:string,
    routeHops:number|null,age:number|null,hop:number):void {
    this.record(id,at,`decision:${mode}`,detail);
    if(mode==='route') {
      const via=this.incoming.get(`${id}/${attempt}/${node}`);
      if(via&&targets.includes(via))this.record(id,at,'route-reverse-to-sender',detail);
      if(routeHops!==null&&routeHops+hop>5)this.record(id,at,'advertised-route-over-five',`${routeHops}+${hop}`);
      if(age!==null&&age>10000)this.record(id,at,'route-age-over-10s',String(age));
    }
  }
  log(id:string,at:number,kind:string,detail:string):void {
    const tag=kind==='loss'?(detail.includes('queue full')?'radio-queue-full':detail.includes('receiver')?'radio-receiver-loss':'radio-link-loss'):
      kind==='duplicate'?'duplicate-suppression':
      detail.includes('TTL exhausted')?'ttl-exhausted':detail.includes('retries exhausted')?'source-retries-exhausted':
      detail.includes('MPR-suppressed')?'mpr-suppression':kind==='queue'?'queued':null;
    if(tag)this.record(id,at,tag,detail);
  }
}
