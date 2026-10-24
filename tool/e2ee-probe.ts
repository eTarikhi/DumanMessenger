/**
 * E2EE handshake cost probe (docs/07 §2–§4).
 *
 * `docs/07-e2ee-noise-xx.md` publishes three sets of numbers: the three-leg establishment latency
 * table (§2.1), the leg that was lost at four hops in a crowd (§2.2), and the session-churn rate
 * that decides whether a device may handshake on discovery (§3). Until now nothing in this
 * repository could reproduce any of them — the harness that produced them was never committed, so
 * the figures were citations rather than results. This is that harness.
 *
 * The `latency`, `churn` and `packet` sections implement no cryptography, which was the whole
 * point when this probe was written: `skills/03` says "use libsodium via FFI; never custom crypto",
 * and what a protocol simulator can honestly answer is what the *mesh* does to messages of the size
 * and shape the crypto produces. So each Noise_XX leg is sent as an ordinary unicast through the
 * real engine — routing, MPR wait, link loss, ACKs and retries all active — and the latency
 * reported is the engine's own end-to-end figure for that message, not a model of a handshake.
 *
 * The `crypto` section is different and says so. It runs the reference protocol layer in
 * `src/crypto/` — Noise_XX, the per-message ratchet, the packet — over OpenSSL primitives from
 * `node:crypto`, which is not custom crypto and does not contradict `skills/03`. It exists because
 * three of docs/07's claims were arithmetic on constants rather than measurements, and a
 * serialiser settles them: the real size of a sealed packet against §4's table, the real size of
 * each handshake leg against §7.2's MTU question, and the real CPU cost of a handshake against
 * §2.1's radio figures.
 *
 * Where this probe's numbers differ from the published table, the difference is printed rather
 * than tuned away: the original pair selection and seed are not recorded in docs/07, so exact
 * agreement was never on offer. What *is* asserted is the part that is a claim rather than a
 * measurement — the per-message latency budget, at the two distances it is actually published
 * for, and §4's packet sizing, which follows from exported constants and can be checked exactly.
 *
 *   npm run e2ee                 every section
 *   npm run e2ee latency         one section
 *
 * Sections: latency (§2.1, §2.2) · churn (§3) · packet (§4) · crypto (§2.1 note 3, §4, §7.2)
 */
import { MeshSimulation, type DeliveryRecord, type SimConfig } from "../src/simulation";
import { campusQuad, festivalCrowd, sparseVillage } from "../src/scenarios";
import { canReach } from "../src/rf";
import {
  BLE_MAX_BYTES,
  PACKET_OVERHEAD_BYTES,
  PAD_BLOCK_BYTES,
  selectTransport,
  wireSizeOf,
} from "../src/routing";
import type { MeshNode, NodeId } from "../src/types";
import { utf8ByteLength, wireSizeOfBody } from "../src/routing";
import {
  DumanSession,
  LEG_SIZES,
  SymmetricRatchet,
  decodeNonce,
  generateIdentity,
  handshakeInProcess,
  nodePrimitives as crypto,
  openPacket,
  relayVisible,
  sessionPrologueFromQr,
} from "../src/crypto";
import { HEADER_BYTES, NONCE_BYTES } from "../src/crypto/packet";

/** docs/07 §2.2: the crowd's 4-hop leg 2 "did not arrive inside 8 s", so 8 s is the leg budget. */
const LEG_TIMEOUT_MS = 8000;
/** Settle elections and routes before measuring, as the sibling probes do. */
const SETTLE_MS = 90000;
/**
 * Two seeds, not one. A single latency figure from a single seed is not a result, it is an
 * anecdote — and docs/07's table is exactly that today, because the seed it used is not recorded.
 */
const SEEDS = [42, 7];
/**
 * The per-message latency budget: < 2 s at one hop, < 5 s at three.
 *
 * Sourced from `docs/02-technical-architecture.md` ("Text delivery < 2s (1 hop), < 5s (3 hops)")
 * and the roadmap's Phase 1 exit criteria, which say the same thing. `docs/07` §2.1 and `docs/06`
 * both attribute it to "`docs/04` §5", which is Relay Privacy and contains no latency budget at
 * all — the citation is wrong in both places, and this probe cites the real ones.
 *
 * No budget is published for two hops or four, so none is asserted there. Judging a 4-hop leg
 * against the 3-hop figure would be inventing a requirement, and the first run of this probe did
 * exactly that before its source was checked.
 */
