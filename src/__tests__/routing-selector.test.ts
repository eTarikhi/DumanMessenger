import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
import { describe,it,expect } from "vitest";
import { RoutingSelector, normalizeContext, validateModel, type SelectorMode } from "../routing-selector";
import { MeshSimulation } from "../simulation";
import { campusQuad } from "../scenarios";
import { loadSelector } from "../../tool/routing/load-selector";
const fixture=JSON.parse(readFileSync("test-fixtures/routing-selector.json","utf8"));
const model={schema:1,api:1,experimental:true,threshold:8,left:"baseline-v1",right:"ack-6000-v1",confidence:1};
const context={neighbors:20,queue:0,duty:0,battery:.8,saver:false,observedAt:0};
describe("shadow routing deployment safety",()=>{
  for(const test of fixture.cases) it(test.name,()=>{
    const s=new RoutingSelector({mode:test.mode as SelectorMode,model:test.model});
    for(const step of test.steps) expect(s.decide(step.context,step.now)).toEqual(step.expected);
  });
  it("rejects nonfinite inputs, exceptions, and all incompatible outputs",()=>{
    for(const n of [NaN,Infinity,-Infinity]) {
      expect(validateModel({...model,confidence:n})).toBeNull();
      expect(normalizeContext({...context,neighbors:n},0)).toBeNull();
    }
    expect(validateModel(new Proxy({}, {get(){throw Error('bad model')}}))).toBeNull();
    const s=new RoutingSelector({mode:"shadow",model});
    const result=s.decide(new Proxy(context,{get(){throw Error('inference fault')}}),0);
    expect(result.reason).toBe("inference-error");
    expect(s.decide(context,0).reason).toBe("latched-baseline");
  });
  it("copies the model and supports irreversible session rollback",()=>{
    const raw={...model};const s=new RoutingSelector({mode:"shadow",model:raw});raw.right="flood-all";
    for(let t=0;t<=2;t++)s.decide({...context,observedAt:t},t);
    expect(s.decide({...context,observedAt:3},3).proposed).toBe("ack-6000-v1");
    s.rollback();expect(s.decide(context,3).proposed).toBe("baseline-v1");
  });
  it("verifies artifact integrity before parsing and bounds load size",()=>{
    const dir=mkdtempSync(`${tmpdir()}/selector-`),path=`${dir}/model.json`;
    try {
      const raw=JSON.stringify(model);writeFileSync(path,raw);
      const hash=createHash("sha256").update(raw).digest("hex");
      expect(loadSelector(path,hash)).toEqual(model);
      writeFileSync(path,JSON.stringify({...model,right:"flood-all"}));
      expect(loadSelector(path,hash)).toBeNull();
      writeFileSync(path," ".repeat(4097));
      expect(loadSelector(path,createHash("sha256").update(" ".repeat(4097)).digest("hex"))).toBeNull();
    } finally { rmSync(dir,{recursive:true,force:true}); }
  });
  it("normalizes boundaries and fails model load closed",()=>{
    expect(normalizeContext({...context,neighbors:128,queue:500,duty:1,battery:0},0)).toEqual([1,1,1]);
    expect(loadSelector("missing-model.json","0".repeat(64))).toBeNull();
    expect(loadSelector("test-fixtures/routing-selector.json","0".repeat(64))).toBeNull();
  });
  it.each(["baseline","shadow","canary"] as const)("%s integration leaves exact baseline routing intact",mode=>{
    const cfg=campusQuad(42),baseline=new MeshSimulation(cfg),shadow=new MeshSimulation(cfg,{mode,model});
    for(let i=0;i<20;i++) {
      for(const sim of [baseline,shadow]) {sim.sendMessage(sim.nodes[i%20].id,sim.nodes[(i+5)%20].id,`m${i}`,"text");sim.runFor(1500);sim.refresh();}
    }
    expect(shadow.deliveries).toEqual(baseline.deliveries);
    expect(shadow.stats).toEqual(baseline.stats);
    expect(shadow.selectorDiagnostics.length).toBeGreaterThan(0);
    expect(shadow.selectorDiagnostics.every(d=>d.applied==="baseline-v1")).toBe(true);
    shadow.rollbackRoutingSelector();
  });
  it("isolates motion reproducibly when explicitly requested",()=>{
    const cfg=campusQuad(7);
    const a=new MeshSimulation(cfg,undefined,77),b=new MeshSimulation({...cfg,ackTimeoutMs:6000},undefined,77);
    for(const s of [a,b]) {s.sendMessage(s.nodes[0].id,s.nodes[10].id,"motion","text");s.runFor(30000);}
    expect(a.nodes.map(n=>n.pos)).toEqual(b.nodes.map(n=>n.pos));
  });
});
