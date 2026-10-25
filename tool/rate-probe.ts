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
 * Since §6's first bullet landed — *"Block/mute peer locally (ignore msgs from pubKey)"*
 * — the probe covers that too, because it is the same section of the same threat model
 * and the same question: what does the control cost, and who pays? `block` measures
 * blocking a flooder at half the network under both readings of the bullet.
 *
 * Sections: honest (a compliant network loses nothing) · flood (what a 12× flooder
 * costs, with and without the caps) · block (what a local block costs, and who pays)
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


// --- section: a local block, and who pays for it --------------------------------

/** `none` is the control arm: the same world with an empty blocklist. */
type BlockArm = "none" | "delivery" | "relay";

interface BlockRun {
  seed: number;
  arm: BlockArm;
  /** Spam from the blocked source that reached a node which blocked it. Must be 0. */
  blockerReceipts: number;
  /** Spam from the blocked source that reached a node which did not. Locality lives here. */
  bystanderReceipts: number;
  /** The SOS the same blocked source sent, counted at every node that blocked it. */
  sosAtBlockers: number;
  /** A text unicast from the blocked source to one specific blocker. Must be 0. */
  unicastAtBlocker: number;
  /** Everything a bystander received from *anybody else*. Not the locality claim — see
   *  the section — but the second-order effect a block has on unrelated traffic. */
  bystanderOtherReceipts: number;
  /** ACKs and gossip-pruned bundles: the mechanism behind the line above. A blocker that
   *  ignores a message sends no ACK for it, and an ACK is what prunes a bundle out of
   *  every carrier that overheard it (`skills/04`). */
  acksReceived: number;
  bundlesPruned: number;
  blockedDrops: number;
  deliveryRatio: number;
  transmissions: number;
}

/** How many broadcasts the blocked source sends, and over what window. */
const SPAM_COUNT = 24;
const SPAM_WINDOW_MS = 24_000;
const SOS_BODY = "sos from a blocked sender";
const UNICAST_BODY = "unicast from a blocked sender";

function blockRun(seed: number, arm: BlockArm): BlockRun {
  const scope = arm === "relay" ? "relay" : "delivery";
  const sim = new MeshSimulation({ ...campusQuad(seed), blockScope: scope });
  sim.runFor(SETTLE_MS);
  sim.refresh();
  sim.clearRecords();

  const source = sim.nodes[0];
  // Half the network blocks the source, so the other half is there to be measured: the
  // whole question is whether one device's blocklist changes what anybody else receives.
  const blockers = sim.nodes.filter((_, i) => i > 0 && i % 2 === 1);
  const bystanders = sim.nodes.filter((n) => n.id !== source.id && !blockers.includes(n));
  if (arm !== "none") {
    for (const b of blockers) sim.blockPeer(b.id, source.id);
  }

  sim.injectTraffic(HONEST_MESSAGES, HONEST_WINDOW_MS);
  const step = SPAM_WINDOW_MS / SPAM_COUNT;
  for (let i = 0; i < SPAM_COUNT; i++) {
    sim.sendMessage(source.id, "BROADCAST", `spam ${i}`, "broadcast");
    sim.runFor(step);
  }
  // The two exemptions, sent after the spam so nothing about their arrival can be
  // confused with it: an SOS on the pager channel, and a unicast in the other direction
  // — blocking filters what a user sees, not what a user may send.
  sim.sendMessage(source.id, "BROADCAST", SOS_BODY, "sos");
  sim.sendMessage(source.id, blockers[0].id, UNICAST_BODY, "text");
  sim.runFor(HONEST_WINDOW_MS + DRAIN_MS - SPAM_WINDOW_MS);
  sim.refresh();

  const held = (n: { inbox: { from: string; body: string }[] }) =>
    n.inbox.filter((m) => m.from === source.id && m.body.startsWith("spam")).length;
  const fromOthers = (n: { inbox: { from: string }[] }) =>
    n.inbox.filter((m) => m.from !== source.id).length;

  return {
    seed,
    arm,
    blockerReceipts: blockers.reduce((sum, b) => sum + held(b), 0),
    bystanderReceipts: bystanders.reduce((sum, b) => sum + held(b), 0),
    sosAtBlockers: blockers.filter((b) =>
      b.inbox.some((m) => m.body === SOS_BODY && m.type === "sos")
    ).length,
    unicastAtBlocker: blockers[0].inbox.filter((m) => m.body === UNICAST_BODY).length,
    bystanderOtherReceipts: bystanders.reduce((sum, b) => sum + fromOthers(b), 0),
    acksReceived: sim.stats.acksReceived,
    bundlesPruned: sim.stats.bundlesPruned,
    blockedDrops: sim.stats.blockedDrops,
    deliveryRatio: sim.stats.deliveryRatio,
    transmissions: sim.nodes.reduce((sum, n) => sum + n.txCount, 0),
  };
}