const BUDGET_1HOP_MS = 2000;
const BUDGET_3HOP_MS = 5000;

/**
 * The three legs of Noise_XX, with the payload each carries.
 *
 * Every leg pads into a single 256 B block: §4's layout puts the wire size at
 * `ceil((95 + body) / 256) * 256`, and the largest leg here is `95 + 64 = 159`. So all three
 * select BLE whatever the exact key lengths turn out to be, which is worth stating instead of
 * assuming — it is what makes the latency measurement insensitive to a detail the crypto library
 * has not fixed yet (docs/07 §7.2 is still asking the question).
 */
const LEGS: ReadonlyArray<{ label: string; chars: number }> = [
  { label: "-> e", chars: 32 },
  { label: "<- e, ee, s, es", chars: 64 },
  { label: "-> s, se", chars: 32 },
];

const WORLDS: ReadonlyArray<{ name: string; build: (seed: number) => SimConfig }> = [
  { name: "campus_quad", build: campusQuad },
  { name: "festival_crowd", build: festivalCrowd },
];

interface LegResult {
  label: string;
  ms: number | null;
  hops: number | null;
  attempt: number | null;
}

interface HandshakeResult {
  distance: number;
  from: NodeId;
  to: NodeId;
  legs: LegResult[];
  totalMs: number | null;
  established: boolean;
}

// --- the in-range graph, and how far apart two nodes are in it ----------------

function onlineIds(sim: MeshSimulation): NodeId[] {
  return sim.nodes
    .filter((n) => n.isOnline)
    .map((n) => n.id)
    .sort();
}

/** Breadth-first hop count over "who can hear whom", from every node to every node. */
function hopDistances(sim: MeshSimulation): Map<NodeId, Map<NodeId, number>> {
  const ids = onlineIds(sim);
  const byId = new Map<NodeId, MeshNode>(sim.nodes.map((n) => [n.id, n]));
  const adj = new Map<NodeId, NodeId[]>();
  for (const a of ids) {
    const out: NodeId[] = [];
    const na = byId.get(a);
    if (!na) continue;
    for (const b of ids) {
      const nb = byId.get(b);
      if (nb && canReach(na, nb, sim.rf)) out.push(b);
    }
    adj.set(a, out);
  }
  const all = new Map<NodeId, Map<NodeId, number>>();
  for (const s of ids) {
    const d = new Map<NodeId, number>([[s, 0]]);
    const queue: NodeId[] = [s];
    while (queue.length > 0) {
      const u = queue.shift() as NodeId;
      const du = d.get(u) as number;
      for (const v of adj.get(u) ?? []) {
        if (!d.has(v)) {
          d.set(v, du + 1);
          queue.push(v);
        }
      }
    }
    all.set(s, d);
  }
  return all;
}

/**
 * The first pair, in sorted id order, that is exactly `want` hops apart.
 *
 * Deterministic and stated, because docs/07 does not record which pairs it measured and a table
 * of latencies is meaningless without knowing which pairs produced it.
 */
function pairAtDistance(
  dist: Map<NodeId, Map<NodeId, number>>,
  ids: NodeId[],
  want: number
): [NodeId, NodeId] | null {
  for (const a of ids) {
    for (const b of ids) {
      if (a >= b) continue;
      if (dist.get(a)?.get(b) === want) return [a, b];
    }
  }
  return null;
}

// --- §2.1 and §2.2: what a three-leg handshake costs --------------------------

