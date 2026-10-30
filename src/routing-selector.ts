/** Dependency-free, immutable, shadow-first deployment interface. No user data or IO. */
export const SELECTOR_API = 1;
export type RoutingAction = "baseline-v1" | "ack-6000-v1";
export type SelectorMode = "baseline" | "shadow" | "canary";
export interface LocalContext {
  neighbors: number; queue: number; duty: number; battery: number;
  saver: boolean; observedAt: number;
}
export interface RoutingModel {
  schema: 1; api: 1; experimental: true; threshold: number;
  left: RoutingAction; right: RoutingAction; confidence: number;
}
export interface SelectorOptions { mode: SelectorMode; model?: unknown }
export interface SelectorDecision {
  proposed: RoutingAction; applied: RoutingAction; reason: string; switches: number;
}
function action(x: unknown): x is RoutingAction { return x === "baseline-v1" || x === "ack-6000-v1"; }
export function validateModel(raw: unknown): Readonly<RoutingModel> | null {
  if (!raw || typeof raw !== "object") return null;
  try {
  const m = raw as Record<string, unknown>;
  if (m.schema !== 1 || m.api !== SELECTOR_API || m.experimental !== true ||
      typeof m.threshold !== "number" || !Number.isFinite(m.threshold) ||
      ![4,8,12,16,24].includes(m.threshold) || !action(m.left) || !action(m.right) ||
      typeof m.confidence !== "number" || !Number.isFinite(m.confidence) || m.confidence < 0 || m.confidence > 1) return null;
  return Object.freeze({schema:1,api:1,experimental:true,threshold:m.threshold,
    left:m.left,right:m.right,confidence:m.confidence});
  } catch { return null; }
}
export function normalizeContext(c: LocalContext, now: number): number[] | null {
  if (![now,c.observedAt,c.neighbors,c.queue,c.duty,c.battery].every(Number.isFinite) ||
      c.observedAt > now || now-c.observedAt > 10000 ||
      c.neighbors<0 || c.neighbors>128 || c.queue<0 || c.queue>500 ||
      !Number.isInteger(c.neighbors) || !Number.isInteger(c.queue) ||
      ![0,1].includes(c.duty) || c.battery<0 || c.battery>1 || typeof c.saver!=="boolean") return null;
  return [c.neighbors/128,c.duty,c.queue/500];
}
export class RoutingSelector {
  private readonly model: Readonly<RoutingModel> | null;
  private readonly mode: SelectorMode;
  private current: RoutingAction = "baseline-v1";
  private pending: RoutingAction = "baseline-v1";
  private votes = 0;
  private lastVoteAt = -Infinity;
  private lastSwitch = -Infinity;
  private lastNow = -Infinity;
  private changes = 0;
  private latched = false;
  constructor(options: SelectorOptions = {mode:"baseline"}) {
    this.mode = options.mode;
    this.model = validateModel(options.model);
  }
  /** Rollback/fault persists for the lifetime of this controller. Construct a new session to rearm. */
  rollback(): void { this.latched=true; this.current="baseline-v1"; }
  decide(c: LocalContext, now: number): SelectorDecision {
    try { return this.evaluate(c,now); }
    catch { this.rollback();return {proposed:"baseline-v1",applied:"baseline-v1",reason:"inference-error",switches:this.changes}; }
  }
  private evaluate(c: LocalContext, now: number): SelectorDecision {
    const answer=(reason:string):SelectorDecision=>({proposed:this.current,applied:"baseline-v1",reason,switches:this.changes});
    if(this.mode==="baseline") return answer("baseline-mode");
    if(this.latched) return answer("latched-baseline");
    if(!["shadow","canary"].includes(this.mode)||!this.model) {this.rollback();return answer("invalid-model");}
    const normalized=normalizeContext(c,now);
    if(!normalized||now<this.lastNow) {this.rollback();return answer("invalid-context");}
    this.lastNow=now;
    if(c.saver||c.battery<.25||c.duty===1) {this.current="baseline-v1";this.votes=0;this.pending="baseline-v1";return answer("power-override");}
    if(this.model.confidence<.6) return answer("low-confidence");
    const proposal=normalized[0]<=this.model.threshold/128?this.model.left:this.model.right;
    if(c.observedAt>this.lastVoteAt) {
      if(proposal!==this.pending) {this.pending=proposal;this.votes=1;} else this.votes++;
      this.lastVoteAt=c.observedAt;
    }
    if(proposal!==this.current&&this.votes>=3&&now-this.lastSwitch>=30000&&this.changes<4) {
      this.current=proposal;this.lastSwitch=now;this.changes++;
    }
    // No artifact is production approved. Even canary mode cannot activate a candidate.
    return answer(this.mode==="canary"?"approval-required":"shadow-only");
  }
}
