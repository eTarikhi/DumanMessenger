/**
 * Abuse-limit probe: what `docs/04` §6's two caps cost, and what they buy.
 *
 * `docs/04` §6 states two numbers — "Max 5 broadcasts / minute per node; SUPERs drop
 * excess" and "Cap relay to 30 msgs/min per source; ignore floods" — and until now
 * neither engine enforced either, so the threat model's answer to a battery-drain
 * attack was prose. Both are implemented (`admitByRate` in `src/routing.ts` and its
 * Dart mirror), off by default, and this is the harness behind the numbers in
 * `docs/06` §21.
 *
 * It measures three things, and only two of them are asserted:
 *
 * - **The caps are inert when nothing abuses them.** A network that stays inside
 *   5 broadcasts/min and 30 relays/min/source must lose nothing. This is asserted,
 *   because a limit that costs honest traffic is not shippable and the whole design
 *   rests on it.
 * - **The caps fire when something abuses them.** A source sending 60 broadcasts in
 *   60 s is twelve times the documented cap. This is asserted too.
 * - **What the caps are worth to everybody else.** Delivery, broadcast reach and
 *   overhead for the honest traffic, flooded and unflooded, limits on and off. This
 *   is **reported, not asserted**: `docs/06` records seventeen levers that were built,
 *   measured and rejected, and a probe that only passes when the answer is the one
 *   the author hoped for is how a rejected lever gets published as a win.
 *
 *   npm run rate              every section
 *   npm run rate flood        one section
 *
 * Sections: honest (a compliant network loses nothing) · flood (what a 12× flooder
 * costs, with and without the caps)
 */
import { MeshSimulation, type SimConfig } from "../src/simulation";
import { campusQuad } from "../src/scenarios";
import {
  BROADCAST_PER_MINUTE_CAP,
  RELAY_PER_SOURCE_PER_MINUTE_CAP,
} from "../src/routing";

/** Settle elections and routes before measuring, as the sibling probes do. */
const SETTLE_MS = 90_000;
/** Three seeds: one number from one seed is an anecdote, not a result. */
const SEEDS = [42, 7, 11];
/** Honest unicast traffic, spread evenly. 15/min is well inside the 30/min relay cap. */
const HONEST_MESSAGES = 30;
const HONEST_WINDOW_MS = 120_000;
/** Let the honest traffic land before reading the stats. */
const DRAIN_MS = 40_000;
/** The flooder: 60 broadcasts in 60 s is 12× the documented cap of 5/min. */
const FLOOD_COUNT = 60;
const FLOOD_WINDOW_MS = 60_000;

/** Who enforces the broadcast cap. `"super"` is what docs/04 §6 says. */
type CapScope = "super" | "all";

interface RunResult {
  seed: number;
  rateLimits: boolean;
  flooded: boolean;
  scope: CapScope;
  deliveryRatio: number;
  broadcastReach: number;
  overheadRatio: number;
  superRatio: number;
  rateBroadcastDrops: number;
  rateRelayDrops: number;
  transmissions: number;
}

function run(
  seed: number,
  rateLimits: boolean,
  flooded: boolean,
  scope: CapScope = "super"
): RunResult {
  const config: SimConfig = { ...campusQuad(seed), rateLimits, broadcastCapScope: scope };
  const sim = new MeshSimulation(config);
  sim.runFor(SETTLE_MS);
  sim.refresh();
  // Measure the window, not the settle: elections and route discovery are the busiest
  // the network ever gets, and counting them would flatter the caps by putting the
  // flood inside a period that already looks like one.
  sim.clearRecords();

  const source = sim.nodes[0];
  sim.injectTraffic(HONEST_MESSAGES, HONEST_WINDOW_MS);

  if (flooded) {
    const step = FLOOD_WINDOW_MS / FLOOD_COUNT;
    for (let i = 0; i < FLOOD_COUNT; i++) {
      sim.sendMessage(source.id, "BROADCAST", `flood ${i}`, "broadcast");
      sim.runFor(step);
    }
  }
  sim.runFor(HONEST_WINDOW_MS + DRAIN_MS - (flooded ? FLOOD_WINDOW_MS : 0));
  sim.refresh();

  const stats = sim.stats;
  return {
    seed,
    rateLimits,
    flooded,
    scope,
    deliveryRatio: stats.deliveryRatio,
    broadcastReach: stats.broadcastReach,
    overheadRatio: stats.overheadRatio,
    superRatio: stats.superRatio,
    rateBroadcastDrops: stats.rateBroadcastDrops,
    rateRelayDrops: stats.rateRelayDrops,
    transmissions: sim.nodes.reduce((sum, node) => sum + node.txCount, 0),
  };
}

