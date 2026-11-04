import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { expect,it } from "vitest";
import { validateModel } from "../routing-selector";
import { buildScenario } from "../scenarios";
const dir="reports/routing/2026-10-28-evolution";
const bytes=readFileSync(`${dir}/policy.json`),policy=JSON.parse(bytes.toString());
const data=JSON.parse(readFileSync(`${dir}/runs.json`,"utf8"));
it("keeps learned parameter artifacts immutable, checksummed and rejected by the live selector",()=>{
  expect(createHash("sha256").update(bytes).digest("hex")).toBe(readFileSync(`${dir}/policy.sha256`,"utf8").trim());
  expect(policy.status).toBe("offline-experimental-not-approved");
  expect(validateModel(policy)).toBeNull();
});
it("retains fixed disjoint seed blocks and unchanged metric/config population",()=>{
  const allowed:Record<string,number[]>={train:[1101,1102],validation:[2201,2202,2203],holdout:[3301,3302,3303],protected:[2201,2202]};
  expect(data.rows).toHaveLength(80);
  for(const r of data.rows) {
    expect(allowed[r.split]).toContain(r.seed);
    expect(r.sent).toBe(150);expect(r.ratio).toBe(r.five/r.sent);
    expect(r.five).toBeLessThanOrEqual(r.delivered);expect(r.three).toBeLessThanOrEqual(r.five);
    expect(r.config).toEqual({...buildScenario(r.scenario,r.seed),dutyCycleEnabled:r.duty,
      ogmIntervalMs:r.policy.beacon,ackTimeoutMs:r.policy.ack});
  }
});
it("selected profiles maximize the declared TRAIN-only worst-seed objective",()=>{
  for(const duty of [false,true]) {
    const score=(p:{beacon:number;ack:number})=>{
      const rs=data.rows.filter((r:any)=>r.split==="train"&&r.duty===duty&&r.policy.beacon===p.beacon&&r.policy.ack===p.ack);
      expect(rs).toHaveLength(2);
      return [Math.min(...rs.map((r:any)=>r.ratio)),rs.reduce((s:number,r:any)=>s+r.ratio,0),-rs.reduce((s:number,r:any)=>s+r.stats.totalForwarded,0)];
    };
    const winner=score(policy.selected[duty?1:0]);
    for(const candidate of policy.population) {
      const other=score(candidate);
      const first=winner.findIndex((v:number,i:number)=>v!==other[i]);
      if(first>=0)expect(winner[first]).toBeGreaterThan(other[first]);
    }
  }
});