function runHandshake(sim: MeshSimulation, a: NodeId, b: NodeId, distance: number): HandshakeResult {
  const legs: LegResult[] = [];
  let total = 0;
  let established = true;

  LEGS.forEach((leg, i) => {
    // XX alternates direction: the initiator sends legs 1 and 3, the responder sends leg 2.
    const from = i % 2 === 0 ? a : b;
    const to = i % 2 === 0 ? b : a;
    const before = sim.deliveries.length;
    const msg = sim.sendMessage(from, to, "x".repeat(leg.chars), "text");
    if (!msg) {
      legs.push({ label: leg.label, ms: null, hops: null, attempt: null });
      established = false;
      return;
    }
    const t0 = sim.now;
    let rec: DeliveryRecord | undefined;
    // Advance in small steps and stop as soon as the leg lands: an 8 s budget that always ran the
    // full 8 s would make this probe minutes long for legs that arrive in 200 ms.
    while (sim.now - t0 < LEG_TIMEOUT_MS) {
      sim.runFor(50);
      rec = sim.deliveries.slice(before).find((d) => d.msgId === msg.id);
      if (rec) break;
    }
    if (!rec) {
      legs.push({ label: leg.label, ms: null, hops: null, attempt: null });
      established = false;
      return;
    }
    legs.push({ label: leg.label, ms: rec.latencyMs, hops: rec.hops, attempt: rec.attempt });
    total += rec.latencyMs;
  });

  return { distance, from: a, to: b, legs, totalMs: established ? total : null, established };
}

function latencySection(): boolean {
  console.log("\n=== Noise_XX establishment latency (docs/07 §2.1, §2.2) ===");
  console.log(
    `Each leg is one unicast through the real engine. A leg that has not arrived inside\n` +
      `${LEG_TIMEOUT_MS / 1000} s is lost (§2.2's budget), and a lost leg means the session was never\n` +
      `established — retry is per leg, not per handshake, but this measures the first attempt.\n` +
      `Seeds: ${SEEDS.join(", ")}. Wire size per leg: ${wireSizeOf(64)} B, so every leg rides ` +
      `${selectTransport(wireSizeOf(64)) === "ble" ? "BLE" : "Wi-Fi Direct"}.\n`
  );

  const budgetFailures: string[] = [];
  const lost: string[] = [];

  for (const world of WORLDS) {
    for (const seed of SEEDS) {
      const sim = new MeshSimulation(world.build(seed));
      sim.runFor(SETTLE_MS);
      sim.clearRecords();
      const ids = onlineIds(sim);
      const dist = hopDistances(sim);

      console.log(`--- ${world.name} (${ids.length} nodes, seed ${seed}) ---`);
      console.log(
        "  hops  pair                     leg 1     leg 2     leg 3     total      status"
      );

      for (const want of [1, 2, 3, 4]) {
        const pair = pairAtDistance(dist, ids, want);
        if (!pair) {
          console.log(`  ${want}     (no pair at this distance)`);
          continue;
        }
        const r = runHandshake(sim, pair[0], pair[1], want);
        const cells = r.legs.map((l) => (l.ms === null ? "lost".padStart(8) : `${l.ms.toFixed(0)} ms`.padStart(8)));
        const total = r.totalMs === null ? "never".padStart(9) : `${r.totalMs.toFixed(0)} ms`.padStart(9);
        const short = (s: string, n: number) => (s.length > n ? s.slice(0, n - 1) + "…" : s.padEnd(n));
        console.log(
          `  ${want}     ${short(`${r.from} → ${r.to}`, 24)} ${cells.join(" ")} ${total}  ` +
            `${r.established ? "established" : "NOT established"}`
        );

        // The part that is a claim rather than a measurement: the published per-message budget,
        // at the two distances it is published for and nowhere else.
        r.legs.forEach((l) => {
          if (l.ms === null) {
            lost.push(`${world.name} seed ${seed}, ${want} hop(s), ${l.label}`);
            return;
          }
          const budget = want === 1 ? BUDGET_1HOP_MS : want === 3 ? BUDGET_3HOP_MS : null;
          if (budget !== null && l.ms > budget) {
            budgetFailures.push(
              `${world.name} seed ${seed}, ${want} hop(s), ${l.label}: ${l.ms.toFixed(0)} ms ` +
                `exceeds the published ${budget} ms budget for ${want} hop(s)`
            );
          }
        });
      }
      console.log("");
    }
  }

  console.log("=== verdict ===");
  if (lost.length > 0) {
    console.log(
      `  ${lost.length} leg(s) lost inside ${LEG_TIMEOUT_MS / 1000} s — §2.2 is reproduced, and a\n` +
        `  three-leg session inherits the loss: ${lost.join("; ")}`
    );
  } else {
    console.log(
      `  no leg was lost at these seeds. §2.2's lost leg is not reproduced here, which is a\n` +
        `  statement about these pairs and seeds, not evidence that it does not happen.`
    );
  }
  if (budgetFailures.length > 0) {
    console.log(`  ${budgetFailures.length} leg(s) outside docs/04 §5's per-message budget:`);
    for (const f of budgetFailures) console.log(`    · ${f}`);
  } else {
    console.log(
      `  every leg that arrived was inside the published per-message budget (< ${BUDGET_1HOP_MS} ms at\n` +
        `  one hop, < ${BUDGET_3HOP_MS} ms at three). §2.1's conclusion stands: the budget was written for\n` +
        `  a message, and a session is three of them in series. Two- and four-hop legs are reported but\n` +
        `  not judged, because no budget is published for either distance.`
    );
  }
  return budgetFailures.length === 0;
}

