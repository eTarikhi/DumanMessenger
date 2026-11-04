import { expect,it } from 'vitest';
import { FailureDiagnostics } from '../failure-diagnostics';
import { MeshSimulation } from '../simulation';
import { buildScenario } from '../scenarios';
it('bounded collector preserves first event and limits detail/examples/keys',()=>{
 const d=new FailureDiagnostics(1,1,1);
 d.record('m',10,'loss','x'.repeat(500));d.record('m',20,'loss','y');d.record('other',0,'loss');
 d.receive('m',0,'b','a');d.receive('m',0,'c','b');
 expect(d.messages.size).toBe(1);expect(d.overflow).toBe(2);
 expect(d.messages.get('m')?.first.loss).toBe(10);expect(d.messages.get('m')?.counts.loss).toBe(2);
 expect(d.messages.get('m')?.examples).toHaveLength(1);expect(d.messages.get('m')?.examples[0].detail).toHaveLength(240);
 d.decision('m',30,0,'b',['a'],'route','reverse',2,11000,4);
 expect(d.messages.get('m')?.counts['route-reverse-to-sender']).toBe(1);
 expect(d.messages.get('m')?.counts['advertised-route-over-five']).toBe(1);
});
it('opt-in diagnosis preserves complete statistics, deliveries, nodes, logs and RNG state',()=>{
 const c={...buildScenario('festival_crowd',3301),captureLog:true,maxLogEntries:2000};
 const a=new MeshSimulation(c,undefined,3301^0x1347),d=new FailureDiagnostics(),b=new MeshSimulation(c,undefined,3301^0x1347,d);
 for(let i=0;i<12;i++)for(const s of [a,b]){
  s.sendMessage(s.nodes[i].id,s.nodes[(i+20)%s.nodes.length].id,`synthetic-${i}`,'text');s.runFor(1500);
 }
 a.refresh();b.refresh();
 expect(b.stats).toEqual(a.stats);expect(b.deliveries).toEqual(a.deliveries);
 expect(b.nodes).toEqual(a.nodes);expect(b.log).toEqual(a.log);
 expect(b.rng()).toBe(a.rng());expect(d.messages.size).toBeGreaterThan(0);
},60000);