function mean(values: number[]): number {
  return values.length === 0 ? 0 : values.reduce((a, b) => a + b, 0) / values.length;
}

function pct(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

// --- section: a compliant network loses nothing --------------------------------

function honestSection(): boolean {
  console.log("\n=== a compliant network loses nothing (docs/04 §6) ===");
  console.log(
    `docs/04 §6 caps broadcasts at ${BROADCAST_PER_MINUTE_CAP}/min per node and relays at\n` +
      `${RELAY_PER_SOURCE_PER_MINUTE_CAP}/min per source. The engine's own traffic generator sends\n` +
      `${HONEST_MESSAGES} unicasts over ${HONEST_WINDOW_MS / 1000} s — ${(HONEST_MESSAGES / (HONEST_WINDOW_MS / 60_000)).toFixed(0)}/min\n` +
      `network-wide, and each node beacons one OGM every 2 s. Neither is near either cap,\n` +
      `so the limits must be invisible. If they are not, they are not shippable.\n`
  );
  const failures: string[] = [];
  console.log("  seed  scope    delivery   bcast reach   overhead   SUPER   bcast drops   relay drops");
  for (const seed of SEEDS) {
    const off = run(seed, false, false);
    // Both scopes are checked here. `"all"` is the more aggressive reading — every
    // node filters — so it is the one that would cost an honest network something if
    // either did, and it is the scope §21.5 proposes without having measured it.
    for (const scope of ["super", "all"] as CapScope[]) {
    const on = run(seed, true, false, scope);
    if (on.rateBroadcastDrops !== 0 || on.rateRelayDrops !== 0) {
      failures.push(
        `seed ${seed}, scope ${scope}: an honest network was rate-limited — ` +
          `${on.rateBroadcastDrops} broadcast and ${on.rateRelayDrops} relay drops`
      );
    }
    // The honest runs must also agree with each other: if turning the caps on changed
    // delivery, something is being dropped that should not be.
    if (Math.abs(on.deliveryRatio - off.deliveryRatio) > 1e-9) {
      failures.push(
        `seed ${seed}, scope ${scope}: delivery moved from ${pct(off.deliveryRatio)} to ` +
          `${pct(on.deliveryRatio)} when the caps were switched on with nothing to cap`
      );
    }
    console.log(
      `  ${String(seed).padEnd(5)} ${scope.padEnd(8)} ${pct(on.deliveryRatio).padStart(8)}   ${pct(on.broadcastReach).padStart(11)}   ` +
        `${pct(on.overheadRatio).padStart(8)}   ${pct(on.superRatio).padStart(6)}   ` +
        `${String(on.rateBroadcastDrops).padStart(11)}   ${String(on.rateRelayDrops).padStart(11)}`
    );
    }
  }
  console.log(
    `\n  OGMs are exempt from the relay cap, and this is where that decision shows: at 2 s a\n` +
      `  beacon a node emits ${60_000 / 2000}/min, which is exactly the documented cap of\n` +
      `  ${RELAY_PER_SOURCE_PER_MINUTE_CAP}. Counting beacons would leave every node's own routing protocol holding\n` +
      `  the entire budget — measured in the test suite as 29 messages admitted in ten minutes\n` +
      `  instead of 300 — so the caps would fire on a completely honest network and the row\n` +
      `  above would not be zero.`
  );
  console.log("\n=== verdict ===");
  if (failures.length > 0) {
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    `  Zero drops on all ${SEEDS.length} seeds under both enforcement scopes, and delivery is\n` +
      `  identical with the caps on and off. The limits cost a compliant network nothing.`
  );
  return true;
}

// --- section: what a flooder costs ---------------------------------------------

function floodSection(): boolean {
  console.log("\n=== what a 12× flooder costs, with and without the caps (docs/04 §6) ===");
  console.log(
    `One node sends ${FLOOD_COUNT} broadcasts in ${FLOOD_WINDOW_MS / 1000} s — ${(FLOOD_COUNT / (FLOOD_WINDOW_MS / 60_000)).toFixed(0)}/min,\n` +
      `${(FLOOD_COUNT / (FLOOD_WINDOW_MS / 60_000) / BROADCAST_PER_MINUTE_CAP).toFixed(0)}× the documented cap — while ${HONEST_MESSAGES} honest unicasts are in flight.\n` +
      `Four arms per seed: flood/no-flood × caps off/on. The delivery and overhead columns\n` +
      `are reported rather than asserted, because the answer is a measurement.\n`
  );
  // An explicit arm table rather than nested loops, because the two enforcement
  // scopes only differ where there is a flood to enforce against — a fifth arm, not
  // a doubled fourth.
  const ARMS: ReadonlyArray<{
    key: string;
    label: string;
    flooded: boolean;
    rateLimits: boolean;
    scope: CapScope;
  }> = [
    { key: "noflood-off", label: "no flood / caps off", flooded: false, rateLimits: false, scope: "super" },
    { key: "noflood-on", label: "no flood / caps on", flooded: false, rateLimits: true, scope: "super" },
    { key: "flood-off", label: "flood / caps off", flooded: true, rateLimits: false, scope: "super" },
    { key: "flood-on", label: "flood / caps SUPERs", flooded: true, rateLimits: true, scope: "super" },
    { key: "flood-all", label: "flood / caps all", flooded: true, rateLimits: true, scope: "all" },
  ];

  const failures: string[] = [];
  console.log("  seed  arm                     delivery   bcast reach   overhead   tx      bcast drops  relay drops");
  const arms: Record<string, RunResult[]> = {};
  for (const arm of ARMS) arms[arm.key] = [];
  for (const seed of SEEDS) {
    for (const arm of ARMS) {
      const r = run(seed, arm.rateLimits, arm.flooded, arm.scope);
      arms[arm.key].push(r);
      console.log(
        `  ${String(seed).padEnd(5)} ${arm.label.padEnd(23)} ` +
          `${pct(r.deliveryRatio).padStart(8)}   ${pct(r.broadcastReach).padStart(11)}   ` +
          `${pct(r.overheadRatio).padStart(8)}   ${String(r.transmissions).padStart(6)}   ` +
          `${String(r.rateBroadcastDrops).padStart(11)}  ${String(r.rateRelayDrops).padStart(11)}`
      );
    }
  }

  // Asserted: the caps fire on a flooder, and stay silent without one.
  const floodOn = arms["flood-on"];
  const floodOff = arms["flood-off"];
  if (!floodOn.every((r) => r.rateBroadcastDrops > 0)) {
    failures.push("the caps did not fire on a source sending 12× the documented broadcast rate");
  }
  if (!floodOff.every((r) => r.rateBroadcastDrops === 0)) {
    failures.push("drops were recorded with the caps switched off, so the feature is not inert");
  }

  const meanOf = (key: keyof RunResult) => (arm: string) =>
    mean(arms[arm].map((r) => Number(r[key])));
  const delivery = meanOf("deliveryRatio");
  const overhead = meanOf("overheadRatio");
  const reach = meanOf("broadcastReach");
  const tx = meanOf("transmissions");
  const drops = meanOf("rateBroadcastDrops");

  console.log(
    `\n  mean over ${SEEDS.length} seeds\n` +
      `    honest delivery   no flood ${pct(delivery("noflood-off"))} → ${pct(delivery("noflood-on"))} (caps on)   ` +
      `flood ${pct(delivery("flood-off"))} → ${pct(delivery("flood-on"))} → ${pct(delivery("flood-all"))}\n` +
      `    broadcast reach   no flood ${pct(reach("noflood-off"))} → ${pct(reach("noflood-on"))}   ` +
      `flood ${pct(reach("flood-off"))} → ${pct(reach("flood-on"))} → ${pct(reach("flood-all"))}\n` +
      `    overhead          no flood ${pct(overhead("noflood-off"))} → ${pct(overhead("noflood-on"))}   ` +
      `flood ${pct(overhead("flood-off"))} → ${pct(overhead("flood-on"))} → ${pct(overhead("flood-all"))}\n` +
      `    transmissions     flood ${tx("flood-off").toFixed(0)} → ${tx("flood-on").toFixed(0)} → ${tx("flood-all").toFixed(0)}   ` +
      `(the last two columns are caps on, SUPERs only then every node)\n` +
      `    suppressions      SUPERs ${drops("flood-on").toFixed(0)}   all ${drops("flood-all").toFixed(0)}   ` +
      `of ${FLOOD_COUNT} messages sent, summed over every enforcing node\n`
  );

  const honestDelta = delivery("flood-all") - delivery("flood-off");
  const overheadDelta = overhead("flood-all") - overhead("flood-off");
  console.log(
    `  The caps move honest delivery under flood by ${(honestDelta * 100 >= 0 ? "+" : "")}${(honestDelta * 100).toFixed(1)} points and\n` +
    `  overhead by ${(overheadDelta * 100 >= 0 ? "+" : "")}${(overheadDelta * 100).toFixed(1)} points. Neither number is asserted, for the reason docs/06\n` +
    `  gives for its seventeen rejected levers: a probe that only passes when the answer is the\n` +
    `  one its author hoped for is how a rejected lever gets published as a win.\n` +
    `\n` +
    `  Read the suppressions column as a sum over enforcing nodes, not as messages: one flood\n` +
    `  broadcast heard by four SUPERs over its cap is four suppressions, which is why the mean\n` +
    `  (${drops("flood-on").toFixed(0)}) is larger than the ${FLOOD_COUNT} messages the source sent. And read the overhead\n` +
    `  column with its denominator in mind — it is transmissions per delivered message, and a\n` +
    `  suppressed flood copy is a transmission that never becomes a delivery, so capping a flood\n` +
    `  can raise the ratio while removing work. The transmissions column is the one that says\n` +
    `  what the radio actually did.\n` +
    `\n` +
    `  §21.5's question, answered with a measurement rather than an opinion: docs/04 §6 says\n` +
    `  "SUPERs drop excess", so only SUPERs enforce, which bounds how *far* a flood travels\n` +
    `  and not whether the flooder's own neighbours see it — a NORMAL node neither relays far\n` +
    `  nor filters. Making every node enforce instead is the fifth arm above, and it is not a\n` +
    `  rule this document contains, so it ships as a knob (\`broadcastCapScope\`,\n` +
    `  \`--broadcast-cap-scope super|all\`) with the two measured against each other.\n` +
    `\n` +
    `    reach    ${pct(reach("flood-off"))} uncapped → ${pct(reach("flood-on"))} SUPERs only → ${pct(reach("flood-all"))} every node\n` +
    `    airtime  ${tx("flood-off").toFixed(0)} → ${tx("flood-on").toFixed(0)} → ${tx("flood-all").toFixed(0)} transmissions\n` +
    `\n` +
    `  The ${pct(BROADCAST_PER_MINUTE_CAP / (FLOOD_COUNT / (FLOOD_WINDOW_MS / 60_000)))} that ${BROADCAST_PER_MINUTE_CAP} admitted of ${FLOOD_COUNT} sent would imply is not reachable by either scope,\n` +
    `  because the honest broadcasts in the same window are counted in that reach too.`
  );

  console.log("\n=== verdict ===");
  if (failures.length > 0) {
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    `  The caps fired on all ${SEEDS.length} seeds under a 12× flood and stayed silent without one,\n` +
      `  and the honest-network section shows they cost a compliant network nothing.`
  );
  return true;
}

// --- section dispatch ----------------------------------------------------------

const SECTIONS: ReadonlyArray<[string, () => boolean | void]> = [
  ["honest", honestSection],
  ["flood", floodSection],
];

function main(): void {
  const only = process.argv[2];
  if (only && !SECTIONS.some(([name]) => name === only)) {
    console.error(`unknown section "${only}". one of: ${SECTIONS.map(([name]) => name).join(", ")}`);
    process.exit(2);
  }
  console.log(
    "Duman Messenger — what docs/04 §6's abuse limits cost and buy\n" +
      "Two caps, both off by default, both token buckets rather than per-minute tallies,\n" +
      "both enforced exactly where the document says and no further."
  );
  let failed = false;
  for (const [name, section] of SECTIONS) {
    if (only && name !== only) continue;
    if (section() === false) failed = true;
  }
  if (failed) {
    console.error("\nFAIL — a cap fired on honest traffic, or stayed silent under a flood.");
    process.exitCode = 1;
  } else {
    console.log("\nPASS — the caps are inert on honest traffic and fire under abuse.");
  }
}

main();
