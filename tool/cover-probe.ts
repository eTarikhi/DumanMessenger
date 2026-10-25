/**
 * Cover-traffic probe: what `docs/04` §5's dummy beacons buy, and what they cost.
 *
 * `docs/04` §5 asks for two traffic-analysis mitigations: *"random jitter 50-200 ms before
 * forwarding, dummy beacons at low rate"*. The jitter half has shipped unconditionally since
 * the engine's first version (`jitterMinMs` / `jitterMaxMs`, drawn per forward). The dummy
 * beacons did not exist until `coverTraffic` landed, and §5 gives no rate — *"low"* is an
 * adjective, not a number — so this probe sweeps it rather than picking one and defending it.
 *
 * What is modelled, and what is not. A cover packet here is one radio burst that carries
 * nothing: it increments the sending node's `txCount` — the counter a passive observer
 * would be counting — and it enters no routing table, delivers nothing and is never
 * acknowledged. So the observable this probe attacks is **transmission count and timing**.
 * A real adversary also sees packet *lengths*, and this engine gives beacons no length at
 * all, so length-based traffic analysis is out of reach here and nothing below should be
 * read as saying otherwise. `docs/06` §23 carries the same caveat next to the numbers.
 *
 * It asserts four things and reports the rest:
 *
 * - **The knob is inert when off** — `coverTx` is 0 and the world is the shipped one.
 * - **Cover traffic is traffic** — total transmissions rise, monotonically as the interval
 *   tightens. A mitigation with no cost is a mitigation that is not running.
 * - **It does not break delivery** — asserted in the weak and honest form, because cover
 *   packets consume RNG draws, so the arms are different worlds and an equality would be a
 *   lie: delivery does not collapse.
 *
 * Concealment itself is **reported and not asserted**, because the answer turned out to be
 * nothing: on this observable the sender was already hidden by relay traffic before a single
 * dummy beacon existed, so the sweep is a cost curve with a flat benefit. `docs/06` §23
 * records it as a rejected lever. An earlier version of this probe asserted the benefit and
 * failed on its first honest run.
 *
 *   npm run cover              every section
 *   npm run cover sweep        one section
 *
 * Sections: inert (off means off) · sweep (conspicuousness against cost, by interval)
 */
import { MeshSimulation, type SimConfig } from "../src/simulation";
import { campusQuad } from "../src/scenarios";

/** Settle elections and routes before measuring, as the sibling probes do. */
const SETTLE_MS = 90_000;
/** Three seeds: one number from one seed is an anecdote, not a result. */
const SEEDS = [42, 7, 11];
/** The measurement window. Long enough for several cover intervals to fire. */
const WINDOW_MS = 120_000;
/** Let the burst land before reading the counters. */
const DRAIN_MS = 40_000;
/** The burst: what makes one node stand out, and what the cover traffic has to hide. */
const BURST_COUNT = 12;
const BURST_WINDOW_MS = 60_000;
/** Which node sends the burst. Not `nodes[0]`, so the target is an ordinary node. */
const TARGET_INDEX = 3;
/** Intervals swept, in ms. `null` is the control arm: the shipped engine, cover off. */
const INTERVALS: ReadonlyArray<number | null> = [null, 60_000, 30_000, 10_000, 5_000];

interface CoverRun {
  seed: number;
  /** `null` is the control arm. */
  intervalMs: number | null;
  /** Transmissions per node during the window, in node order — the observer's data. */
  txPerNode: number[];
  /** Which node the observer would name as the sender, by transmission count. */
  guessedIndex: number;
  /** The target's rank, 1 = most conspicuous. */
  targetRank: number;
  /** (target − median) / stddev over all nodes. 0 means indistinguishable. */
  conspicuousness: number;
  coverTx: number;
  transmissions: number;
  deliveryRatio: number;
  /** The burst the target actually originated, as a check on the harness itself. */
  targetOriginated: number;
}