// --- §3: how often a device meets a new peer ----------------------------------

function churnSection(): void {
  const WINDOW_MS = 600000; // 10 simulated minutes, as §3 states
  const SAMPLE_MS = 5000; // sampled every 5 s, as §3 states
  const hours = WINDOW_MS / 3600000;

  console.log("\n=== session churn: how often a device meets a new peer (docs/07 §3) ===");
  console.log(
    `The in-range graph is sampled every ${SAMPLE_MS / 1000} s over ${WINDOW_MS / 60000} simulated\n` +
      `minutes, and a pair counts once however many times it recurs. This is the measurement that\n` +
      `decides whether a device may handshake on discovery, so it is worth being careful about what\n` +
      `"per node" means — see the two columns at the end.\n`
  );

  const worlds: ReadonlyArray<{ name: string; config: SimConfig }> = [
    { name: "campus_quad", config: campusQuad(42) },
    { name: "festival_crowd", config: festivalCrowd(42) },
    { name: "sparse_village", config: sparseVillage(42) },
  ];

  console.log(
    "  world            nodes   pairs met   of all pairs   peers/node/hour   pairs/node/hour"
  );
  console.log("                                                        (counted)       (§3's formula)");

  for (const w of worlds) {
    const sim = new MeshSimulation(w.config);
    const ids = onlineIds(sim);
    const perNode = new Map<NodeId, Set<NodeId>>();
    for (const id of ids) perNode.set(id, new Set<NodeId>());
    const pairs = new Set<string>();

    for (let t = 0; t < WINDOW_MS; t += SAMPLE_MS) {
      sim.runFor(SAMPLE_MS);
      const online = sim.nodes.filter((n) => n.isOnline);
      for (let i = 0; i < online.length; i++) {
        for (let j = i + 1; j < online.length; j++) {
          const a = online[i];
          const b = online[j];
          if (!canReach(a, b, sim.rf)) continue;
          pairs.add(a.id < b.id ? `${a.id}|${b.id}` : `${b.id}|${a.id}`);
          perNode.get(a.id)?.add(b.id);
          perNode.get(b.id)?.add(a.id);
        }
      }
    }

    const n = ids.length;
    const possible = (n * (n - 1)) / 2;
    // Counted: for each node, how many distinct peers it came into range with, averaged, per hour.
    // This is what "new peers per node per hour" says. §3 divides the pair count by the node count
    // instead, which counts each meeting once for the pair rather than once for each of its two
    // members — exactly half. Both are printed so the reader can see which is which.
    let sum = 0;
    for (const id of ids) sum += perNode.get(id)?.size ?? 0;
    const counted = sum / n / hours;
    const formula = pairs.size / n / hours;

    console.log(
      `  ${w.name.padEnd(16)} ${String(n).padStart(3)}     ${String(pairs.size).padStart(7)}   ` +
        `${((pairs.size / possible) * 100).toFixed(0).padStart(5)}% of ${String(possible).padStart(4)}   ` +
        `${counted.toFixed(1).padStart(11)}   ${formula.toFixed(1).padStart(17)}`
    );
  }

  console.log(
    `\n  Read the counted column for "how many strangers does one device meet". The formula column\n` +
      `  is what docs/07 §3's table prints (30.6 / 70.2 / 9.0), and it is half the counted figure\n` +
      `  because a pair meeting is a new peer for *both* of its members. §3's conclusion is not\n` +
      `  affected — it argues against handshaking on discovery, and twice the churn argues harder —\n` +
      `  but the number it quotes understates the rate by a factor of two.`
  );
}

