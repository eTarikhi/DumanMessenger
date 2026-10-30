/** Bounded offline search. Output is evidence, never an auto-promoted live policy. */
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { MeshSimulation } from "../src/simulation";
import { buildScenario, scenarioNames } from "../src/scenarios";
import { createRng } from "../src/rng";
import { STRATEGIES, applyStrategy, trafficPlan, percentile } from "./routing/strategies";

const args = process.argv.slice(2);
for (const arg of args.filter(a => a.startsWith("--"))) {
  if (!["--smoke", "--ood"].includes(arg)) throw Error(`Unknown flag ${arg}`);
}
const output = args.find(a => !a.startsWith("--")) ?? "artifacts/routing/benchmark.json";
const ood = args.includes("--ood");
const smoke = process.argv.includes("--smoke");
const partitions = ood ? { ood: [424242, 8675309, 65537] } :
  smoke ? { smoke: [42] } : { train: [42, 7, 1234], validation: [31415, 27182, 16180] };
const sourceSha = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const dirtyAtStart = execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim();
const rows: object[] = [];
for (const [split, seeds] of Object.entries(partitions)) for (const seed of seeds)
for (const scenario of (ood ? ["festival_crowd", "campus_quad"] : scenarioNames()))
for (const duty of [false, true]) {
  const base = { ...buildScenario(scenario, seed), dutyCycleEnabled: duty };
  // Separate scenario/model combinations, never used for tuning. Static crowd
  // removes policy-dependent RNG consumption as a mobility confound; CSMA stresses queues.
  if (ood && scenario === "festival_crowd") base.enableMobility = false;
  if (ood && scenario === "campus_quad") {
    base.channelAccess = "csma";
    base.channelCapture = "strongest";
    base.channelBackoff = "binary";
  }
  const plan = trafficPlan(seed, 150, base.nodeCount, createRng);
  for (const strategy of STRATEGIES) {
    const config = applyStrategy(base, strategy.id, true);
    const start = performance.now();
    const sim = new MeshSimulation(config);
    let sent = 0;
    for (let i = 0; i < plan.length; i++) {
      const [a, b] = plan[i];
      if (sim.nodes[a].isOnline && sim.nodes[b].isOnline &&
          sim.sendMessage(sim.nodes[a].id, sim.nodes[b].id, `acc-${i}`, "text")) sent++;
      sim.runFor(1500);
    }
    sim.refresh();
    const uni = sim.deliveries.filter(d => d.type !== "ack" && d.type !== "broadcast");
    if (new Set(uni.map(d => d.msgId)).size !== uni.length) throw Error("Duplicate gate population");
    if (sim.stats.sentUnicast !== sent) throw Error("Sent denominator mismatch");
    const count = (h: number) => uni.filter(d => d.hops <= h).length;
    const row = { split, scenario, seed, strategy: strategy.id, duty, config, sent,
      delivered: uni.length, withinFive: count(5), fiveRatio: count(5) / Math.max(1, sent),
      threeRatio: count(3) / Math.max(1, sent), deliveryRatio: uni.length / Math.max(1, sent),
      hopsMean: uni.length ? uni.reduce((s, d) => s + d.hops, 0) / uni.length : null,
      hopsP95: percentile(uni.map(d => d.hops), .95),
      latencyP95Ms: percentile(uni.map(d => d.latencyMs), .95),
      latencyMeanMs: uni.length ? uni.reduce((s, d) => s + d.latencyMs, 0) / uni.length : null,
      undeliveredAtHorizon: sent - uni.length,
      // Not all undelivered messages have expired: DTN may retain them for seven days.
      stats: sim.stats, totalTx: sim.nodes.reduce((s, n) => s + n.txCount, 0),
      wallMs: performance.now() - start };
    rows.push(row);
    console.error(`${split} ${scenario} ${seed} duty=${duty} ${strategy.id}: ${count(5)}/${sent}`);
  }
}
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, JSON.stringify({ schemaVersion: 1,
  sourceSha, dirtyAtStart,
  engine: "typescript-reference", node: process.version,
  protocol: { messages: 150, gapMs: 1500, drainMs: 0, primary: "unicast deliveries with hops<=5 / successful sends", partitions },
  strategies: STRATEGIES, rows }, null, 2) + "\n");