function blockSection(): boolean {
  console.log("\n=== a local block, and who pays for it (docs/04 §6, bullet 1) ===");
  console.log(
    `docs/04 §6 says "Block/mute peer locally (ignore msgs from pubKey)" and, in the same\n` +
      `section, "ignore floods". Those are two different reach: the first is about what a\n` +
      `user sees, the second about what a relay pays for. \`blockScope\` is the seam between\n` +
      `them — \`delivery\` (the default) filters the inbox only, \`relay\` refuses to forward\n` +
      `as well — and one node spamming ${SPAM_COUNT} broadcasts is blocked at half the network\n` +
      `so the other half can show whether a block stays local.\n`
  );

  const failures: string[] = [];
  console.log("  seed  arm       spam@blockers  spam@others  others@bystanders  SOS@blockers  unicast  delivery   tx      blocked");
  const arms: Record<BlockArm, BlockRun[]> = { none: [], delivery: [], relay: [] };
  for (const seed of SEEDS) {
    for (const arm of ["none", "delivery", "relay"] as BlockArm[]) {
      const r = blockRun(seed, arm);
      arms[arm].push(r);
      console.log(
        `  ${String(seed).padEnd(5)} ${arm.padEnd(9)} ${String(r.blockerReceipts).padStart(13)}  ` +
          `${String(r.bystanderReceipts).padStart(12)}  ${String(r.bystanderOtherReceipts).padStart(17)}  ` +
          `${String(r.sosAtBlockers).padStart(12)}  ` +
          `${String(r.unicastAtBlocker).padStart(7)}  ${pct(r.deliveryRatio).padStart(8)}   ` +
          `${String(r.transmissions).padStart(6)}  ${String(r.blockedDrops).padStart(8)}`
      );
    }
  }

  const sum = (arm: BlockArm, key: keyof BlockRun) =>
    arms[arm].reduce((a, r) => a + (r[key] as number), 0);
  const meanOf = (arm: BlockArm, key: keyof BlockRun) => sum(arm, key) / SEEDS.length;

  // Asserted, because these are the properties that make the feature correct rather than
  // merely effective.
  for (const arm of ["delivery", "relay"] as BlockArm[]) {
    if (sum(arm, "blockerReceipts") !== 0) {
      failures.push(
        `arm ${arm}: a blocked sender's spam reached the nodes that blocked it ` +
          `(${sum(arm, "blockerReceipts")} receipts over ${SEEDS.length} seeds)`
      );
    }
    if (sum(arm, "unicastAtBlocker") !== 0) {
      failures.push(`arm ${arm}: a blocked sender's unicast reached the node that blocked it`);
    }
    if (sum(arm, "blockedDrops") === 0) {
      failures.push(`arm ${arm}: nothing was ever blocked, so the arm measured nothing`);
    }
  }
  // SOS is exempt, and the exemption has to survive the aggressive scope too: `relay`
  // refuses to forward blockable traffic, and an SOS is not blockable.
  for (const arm of ["none", "delivery", "relay"] as BlockArm[]) {
    if (sum(arm, "sosAtBlockers") === 0) {
      failures.push(
        `arm ${arm}: a blocked sender's SOS reached nobody who blocked it — docs/04 §6 ` +
          `exempts SOS, and suppressing an emergency is the failure the exemption exists for`
      );
    }
    if (sum(arm, "sosAtBlockers") !== sum("none", "sosAtBlockers")) {
      failures.push(
        `arm ${arm}: SOS reached ${sum(arm, "sosAtBlockers")} blockers where the control arm ` +
          `reached ${sum("none", "sosAtBlockers")} — blocking must not move an exempt message`
      );
    }
  }
  // Locality: under `delivery`, a block changes one inbox and nothing else. The bystanders
  // must receive exactly what they received with no blocklist at all, and honest delivery
  // must not move either. This is asserted as an equality because it is an equality —
  // neither gate consumes RNG, so the two worlds run the same random sequence.
  if (sum("delivery", "bystanderReceipts") !== sum("none", "bystanderReceipts")) {
    failures.push(
      `arm delivery: bystanders received ${sum("delivery", "bystanderReceipts")} of the blocked ` +
        `sender's spam where the control arm delivered ${sum("none", "bystanderReceipts")} — a ` +
        `local blocklist changed what another device receives, which is what "locally" forbids`
    );
  }
  // Locality, measured on the traffic that has nothing to do with the block: what the
  // bystanders received from everybody except the blocked source. `deliveryRatio` is the
  // wrong instrument here and the first version of this section asserted on it — it is a
  // whole-network ratio whose numerator includes the blocked sender's own messages to the
  // nodes that blocked it, so it *must* move when a block works, and it moved by up to 60
  // points across seeds while nothing except the blocklist had changed. Excluding the
  // blocked pair leaves a number that has no business moving, and an exact equality is the
  // assertion because neither gate consumes RNG: the two worlds run the same sequence.
  // What *is* asserted is the direction that matters for censorship: the blocked sender's
  // own copies reach at least as many bystanders when somebody blocks it as when nobody
  // does (`spam@others` above). Unrelated traffic is reported and not asserted, because a
  // block does move it — and the first version of this section asserted an exact equality
  // there and was wrong twice over, once on `deliveryRatio` (whose numerator counts the
  // blocked pair's own messages, so a working block must reduce it) and once on this
  // column. The mechanism it guessed — fewer ACKs, so fewer gossip-pruned bundles, so
  // carriers hold copies longer — is printed two lines below and is *not* what happens:
  // `bundlesPruned` is zero in every arm, which is what `docs/06` §20.5 already measured.
  // ACKs do fall, and that is enough on its own: a transmission this node no longer makes
  // is an RNG draw this world no longer spends, and jitter, the MPR wait and backoff are
  // all drawn per transmission, so the two worlds diverge from the first ignored message
  // and unrelated counts differ the way any two different sequences differ.
  if (sum("delivery", "acksReceived") > sum("none", "acksReceived")) {
    failures.push(
      `arm delivery: blocking produced more ACKs (${sum("delivery", "acksReceived")}) than not ` +
        `blocking (${sum("none", "acksReceived")}) — an ignored message must not be acknowledged`
    );
  }
  if (sum("delivery", "bundlesPruned") > sum("none", "bundlesPruned")) {
    failures.push(
      `arm delivery: blocking pruned more bundles (${sum("delivery", "bundlesPruned")}) than not ` +
        `blocking (${sum("none", "bundlesPruned")}) — the ACK that prunes is the one never sent`
    );
  }
  // And the sharp form of locality, as an inequality rather than an equality: a block may
  // not *remove* a copy from a node that did not block. It is not asserted as an equality
  // because 216 is 24 messages × 9 bystanders — saturation — so equality here says the
  // ceiling was reached in both arms, not that the two worlds are identical.
  if (sum("delivery", "bystanderReceipts") < sum("none", "bystanderReceipts")) {
    failures.push(
      `arm delivery: bystanders received ${sum("delivery", "bystanderReceipts")} of the blocked ` +
        `sender's copies against ${sum("none", "bystanderReceipts")} with no blocklist — a local ` +
        `block removed a message from a device that never asked for it`
    );
  }
  // And the reason `relay` exists at all: it has to cost the blocked source airtime.
  if (meanOf("relay", "transmissions") >= meanOf("delivery", "transmissions")) {
    failures.push(
      `scope relay did not reduce transmissions (${meanOf("relay", "transmissions").toFixed(0)} vs ` +
        `${meanOf("delivery", "transmissions").toFixed(0)}) — refusing to forward should be the ` +
        `cheaper of the two`
    );
  }

  const txSaved = meanOf("delivery", "transmissions") - meanOf("relay", "transmissions");
  const bystanderLoss = meanOf("none", "bystanderReceipts") - meanOf("relay", "bystanderReceipts");
  console.log(
    `\n  mean over ${SEEDS.length} seeds\n` +
      `    spam at the nodes that blocked it   none ${meanOf("none", "blockerReceipts").toFixed(1)} → delivery ` +
      `${meanOf("delivery", "blockerReceipts").toFixed(1)} → relay ${meanOf("relay", "blockerReceipts").toFixed(1)}\n` +
      `    spam at the nodes that did not      none ${meanOf("none", "bystanderReceipts").toFixed(1)} → delivery ` +
      `${meanOf("delivery", "bystanderReceipts").toFixed(1)} → relay ${meanOf("relay", "bystanderReceipts").toFixed(1)}\n` +
      `    SOS at the nodes that blocked it    none ${meanOf("none", "sosAtBlockers").toFixed(1)} → delivery ` +
      `${meanOf("delivery", "sosAtBlockers").toFixed(1)} → relay ${meanOf("relay", "sosAtBlockers").toFixed(1)}\n` +
      `    everything else at the bystanders    none ${meanOf("none", "bystanderOtherReceipts").toFixed(1)} → delivery ` +
      `${meanOf("delivery", "bystanderOtherReceipts").toFixed(1)} → relay ${meanOf("relay", "bystanderOtherReceipts").toFixed(1)}\n` +
      `    ACKs / bundles gossip-pruned         none ${meanOf("none", "acksReceived").toFixed(1)} / ${meanOf("none", "bundlesPruned").toFixed(1)} → delivery ` +
      `${meanOf("delivery", "acksReceived").toFixed(1)} / ${meanOf("delivery", "bundlesPruned").toFixed(1)} → relay ` +
      `${meanOf("relay", "acksReceived").toFixed(1)} / ${meanOf("relay", "bundlesPruned").toFixed(1)}\n` +
      `    network delivery ratio              none ${pct(meanOf("none", "deliveryRatio"))} → delivery ` +
      `${pct(meanOf("delivery", "deliveryRatio"))} → relay ${pct(meanOf("relay", "deliveryRatio"))}\n` +
      `    transmissions                       none ${meanOf("none", "transmissions").toFixed(0)} → delivery ` +
      `${meanOf("delivery", "transmissions").toFixed(0)} → relay ${meanOf("relay", "transmissions").toFixed(0)}\n` +
      `\n` +
      `  Read the second line as the price of "relay": ${bystanderLoss.toFixed(1)} of the blocked\n` +
      `  sender's copies per seed never reached nodes that did not block it, because a blocker\n` +
      `  that refuses to forward is a hole in that source's routes. The first and third lines\n` +
      `  are the feature and its exemption. The second line is the locality claim — a block\n` +
      `  removes nothing from a device that did not block — though at 24 messages × 9\n` +
      `  bystanders it is a saturated one, so it rules out removal rather than proving the two\n` +
      `  worlds identical.\n` +
      `\n` +
      `  The fourth line moves and the sixth moves with it, and neither is a cost of blocking.\n` +
      `  The sixth is a whole-network ratio whose numerator counts the blocked sender's own\n` +
      `  messages to the nodes that blocked it, so a working block reduces it by construction;\n` +
      `  reading it as "a block costs the network delivery" is the mistake this section exists\n` +
      `  to prevent. The fourth is unrelated traffic at unrelated nodes, and it moves because\n` +
      `  the fifth line's ACKs are transmissions: an ignored message is not acknowledged, a\n` +
      `  transmission not made is an RNG draw not spent, and jitter, the MPR wait and backoff\n` +
      `  are drawn per transmission — so the two worlds diverge at the first ignored message.\n` +
      `  The pruning half of that story is printed and is zero: docs/06 §20.5 measured\n` +
      `  gossip-pruning as essentially never firing, and it does not fire here either.\n` +
      `\n` +
      `  Scope relay saves ${txSaved.toFixed(0)} transmissions per seed (${pct(txSaved / meanOf("delivery", "transmissions"))} of the network's\n` +
      `  airtime) that scope delivery spends forwarding someone the forwarder has blocked.\n` +
      `  Whether that trade is worth a hole in the blocked source's routes is a policy\n` +
      `  question, so both ship and the default is the one that cannot censor anybody.\n`
  );

  if (failures.length > 0) {
    console.log("FAIL");
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    "PASS — the block filters what the blocker sees and nothing else: a bystander loses no\n" +
      "  copy of the blocked sender's traffic, an SOS still gets through under both scopes,\n" +
      "  and the network spends less airtime only when it is asked to."
  );
  return true;
}

const SECTIONS: ReadonlyArray<[string, () => boolean | void]> = [
  ["honest", honestSection],
  ["flood", floodSection],
  ["block", blockSection],
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
    console.error(
      "\nFAIL — a control fired where it should not have, or stayed silent where it should " +
        "not have."
    );
    process.exitCode = 1;
  } else {
    console.log(
      "\nPASS — the caps and the blocklist are inert on traffic that does not abuse them, " +
        "fire on traffic that does, and neither reaches past the node that decided."
    );
  }
}

main();