// --- §4: the packet layout, checked exactly -----------------------------------

function packetSection(): boolean {
  console.log("\n=== packet size, padding and the transport boundary (docs/07 §4) ===");
  console.log(
    `skills/03's packet is header 27 B + nonce 12 B + tag 16 B + from 32 B + ts 8 B = ` +
      `${PACKET_OVERHEAD_BYTES} B,\n` +
      `padded to ${PAD_BLOCK_BYTES} B blocks, so the wire size is ceil((${PACKET_OVERHEAD_BYTES} + body) / ` +
      `${PAD_BLOCK_BYTES}) × ${PAD_BLOCK_BYTES}. BLE carries up to\n` +
      `${BLE_MAX_BYTES} B. The heuristic this replaced was 64 + 4 B per character, which crossed the ` +
      `BLE ceiling\nat 241 characters instead of 930 — and transport is what sets per-hop latency in ` +
      `this model.\n`
  );

  // docs/07 §4's published table. These are checkable exactly, because they follow from the
  // exported constants rather than from a simulation, so this section is a test and not a printout.
  const rows: ReadonlyArray<{ body: number; wire: number; transport: string; old: number; oldTransport: string }> = [
    { body: 0, wire: 256, transport: "BLE", old: 64, oldTransport: "BLE" },
    { body: 241, wire: 512, transport: "BLE", old: 1028, oldTransport: "Wi-Fi Direct" },
    { body: 700, wire: 1024, transport: "BLE", old: 2864, oldTransport: "Wi-Fi Direct" },
    { body: 900, wire: 1024, transport: "BLE", old: 3664, oldTransport: "Wi-Fi Direct" },
    { body: 930, wire: 1280, transport: "Wi-Fi Direct", old: 3784, oldTransport: "Wi-Fi Direct" },
  ];

  console.log("  body     engine wire   transport      old heuristic   its transport   matches §4");
  const failures: string[] = [];
  for (const r of rows) {
    const wire = wireSizeOf(r.body);
    const transport = selectTransport(wire);
    const old = 64 + 4 * r.body;
    const oldTransport = selectTransport(old);
    const transportName = transport === "ble" ? "BLE" : "Wi-Fi Direct";
    const oldName = oldTransport === "ble" ? "BLE" : "Wi-Fi Direct";
    const ok = wire === r.wire && transportName === r.transport && old === r.old && oldName === r.oldTransport;
    if (!ok) {
      failures.push(
        `${r.body} chars: measured ${wire} B / ${transportName} and ${old} B / ${oldName}, ` +
          `docs/07 §4 says ${r.wire} B / ${r.transport} and ${r.old} B / ${r.oldTransport}`
      );
    }
    console.log(
      `  ${String(r.body).padStart(5)}   ${String(wire).padStart(9)} B   ${transportName.padEnd(14)} ` +
        `${String(old).padStart(9)} B   ${oldName.padEnd(13)} ${ok ? "yes" : "NO"}`
    );
  }

  // The claim §4 is actually making: where each model crosses the BLE ceiling.
  const crossing = (size: (n: number) => number): number | null => {
    for (let c = 0; c <= 2000; c++) if (selectTransport(size(c)) !== "ble") return c;
    return null;
  };
  const documentedCrossing = crossing(wireSizeOf);
  const oldCrossing = crossing((c) => 64 + 4 * c);
  console.log(
    `\n  the documented packet first leaves BLE at ${documentedCrossing} characters; ` +
      `the old heuristic left at ${oldCrossing}.`
  );
  if (documentedCrossing !== 930 || oldCrossing !== 241) {
    failures.push(
      `crossing points are ${documentedCrossing} and ${oldCrossing}, docs/07 §4 says 930 and 241`
    );
  }

  console.log("\n=== verdict ===");
  if (failures.length > 0) {
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    `  §4's table and both crossing points reproduce exactly from the exported constants.\n` +
      `  Padding makes length uninformative below ${PAD_BLOCK_BYTES - PACKET_OVERHEAD_BYTES} characters of body ` +
      `and coarse above it.`
  );
  return true;
}