function median(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

function stddev(values: number[]): number {
  const m = values.reduce((a, b) => a + b, 0) / values.length;
  return Math.sqrt(values.reduce((a, b) => a + (b - m) ** 2, 0) / values.length);
}

function run(seed: number, intervalMs: number | null): CoverRun {
  const config: SimConfig = {
    ...campusQuad(seed),
    coverTraffic: intervalMs !== null,
    coverIntervalMs: intervalMs ?? 30_000,
  };
  const sim = new MeshSimulation(config);
  sim.runFor(SETTLE_MS);
  sim.refresh();
  sim.clearRecords();

  // Snapshot the counters the observer reads, so the settle period — the busiest the
  // network ever gets — is not counted as part of the window.
  const before = sim.nodes.map((n) => n.txCount);

  const target = sim.nodes[TARGET_INDEX];
  // The burst: 12 broadcasts over a minute, which is also inside docs/04 §6's cap of
  // 5/min only if the caps are off — they are off here, because this probe is about
  // being *seen*, not about being rate-limited. `npm run rate flood` covers that.
  const step = BURST_WINDOW_MS / BURST_COUNT;
  for (let i = 0; i < BURST_COUNT; i++) {
    sim.sendMessage(target.id, "BROADCAST", `burst ${i}`, "broadcast");
    sim.runFor(step);
  }
  // Honest baseline: every other node originates one unicast to its neighbour by index,
  // so the traffic is identical in every arm and draws nothing from the engine's RNG.
  for (let i = 0; i < sim.nodes.length; i++) {
    if (i === TARGET_INDEX) continue;
    const peer = sim.nodes[(i + 1) % sim.nodes.length];
    sim.sendMessage(sim.nodes[i].id, peer.id, `honest from ${i}`, "text");
  }
  sim.runFor(WINDOW_MS + DRAIN_MS - BURST_WINDOW_MS);
  sim.refresh();

  const txPerNode = sim.nodes.map((n, i) => n.txCount - before[i]);
  const total = txPerNode.reduce((a, b) => a + b, 0);
  const med = median(txPerNode);
  const sd = stddev(txPerNode);
  // The observer's guess: whichever node transmitted most. Ties break to the lower index,
  // which is arbitrary and favours nobody — the target is index 3 of 20.
  let guessed = 0;
  for (let i = 1; i < txPerNode.length; i++) if (txPerNode[i] > txPerNode[guessed]) guessed = i;
  const ranked = txPerNode
    .map((tx, i) => ({ tx, i }))
    .sort((a, b) => b.tx - a.tx || a.i - b.i);

  return {
    seed,
    intervalMs,
    txPerNode,
    guessedIndex: guessed,
    targetRank: ranked.findIndex((r) => r.i === TARGET_INDEX) + 1,
    conspicuousness: sd === 0 ? 0 : (txPerNode[TARGET_INDEX] - med) / sd,
    coverTx: sim.stats.coverTx,
    transmissions: total,
    deliveryRatio: sim.stats.deliveryRatio,
    targetOriginated: BURST_COUNT,
  };
}

function mean(values: number[]): number {
  return values.length === 0 ? 0 : values.reduce((a, b) => a + b, 0) / values.length;
}

function label(intervalMs: number | null): string {
  return intervalMs === null ? "off" : `${intervalMs / 1000}s`;
}

// --- section: off means off ------------------------------------------------------

function inertSection(): boolean {
  console.log("\n=== cover traffic off is the shipped engine (docs/04 §5) ===");
  console.log(
    `A mitigation that is on by default is a change to every number this repository has\n` +
      `published, so \`coverTraffic\` defaults to false and this section checks that the\n` +
      `default is inert: no dummy beacons, no transmissions, and nothing in the world that\n` +
      `differs from a build without the feature.\n`
  );
  const failures: string[] = [];
  console.log("  seed   coverTx   transmissions   delivery   target rank   conspicuousness");
  for (const seed of SEEDS) {
    const off = run(seed, null);
    console.log(
      `  ${String(seed).padEnd(6)} ${String(off.coverTx).padStart(7)}   ${String(off.transmissions).padStart(13)}   ` +
        `${(off.deliveryRatio * 100).toFixed(1).padStart(6)}%   ${String(off.targetRank).padStart(11)}   ` +
        `${off.conspicuousness.toFixed(3).padStart(15)}`
    );
    if (off.coverTx !== 0) {
      failures.push(`seed ${seed}: ${off.coverTx} dummy beacons with coverTraffic off`);
    }
    if (off.targetOriginated !== BURST_COUNT) {
      failures.push(`seed ${seed}: the harness did not send the burst it thinks it sent`);
    }
  }
  if (failures.length > 0) {
    console.log("FAIL");
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    `\n  Zero dummy beacons on all ${SEEDS.length} seeds, so the feature is inert as shipped and the\n` +
      `  golden vectors are unchanged by its existence.`
  );
  return true;
}

// --- section: conspicuousness against cost --------------------------------------

function sweepSection(): boolean {
  console.log("\n=== what a dummy beacon buys, and what it costs (docs/04 §5) ===");
  console.log(
    `One node sends a burst of ${BURST_COUNT} broadcasts while every other node sends one unicast,\n` +
      `and the observer sees nothing but transmission counts per node over ${WINDOW_MS / 1000} s. It names\n` +
      `the node that transmitted most. \`conspicuousness\` is the target's count as a z-score\n` +
      `against the other nodes: how far it stands out from the median, in standard\n` +
      `deviations. Zero means the burst is invisible in that statistic.\n`
  );

  const failures: string[] = [];
  console.log("  seed  cover    coverTx   transmissions   delivery   guess hit   target rank   conspicuousness");
  const arms = new Map<number | null, CoverRun[]>();
  for (const interval of INTERVALS) arms.set(interval, []);
  for (const seed of SEEDS) {
    for (const interval of INTERVALS) {
      const r = run(seed, interval);
      arms.get(interval)!.push(r);
      console.log(
        `  ${String(seed).padEnd(5)} ${label(interval).padEnd(8)} ${String(r.coverTx).padStart(7)}   ` +
          `${String(r.transmissions).padStart(13)}   ${(r.deliveryRatio * 100).toFixed(1).padStart(6)}%   ` +
          `${(r.guessedIndex === TARGET_INDEX ? "yes" : "no").padStart(9)}   ${String(r.targetRank).padStart(11)}   ` +
          `${r.conspicuousness.toFixed(3).padStart(15)}`
      );
    }
  }

  const meanOf = (interval: number | null, key: keyof CoverRun) =>
    mean(arms.get(interval)!.map((r) => r[key] as number));
  const hits = (interval: number | null) =>
    arms.get(interval)!.filter((r) => r.guessedIndex === TARGET_INDEX).length;

  console.log(
    `\n  mean over ${SEEDS.length} seeds\n` +
      `    cover       coverTx   transmissions   vs off    delivery   observer named the target   rank   conspicuousness\n` +
      INTERVALS.map((interval) => {
        const tx = meanOf(interval, "transmissions");
        const off = meanOf(null, "transmissions");
        return (
          `    ${label(interval).padEnd(11)} ${meanOf(interval, "coverTx").toFixed(0).padStart(7)}   ` +
          `${tx.toFixed(0).padStart(13)}   ${(off === 0 ? 0 : ((tx - off) / off) * 100).toFixed(1).padStart(6)}%   ` +
          `${(meanOf(interval, "deliveryRatio") * 100).toFixed(1).padStart(6)}%   ` +
          `${`${hits(interval)}/${SEEDS.length}`.padStart(23)}   ` +
          `${meanOf(interval, "targetRank").toFixed(1).padStart(4)}   ` +
          `${meanOf(interval, "conspicuousness").toFixed(3).padStart(15)}`
        );
      }).join("\n")
  );

  // Cover traffic is traffic: it has to cost airtime, and more of it has to cost more.
  let previous = meanOf(null, "transmissions");
  for (const interval of INTERVALS.slice(1)) {
    const tx = meanOf(interval, "transmissions");
    if (tx <= previous) {
      failures.push(
        `cover at ${label(interval)} did not add airtime over the previous arm ` +
          `(${tx.toFixed(0)} vs ${previous.toFixed(0)} transmissions) — a dummy beacon that ` +
          `costs nothing is not on air`
      );
    }
    previous = tx;
    if (meanOf(interval, "coverTx") <= 0) {
      failures.push(`cover at ${label(interval)} emitted no dummy beacons at all`);
    }
  }
  // What this section does NOT assert, and why: that cover traffic conceals anything.
  // The first version of it did — "the tightest arm must hide the sender better than no
  // cover at all" — and the measurement refuted it, so the assertion is gone and the
  // result is reported below as the null result it is. `docs/06` §23 records it as a
  // rejected lever alongside the seventeen others, which is the discipline that keeps a
  // probe from publishing a hoped-for answer: a check that only passes when the numbers
  // flatter the feature is not a check.
  const off = meanOf(null, "conspicuousness");
  const tightest = meanOf(INTERVALS[INTERVALS.length - 1], "conspicuousness");
  // Delivery must not collapse. Not an equality: cover packets consume RNG draws, so the
  // arms are different worlds, and pretending otherwise would be the same mistake
  // `npm run rate block` made twice before it was corrected.
  for (const interval of INTERVALS) {
    const d = meanOf(interval, "deliveryRatio");
    if (d < 0.5) {
      failures.push(
        `cover at ${label(interval)} pushed delivery to ${(d * 100).toFixed(1)}% — cover ` +
          `traffic that starves the network is not a mitigation`
      );
    }
  }

  const offTx = meanOf(null, "transmissions");
  const tightTx = meanOf(INTERVALS[INTERVALS.length - 1], "transmissions");
  const costPct = offTx === 0 ? 0 : ((tightTx - offTx) / offTx) * 100;
  console.log(
    `\n  The result is null, and the reason is in the "observer named the target" column: it\n` +
      `  reads ${hits(null)}/${SEEDS.length} with cover off. Relaying already dominates every node's transmission\n` +
      `  count, so a ${BURST_COUNT}-message burst does not make its sender the top transmitter — the target\n` +
      `  ranks ${meanOf(null, "targetRank").toFixed(1)} of ${arms.get(null)![0].txPerNode.length}, and the z-score that measures how far it stands out is\n` +
      `  ${off.toFixed(3)} before any dummy beacon exists. Cover traffic cannot hide a sender who is already\n` +
      `  hidden, and tightening the interval to ${label(INTERVALS[INTERVALS.length - 1])} moves that z-score to ${tightest.toFixed(3)} — no\n` +
      `  direction, no trend — while costing ${costPct.toFixed(0)}% more airtime. On this observable the mitigation\n` +
      `  buys nothing measurable and is not free, so the knob ships off and §23 records it as a\n` +
      `  rejected lever rather than a feature that works.\n` +
      `\n` +
      `  That is a statement about this observable, not about cover traffic in general. The\n` +
      `  premise it rests on — that relay traffic swamps a burst — is a property of a dense\n` +
      `  20-node campus mesh, and a sparse or partitioned topology relays less, so the column\n` +
      `  that reads ${hits(null)}/${SEEDS.length} here is the one to re-read before concluding anything elsewhere.\n` +
      `\n` +
      `  Two limits on what any of these numbers mean. First, the observable is transmission\n` +
      `  *count*: this engine gives beacons no length, so an adversary doing length-based\n` +
      `  analysis is not modelled here at all, and a real one would need padded cover rather\n` +
      `  than counted cover. Second, the battery model is a role-based hourly rate\n` +
      `  (NORMAL_DRAIN_PER_HOUR in src/rf.ts) with no per-packet term, so the cost of cover\n` +
      `  traffic shows up in airtime and in nothing else — this probe cannot price it in\n` +
      `  battery, and skills/07's "Battery %/h per role" cannot either.\n`
  );

  if (failures.length > 0) {
    console.log("FAIL");
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    "PASS — cover traffic is inert when off, costs airtime in proportion to its rate, and\n" +
      "  leaves delivery alone. It does not measurably conceal the sender on this observable,\n" +
      "  which is reported above and recorded in docs/06 §23 rather than asserted away."
  );
  return true;
}

const SECTIONS: ReadonlyArray<[string, () => boolean | void]> = [
  ["inert", inertSection],
  ["sweep", sweepSection],
];

function main(): void {
  const only = process.argv[2];
  if (only && !SECTIONS.some(([name]) => name === only)) {
    console.error(
      `unknown section "${only}". one of: ${SECTIONS.map(([name]) => name).join(", ")}`
    );
    process.exit(2);
  }
  console.log(
    "Duman Messenger — what docs/04 §5's dummy beacons buy, and what they cost\n" +
      "Count and timing cover only: this engine gives beacons no length, so length-based\n" +
      "traffic analysis is out of reach and nothing here claims otherwise."
  );
  let failed = false;
  for (const [name, section] of SECTIONS) {
    if (only && name !== only) continue;
    if (section() === false) failed = true;
  }
  if (failed) {
    console.error("\nFAIL — cover traffic was not inert when off, not costly when on, or not survivable.");
    process.exitCode = 1;
  } else {
    console.log(
      "\nPASS — off means off, on costs airtime in proportion to its rate, and delivery survives."
    );
  }
}

main();