// --- the crypto itself: sizes that used to be arithmetic, and costs that were guesses ---

/**
 * docs/07 §2.1's measured one-hop establishment total for `campus_quad`: 675 ms of
 * radio for three legs. Used below as the denominator for "what fraction of a
 * handshake is the CPU" — which §2.1 note 3 asserts qualitatively ("SAS
 * verification is not the slow part") and never measured.
 */
const ONE_HOP_RADIO_TOTAL_MS = 675;
/** A negotiated GATT MTU, the ceiling §7.2 asks about. */
const GATT_MTU_BYTES = 247;

function cryptoSection(): boolean {
  console.log("\n=== the crypto itself: real sizes and real costs (docs/07 §2.1 note 3, §4, §7.2) ===");
  console.log(
    `Everything below is measured from src/crypto/, the reference protocol layer over OpenSSL.\n` +
      `It is not custom crypto — skills/03 forbids that and this probe does not do it — but it is\n` +
      `real code producing real bytes, so the sizes it reports are not arithmetic on constants.\n`
  );
  const failures: string[] = [];

  // --- §7.2: does a handshake leg fit a GATT MTU? ---
  const pair = handshakeInProcess(crypto, crypto.generateX25519(), crypto.generateX25519());
  const legLengths = pair.legs.map((leg) => leg.length);
  console.log(`  §7.2  leg sizes on air                ${legLengths.join(" / ")} B`);
  console.log(
    `        largest leg vs a ${GATT_MTU_BYTES} B MTU          ${Math.max(...legLengths)} B, ` +
      `${GATT_MTU_BYTES - Math.max(...legLengths)} B to spare`
  );
  if (legLengths.join(",") !== LEG_SIZES.join(",")) {
    failures.push(
      `measured leg sizes ${legLengths.join("/")} disagree with LEG_SIZES ${LEG_SIZES.join("/")}`
    );
  }
  for (const [index, size] of legLengths.entries()) {
    if (size > GATT_MTU_BYTES) {
      failures.push(`leg ${index + 1} is ${size} B and does not fit a ${GATT_MTU_BYTES} B MTU`);
    }
  }

  // --- §4: does a sealed packet measure what the model says? ---
  const alice = generateIdentity(crypto);
  const bob = generateIdentity(crypto);
  const aliceSession = new DumanSession(
    crypto,
    alice,
    "initiator",
    sessionPrologueFromQr(crypto, alice, bob.signing.publicKey)
  );
  const bobSession = new DumanSession(
    crypto,
    bob,
    "responder",
    sessionPrologueFromQr(crypto, bob, alice.signing.publicKey)
  );
  bobSession.readLeg(aliceSession.writeLeg()!);
  aliceSession.readLeg(bobSession.writeLeg()!);
  bobSession.readLeg(aliceSession.writeLeg()!);
  if (aliceSession.currentPhase !== "unverified" || bobSession.currentPhase !== "unverified") {
    failures.push(
      `the handshake did not come up: ${aliceSession.currentPhase} / ${bobSession.currentPhase}`
    );
  }

  console.log("\n  §4    body                                    sealed packet   engine model   agrees");
  const emoji = "\u{1F600}".repeat(300);
  const bodies: ReadonlyArray<[string, string]> = [
    ["0 chars", ""],
    ["241 chars", "x".repeat(241)],
    ["700 chars", "x".repeat(700)],
    ["900 chars", "x".repeat(900)],
    ["929 chars (docs/08 §5.3 BLE ceiling)", "x".repeat(929)],
    ["930 chars", "x".repeat(930)],
    [`300 emoji (${emoji.length} code units, ${utf8ByteLength(emoji)} bytes)`, emoji],
  ];
  for (const [label, body] of bodies) {
    const sealed = aliceSession.send(
      {
        msgId: `m${label.length}`,
        type: "text",
        ttl: 5,
        hop: 0,
        nowMs: 1_760_000_000_000,
        body: new TextEncoder().encode(body),
      },
      bob.signing.publicKey
    );
    const measured = sealed ? sealed.length : -1;
    const model = wireSizeOfBody(body);
    const agrees = measured === model;
    if (!agrees) {
      failures.push(`"${label}": sealed to ${measured} B but the engine model says ${model} B`);
    }
    const received = sealed ? bobSession.receive(sealed) : null;
    if (!received || !received.ok) failures.push(`"${label}": Bob could not open what Alice sealed`);
    console.log(
      `        ${label.padEnd(42)} ${String(measured).padStart(7)} B   ${String(model).padStart(7)} B   ` +
        `${agrees ? "yes" : "NO"}`
    );
  }
  // The last row is why the engine counts bytes: sizing that body by `.length`
  // would have put 1 200 bytes on a transport that carries 1 024.
  console.log(
    `        (sized by .length the emoji body would be ${wireSizeOf(emoji.length)} B -> ` +
      `${selectTransport(wireSizeOf(emoji.length))}, and it does not fit)`
  );

  // --- §2.1 note 3: how much of a handshake is the CPU? ---
  for (let i = 0; i < 20; i++) {
    handshakeInProcess(crypto, crypto.generateX25519(), crypto.generateX25519());
  }
  const handshakes = 200;
  const startedHandshake = performance.now();
  for (let i = 0; i < handshakes; i++) {
    handshakeInProcess(crypto, crypto.generateX25519(), crypto.generateX25519());
  }
  const handshakeMs = (performance.now() - startedHandshake) / handshakes;

  const payload = new TextEncoder().encode("x".repeat(160));
  const chain = new SymmetricRatchet(crypto, crypto.randomBytes(32));
  const drain = SymmetricRatchet.restore(crypto, chain.compromise());
  for (let i = 0; i < 200; i++) {
    const sealed = chain.seal(payload);
    drain.open(sealed.num, sealed.sealed);
  }
  const sealRounds = 2000;
  const startedSeal = performance.now();
  for (let i = 0; i < sealRounds; i++) chain.seal(payload);
  const sealMs = (performance.now() - startedSeal) / sealRounds;

  const share = (handshakeMs / ONE_HOP_RADIO_TOTAL_MS) * 100;
  console.log(
    `\n  §2.1  one handshake (2 keygen, 3 DH, 4 AEAD)   ${(handshakeMs * 1000).toFixed(0)} µs`
  );
  console.log(`        one-hop radio total from §2.1's table   ${ONE_HOP_RADIO_TOTAL_MS} ms`);
  console.log(`        the CPU is ${share.toFixed(3)} % of a one-hop handshake`);
  // sealMs is milliseconds, so a rate per second needs the 1000 — the first
  // version of this line printed "63 msg/s" for 63 000 and "9 876 MB/s" for 9.6.
  const sealsPerSecond = 1000 / sealMs;
  const megabytesPerSecond = payload.length / (sealMs / 1000) / (1024 * 1024);
  console.log(
    `        one message sealed (160 B + ratchet)    ${(sealMs * 1000).toFixed(1)} µs  ` +
      `→ ${sealsPerSecond.toFixed(0)} msg/s, ${megabytesPerSecond.toFixed(1)} MiB/s`
  );
  // §2.1 note 3 says the SAS comparison is instant and the 0.5-6.7 s is the radio.
  // That is now a measured statement with a threshold attached rather than an
  // intuition: if the CPU ever became a visible share of a handshake, the note
  // would be wrong and this would say so.
  if (share > 5) {
    failures.push(
      `the handshake CPU is ${share.toFixed(2)} % of the one-hop radio total; §2.1 note 3's ` +
        `"the 0.5-6.7 s is the radio" assumes it is negligible`
    );
  }

  // --- §6 row 1: the capture test, with a relay that holds real keys ---
  const relayId = generateIdentity(crypto);
  const aliceToRelay = new DumanSession(
    crypto,
    alice,
    "initiator",
    sessionPrologueFromQr(crypto, alice, relayId.signing.publicKey)
  );
  const relay = new DumanSession(
    crypto,
    relayId,
    "responder",
    sessionPrologueFromQr(crypto, relayId, alice.signing.publicKey)
  );
  relay.readLeg(aliceToRelay.writeLeg()!);
  aliceToRelay.readLeg(relay.writeLeg()!);
  relay.readLeg(aliceToRelay.writeLeg()!);

  const packet = aliceSession.send(
    {
      msgId: "capture",
      type: "text",
      ttl: 5,
      hop: 1,
      nowMs: 1_760_000_000_000,
      body: new TextEncoder().encode("the atrium at 14:00, bring the battery pack"),
    },
    bob.signing.publicKey
  )!;
  const visible = relayVisible(packet);
  const stolen = relay.compromise()!;
  const attacker = SymmetricRatchet.restore(crypto, stolen.recv);
  const num = decodeNonce(packet.subarray(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES))!;
  const derived = attacker.keyFor(num);
  const attempt = derived.ok ? openPacket(crypto, derived.key, packet) : null;
  const onAir = Buffer.from(packet).toString("latin1");

  console.log("\n  §6    what a SUPER relay that is also a legitimate peer of Alice can read:");
  console.log(
    `        header   ttl ${visible?.ttl}, type ${visible?.type}, hop ${visible?.hop}, ` +
      `destHint ${visible?.destHint}`
  );
  console.log(`        body     ${visible?.bodyReadable ? "READABLE — bug" : "not readable"}`);
  console.log(
    `        opened with its own legitimate message key   ` +
      `${attempt && attempt.ok ? "SUCCEEDED — bug" : `fails (${attempt && !attempt.ok ? attempt.reason : "no key"})`}`
  );
  console.log(`        plaintext visible in the bytes on air        ${onAir.includes("atrium") ? "YES — bug" : "no"}`);
  if (!visible || visible.bodyReadable) failures.push("a relay could read the body of a sealed packet");
  if (attempt && attempt.ok) {
    failures.push("a relay opened a packet addressed to someone else with its own legitimate key");
  }
  if (onAir.includes("atrium")) failures.push("the body appeared in plaintext in the sealed packet");

  console.log("\n=== verdict ===");
  if (failures.length > 0) {
    for (const f of failures) console.log(`  · ${f}`);
    return false;
  }
  console.log(
    `  Legs are ${legLengths.join("/")} B and each fits one unfragmented ${GATT_MTU_BYTES} B GATT write (§7.2).\n` +
      `  Every sealed packet measures what the engine's wireSizeOf predicts, including a body whose\n` +
      `  code-unit count and byte count disagree (§4).\n` +
      `  A handshake is ${share.toFixed(3)} % CPU and ${(100 - share).toFixed(3)} % radio at one hop, so §2.1\n` +
      `  note 3 holds with a number attached: the seconds are the mesh, not the crypto.\n` +
      `  A relay holding a legitimate key from its own session with the sender reads the header and\n` +
      `  nothing else (§6 row 1).`
  );
  return true;
}

// --- section dispatch ---------------------------------------------------------

const SECTIONS: ReadonlyArray<[string, () => boolean | void]> = [
  ["latency", latencySection],
  ["churn", churnSection],
  ["packet", packetSection],
  ["crypto", cryptoSection],
];

function main(): void {
  const only = process.argv[2];
  if (only && !SECTIONS.some(([name]) => name === only)) {
    console.error(`unknown section "${only}". one of: ${SECTIONS.map(([name]) => name).join(", ")}`);
    process.exit(2);
  }

  console.log(
    "Duman Messenger — what E2EE costs on this mesh (docs/07 §2–§4, §7)\n" +
      "Three sections measure the mesh carrying crypto-shaped messages, which is the part a\n" +
      "protocol simulator can honestly answer. The fourth runs the reference protocol layer in\n" +
      "src/crypto/ over OpenSSL and measures the crypto itself."
  );

  let failed = false;
  for (const [name, run] of SECTIONS) {
    if (only && name !== only) continue;
    const ok = run();
    if (ok === false) failed = true;
  }

  if (failed) {
    console.error("\nFAIL — a documented figure did not reproduce; see the verdicts above.");
    process.exitCode = 1;
  } else {
    console.log("\nPASS — every figure this probe asserts reproduced.");
  }
}

main();
