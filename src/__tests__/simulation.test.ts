import { describe, expect, it } from "vitest";
import {
  MeshSimulation,
  DEFAULT_CONFIG,
  deliveredChain,
  encodeHistoryBeacon,
  fnv1a32,
  historyBucket,
  historyDigest,
  type SimConfig,
} from "../simulation";
import {
  buildScenario,
  campusQuad,
  festivalCrowd,
  partitionedPair,
  scenarioNames,
  sparseVillage,
} from "../scenarios";
import { canReach, effectiveLossProbability, peersInRange, rssiModel } from "../rf";
import { createRng } from "../rng";
import {
  OPP_QUEUE_MAX,
  OPP_TTL_MS,
  SPRAY_LIMIT,
  createMessage,
  deliverToInbox,
  enqueueOpp,
  pruneAcked,
  pruneOppQueue,
  selectTransport,
  wireSizeOf,
} from "../routing";
import { makeNode, rfWith } from "./helpers";
import {
  BATTERY_FLOOR,
  CHARGING_BONUS,
  WEIGHTS,
  computeScore,
  isCommunityRelay,
  selectMprSet,
} from "../election";
import {
  HISTORY_BUCKETS,
  type HistoryEntry,
  type MeshMessage,
  type MeshNode,
  type NodeId,
  type PeerNorm,
} from "../types";

/**
 * Every test in the first block pins a defect that existed in the original
 * prototype engine. They are written as regressions so the failure modes cannot
 * silently return.
 */

/** Minimal SOS message for the inbox rules, which are pure functions. */
function makeSos(repeat: number, timestamp: number, pos: { x: number; y: number }): MeshMessage {
  const msg = createMessage(
    `sos-msg-${repeat}`,
    timestamp,
    "node-a",
    "BROADCAST",
    "injured, need help",
    "sos",
    5,
    "high"
  );
  msg.sosId = "sos-a";
  msg.sosRepeat = repeat;
  msg.sosPos = pos;
  return msg;
}

/** Deterministic traffic: pairs drawn from the simulation's own RNG. */
function driveTraffic(sim: MeshSimulation, messages: number, gapMs = 1500): void {
  for (let i = 0; i < messages; i++) {
    const online = sim.nodes.filter((n) => n.isOnline);
    if (online.length >= 2) {
      const from = online[Math.floor(sim.rng() * online.length)];
      let to = online[Math.floor(sim.rng() * online.length)];
      let guard = 0;
      while (to.id === from.id && guard++ < 32) to = online[Math.floor(sim.rng() * online.length)];
      if (to.id !== from.id) sim.sendMessage(from.id, to.id, `probe-${i}`, "text");
    }
    sim.runFor(gapMs);
  }
  sim.refresh();
}

/** Size of the connected component containing `start`, over the RF graph. */
function componentSize(sim: MeshSimulation, start = "node-0"): number {
  const seen = new Set<string>([start]);
  const queue = [start];
  while (queue.length > 0) {
    const cur = queue.shift() as string;
    const node = sim.nodes.find((n) => n.id === cur);
    if (!node) continue;
    for (const peer of peersInRange(node, sim.nodes, sim.rf)) {
      if (!seen.has(peer.id)) {
        seen.add(peer.id);
        queue.push(peer.id);
      }
    }
  }
  return seen.size;
}

describe("regressions against the original prototype", () => {
  it("does not blow the stack when two adjacent nodes exchange one message", () => {
    // Original defect: delivering a message minted a *new* ACK id every time, so
    // ACK -> delivery -> ACK recursed until "Maximum call stack size exceeded".
    const cfg: SimConfig = {
      ...DEFAULT_CONFIG,
      nodeCount: 2,
      clusters: [],
      enableMobility: false,
      enableSuperElection: false,
      areaWidth: 60,
      areaHeight: 60,
      warmupMs: 4000,
    };
    const sim = new MeshSimulation(cfg);
    sim.nodes[0].pos = { x: 20, y: 30 };
    sim.nodes[1].pos = { x: 28, y: 30 };
    expect(canReach(sim.nodes[0], sim.nodes[1], sim.rf)).toBe(true);

    expect(() => {
      sim.sendMessage("node-0", "node-1", "hello", "text");
      sim.runFor(30000);
    }).not.toThrow();

    sim.refresh();
    expect(sim.nodes[1].inbox.some((m) => m.body === "hello")).toBe(true);
    // Exactly one ACK per delivered message — never an ACK of an ACK.
    expect(sim.stats.acksReceived).toBeLessThanOrEqual(1);
    const ackCount = sim.nodes.reduce(
      (s, n) => s + n.inbox.filter((m) => m.type === "ack").length,
      0
    );
    expect(ackCount).toBeLessThanOrEqual(1);
  });

  it("brings up a connected world by default", () => {
    // Original defect: an 800x600 canvas with a ~35 m radio left 11-18 of 20
    // nodes isolated, so nothing could be elected or delivered.
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(20000);
    sim.refresh();
    expect(componentSize(sim)).toBe(sim.nodes.length);
    const avgPeers = sim.nodes.reduce((s, n) => s + n.peerCount, 0) / sim.nodes.length;
    expect(avgPeers).toBeGreaterThan(3);
    expect(sim.nodes.filter((n) => n.peerCount === 0)).toHaveLength(0);
  });

  it("never spawns a node inside a building", () => {
    const cfg = campusQuad(42);
    const sim = new MeshSimulation(cfg);
    for (const n of sim.nodes) {
      for (const o of cfg.obstacles) {
        const inside = n.pos.x > o.x && n.pos.x < o.x + o.w && n.pos.y > o.y && n.pos.y < o.y + o.h;
        expect(inside).toBe(false);
      }
    }
  });

  it("learns routes beyond one hop by gossiping OGMs", () => {
    // Original defect: OGMs were handed only to direct peers, so the nextHop
    // table never contained a non-neighbour and multi-hop unicast was impossible.
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(30000);
    sim.refresh();
    const withRemoteRoutes = sim.nodes.filter((n) =>
      Object.values(n.nextHopTable).some((e) => e.hopCount > 1)
    );
    expect(withRemoteRoutes.length).toBeGreaterThan(sim.nodes.length * 0.8);
  });

  it("delivers a multi-hop unicast along a routed path", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), enableMobility: false });
    sim.runFor(20000);
    sim.refresh();

    // Pick a pair that is out of direct range but in the same component.
    const from = sim.nodes[0];
    // `canReach(a, a)` is false by construction (rf.ts), so without the id check
    // this silently picked the *sender* as its multi-hop target — and the test
    // only passed because the engine used to bounce a node's own message back to
    // it through the mesh. onMsgReceive now drops copies of a message the receiver
    // originated, so the pick has to be explicit.
    const target = sim.nodes.find(
      (n) => n.id !== from.id && !canReach(from, n, sim.rf) && componentSize(sim) > 1
    );
    expect(target).toBeDefined();
    const to = target as MeshNode;

    const msg = sim.sendMessage(from.id, to.id, "multi-hop", "text");
    sim.runFor(20000);
    sim.refresh();

    expect(msg).not.toBeNull();
    const delivered = to.inbox.some((m) => m.id === (msg as { id: string }).id);
    expect(delivered).toBe(true);
    const record = sim.deliveries.find((d) => d.msgId === (msg as { id: string }).id);
    expect(record).toBeDefined();
    expect(record!.hops).toBeGreaterThan(1);
    expect(record!.path.length).toBeGreaterThan(2);
  });

  it("measures latency on a virtual clock that grows with hop count", () => {
    // Original defect: latency was Date.now() arithmetic around a synchronous
    // burst, so it was permanently 0 ms and TTL/expiry never fired.
    const sim = new MeshSimulation(campusQuad(42));
    driveTraffic(sim, 40);
    const delivered = sim.deliveries.filter((d) => d.type !== "ack");
    expect(delivered.length).toBeGreaterThan(0);
    for (const d of delivered) expect(d.latencyMs).toBeGreaterThan(0);

    const direct = delivered.filter((d) => d.hops === 1);
    const relayed = delivered.filter((d) => d.hops >= 3);
    if (direct.length > 0 && relayed.length > 0) {
      const avg = (xs: number[]) => xs.reduce((s, v) => s + v, 0) / xs.length;
      expect(avg(relayed.map((d) => d.latencyMs))).toBeGreaterThan(
        avg(direct.map((d) => d.latencyMs))
      );
    }
    expect(sim.stats.simTimeMs).toBeGreaterThan(0);
  });

  it("counts broadcast deliveries instead of silently dropping them", () => {
    // Original defect: broadcast recipients were pushed into inboxes without a
    // delivery record, so the dashboard under-reported everything.
    const sim = new MeshSimulation({ ...campusQuad(42), enableMobility: false });
    sim.runFor(15000);
    sim.sendMessage("node-0", "BROADCAST", "pager check", "broadcast");
    sim.runFor(20000);
    sim.refresh();

    const recipients = sim.nodes.filter((n) => n.inbox.some((m) => m.body === "pager check"));
    expect(recipients.length).toBeGreaterThan(1);
    expect(sim.stats.broadcastReach).toBeGreaterThan(0);
    const record = sim.sentRecords.find((r) => r.to === "BROADCAST");
    expect(record).toBeDefined();
    expect(record!.recipients).toBe(recipients.length);
    expect(record!.delivered).toBe(true);
  });

  it("expires soft state on simulated time, not wall-clock time", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), enableMobility: false });
    sim.runFor(20000);
    sim.refresh();
    const before = sim.nodes.reduce((s, n) => s + Object.keys(n.nextHopTable).length, 0);
    expect(before).toBeGreaterThan(0);

    // 10 simulated minutes with elections and OGMs still flowing: entries whose
    // originator vanished must be gone (30 s soft-state expiry).
    sim.toggleNodeOnline("node-3");
    sim.runFor(600000);
    sim.refresh();
    const stillKnowsNode3 = sim.nodes.filter((n) => n.nextHopTable["node-3"]).length;
    expect(stillKnowsNode3).toBe(0);
  });
});

describe("determinism", () => {
  it("reproduces a run exactly for the same seed", () => {
    const a = new MeshSimulation(campusQuad(42));
    const b = new MeshSimulation(campusQuad(42));
    driveTraffic(a, 25);
    driveTraffic(b, 25);
    expect(a.stats.totalDelivered).toBe(b.stats.totalDelivered);
    expect(a.stats.totalForwarded).toBe(b.stats.totalForwarded);
    expect(a.stats.superNodes).toBe(b.stats.superNodes);
    expect(a.stats.avgLatencyMs).toBe(b.stats.avgLatencyMs);
    expect(a.nodes.map((n) => n.pos.x)).toEqual(b.nodes.map((n) => n.pos.x));
    expect(a.deliveries.map((d) => `${d.msgId}:${d.hops}`)).toEqual(
      b.deliveries.map((d) => `${d.msgId}:${d.hops}`)
    );
  });

  it("diverges for a different seed", () => {
    const a = new MeshSimulation(campusQuad(42));
    const b = new MeshSimulation(campusQuad(43));
    expect(a.nodes.map((n) => n.pos.x)).not.toEqual(b.nodes.map((n) => n.pos.x));
  });

  it("resets back to the seeded world", () => {
    const sim = new MeshSimulation(campusQuad(42));
    const firstPositions = sim.nodes.map((n) => `${n.pos.x.toFixed(6)},${n.pos.y.toFixed(6)}`);
    driveTraffic(sim, 10);
    sim.reset();
    expect(sim.nodes.map((n) => `${n.pos.x.toFixed(6)},${n.pos.y.toFixed(6)}`)).toEqual(firstPositions);
    expect(sim.deliveries).toHaveLength(0);
    expect(sim.sentRecords).toHaveLength(0);
  });
});

describe("delay-tolerant networking (docs/03 §8)", () => {
  it("carries a message across a partition until the groups meet", () => {
    const cfg = partitionedPair(42);
    const sim = new MeshSimulation({ ...cfg, enableMobility: false });
    sim.runFor(15000);
    sim.refresh();

    const west = sim.nodes.filter((n) => n.pos.x < 130);
    const east = sim.nodes.filter((n) => n.pos.x >= 130);
    expect(west.length).toBeGreaterThan(0);
    expect(east.length).toBeGreaterThan(0);
    expect(canReach(west[0], east[0], sim.rf)).toBe(false);

    const msg = sim.sendMessage(west[0].id, east[0].id, "carry me", "text");
    sim.runFor(30000);
    sim.refresh();
    expect(msg).not.toBeNull();
    expect(east[0].inbox.some((m) => m.id === (msg as { id: string }).id)).toBe(false);
    const carriers = sim.nodes.filter((n) => n.oppQueue.some((q) => q.msg.id === (msg as { id: string }).id));
    expect(carriers.length).toBeGreaterThan(0);

    // A node walks the bundle into range of the destination group.
    const carrier = carriers[0];
    carrier.pos = { x: east[0].pos.x - 5, y: east[0].pos.y };
    sim.runFor(20000);
    sim.refresh();
    expect(east[0].inbox.some((m) => m.id === (msg as { id: string }).id)).toBe(true);
  });

  it("keeps undeliverable traffic in a sparse village instead of dropping it", () => {
    const sim = new MeshSimulation(sparseVillage(42));
    driveTraffic(sim, 20);
    expect(sim.stats.totalQueued).toBeGreaterThan(0);
    expect(sim.nodes.every((n) => n.oppQueue.length <= 500)).toBe(true);
  });
});

describe("node lifecycle and manual controls", () => {
  it("takes a node offline when its battery is exhausted", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), batteryDrainMultiplier: 4000 });
    sim.runFor(60000);
    sim.refresh();
    const dead = sim.nodes.filter((n) => !n.isOnline);
    expect(dead.length).toBeGreaterThan(0);
    for (const n of dead) {
      expect(n.battery).toBe(0);
      expect(n.role).toBe("NORMAL");
      expect(n.reasonTrace).toMatch(/Battery depleted/);
    }
  });

  it("honours manual offline/online and charging toggles", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.toggleNodeOnline("node-1");
    expect(sim.nodes[1].isOnline).toBe(false);
    expect(sim.nodes[1].role).toBe("NORMAL");
    sim.runFor(10000);
    sim.toggleNodeOnline("node-1");
    expect(sim.nodes[1].isOnline).toBe(true);
    expect(sim.nodes[1].battery).toBeGreaterThanOrEqual(0.3);

    sim.setNodeCharging("node-2", true);
    expect(sim.nodes[2].charging).toBe(true);
    const before = sim.nodes[2].battery;
    sim.runFor(600000);
    expect(sim.nodes[2].battery).toBeGreaterThan(before);
  });

  it("refuses to send from an offline node", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.toggleNodeOnline("node-0");
    expect(sim.sendMessage("node-0", "node-1", "ghost", "text")).toBeNull();
  });
});

describe("protocol behaviour", () => {
  it("retransmits from the source when no ACK returns, and stops at the budget", () => {
    const sim = new MeshSimulation(campusQuad(42));
    driveTraffic(sim, 60);
    expect(sim.stats.retriesSent).toBeGreaterThanOrEqual(0);
    expect(sim.stats.retriesExhausted).toBeLessThanOrEqual(sim.stats.sentUnicast);
    expect(sim.stats.acksReceived).toBeGreaterThan(0);
    // Retries never exceed the configured budget per logical message.
    expect(sim.stats.retriesSent).toBeLessThanOrEqual(sim.stats.sentUnicast * 2);
  });

  it("suppresses redundant NORMAL relays under MPR but not under flood-all", () => {
    const mpr = new MeshSimulation(campusQuad(42));
    const flood = new MeshSimulation({ ...campusQuad(42), relayPolicy: "flood-all" });
    driveTraffic(mpr, 60);
    driveTraffic(flood, 60);
    expect(mpr.stats.mprSuppressed).toBeGreaterThan(0);
    expect(flood.stats.mprSuppressed).toBe(0);
    expect(mpr.stats.totalForwarded).toBeLessThan(flood.stats.totalForwarded);
  });

  it("elects super-nodes only from eligible candidates", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(120000);
    sim.refresh();
    for (const n of sim.nodes.filter((x) => x.role === "SUPER")) {
      expect(n.battery).toBeGreaterThanOrEqual(0.25);
      expect(n.peerCount).toBeGreaterThanOrEqual(3);
      expect(n.score).toBeGreaterThan(0.5);
      expect(n.reasonTrace).toMatch(/SUPER|Promoted/);
    }
  });

  it("disables election when configured to", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), enableSuperElection: false });
    sim.runFor(120000);
    sim.refresh();
    expect(sim.stats.superNodes).toBe(0);
  });

describe("hop traces and the capture log (roadmap Phase 4)", () => {
  /** A run with real multi-hop traffic to inspect. */
  function traced(over: Partial<SimConfig> = {}, messages = 24): MeshSimulation {
    const sim = new MeshSimulation({ ...campusQuad(42), ...over });
    sim.runFor(90000);
    driveTraffic(sim, messages);
    return sim;
  }

  it("records when each hop arrived, over what link, and what it decided", () => {
    const sim = traced();
    const multi = sim.deliveries.find((d) => d.hops >= 2 && !d.dtn);
    expect(multi).toBeDefined();
    const hops = multi!.hopTrace;
    expect(hops.length).toBeGreaterThan(0);

    let prev = -1;
    for (const h of hops) {
      expect(h.atMs).toBeGreaterThanOrEqual(prev); // arrival order
      prev = h.atMs;
      expect(h.rssi).toBeLessThan(0); // a real dBm figure from the docs/05 model
      expect(h.rssi).toBeGreaterThan(-100);
      expect(h.via).not.toBe(h.nodeId);
      expect(["received", "delivered", "relayed", "suppressed", "queued", "expired"]).toContain(
        h.action
      );
      if (h.action === "relayed" || h.action === "suppressed") {
        expect(h.reason).toBeTruthy(); // decideForward's own words
      }
    }
    // The recipient's copy is the one that says so.
    expect(hops.some((h) => h.nodeId === multi!.to && h.action === "delivered")).toBe(true);
  });

  it("recovers the route chain from the fan-out tree", () => {
    // `path` lists every node that accepted a fresh copy, so it branches as soon
    // as a relay fans out; "via 2 nodes" needs the single route the delivered
    // copy took. Walking `via` backwards must reproduce exactly `hops` links.
    const sim = traced();
    expect(sim.deliveries.length).toBeGreaterThan(5);
    let sawTree = false;
    for (const d of sim.deliveries) {
      const chain = deliveredChain(d.hopTrace, d.to);
      expect(chain.length).toBe(d.hops);
      expect(chain[chain.length - 1].nodeId).toBe(d.to);
      if (d.path.length > d.hops + 1) sawTree = true;
    }
    // The fan-out this exists to cut through actually happens in this world.
    expect(sawTree).toBe(true);
  });

  it("marks the relays MPR suppressed, with the reason", () => {
    const sim = traced();
    const suppressed = sim.deliveries.flatMap((d) =>
      d.hopTrace.filter((h) => h.action === "suppressed")
    );
    expect(suppressed.length).toBeGreaterThan(0);
    expect(suppressed.every((h) => /MPR/.test(h.reason ?? ""))).toBe(true);
  });

  it("traces hops always, and captures the log only when asked", () => {
    expect(DEFAULT_CONFIG.captureLog).toBe(false);
    const plain = traced();
    expect(plain.log).toHaveLength(0);
    expect(plain.deliveries.some((d) => d.hopTrace.length > 0)).toBe(true);

    const captured = traced({ captureLog: true });
    expect(captured.log.length).toBeGreaterThan(0);
    const kinds = new Set(captured.log.map((e) => e.kind));
    expect(kinds.has("tx")).toBe(true);
    expect(kinds.has("decision")).toBe(true);
    expect(kinds.has("deliver")).toBe(true);
    // Beacons outnumber everything else, so they stay out unless asked for.
    expect(kinds.has("ogm")).toBe(false);
    for (const e of captured.log) {
      expect(e.detail.length).toBeGreaterThan(0);
      expect(e.atMs).toBeGreaterThanOrEqual(0);
    }
  });

  it("logs beacons too when captureOgm is set", () => {
    const sim = traced({ captureLog: true, captureOgm: true }, 4);
    expect(sim.log.some((e) => e.kind === "ogm")).toBe(true);
  });

  it("keeps the capture bounded and in time order", () => {
    const sim = traced({ captureLog: true, maxLogEntries: 40 });
    expect(sim.log.length).toBeLessThanOrEqual(40);
    expect(sim.log.length).toBe(40); // the ring buffer is full by now
    for (let i = 1; i < sim.log.length; i++) {
      expect(sim.log[i].atMs).toBeGreaterThanOrEqual(sim.log[i - 1].atMs);
    }
  });

  it("does not perturb the run it is measuring", () => {
    // Instrumentation that changed the result would be worse than none: the log
    // must not touch the RNG, the event order or a single counter.
    const plain = traced();
    const captured = traced({ captureLog: true, captureOgm: true });
    expect(captured.stats.totalForwarded).toBe(plain.stats.totalForwarded);
    expect(captured.stats.controlOverhead).toBe(plain.stats.controlOverhead);
    expect(captured.stats.totalDelivered).toBe(plain.stats.totalDelivered);
    expect(captured.stats.avgLatencyMs).toBe(plain.stats.avgLatencyMs);
    expect(captured.nodes.map((n) => n.pos.x)).toEqual(plain.nodes.map((n) => n.pos.x));
  });

  it("drops the log when metrics are re-baselined", () => {
    const sim = traced({ captureLog: true });
    expect(sim.log.length).toBeGreaterThan(0);
    sim.clearRecords();
    expect(sim.log).toHaveLength(0);
  });

  it("logs the DTN last resort as a queue event", () => {
    // partitioned_pair's two clusters are ~190 m apart, so nothing routes: the
    // originator retries twice, gives up, and starts carrying the bundle
    // (docs/03 §8). That hand-over into the OppQueue is exactly the event a
    // debugger needs, and it happens on a different code path from
    // decideForward's "queue" mode.
    const sim = new MeshSimulation({ ...partitionedPair(42), captureLog: true });
    sim.runFor(60000);
    const online = sim.nodes.filter((n) => n.isOnline);
    for (let i = 0; i < 4; i++) {
      sim.sendMessage(online[0].id, online[online.length - 1].id, `carry-${i}`, "text");
      sim.runFor(60000);
    }
    sim.refresh(); // `stats` is a snapshot, not a live getter
    expect(sim.stats.totalQueued).toBeGreaterThan(0);
    const queued = sim.log.filter((e) => e.kind === "queue");
    expect(queued.length).toBeGreaterThan(0);
    expect(queued[0].detail).toMatch(/carrying/);
    const queuedHere = queued.filter((e) => e.nodeId === sim.nodes[0].id);
    expect(sim.nodes[0].oppQueue.length).toBe(queuedHere.length);
    // In a partitioned world only the originators park anything, because no copy ever
    // reaches the far side. The rule that matters — a carried bundle with no route is
    // parked rather than deleted by flood suppression (skills/04, docs/06 §20) — shows up
    // as *other* nodes queueing copies wherever copies do travel, which is what the crowd
    // measurement in §20 reports.
    expect(queued.length).toBeGreaterThanOrEqual(queuedHere.length);
    expect(new Set(queued.map((e) => e.msgId)).size).toBeLessThanOrEqual(4);
  });
});

describe("power policy and telemetry (skills/02, skills/07, roadmap Phase 2)", () => {
  it("never promotes a node the user opted out of, and steps it down at once", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(90000); // past the first election at 30 s
    sim.refresh();
    const super0 = sim.nodes.find((n) => n.role === "SUPER");
    expect(super0).toBeDefined();
    sim.setSuperOptOut(super0!.id, true);
    expect(super0!.role).toBe("NORMAL");
    expect(super0!.reasonTrace).toMatch(/opt-out/);
    // and it stays down across the next tick
    sim.runFor(40000);
    expect(super0!.role).toBe("NORMAL");
    sim.setSuperOptOut(super0!.id, false);
    sim.runFor(40000);
    expect(super0!.role).toBe("SUPER");
  });

  it("keeps the mesh routing when a third of the nodes decline the role", () => {
    // Opt-out is user intent, so it outranks the 15-25% band skills/02 measures
    // on an unmodified run: the router set must shrink. What must not happen is
    // a coverage hole. Because the declination is advertised in the OGM, the
    // declined nodes drop out of the top-20% candidacy ranking and the
    // remaining ones take the slots — measured here as 4 SUPERs (ratio 0.20)
    // instead of the 2 (ratio 0.10) the ranking produced while declined peers
    // still occupied candidate slots.
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(90000);
    for (let i = 0; i < sim.nodes.length; i += 3) sim.setSuperOptOut(sim.nodes[i].id, true);
    expect(sim.nodes.filter((n) => n.superOptOut)).toHaveLength(7);
    sim.clearRecords();
    driveTraffic(sim, 30);
    expect(sim.nodes.filter((n) => n.superOptOut && n.role === "SUPER")).toHaveLength(0);
    // 13 remaining candidates * 20% = 3 slots, so the set must not fall below
    // what the reduced pool still allows.
    expect(sim.stats.superNodes).toBeGreaterThanOrEqual(3);
    expect(sim.stats.superRatio).toBeLessThanOrEqual(0.25);
    expect(sim.stats.deliveryRatio).toBeGreaterThanOrEqual(0.9);
  });

  it("never auto-promotes with battery saver on", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(90000);
    for (const n of sim.nodes) sim.setBatterySaver(n.id, true);
    sim.runFor(60000);
    sim.refresh();
    expect(sim.stats.superNodes).toBe(0);
    const online = sim.nodes.filter((n) => n.isOnline);
    expect(online.every((n) => n.reasonTrace.includes("Battery saver"))).toBe(true);
  });

  it("leaves duty cycling off by default", () => {
    expect(DEFAULT_CONFIG.dutyCycleEnabled).toBe(false);
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(60000);
    sim.refresh();
    expect(sim.stats.awakeRatio).toBe(1);
    expect(sim.stats.scansSkippedAsleep).toBe(0);
  });

  it("scans 3 s out of every 10 s when duty cycling, and never sleeps a SUPER", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), dutyCycleEnabled: true });
    sim.runFor(90000);
    const normal = sim.nodes.find((n) => n.role === "NORMAL")!;
    const superNode = sim.nodes.find((n) => n.role === "SUPER")!;
    expect(sim.isAwake(superNode)).toBe(true);

    // Sample the window across one full cycle for a node whose phase is 0.
    normal.dutyPhaseMs = 0;
    let awake = 0;
    const samples = 1000;
    for (let i = 0; i < samples; i++) {
      if (sim.isAwake(normal, (i / samples) * 10000)) awake++;
    }
    expect(awake / samples).toBeCloseTo(0.3, 1);
    // Window boundaries: awake at 0 and 2999 ms, asleep at 3000 and 9999 ms.
    expect(sim.isAwake(normal, 0)).toBe(true);
    expect(sim.isAwake(normal, 2999)).toBe(true);
    expect(sim.isAwake(normal, 3000)).toBe(false);
    expect(sim.isAwake(normal, 9999)).toBe(false);
  });

  it("spreads duty phases so a crowd does not sleep in lockstep", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), dutyCycleEnabled: true });
    const phases = new Set(sim.nodes.map((n) => Math.round(n.dutyPhaseMs)));
    expect(phases.size).toBe(sim.nodes.length);
    // At any instant some NORMAL node is awake to carry discovery.
    sim.runFor(60000);
    sim.refresh();
    expect(sim.stats.awakeRatio).toBeGreaterThan(0);
    expect(sim.stats.awakeRatio).toBeLessThan(1);
    expect(sim.stats.scansSkippedAsleep).toBeGreaterThan(0);
  });

  it("trades discovery for battery when duty cycling", () => {
    // skills/07's whole argument: the sleep slot is what keeps NORMAL under
    // 15%/8h. Measured, not asserted from the drain constants.
    const plain = new MeshSimulation(campusQuad(42));
    driveTraffic(plain, 20);
    const duty = new MeshSimulation({ ...campusQuad(42), dutyCycleEnabled: true });
    driveTraffic(duty, 20);
    expect(duty.stats.batteryPercentPerHourNormal).toBeLessThan(
      plain.stats.batteryPercentPerHourNormal
    );
    expect(duty.stats.scansPerSec).toBeLessThan(plain.stats.scansPerSec);
    // Sleeping must not cost delivery: an asleep node still relays what it
    // knows how to route.
    expect(duty.stats.deliveryRatio).toBeGreaterThanOrEqual(plain.stats.deliveryRatio - 0.05);
  });

  it("reports battery %/h per role, scans/sec and relays/sec", () => {
    const sim = new MeshSimulation(campusQuad(42));
    driveTraffic(sim, 20);
    const s = sim.stats;
    expect(s.batteryPercentPerHourNormal).toBeGreaterThan(0);
    expect(s.batteryPercentPerHourSuper).toBeGreaterThan(s.batteryPercentPerHourNormal);
    expect(s.scansPerSec).toBeGreaterThan(0);
    expect(s.relaysPerSec).toBeGreaterThan(0);
    expect(s.electionEvents).toBeGreaterThan(0);
  });

  it("spends exactly the skills/07 budget always-on, and buys headroom by sleeping", () => {
    // Roles are promoted at the first election, so a window that starts at
    // warm-up bleeds pre-promotion drain into the per-role average (measured
    // 6.82 %/h instead of 7.5 for SUPER). Settle first, then re-baseline.
    const measure = (over: Partial<SimConfig>) => {
      const sim = new MeshSimulation({ ...campusQuad(42), stationaryRatio: 1, ...over });
      sim.runFor(90000);
      sim.clearRecords();
      sim.runFor(90000);
      sim.refresh();
      return sim.stats;
    };

    // 15% over 8 h = 1.875 %/h, which is precisely NORMAL_DRAIN_PER_HOUR: an
    // always-scanning NORMAL node spends the whole documented budget with zero
    // margin, and a moving node adds the mobility term on top of it.
    const alwaysOn = measure({});
    expect(alwaysOn.batteryPercentPerHourNormal).toBeCloseTo(1.875, 3);
    expect(alwaysOn.batteryPercentPerHourNormal * 8).toBeCloseTo(15, 2);
    // SUPER is the documented 4x — 60% of the battery in 8 h — which is why the
    // role has to be opt-out-able rather than silently assigned.
    expect(alwaysOn.batteryPercentPerHourSuper).toBeCloseTo(7.5, 3);
    expect(alwaysOn.batteryPercentPerHourSuper / alwaysOn.batteryPercentPerHourNormal).toBeCloseTo(
      4,
      3
    );

    // skills/07 duty cycle: NORMAL scans 3 s and sleeps 7 s, SUPER stays
    // continuous. The sleep slot drains at sleepDrainFactor, so the average is
    // 0.3 + 0.7 * 0.25 = 0.475 of the always-on budget — under 8% per 8 h.
    const duty = measure({ dutyCycleEnabled: true });
    expect(duty.batteryPercentPerHourNormal).toBeCloseTo(1.875 * 0.475, 3);
    expect(duty.batteryPercentPerHourNormal * 8).toBeLessThan(8);
    expect(duty.batteryPercentPerHourSuper).toBeCloseTo(7.5, 3); // never sleeps
    expect(duty.scansPerSec).toBeLessThan(alwaysOn.scansPerSec);
  });

  it("excludes charging nodes from the measured drain rate", () => {
    const sim = new MeshSimulation(campusQuad(42));
    sim.runFor(60000);
    for (const n of sim.nodes) n.charging = true;
    sim.refresh();
    expect(sim.stats.batteryPercentPerHourNormal).toBe(0);
  });

  it("buckets latency by hop for first-attempt routed traffic", () => {
    const sim = new MeshSimulation(campusQuad(42));
    driveTraffic(sim, 30);
    const buckets = sim.stats.latencyByHop;
    expect(buckets.length).toBeGreaterThan(0);
    expect(buckets.map((b) => b.hops)).toEqual(
      buckets.map((b) => b.hops).slice().sort((a, b) => a - b)
    );
    for (const b of buckets) {
      expect(b.hops).toBeGreaterThanOrEqual(1);
      expect(b.count).toBeGreaterThan(0);
      expect(b.avgMs).toBeGreaterThan(0);
      expect(b.p95Ms).toBeGreaterThan(0);
    }
    // docs/04 §5 budget, per hop bucket rather than as one blended number.
    const oneHop = buckets.find((b) => b.hops === 1);
    if (oneHop) expect(oneHop.p95Ms).toBeLessThan(2000);
    const threeHop = buckets.filter((b) => b.hops <= 3);
    for (const b of threeHop) expect(b.p95Ms).toBeLessThan(5000);
  });
});

  describe("scale: the documented 10-200 node range (skills/08)", () => {
    /** Drive a handful of messages through a world of `nodeCount` nodes in the
     *  documented 100×100 m area, and report what it cost. */
    function scaleRun(nodeCount: number, messages = 6) {
      const sim = new MeshSimulation({ ...campusQuad(42), nodeCount });
      sim.runFor(sim.config.warmupMs);
      sim.clearRecords();
      let sent = 0;
      for (let i = 0; i < messages; i++) {
        const from = `node-${i % nodeCount}`;
        const to = `node-${(i * 37 + 11) % nodeCount}`;
        if (sim.sendMessage(from, to, `scale-${i}`, "text")) sent++;
        sim.runFor(1500);
      }
      sim.refresh();
      const uni = sim.deliveries.filter((d) => d.type !== "ack" && d.type !== "broadcast");
      return { sim, sent, delivered: uni.length, txPerMsg: sim.stats.totalForwarded / Math.max(1, sent) };
    }

    it("runs at the bottom of the range with nobody cut off", () => {
      const r = scaleRun(10);
      expect(r.sim.nodes).toHaveLength(10);
      expect(r.sim.stats.isolatedNodes).toBe(0);
      expect(r.delivered / r.sent).toBeGreaterThanOrEqual(0.9);
    });

    it("runs at the top of the range, and the fallback does not go quadratic", () => {
      // 200 nodes in a 100×100 m area is one radio cell: every node hears ~179 of
      // the other 199, so a beacon cannot describe the neighbourhood and the MPR
      // coverage question is unanswerable. Unbounded, that turned one 3-hop delivery
      // into 7,038 transmissions and the run into 531 per message. Bounded to six
      // direction-spread peers it is ~125 per message at 98.3% delivery (docs/06 §15).
      const r = scaleRun(200);
      expect(r.sim.nodes).toHaveLength(200);
      expect(r.sim.stats.isolatedNodes).toBe(0);
      expect(r.delivered / r.sent).toBeGreaterThanOrEqual(0.9); // measured 98.3%
      expect(r.txPerMsg).toBeLessThan(400); // measured ~125; the pre-fix figure was 531
      const peers = r.sim.nodes.filter((n) => n.isOnline).map((n) => n.peerIds.length);
      expect(Math.max(...peers)).toBeGreaterThan(30); // the dense branch really was taken
    });

    it("keeps the dense branch out of the worlds that do not need it", () => {
      // campus_quad peaks at 12 peers and festival_crowd at 24, both under the
      // 30-neighbour beacon cap, so the cap on fallback fan-out cannot fire and
      // every measurement taken at those sizes still stands.
      for (const world of [campusQuad(42), festivalCrowd(42)]) {
        const sim = new MeshSimulation(world);
        sim.runFor(90000);
        sim.refresh();
        const max = Math.max(...sim.nodes.filter((n) => n.isOnline).map((n) => n.peerIds.length));
        expect(max).toBeLessThanOrEqual(30);
      }
    });
  });

  describe("group channels (docs/04 §4, roadmap Phase 1 'group (3-10 members)')", () => {
    /** A settled world with one group in it. Members are picked spread across the
     *  world by default, so delivery has to cross hops rather than fall out of a
     *  single radio range. */
    function groupWorld(
      over: Partial<SimConfig> = {},
      size = 5,
      spread = true,
      world = campusQuad(42)
    ) {
      const sim = new MeshSimulation({ ...world, ...over });
      sim.runFor(90000);
      sim.clearRecords();
      const online = sim.nodes.filter((n) => n.isOnline);
      const cx = online.reduce((a, n) => a + n.pos.x, 0) / online.length;
      const cy = online.reduce((a, n) => a + n.pos.y, 0) / online.length;
      const ranked = online
        .slice()
        .sort(
          (a, b) =>
            (b.pos.x - cx) ** 2 + (b.pos.y - cy) ** 2 - ((a.pos.x - cx) ** 2 + (a.pos.y - cy) ** 2)
        );
      const ids = spread
        ? Array.from(
            new Set(
              Array.from({ length: size }, (_, i) =>
                ranked[(i * Math.floor(ranked.length / size)) % ranked.length].id
              )
            )
          )
        : online
            .slice()
            .sort(
              (a, b) =>
                (a.pos.x - ranked[0].pos.x) ** 2 +
                (a.pos.y - ranked[0].pos.y) ** 2 -
                ((b.pos.x - ranked[0].pos.x) ** 2 + (b.pos.y - ranked[0].pos.y) ** 2)
            )
            .slice(0, size)
            .map((n) => n.id);
      const group = sim.createGroup("field team", ids, ids[0])!;
      return { sim, group, ids, sender: sim.nodes.find((n) => n.id === ids[0])! };
    }

    /** Send `n` group messages, letting each one propagate. */
    function send(sim: MeshSimulation, groupId: string, from: string, n = 4, gapMs = 4000) {
      for (let i = 0; i < n; i++) {
        sim.sendMessage(from, groupId, `status ${i}`, "text");
        sim.runFor(gapMs);
      }
      sim.refresh();
    }

    it("enforces the 3-10 member bound, and nothing else can create a group", () => {
      const { sim } = groupWorld({}, 5, false);
      const all = sim.nodes.map((n) => n.id);
      expect(sim.createGroup("too small", all.slice(0, 2))).toBeNull();
      expect(sim.createGroup("too big", all.slice(0, 11))).toBeNull();
      expect(sim.createGroup("just right", all.slice(0, 3))).not.toBeNull();
      expect(sim.createGroup("at the cap", all.slice(0, 10))).not.toBeNull();
      // duplicate ids and ids that do not exist cannot pad out the minimum
      expect(sim.createGroup("padded", ["node-0", "node-0", "node-404"])).toBeNull();
      const g = sim.createGroup("admin", all.slice(0, 4), all[2])!;
      expect(g.adminId).toBe(all[2]);
      expect(g.keyEpoch).toBe(0);
      expect(g.members.size).toBe(4);
    });

    it("reaches every member and nobody else", () => {
      const { sim, group, ids, sender } = groupWorld();
      send(sim, group.id, sender.id);
      for (const n of sim.nodes) {
        const held = n.inbox.filter((m) => m.groupId === group.id);
        if (n.id === sender.id) {
          expect(held).toHaveLength(0); // a sender does not receive its own message
        } else if (ids.includes(n.id)) {
          expect(held.length).toBe(4);
        } else {
          expect(held).toHaveLength(0);
        }
      }
      expect(sim.stats.groupReceipts).toBe(4 * (ids.length - 1));
      expect(sim.stats.groupExpected).toBe(4 * (ids.length - 1));
      expect(sim.stats.groupDeliveryRatio).toBe(1);
    });

    it("relays through non-members, so a spread group still works", () => {
      const { sim, group, ids, sender } = groupWorld({}, 5, true);
      send(sim, group.id, sender.id, 2);
      // at least one member is out of the sender's radio range and got it anyway
      const far = ids.filter((id) => id !== sender.id && !sender.peerIds.includes(id));
      expect(far.length).toBeGreaterThan(0);
      for (const id of far) {
        expect(sim.nodes.find((n) => n.id === id)!.inbox.filter((m) => m.groupId === group.id).length)
          .toBeGreaterThan(0);
      }
      // and a non-member carried the traffic: it transmitted without receiving
      const carriers = sim.nodes.filter(
        (n) => !ids.includes(n.id) && n.txCount > 0 && !n.inbox.some((m) => m.groupId === group.id)
      );
      expect(carriers.length).toBeGreaterThan(0);
    });

    it("keeps group traffic out of the unicast metrics", () => {
      const { sim, group, sender } = groupWorld();
      send(sim, group.id, sender.id);
      expect(sim.stats.sentUnicast).toBe(0);
      expect(sim.stats.sentBroadcast).toBe(0);
      expect(sim.stats.sentGroup).toBe(4);
      expect(sim.stats.deliveryRatio).toBe(0); // not flattered by 4 member receipts
      expect(sim.deliveries.every((d) => d.groupId === group.id)).toBe(true);
    });

    it("never arms a retry timer for a scoped flood", () => {
      // The flood is addressed to nobody, so no ACK can come back. Arming the timer
      // would burn two retransmissions and then push every group message into the
      // OppQueue.
      const { sim, group, sender } = groupWorld();
      send(sim, group.id, sender.id);
      expect(sim.stats.retriesSent).toBe(0);
      expect(sim.stats.retriesExhausted).toBe(0);
      expect(sender.oppQueue).toHaveLength(0);
      expect(sim.nodes.every((n) => n.oppQueue.length === 0)).toBe(true);
    });

    it("rotates the key when a member leaves, and the departed node can relay but not read", () => {
      const { sim, group, ids, sender } = groupWorld({}, 5, true);
      send(sim, group.id, sender.id, 1);
      const leaving = ids.find((id) => id !== sender.id)!;
      const leaver = sim.nodes.find((n) => n.id === leaving)!;
      expect(leaver.inbox.filter((m) => m.groupId === group.id)).toHaveLength(1);
      const epochBefore = group.keyEpoch;
      expect(sim.removeFromGroup(group.id, leaving)).toBe(true);
      expect(group.keyEpoch).toBe(epochBefore + 1); // docs/04 §4: rotated on leave
      expect(group.members.has(leaving)).toBe(false);

      const txBefore = leaver.txCount;
      leaver.inbox.length = 0;
      send(sim, group.id, sender.id, 2);
      // cannot read any of it...
      expect(leaver.inbox.filter((m) => m.groupId === group.id)).toHaveLength(0);
      // ...but the bytes are not secret to the network, so it still carries them
      expect(leaver.txCount).toBeGreaterThan(txBefore);
      // and the remaining members are unaffected
      for (const id of ids.filter((x) => x !== leaving && x !== sender.id)) {
        expect(sim.nodes.find((n) => n.id === id)!.inbox.filter((m) => m.groupId === group.id))
          .toHaveLength(3);
      }
    });

    it("refuses to shrink a group below three", () => {
      const { sim, group, ids } = groupWorld({}, 3, false);
      expect(group.members.size).toBe(3);
      expect(sim.removeFromGroup(group.id, ids[1])).toBe(false);
      expect(group.members.size).toBe(3);
      expect(sim.removeFromGroup(group.id, "node-404")).toBe(false);
    });

    it("rotates on join, so a joiner cannot read the history it missed", () => {
      const { sim, group, ids, sender } = groupWorld({}, 4, true);
      send(sim, group.id, sender.id, 2);
      const outsider = sim.nodes.find((n) => n.isOnline && !ids.includes(n.id))!;
      const epochBefore = group.keyEpoch;
      expect(sim.inviteToGroup(group.id, outsider.id)).toBe(true);
      expect(group.keyEpoch).toBe(epochBefore + 1);
      // the two messages sent before it joined were under the old epoch
      expect(outsider.inbox.filter((m) => m.groupId === group.id)).toHaveLength(0);
      send(sim, group.id, sender.id, 2);
      expect(outsider.inbox.filter((m) => m.groupId === group.id)).toHaveLength(2);
      // joining twice, or past the cap, is refused
      expect(sim.inviteToGroup(group.id, outsider.id)).toBe(false);
      for (const n of sim.nodes.filter((x) => x.isOnline && !group.members.has(x.id))) {
        if (group.members.size >= 10) break;
        sim.inviteToGroup(group.id, n.id);
      }
      expect(group.members.size).toBeLessThanOrEqual(10);
    });

    it("counts a member that cannot decrypt as a rejected epoch, not a delivery", () => {
      const { sim, group, ids, sender } = groupWorld({}, 4, true);
      // A message already in flight under epoch 0 meets a group that rotated to 1.
      const msg = sim.sendMessage(sender.id, group.id, "in flight", "text")!;
      expect(msg.groupEpoch).toBe(0);
      sim.removeFromGroup(group.id, ids[1]);
      expect(group.keyEpoch).toBe(1);
      sim.runFor(6000);
      sim.refresh();
      expect(sim.stats.groupEpochRejected).toBeGreaterThan(0);
      const stale = sim.deliveries.filter((d) => d.groupId === group.id && d.groupEpoch === 0);
      expect(stale.filter((d) => d.to === ids[1])).toHaveLength(0);
    });

    it("lets only the admin rotate the key", () => {
      const { sim, group, ids, sender } = groupWorld({}, 4, false);
      expect(group.adminId).toBe(sender.id);
      const epoch = group.keyEpoch;
      expect(sim.rotateGroupKey(group.id, ids[1])).toBe(false);
      expect(group.keyEpoch).toBe(epoch);
      expect(sim.rotateGroupKey(group.id, sender.id)).toBe(true);
      expect(group.keyEpoch).toBe(epoch + 1);
      expect(sim.rotateGroupKey("grp-404", sender.id)).toBe(false);
    });

    it("offers per-member unicast as the alternative, with ACKs and the same reach", () => {
      // The mode the measurement says is cheaper when members are close together:
      // 4.0 transmissions per message against 519.6 for a scoped flood in the
      // 60-node crowd, because every member is a direct peer (docs/06 §14).
      const { sim, group, ids, sender } = groupWorld(
        { groupMode: "per-member-unicast" },
        5,
        false
      );
      send(sim, group.id, sender.id, 2);
      expect(sim.stats.sentGroup).toBe(2 * (ids.length - 1)); // one message per member
      expect(sim.stats.groupDeliveryRatio).toBe(1);
      expect(sim.stats.acksReceived).toBeGreaterThan(0); // unicast arms the ACK path
      expect(sim.stats.sentUnicast).toBe(0); // and still is not 1:1 traffic
      // ACKs are deliveries too, and they belong to the member message rather than
      // to the group, so they are the one record here without a groupId.
      expect(
        sim.deliveries.filter((d) => d.type !== "ack").every((d) => d.groupId === group.id)
      ).toBe(true);
      expect(sim.deliveries.filter((d) => d.type === "ack").length).toBeGreaterThan(0);
    });

    it("logs membership changes and stale epochs when capture is on", () => {
      const { sim, group, ids, sender } = groupWorld({ captureLog: true }, 4, false);
      sim.sendMessage(sender.id, group.id, "hello", "text");
      sim.runFor(4000);
      sim.inviteToGroup(group.id, sim.nodes.find((n) => n.isOnline && !ids.includes(n.id))!.id);
      sim.removeFromGroup(group.id, ids[2]);
      sim.rotateGroupKey(group.id, group.adminId);
      const entries = sim.log.filter((e) => e.kind === "group");
      const detail = entries.map((e) => e.detail).join(" | ");
      expect(entries.length).toBeGreaterThanOrEqual(4); // create, join, leave, rotate
      expect(detail).toContain("created with 4 members");
      expect(detail).toContain("joined");
      expect(detail).toContain("left");
      expect(detail).toContain("admin rotated");
    });

    it("lists a node's groups, and forgets them when the world is rebuilt", () => {
      const { sim, group, ids } = groupWorld({}, 4, false);
      expect(sim.groupsOf(ids[0]).map((g) => g.id)).toEqual([group.id]);
      expect(sim.groupsOf("node-404")).toEqual([]);
      sim.reset();
      expect(sim.groups.size).toBe(0);
      expect(sim.groupsOf(ids[0])).toEqual([]);
    });

    it("defaults to the mode whose cost does not depend on the route table", () => {
      expect(DEFAULT_CONFIG.groupMode).toBe("scoped-flood");
    });
  });

  describe("SOS mode: repeated flood of GPS + text (docs/05 §SOS, roadmap Phase 3)", () => {
    /** The node furthest from the centroid: an SOS from the edge makes reach a
     *  real test rather than a formality. */
    function edgeSender(sim: MeshSimulation): MeshNode {
      const online = sim.nodes.filter((n) => n.isOnline);
      const cx = online.reduce((a, n) => a + n.pos.x, 0) / online.length;
      const cy = online.reduce((a, n) => a + n.pos.y, 0) / online.length;
      return online.reduce((a, n) =>
        (n.pos.x - cx) ** 2 + (n.pos.y - cy) ** 2 > (a.pos.x - cx) ** 2 + (a.pos.y - cy) ** 2 ? n : a
      );
    }

    /** Every node a chain of radio links can reach from the sender. The honest
     *  denominator for "SOS reaches all": a node nothing can hear is not a
     *  protocol failure. */
    function componentOf(sim: MeshSimulation, sender: MeshNode): Set<string> {
      const seen = new Set<string>([sender.id]);
      const stack = [sender];
      while (stack.length) {
        const n = stack.pop()!;
        for (const p of peersInRange(n, sim.nodes, sim.rf)) {
          if (n.isOnline && p.isOnline && !seen.has(p.id)) {
            seen.add(p.id);
            stack.push(p);
          }
        }
      }
      return seen;
    }

    function sosRun(cfg: Partial<SimConfig> = {}, world = campusQuad(42), windowMs = 45000) {
      const sim = new MeshSimulation({ ...world, ...cfg });
      sim.runFor(90000);
      sim.clearRecords();
      const sender = edgeSender(sim);
      const at = { x: sender.pos.x, y: sender.pos.y };
      const msg = sim.sendMessage(sender.id, "BROADCAST", "injured, need help", "sos")!;
      sim.runFor(windowMs);
      sim.refresh();
      const floods = sender.sentLog.filter((m) => m.sosId === msg.sosId);
      const others = sim.nodes.filter((n) => n.isOnline && n.id !== sender.id);
      const reached = others.filter((n) => n.inbox.some((m) => m.sosId === msg.sosId));
      return { sim, sender, msg, floods, others, reached, at };
    }

    it("takes its TTL from the documented value, not from a longer data TTL", () => {
      // docs/05 §"Broadcast SOS | All transports, flood (TTL=5)". The engine used
      // to hardcode 7 here, which quietly contradicted the spec; reach in a
      // deployment wider than 5 hops is what sosTtl is for, per scenario.
      expect(DEFAULT_CONFIG.sosTtl).toBe(5);
      const sim = new MeshSimulation(campusQuad(42));
      const sos = sim.sendMessage("node-0", "BROADCAST", "help", "sos")!;
      expect(sos.ttl).toBe(5);
      expect(sos.priority).toBe("high");
      const text = sim.sendMessage("node-0", "node-1", "hi", "text")!;
      expect(text.ttl).toBe(5);
      expect(text.priority).toBe("normal");
    });

    it("carries a GPS fix and goes out on the transport that moves it fastest", () => {
      const { msg, sender, at } = sosRun({ sosRepeats: 0 });
      // `at` is the position when the flood went out; the sender keeps moving for
      // the rest of the window, which is the whole point of re-flooding.
      expect(msg.sosPos).toEqual(at);
      expect(msg.sosRepeat).toBe(0);
      expect(msg.sosId).toContain(sender.id);
      // Wi-Fi Direct: the RF budget is transport-independent in this model, so
      // what it buys is 40 ms per hop instead of 120 (docs/02 §3.1).
      expect(msg.transport).toBe("wifiDirect");
    });

    it("re-floods on the interval, every flood with a fresh id", () => {
      const { sim, msg, floods } = sosRun();
      expect(sim.config.sosRepeats).toBe(3);
      expect(floods.length).toBe(4); // 1 + 3 repeats
      expect(sim.stats.sosFloods).toBe(4);
      // A repeat that reused the id would be dropped by every node that already
      // heard it: the seen-cache is keyed on the message id.
      expect(new Set(floods.map((f) => f.id)).size).toBe(4);
      expect(floods.every((f) => f.sosId === msg.sosId)).toBe(true);
      expect(floods.map((f) => f.sosRepeat)).toEqual([0, 1, 2, 3]);
      for (let i = 1; i < floods.length; i++) {
        expect(floods[i].timestamp - floods[i - 1].timestamp).toBe(sim.config.sosRepeatMs);
      }
    });

    it("gives a single-flood arm to measure against", () => {
      const { sim, floods } = sosRun({ sosRepeats: 0 });
      expect(floods.length).toBe(1);
      expect(sim.stats.sosFloods).toBe(1);
    });

    it("reaches every radio-connected node — the roadmap exit criterion", () => {
      const { sim, sender, msg, others, reached } = sosRun();
      const comp = componentOf(sim, sender);
      const inComp = others.filter((n) => comp.has(n.id));
      expect(inComp.length).toBe(others.length); // campus_quad is one component
      const missed = inComp.filter((n) => !n.inbox.some((m) => m.sosId === msg.sosId));
      expect(missed.map((n) => n.id)).toEqual([]);
      expect(reached.length).toBe(others.length);
    });

    it("reaches all of a 60-node crowd, which TTL=5 cannot span", () => {
      // Measured: from an edge sender this world is 6+ hops across, so the spec
      // TTL=5 flood stops short of ~7% of it. The scenario widens the radius and
      // the repeats absorb the loss; together they reach everyone.
      expect(festivalCrowd(42).sosTtl).toBe(7);
      const { sim, sender, msg, others } = sosRun({}, festivalCrowd(42));
      const comp = componentOf(sim, sender);
      const missed = others
        .filter((n) => comp.has(n.id))
        .filter((n) => !n.inbox.some((m) => m.sosId === msg.sosId));
      expect(comp.size).toBe(others.length + 1);
      expect(missed.map((n) => n.id)).toEqual([]);
    });

    it("re-floods with a fresh fix, so a moving sender stays trackable", () => {
      const { floods, sender } = sosRun();
      // Freshness is the reason to repeat beyond loss recovery: flood 3 reports
      // where the sender is *now*, not where it was 15 s ago.
      if (sender.stationary) return; // a sender that does not move has nothing new to say
      const positions = floods.map((f) => `${f.sosPos!.x.toFixed(3)},${f.sosPos!.y.toFixed(3)}`);
      expect(new Set(positions).size).toBeGreaterThan(1);
      expect(floods[floods.length - 1].sosPos).not.toEqual(floods[0].sosPos);
    });

    it("collapses repeats into one alert per receiver, holding the newest fix", () => {
      const { sim, sender, msg, floods, reached } = sosRun();
      expect(reached.length).toBeGreaterThan(0);
      const radioReceipts = sim.deliveries.filter((d) => d.type === "sos").length;
      for (const n of reached) {
        const alerts = n.inbox.filter((m) => m.sosId === msg.sosId);
        // Four floods, one notification: docs/04 keeps the SOS channel opt-in
        // precisely so an emergency cannot spam it.
        expect(alerts.length).toBe(1);
        const newest = floods.find((f) => f.sosRepeat === alerts[0].sosRepeat)!;
        expect(alerts[0].sosPos).toEqual(newest.sosPos);
        expect(alerts[0].timestamp).toBe(newest.timestamp);
      }
      // The radio did the work four times over; the inbox shows it once.
      expect(radioReceipts).toBeGreaterThan(reached.length);
      expect(sender.sentLog.filter((m) => m.sosId === msg.sosId).length).toBe(4);
    });

    it("keeps a late copy from overwriting a newer fix", () => {
      // Copies arrive out of order across four floods, so the alert must only ever
      // move forward in time.
      const node = makeNode("node-x", 0, 0);
      const older = { ...makeSos(1, 1000, { x: 1, y: 1 }), sosId: "sos-a" };
      const newer = { ...makeSos(3, 2000, { x: 9, y: 9 }), sosId: "sos-a" };
      expect(deliverToInbox(node, newer)).toBe(true);
      expect(deliverToInbox(node, older)).toBe(true); // heard, still a receipt
      expect(node.inbox.length).toBe(1);
      expect(node.inbox[0].sosPos).toEqual({ x: 9, y: 9 });
      expect(node.inbox[0].sosRepeat).toBe(3);
    });

    it("floods to every peer whatever the relay policy says", () => {
      // MPR exists to delete duplicate copies; an SOS is made of them. So the
      // suppression path must not apply, at any hop.
      const { sim, msg } = sosRun({ relayPolicy: "mpr" });
      const sosHops = sim.deliveries
        .filter((d) => d.msgId === msg.id || d.type === "sos")
        .flatMap((d) => d.hopTrace);
      expect(sosHops.length).toBeGreaterThan(0);
      expect(sosHops.every((h) => h.action !== "suppressed")).toBe(true);
      const relays = sosHops.filter((h) => h.reason);
      expect(relays.every((h) => (h.reason ?? "").includes("SOS: flood every peer"))).toBe(true);
    });

    it("stops flooding when the sender goes dark", () => {
      const sim = new MeshSimulation({ ...campusQuad(42), sosRepeats: 3 });
      sim.runFor(90000);
      sim.clearRecords();
      const sender = edgeSender(sim);
      sim.sendMessage(sender.id, "BROADCAST", "injured", "sos");
      sim.runFor(1000);
      sim.toggleNodeOnline(sender.id); // battery dead, or the user switched it off
      sim.runFor(30000);
      sim.refresh();
      expect(sim.stats.sosFloods).toBe(1);
    });

    it("logs every flood when capture is on", () => {
      const { sim, msg } = sosRun({ captureLog: true });
      const sosEntries = sim.log.filter((e) => e.kind === "sos");
      expect(sosEntries.length).toBe(4);
      expect(sosEntries[0].detail).toContain("flood 1/4");
      expect(sosEntries[3].detail).toContain("flood 4/4");
      expect(sosEntries.every((e) => e.msgId)).toBe(true);
      expect(sim.log.filter((e) => e.msgId === msg.id).length).toBeGreaterThan(1);
    });

    it("buys reach with radio time, and the cost is visible", () => {
      const one = sosRun({ sosRepeats: 0 });
      const four = sosRun({ sosRepeats: 3 });
      // Measured on campus_quad seed 42: 178 → 691 data transmissions. Four floods
      // of a fan-out is not free, which is why the repeat count is a knob.
      expect(four.sim.stats.totalForwarded).toBeGreaterThan(one.sim.stats.totalForwarded * 3);
      expect(four.sim.stats.totalForwarded).toBeLessThan(one.sim.stats.totalForwarded * 5);
    });

    it("leaves the unicast metrics baseline alone", () => {
      // An SOS is a broadcast: it must not move deliveryRatio, which the
      // acceptance criteria measure on unicast traffic.
      const { sim } = sosRun();
      expect(sim.stats.sentUnicast).toBe(0);
      expect(sim.stats.sentBroadcast).toBe(4);
      expect(sim.stats.deliveryRatio).toBe(0);
    });
  });
});

describe("media transport (docs/05 §3.2-3.3, roadmap Phase 3)", () => {
  /**
   * A line of nodes 20 m apart: within the 31.6 m LOS budget for a neighbour and
   * outside it for the next one along (at 40 m the model gives −87 dBm against a
   * −85 dBm sensitivity), so hop count is exactly the distance in indices and every
   * assertion below is about the media plane rather than about who happened to be in
   * range.
   */
  function lineWorld(n = 4, over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: n,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      // DEFAULT_CONFIG carries walls, and a wall between two nodes 20 m apart turns
      // the "line" into a partition. The geometry has to be the only variable here.
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
      node.txPower = DEFAULT_CONFIG.txPowerDbm;
    });
    sim.runFor(20000); // beacons settle, routes form
    sim.clearRecords();
    return sim;
  }

  function runUntil(sim: MeshSimulation, done: () => boolean, budgetMs: number): boolean {
    let elapsed = 0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(100);
      elapsed += 100;
    }
    return done();
  }

  it("charges air time only for the part of a payload above one packet", () => {
    const sim = lineWorld(2);
    // A text message, an OGM and an ACK all sit under the 1024 B ceiling, so the
    // hop latency they were calibrated with is untouched — that is what keeps the
    // golden vectors byte-identical.
    expect(sim.serializationMs(0, "ble")).toBe(0);
    expect(sim.serializationMs(1024, "ble")).toBe(0);
    expect(sim.serializationMs(1024, "wifiDirect")).toBe(0);
    // 64 KB slice: (65536 − 1024) × 8 bits over the link rate.
    expect(sim.serializationMs(65536, "wifiDirect")).toBeCloseTo(((65536 - 1024) * 8) / 20000, 6);
    expect(sim.serializationMs(65536, "ble")).toBeCloseTo(((65536 - 1024) * 8) / 80, 6);
    // docs/05 §3.2's "250× faster than BLE" is what the two rates reproduce.
    const ratio = sim.serializationMs(65536, "ble") / sim.serializationMs(65536, "wifiDirect");
    expect(ratio).toBeCloseTo(250, 6);
    expect(sim.config.wifiDirectKbps / sim.config.bleKbps).toBe(250);
  });

  it("sends a file as 64 KB chunks and completes the transfer", () => {
    const sim = lineWorld(3);
    const [a, , c] = sim.nodes;
    const t = sim.sendFile(a.id, c.id, 256 * 1024);
    expect(t).not.toBeNull();
    expect(t!.chunks).toBe(4); // 256 KB / 64 KB
    expect(t!.kind).toBe("file");
    expect(runUntil(sim, () => t!.state === "complete", 120000)).toBe(true);
    expect(t!.received).toBe(4);
    expect(t!.completedAt).not.toBeNull();
    expect(c.inbox.filter((m) => m.type === "file")).toHaveLength(4);

    const stats = sim.refresh();
    expect(stats.transfersStarted).toBe(1);
    expect(stats.transfersCompleted).toBe(1);
    expect(stats.bytesDelivered).toBe(256 * 1024);
    expect(stats.sentChunks).toBeGreaterThanOrEqual(4);
    // Two hops apart, so the chunks rode the radio that can actually carry them.
    expect(t!.transport).toBe("wifiDirect");
  });

  it("keeps media out of the 1:1 delivery metrics", () => {
    const sim = lineWorld(3);
    const [a, , c] = sim.nodes;
    const t = sim.sendFile(a.id, c.id, 256 * 1024)!;
    runUntil(sim, () => t.state === "complete", 120000);
    const stats = sim.refresh();
    // A 10 MB file is 160 chunks: folded into deliveryRatio it would make the
    // metric about the file instead of about the mesh.
    expect(stats.sentUnicast).toBe(0);
    expect(stats.sentChunks).toBeGreaterThanOrEqual(4);
    // The only records in the run are the chunks and their ACKs.
    expect(sim.sentRecords.filter((r) => !r.transferId)).toHaveLength(0);
    expect(
      sim.deliveries.filter((d) => d.type !== "ack").every((d) => d.transferId !== undefined)
    ).toBe(true);
  });

  it("slides a window instead of putting the whole file on air at once", () => {
    const sim = lineWorld(4, { transferWindow: 2 });
    const [a, , , d] = sim.nodes;
    const t = sim.sendFile(a.id, d.id, 8 * 64 * 1024)!;
    expect(t.chunks).toBe(8);
    expect(t.window).toBe(2);
    // Nothing has arrived yet, so only the window is in flight.
    expect(sim.refresh().sentChunks).toBe(2);
    expect(runUntil(sim, () => t.state === "complete", 300000)).toBe(true);
    expect(t.received).toBe(8);
    // A deeper window is measurably faster: this is the lever docs/08 §4 reports.
    const wide = lineWorld(4, { transferWindow: 8 });
    const t2 = wide.sendFile(wide.nodes[0].id, wide.nodes[3].id, 8 * 64 * 1024)!;
    expect(runUntil(wide, () => t2.state === "complete", 300000)).toBe(true);
    expect(t2.completedAt! - t2.startedAt).toBeLessThan(t.completedAt! - t.startedAt);
  });

  it("slices to the BLE ceiling when there is no Wi-Fi Direct capacity", () => {
    const sim = lineWorld(2, { transferChunkBytes: 1024 });
    const [a, b] = sim.nodes;
    const t = sim.sendFile(a.id, b.id, 64 * 1024)!;
    expect(t.chunks).toBe(64);
    expect(t.transport).toBe("ble");
    expect(runUntil(sim, () => t.state === "complete", 300000)).toBe(true);
    expect(t.received).toBe(64);
  });

  it("keeps a 500 ms Opus frame inside one BLE packet at 12 kbps, and not at 24", () => {
    // frameBytes = frameMs × kbps / 8. Under the 1024 B ceiling the frame rides BLE,
    // which is the radio that is guaranteed to be up; over it, the note would
    // silently need Wi-Fi Direct. That is why docs/05 §3.3 says 6-12 kbps.
    const ble = lineWorld(2, { voiceKbps: 12 });
    const note = ble.sendVoice(ble.nodes[0].id, ble.nodes[1].id, 1)!;
    expect(note.chunkBytes).toBe(750);
    expect(note.transport).toBe("ble");

    const wifi = lineWorld(2, { voiceKbps: 24 });
    const loud = wifi.sendVoice(wifi.nodes[0].id, wifi.nodes[1].id, 1)!;
    expect(loud.chunkBytes).toBe(1500);
    expect(loud.transport).toBe("wifiDirect");
    expect((1024 * 8) / wifi.config.voiceFrameMs).toBeCloseTo(16.384, 3);
  });

  it("streams a note while it is being recorded, so audio starts before release", () => {
    const sim = lineWorld(2);
    const [a, b] = sim.nodes;
    const t = sim.sendVoice(a.id, b.id, 3)!;
    expect(t.chunks).toBe(6); // 3 s / 500 ms
    expect(t.releasedAt).toBeCloseTo(t.startedAt + 3000, 6);
    expect(runUntil(sim, () => t.state === "complete", 30000)).toBe(true);
    // The first frame is playable long before the button is let go — that is the
    // whole point of streaming, and the blob's disadvantage.
    expect(t.firstChunkAt!).toBeLessThan(t.releasedAt!);
    expect(t.firstChunkAt! - t.startedAt).toBeLessThan(1500);

    const blobSim = lineWorld(2);
    const blob = blobSim.sendVoice(blobSim.nodes[0].id, blobSim.nodes[1].id, 3, { stream: false })!;
    expect(blob.chunks).toBe(1);
    expect(blob.totalBytes).toBe(6 * 750);
    expect(runUntil(blobSim, () => blob.state === "complete", 30000)).toBe(true);
    expect(blob.firstChunkAt!).toBeGreaterThanOrEqual(blob.releasedAt!);
  });

  it("meets the roadmap's push-to-talk budget at 1 and 3 hops", () => {
    // "PTT Opus note plays in <3s 1-hop / <8s 3-hop", measured from release to the
    // last frame arriving plus the 200 ms jitter buffer.
    const sim = lineWorld(4);
    const near = sim.sendVoice(sim.nodes[0].id, sim.nodes[1].id, 3)!;
    expect(runUntil(sim, () => near.state === "complete", 30000)).toBe(true);
    const nearDelay = near.completedAt! + sim.config.jitterBufferMs - near.releasedAt!;
    expect(nearDelay).toBeGreaterThan(0);
    expect(nearDelay).toBeLessThan(3000);

    const far = sim.sendVoice(sim.nodes[0].id, sim.nodes[3].id, 3)!;
    expect(runUntil(sim, () => far.state === "complete", 30000)).toBe(true);
    const farDelay = far.completedAt! + sim.config.jitterBufferMs - far.releasedAt!;
    expect(farDelay).toBeLessThan(8000);
    expect(farDelay).toBeGreaterThan(nearDelay);
  });

  it("carries a 10 MB image three hops on Wi-Fi Direct inside a minute", () => {
    // The roadmap's exit criterion: "2 phones exchange image <10 MB over WiFi Direct
    // mesh". Three hops is the distance the criterion's latency budget is written for.
    const sim = lineWorld(4);
    const t = sim.sendFile(sim.nodes[0].id, sim.nodes[3].id, 10 * 1024 * 1024)!;
    expect(t.chunks).toBe(160);
    expect(runUntil(sim, () => t.state === "complete", 180000)).toBe(true);
    expect(t.transport).toBe("wifiDirect");
    expect(t.received).toBe(160);
    const elapsed = t.completedAt! - t.startedAt;
    expect(elapsed).toBeLessThan(60000);
    expect(sim.refresh().bytesDelivered).toBe(10 * 1024 * 1024);
  });

  it("cannot carry a 10 MB image over BLE in any reasonable time", () => {
    // Which is what docs/05 §3.2's "auto-reject files >5 MB on BLE-only with a
    // 'move closer to SUPER' hint" is protecting the user from.
    const sim = lineWorld(2, { transferChunkBytes: 1024 });
    const t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1024 * 1024)!;
    expect(t.chunks).toBe(10240);
    expect(t.transport).toBe("ble");
    sim.runFor(60000);
    expect(t.state).toBe("active");
    expect(t.received / t.chunks).toBeLessThan(0.2);
  });

  it("re-sends the chunks a stalled window is missing, and resumes when the peer returns", () => {
    const sim = lineWorld(3);
    const [a, , c] = sim.nodes;
    const t = sim.sendFile(a.id, c.id, 8 * 64 * 1024, { window: 2 })!;
    // The receiver walks away: the window stops moving. Without a watchdog the
    // transfer would hang forever, because a chunk whose retries ran out sits in the
    // OppQueue and its logical id is never seen again.
    sim.toggleNodeOnline(c.id);
    expect(runUntil(sim, () => t.stalls > 0, 60000)).toBe(true);
    expect(sim.refresh().transferStalls).toBeGreaterThan(0);
    expect(t.state).toBe("active");

    // "Resume on reconnect" (docs/05 §3.2): the peer comes back and the missing
    // chunks are re-sent, so the transfer finishes rather than being abandoned.
    sim.toggleNodeOnline(c.id);
    expect(runUntil(sim, () => t.state === "complete", 300000)).toBe(true);
    expect(t.received).toBe(8);
  });

  it("retries a chunk on the media timer, not the text plane's", () => {
    const sim = lineWorld(2);
    const t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 64 * 1024)!;
    // Cold start, before any ACK has measured the path.
    expect(sim.mediaTimeoutMs(t)).toBe(sim.config.mediaAckTimeoutMs);
    expect(sim.config.mediaAckTimeoutMs).toBeLessThan(sim.config.ackTimeoutMs);
    expect(runUntil(sim, () => t.state === "complete", 60000)).toBe(true);

    // With the adaptive rule on, the timer is built from the round trips this
    // transfer's own ACKs reported: 2 × minRtt + 200, clamped to [300, ackTimeoutMs].
    const adaptive = lineWorld(4, { adaptiveMediaAck: true });
    const t2 = adaptive.sendFile(adaptive.nodes[0].id, adaptive.nodes[3].id, 4 * 64 * 1024)!;
    expect(runUntil(adaptive, () => t2.state === "complete", 120000)).toBe(true);
    expect(t2.minRttMs).not.toBeNull();
    expect(sim.mediaTimeoutMs(t2)).toBe(
      Math.min(
        adaptive.config.ackTimeoutMs,
        Math.max(300, 2 * t2.minRttMs! + 200)
      )
    );
    expect(t2.srttMs).not.toBeNull();
  });

  it("refuses media from a node that is offline or to nobody", () => {
    const sim = lineWorld(3);
    sim.toggleNodeOnline(sim.nodes[0].id);
    expect(sim.sendFile(sim.nodes[0].id, sim.nodes[2].id, 64 * 1024)).toBeNull();
    expect(sim.sendVoice(sim.nodes[0].id, sim.nodes[2].id, 3)).toBeNull();
    expect(sim.sendFile(sim.nodes[1].id, sim.nodes[2].id, 0)).toBeNull();
    expect(sim.sendVoice(sim.nodes[1].id, sim.nodes[2].id, 0)).toBeNull();
    expect(sim.refresh().transfersStarted).toBe(0);
  });
});

describe("media against skills/05 (Voice PTT & Media)", () => {
  /** The same 20 m line the media block uses: hop count is the index distance. */
  function line(n = 4, over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: n,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  function runUntil(sim: MeshSimulation, done: () => boolean, budgetMs: number): boolean {
    let elapsed = 0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(100);
      elapsed += 100;
    }
    return done();
  }

  it("sends voice chunks as VOICE_CHUNK: type voice, priority high, ttl 3", () => {
    const sim = line(3, { captureLog: true });
    const t = sim.sendVoice(sim.nodes[0].id, sim.nodes[2].id, 1)!;
    runUntil(sim, () => t.state === "complete", 60000);
    const frames = sim.nodes[2].inbox.filter((m) => m.transferId === t.id);
    expect(frames).toHaveLength(2);
    for (const f of frames) {
      expect(f.type).toBe("voice");
      expect(f.priority).toBe("high");
      // skills/05: "VOICE_CHUNK packets prio=high, ttl=3". A frame that needs four
      // hops is stale on arrival, so it is not worth the radio time.
      expect(f.ttl).toBeLessThanOrEqual(3);
      expect(f.sizeBytes).toBe(750);
      expect(f.transport).toBe("ble");
    }
    // A file chunk is not a voice chunk: it keeps the data plane's ttl.
    const file = sim.sendFile(sim.nodes[0].id, sim.nodes[2].id, 128 * 1024)!;
    runUntil(sim, () => file.state === "complete", 60000);
    const slices = sim.nodes[2].inbox.filter((m) => m.transferId === file.id);
    expect(slices.every((m) => m.type === "file")).toBe(true);
    expect(slices[0].ttl).toBeLessThanOrEqual(5);
  });

  it("rides Wi-Fi Direct for a voice note when the group owner is already connected", () => {
    // skills/05: "Send: VOICE_CHUNK packets ... via best transport (WiFi Direct if GO
    // connected, else chunked BLE 512B MTU)". The transport is a property of what has
    // been negotiated, not only of the payload size.
    const sim = line(2);
    const t = sim.sendVoice(sim.nodes[0].id, sim.nodes[1].id, 1, { transport: "wifiDirect" })!;
    expect(t.forcedTransport).toBe("wifiDirect");
    expect(runUntil(sim, () => t.state === "complete", 60000)).toBe(true);
    expect(t.transport).toBe("wifiDirect");
    const delay = t.completedAt! + sim.config.jitterBufferMs - t.releasedAt!;
    // skills/05 acceptance: "1-hop WiFi: PTT round-trip <1s".
    expect(delay).toBeLessThan(1000);
    // Its modes table puts streaming PTT at 150-300 ms on one Wi-Fi Direct hop; the
    // model's floor is the 40 ms hop plus 50-200 ms of jitter.
    expect(delay - sim.config.jitterBufferMs).toBeLessThan(300);
  });

  it("refuses a transfer over the 10 MB ceiling", () => {
    const sim = line(2, { captureLog: true });
    expect(sim.config.maxTransferBytes).toBe(10 * 1048576);
    expect(sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1048576)).not.toBeNull();
    expect(sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1048576 + 1)).toBeNull();
    expect(sim.log.some((l) => l.kind === "transfer" && l.detail.includes("ceiling"))).toBe(true);
  });

  it("resumes a 10 MB Wi-Fi Direct image after a mid-transfer disconnect", () => {
    // skills/05 acceptance, verbatim: "10 MB image: delivered over WiFi Direct with
    // resume after mid-transfer disconnect". Three hops, receiver gone for 20 s at
    // about a third of the way in.
    const sim = line(4, { captureLog: true });
    const t = sim.sendFile(sim.nodes[0].id, sim.nodes[3].id, 10 * 1048576, {
      transport: "wifiDirect",
    })!;
    expect(t.chunks).toBe(160);
    expect(runUntil(sim, () => t.received >= Math.floor(t.chunks * 0.3), 120000)).toBe(true);
    const atDisconnect = t.received;

    sim.toggleNodeOnline(sim.nodes[3].id);
    sim.runFor(20000);
    expect(t.state).toBe("active");
    expect(t.received).toBe(atDisconnect); // nothing arrives while it is away
    expect(t.stalls).toBeGreaterThan(0); // ... and the watchdog notices

    sim.toggleNodeOnline(sim.nodes[3].id);
    expect(runUntil(sim, () => t.state === "complete", 600000)).toBe(true);
    expect(t.received).toBe(160);
    expect(t.transport).toBe("wifiDirect");
    expect(sim.refresh().bytesDelivered).toBeGreaterThanOrEqual(10 * 1048576);
  });

  it("slices to the 512 B BLE MTU when there is no Wi-Fi Direct capacity", () => {
    // skills/05: "else chunked BLE 512B MTU". Half the packet ceiling, so a slice
    // stays on BLE with room for its header, and a 10 MB image becomes 20480 of them
    // — which is what docs/05's auto-reject rule is for (docs/08 §8).
    const sim = line(2);
    const t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1048576, {
      chunkBytes: 512,
    })!;
    expect(t.chunks).toBe(20480);
    expect(t.transport).toBe("ble");
    sim.runFor(60000);
    expect(t.state).toBe("active");
    expect(t.received / t.chunks).toBeLessThan(0.1);
  });
});

describe("group history anti-entropy (roadmap Phase 1: hash beacon)", () => {
  /**
   * A line of members 20 m apart, all in one group, so every member can hear every
   * neighbour and a beacon reaches the peer it is addressed to in one hop.
   */
  function lineGroup(n = 3, over: Partial<SimConfig> = {}) {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: n,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      captureLog: true,
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    const ids = sim.nodes.map((node) => node.id);
    const group = sim.createGroup("field team", ids, ids[0])!;
    sim.runFor(2000);
    sim.clearRecords();
    return { sim, group, ids };
  }

  function runUntil(sim: MeshSimulation, done: () => boolean, budgetMs: number): boolean {
    let elapsed = 0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(250);
      elapsed += 250;
    }
    return done();
  }

  const entry = (msgId: string): HistoryEntry => ({
    msgId,
    groupId: "grp-1",
    from: "node-0",
    at: 0,
    body: msgId,
    epoch: 0,
  });

  it("repairs a flood a member missed while it was offline", () => {
    const { sim, group, ids } = lineGroup();
    sim.toggleNodeOnline(ids[2]);
    sim.sendMessage(ids[0], group.id, "meet at the north gate");
    sim.runFor(4000);
    expect(sim.groupHistoryOf(ids[1], group.id).map((e) => e.body)).toContain(
      "meet at the north gate"
    );
    expect(sim.groupHistoryOf(ids[2], group.id)).toHaveLength(0); // it was away
    expect(sim.historyConverged(group)).toBe(false);

    sim.toggleNodeOnline(ids[2]);
    sim.runFor(30000); // three beacon intervals

    const recovered = sim.groupHistoryOf(ids[2], group.id);
    expect(recovered.map((e) => e.body)).toContain("meet at the north gate");
    expect(recovered[0].synced).toBe(true);
    expect(recovered[0].from).toBe(ids[0]);
    expect(sim.refresh().historyEntriesSynced).toBe(1);
    expect(sim.historyConverged(group)).toBe(true);
    // The exchange is visible in the capture log as control traffic, not as chat.
    expect(sim.log.some((l) => l.kind === "sync" && l.detail.includes("recovered 1 message"))).toBe(
      true
    );
  });

  it("digests a set, not a sequence: the union properties the merge relies on", () => {
    // Cross-language fixed points — the Dart engine asserts the same numbers.
    expect(fnv1a32("m1")).toBe(2486071275);
    expect(fnv1a32("m2")).toBe(2502848894);
    expect(fnv1a32("msg-0001")).toBe(3384865146);
    expect(historyBucket("m1")).toBe(11);
    expect(historyBucket("m2")).toBe(14);
    expect(historyBucket("msg-0001")).toBe(10);

    const three = [entry("m1"), entry("m2"), entry("msg-0001")];
    const digest = historyDigest(three);
    expect(digest.count).toBe(3);
    expect(digest.buckets).toHaveLength(HISTORY_BUCKETS);
    // Commutative: XOR over a set does not depend on arrival order.
    expect(historyDigest([...three].reverse()).buckets).toEqual(digest.buckets);
    // Associative: merging in two steps gives the same buckets as one.
    const staged = historyDigest([entry("m1")]);
    const rest = historyDigest([entry("m2"), entry("msg-0001")]);
    expect(staged.buckets.map((b, i) => (b ^ rest.buckets[i]) >>> 0)).toEqual(digest.buckets);
    // XOR folds a *set*: the same id twice cancels itself out. That is not a defect
    // to fix but the reason the store is keyed by message id and the merge is a union
    // — `putHistory` reports false the second time, so a digest can never be fed a
    // multiset. Idempotence is asserted at the store level in the repair test above.
    const twice = historyDigest([...three, entry("m1")]);
    expect(twice.buckets[historyBucket("m1")]).toBe(0); // cancelled
    expect(twice.count).toBe(4); // the count is not a set, so it still disagrees
  });

  it("keeps a beacon inside one BLE packet whatever the history holds", () => {
    const empty = encodeHistoryBeacon("grp-1", 0, historyDigest([]));
    const full = encodeHistoryBeacon(
      "grp-1",
      0,
      historyDigest(Array.from({ length: 400 }, (_, i) => entry(`msg-${i}`)))
    );
    expect(empty.length).toBe(156);
    // The only thing that grows with the history is the decimal entry count: 16
    // bucket digests, not 400 ids.
    expect(full.length).toBe(158);
    expect(wireSizeOf(empty.length)).toBe(256);
    expect(wireSizeOf(full.length)).toBe(256);
    expect(selectTransport(wireSizeOf(full.length))).toBe("ble");
  });

  it("repairs a long absence in bounded rounds rather than one huge reply", () => {
    const { sim, group, ids } = lineGroup(3, { historyReplyMax: 8 });
    sim.toggleNodeOnline(ids[2]);
    for (let i = 0; i < 20; i++) {
      sim.sendMessage(ids[0], group.id, `status ${i}`);
      sim.runFor(200);
    }
    sim.runFor(2000);

    sim.toggleNodeOnline(ids[2]);
    sim.runFor(12000); // one round
    const afterOne = sim.groupHistoryOf(ids[2], group.id).length;
    expect(afterOne).toBeGreaterThan(0);
    expect(afterOne).toBeLessThan(20); // the reply is capped at 8 entries

    // Rounds are 10 s apart, a round can be lost to link loss, and a copy one member
    // lost has to reach it from another member first — repair is transitive, so it is
    // given time rather than a fixed number of rounds. The sender always holds its own
    // entries, so a converged group necessarily holds all 20.
    expect(runUntil(sim, () => sim.historyConverged(group), 200000)).toBe(true);
    expect(sim.groupHistoryOf(ids[2], group.id)).toHaveLength(20);
    expect(sim.groupHistoryOf(ids[1], group.id)).toHaveLength(20);
    expect(sim.refresh().historyReplies).toBeGreaterThanOrEqual(3);
    expect(
      sim.log.some((l) => l.kind === "sync" && l.detail.includes("missing entries"))
    ).toBe(true);
  });

  it("cannot repair history a key rotation made unreadable", () => {
    const { sim, group, ids } = lineGroup();
    sim.toggleNodeOnline(ids[2]);
    sim.sendMessage(ids[0], group.id, "before the rotation");
    sim.runFor(3000);
    expect(sim.groupHistoryOf(ids[1], group.id)).toHaveLength(1);

    // docs/06 §14: a rotation makes every older copy unreadable network-wide, so
    // there is nothing worth repairing — and the engine does not offer it.
    expect(sim.rotateGroupKey(group.id, group.adminId)).toBe(true);
    expect(sim.syncableHistory(sim.nodes[1], group).size).toBe(0);

    sim.sendMessage(ids[0], group.id, "after the rotation");
    sim.runFor(3000);
    sim.toggleNodeOnline(ids[2]);
    sim.runFor(40000);

    const recovered = sim.groupHistoryOf(ids[2], group.id).map((e) => e.body);
    expect(recovered).toContain("after the rotation");
    expect(recovered).not.toContain("before the rotation");
    // Nothing stale was even put on air, so nothing had to be dropped on arrival.
    expect(sim.refresh().historyEpochDropped).toBe(0);
    expect(sim.historyConverged(group)).toBe(true);
  });

  it("costs control traffic only: no ACKs, no deliveries, no unicast count", () => {
    const { sim } = lineGroup(4);
    sim.runFor(60000); // six beacon intervals, and not one group message
    const stats = sim.refresh();
    expect(stats.sentUnicast).toBe(0);
    expect(stats.sentGroup).toBe(0);
    expect(stats.sentSync).toBeGreaterThan(0);
    expect(stats.historyBeacons).toBeGreaterThan(0);
    expect(stats.acksReceived).toBe(0); // periodic, so a lost beacon is not retried
    expect(stats.deliveryRatio).toBe(0);
    expect(sim.deliveries.filter((d) => d.type !== "sync")).toHaveLength(0);
    // Beacons go to co-members the node can hear, not across the mesh.
    expect(stats.historyBytes).toBeGreaterThan(0);
    expect(
      sim.sentRecords.filter((r) => r.type === "sync").every((r) => r.body.startsWith("HB|"))
    ).toBe(true);
  });

  it("stops beaconing when a node leaves its last group, and can be switched off", () => {
    const { sim, group, ids } = lineGroup(4);
    sim.runFor(12000);
    const before = sim.refresh().historyBeacons;
    expect(before).toBeGreaterThan(0);
    expect(sim.removeFromGroup(group.id, ids[3])).toBe(true); // 4 -> 3 members
    sim.runFor(40000);
    const after = sim.refresh().historyBeacons;
    // The departed node contributes no more beacons; the three remaining members do.
    expect(
      sim.sentRecords.filter((r) => r.type === "sync" && r.from === ids[3] && r.timestamp > sim.now - 40000)
    ).toHaveLength(0);
    expect(after).toBeGreaterThan(before);

    const off = lineGroup(3, { historyBeaconMs: 0 });
    off.sim.sendMessage(off.ids[0], off.group.id, "no repair here");
    off.sim.toggleNodeOnline(off.ids[2]);
    off.sim.runFor(60000);
    expect(off.sim.refresh().historyBeacons).toBe(0);
    expect(off.sim.groupHistoryOf(off.ids[2], off.group.id)).toHaveLength(0);
    expect(off.sim.historyConverged(off.group)).toBe(false);
  });
});

describe("the atrium becomes a router (roadmap Phase 2 field test, docs/09 §5)", () => {
  /**
   * The roadmap's field-test criterion names a building feature — "atrium should become
   * SUPER" — and the simulator can answer it before anybody travels: the node with the
   * most open position hears the most peers through the fewest walls, which is exactly
   * what the coverage score's first two terms reward (docs/03 §3, weights 0.30 peer
   * count and 0.25 average RSSI).
   *
   * The most open point in each world is found rather than assumed: the position, out of
   * every node's own, that reaches the most peers with the least wall attenuation.
   */
  function mostOpenNode(sim: MeshSimulation): MeshNode {
    const online = sim.nodes.filter((n) => n.isOnline);
    let best = online[0];
    let bestScore = -1;
    for (const n of online) {
      const peers = peersInRange(n, online, sim.rf);
      let rssiSum = 0;
      for (const p of peers) rssiSum += rssiModel(n, p, sim.rf);
      const avg = peers.length > 0 ? rssiSum / peers.length : -120;
      const score = peers.length * 100 + avg;
      if (score > bestScore) {
        bestScore = score;
        best = n;
      }
    }
    return best;
  }

  /**
   * Openness is only 55% of the coverage score — 0.30 on peer count and 0.25 on average
   * RSSI (docs/03 §3) — so the roadmap's "atrium should become SUPER" is a statement
   * about a *healthy* phone in the atrium. This is the trade-off, measured directly
   * against `computeScore` rather than through a world, so the numbers are not confounded
   * by whoever else happened to spawn nearby.
   */
  it("weighs openness against health, and says where the crossover is", () => {
    const rf = rfWith();
    expect(WEIGHTS.peers + WEIGHTS.rssi).toBeCloseTo(0.55, 9);
    expect(
      WEIGHTS.peers + WEIGHTS.rssi + WEIGHTS.battery + WEIGHTS.stability + WEIGHTS.pdr
    ).toBeCloseTo(1, 9);
    expect(CHARGING_BONUS).toBe(0.1);
    expect(BATTERY_FLOOR).toBe(0.25);

    /** A candidate with `peerCount` peers 12 m away in every direction. */
    function score(peerCount: number, over: Partial<MeshNode>): number {
      const node = makeNode("candidate", 50, 50, over);
      const all = [node];
      for (let i = 0; i < peerCount; i++) {
        const a = (i / Math.max(1, peerCount)) * 2 * Math.PI;
        all.push(makeNode(`p${i}`, 50 + Math.cos(a) * 12, 50 + Math.sin(a) * 12));
      }
      return computeScore(node, all, rf);
    }

    // The atrium phone at the end of a long day, against a corridor phone that has been
    // sitting on a desk all week.
    const openButDrained = score(19, { battery: 0.3, uptimeMin: 20, pdr: 0.9 });
    const closedButHealthy = score(9, { battery: 1, uptimeMin: 600, pdr: 0.99 });
    expect(closedButHealthy).toBeGreaterThan(openButDrained);

    // How many peers the drained phone needs to overtake it: the price of a bad day.
    // The answer is "more than any world in this repository has nodes", because the
    // peer term is normalised logarithmically against 50 peers (docs/03 §3) and so
    // saturates: at 199 peers — the largest world §15 of docs/06 measures — it still
    // loses to a healthy phone with nine.
    expect(score(199, { battery: 0.3, uptimeMin: 20, pdr: 0.9 })).toBeLessThan(closedButHealthy);
    expect(score(60, { battery: 0.3, uptimeMin: 20, pdr: 0.9 })).toBeLessThan(closedButHealthy);
    // Health has more range than position: the two position terms can contribute at most
    // 0.30 x log(1+P)/log(51) + 0.25, while battery, stability and pdr contribute up to
    // 0.45 between them.
    expect(WEIGHTS.battery + WEIGHTS.stability + WEIGHTS.pdr).toBeCloseTo(0.45, 9);
    // Which is the right way round for a mesh that has to survive a day without chargers,
    // and the reason the field test has to record battery and uptime next to placement.
    // Plugging in changes the answer without changing the position: the 0.1 charging
    // bonus is worth roughly what a doubling of peer count is not.
    expect(score(9, { battery: 0.3, uptimeMin: 20, pdr: 0.9, charging: true })).toBeGreaterThan(
      score(9, { battery: 0.4, uptimeMin: 20, pdr: 0.9, charging: false })
    );
  });

  for (const name of scenarioNames()) {
    it(`elects a healthy open node in ${name} within two cycles`, () => {
      const sim = new MeshSimulation({ ...buildScenario(name, 42), enableMobility: false });
      sim.runFor(20000); // let the peer lists settle before judging who is open
      const atrium = mostOpenNode(sim);
      const peers = peersInRange(atrium, sim.nodes.filter((n) => n.isOnline), sim.rf).length;
      expect(peers).toBeGreaterThan(0);

      // Healthy as well as open: full battery, ten hours of uptime, a stationary phone
      // that has not been dropping packets. The second test below shows why both halves
      // of that are needed.
      atrium.battery = 1;
      atrium.uptimeMin = 600;
      atrium.pdr = 0.99;
      atrium.mobility = 0;

      // Two election cycles at the 30 s interval: the criterion is not "eventually" but
      // "before the walk is over".
      sim.runFor(60000);
      expect(atrium.role).toBe("SUPER");

      // And it is not luck: its score is at or above the mean of the elected set.
      const supers = sim.nodes.filter((n) => n.role === "SUPER");
      const meanScore = supers.reduce((a, n) => a + n.score, 0) / supers.length;
      expect(atrium.score).toBeGreaterThanOrEqual(meanScore - 1e-9);
    });
  }
});

describe("community relays (roadmap Phase 5: a plugged tablet in a café)", () => {
  const MESSAGES = 100;
  const GAP_MS = 1000;

  /** Identical traffic for both arms: drawing pairs from the simulation's own RNG would
   *  make the A/B two different experiments, because the relay policy changes event
   *  interleaving (the confound `acceptance.test.ts` was written around). */
  function plan(seed: number, nodeCount: number): Array<[number, number]> {
    const rng = createRng((seed ^ 0x5bf03635) >>> 0);
    const out: Array<[number, number]> = [];
    for (let i = 0; i < MESSAGES; i++) {
      const from = Math.floor(rng() * nodeCount);
      let to = Math.floor(rng() * nodeCount);
      let guard = 0;
      while (to === from && guard++ < 32) to = Math.floor(rng() * nodeCount);
      if (to !== from) out.push([from, to]);
    }
    return out;
  }

  interface Arm {
    sent: number;
    delivered: number;
    ratio: number;
    relayTx: number;
    superRatio: number;
    relaysAreSuper: number;
    /** Radio transmissions by nodes that are *not* community relays: the burden the
     *  programme is supposed to move off other people's batteries. `txCount` rather than
     *  the capture log, which a 60-node crowd cannot afford to keep. */
    burdenOnOthers: number;
    /** The same count for the tablets themselves, which are plugged in. */
    burdenOnRelays: number;
    normalPctPerHour: number;
    /** Every tablet that did not become a SUPER, with what actually beat it: how many
     *  better-scoring candidates were themselves community relays, and how many were
     *  phones. That distinction is the whole finding (§19.4). */
    blocked: Array<{ id: string; reason: string; betterTablets: number; betterPhones: number }>;
    superCount: number;
  }

  function runArm(
    seed: number,
    relays: number,
    policy: SimConfig["relayPolicy"],
    quota = 0
  ): Arm {
    const world = festivalCrowd(seed);
    const sim = new MeshSimulation({ ...world, relayPolicy: policy, communityRelayQuota: quota });
    sim.runFor(20000);

    const relayIds = new Set<string>();
    if (relays > 0) {
      // The `relays` most open positions in the crowd: a café on a corner, not a phone
      // in somebody's pocket. Charging, stationary, full, and not opted out — which is
      // what "keep Duman on a plugged tablet" means in the model.
      const online = sim.nodes.filter((n) => n.isOnline);
      const ranked = [...online].sort((a, b) => {
        const pa = peersInRange(a, online, sim.rf).length;
        const pb = peersInRange(b, online, sim.rf).length;
        return pb - pa || (a.id < b.id ? -1 : 1);
      });
      for (const node of ranked.slice(0, relays)) {
        node.charging = true;
        node.stationary = true;
        node.battery = 1;
        node.superOptOut = false;
        node.batterySaver = false;
        node.uptimeMin = 600;
        relayIds.add(node.id);
      }
    }
    sim.clearRecords();

    const p = plan(seed, sim.nodes.length);
    let sent = 0;
    for (let i = 0; i < p.length; i++) {
      const from = sim.nodes[p[i][0]];
      const to = sim.nodes[p[i][1]];
      if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `cr-${i}`, "text")) sent++;
      sim.runFor(GAP_MS);
    }
    const stats = sim.refresh();
    const uni = sim.deliveries.filter(
      (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
    );
    let byOthers = 0;
    let byRelays = 0;
    for (const node of sim.nodes) {
      if (relayIds.has(node.id)) byRelays += node.txCount;
      else byOthers += node.txCount;
    }
    return {
      sent,
      delivered: uni.length,
      ratio: uni.length / Math.max(1, sent),
      relayTx: stats.totalForwarded,
      superRatio: stats.superRatio,
      relaysAreSuper: [...relayIds].filter(
        (id) => sim.nodes.find((n) => n.id === id)?.role === "SUPER"
      ).length,
      burdenOnOthers: byOthers,
      burdenOnRelays: byRelays,
      normalPctPerHour: stats.batteryPercentPerHourNormal,
      blocked: [...relayIds]
        .map((id) => sim.nodes.find((n) => n.id === id)!)
        .filter((n) => n.role !== "SUPER")
        .map((n) => {
          const peers = peersInRange(n, sim.nodes, sim.rf).filter((p) => p.score > n.score);
          return {
            id: n.id,
            reason: n.reasonTrace,
            betterTablets: peers.filter((p) => p.charging && p.stationary).length,
            betterPhones: peers.filter((p) => !(p.charging && p.stationary)).length,
          };
        }),
      superCount: sim.nodes.filter((n) => n.role === "SUPER").length,
    };
  }

  it("elects the plugged tablets and moves relay work off other people's batteries", () => {
    const seed = 42;
    const baseMpr = runArm(seed, 0, "mpr");
    const baseFlood = runArm(seed, 0, "flood-all");
    const relayMpr = runArm(seed, 3, "mpr");
    const relayFlood = runArm(seed, 3, "flood-all");
    const sixMpr = runArm(seed, 6, "mpr");

    // eslint-disable-next-line no-console
    console.log(
      JSON.stringify(
        {
          baseMpr,
          baseFloodRelays: baseFlood.relayTx,
          baseFloodRatio: Number(baseFlood.ratio.toFixed(4)),
          relayMpr,
          relayFloodRelays: relayFlood.relayTx,
          relayFloodRatio: Number(relayFlood.ratio.toFixed(4)),
          sixMpr,
        },
        null,
        1
      )
    );

    // The programme's own claim: a plugged, stationary, well-placed tablet becomes a
    // router. The charging bonus is +0.10 of score and these nodes also have the peers.
    expect(relayMpr.relaysAreSuper).toBe(3);

    // Delivery: three tablets are worth about one message and six are worth four, out of
    // a hundred, against a naive flood-all baseline that reaches 1.000 in both arms for
    // roughly nine times the transmissions. So this is not a coverage programme, and the
    // gain is inside the band §16.4 warns about — one seed, 100 messages.
    expect(relayMpr.ratio).toBeGreaterThanOrEqual(baseMpr.ratio - 0.02);
    expect(sixMpr.ratio).toBeGreaterThan(baseMpr.ratio);
    expect(sixMpr.ratio).toBeLessThan(1);
    expect(baseFlood.ratio).toBe(1);
    expect(relayFlood.ratio).toBe(1);

    // Adding always-on SUPERs adds relays: a SUPER relays everything by design (roadmap
    // Phase 2 item 65), so at three tablets total traffic rises ~13% and the work carried
    // by everybody else is flat (+1.1%).
    expect(relayMpr.relayTx).toBeGreaterThan(baseMpr.relayTx);
    expect(relayMpr.burdenOnRelays).toBeGreaterThan(0);

    // At six the tablets displace battery-powered SUPERs instead of joining them, and the
    // burden moves: other nodes transmit ~19% less than baseline and their drain falls
    // ~6%. Two of the six are not elected at all — the top-20% cap is nearly full at
    // 21.7%, so a plugged tablet competes with the nodes the score already favours.
    expect(sixMpr.burdenOnOthers).toBeLessThan(baseMpr.burdenOnOthers);
    expect(sixMpr.burdenOnOthers).toBeLessThan(relayMpr.burdenOnOthers);
    expect(sixMpr.relayTx).toBeLessThan(relayMpr.relayTx);
    expect(sixMpr.relaysAreSuper).toBeGreaterThanOrEqual(3);
    expect(sixMpr.relaysAreSuper).toBeLessThan(6);

    // The claim the programme can actually make: NORMAL nodes drain more slowly with
    // tablets in the mesh — 2.914 %/h at none, 2.822 at three, 2.877 at six. The
    // ordering *between* the two arms is one or two hundredths of a percent on a single
    // seed, so it is reported and not asserted (§16.4's rule about small differences).
    expect(relayMpr.normalPctPerHour).toBeLessThan(baseMpr.normalPctPerHour);
    expect(sixMpr.normalPctPerHour).toBeLessThan(baseMpr.normalPctPerHour);
  });
});

describe("store-carry-forward against skills/04", () => {
  /** A-B-C in a line, 20 m apart: A and C are 40 m apart, which is outside the 31.6 m
   *  line-of-sight budget, so every bundle between them has to be carried by B. */
  function carryWorld(over: Partial<SimConfig> = {}) {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 3,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      captureLog: true,
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  it("carries a bundle for a destination that was offline, and delivers it on contact", () => {
    // skills/04 acceptance: "A→C: A enqueues for C (C offline); B meets A then later C →
    // C receives (carry test)".
    const sim = carryWorld();
    const a = sim.nodes[0];
    const c = sim.nodes[2];
    sim.toggleNodeOnline(c.id); // C walks away: no route, no contact
    const msg = sim.sendMessage(a.id, c.id, "carry me", "text");
    expect(msg).not.toBeNull();
    sim.runFor(30000); // retries exhaust, the bundle is parked
    expect(a.oppQueue.map((q) => q.msg.id)).toContain(msg!.id);
    expect(a.oppQueue[0].msg.carried).toBe(true);
    expect(sim.refresh().totalQueued).toBeGreaterThan(0);

    sim.toggleNodeOnline(c.id); // ... and comes back, within B's range but not A's
    let elapsed = 0;
    while (sim.deliveries.filter((d) => d.msgId === msg!.id).length === 0 && elapsed < 300000) {
      sim.runFor(250);
      elapsed += 250;
    }
    const arrived = sim.deliveries.filter((d) => d.msgId === msg!.id);
    expect(arrived).toHaveLength(1);
    // It arrived opportunistically, so it is marked as carried and stays out of the
    // latency budget docs/04 §5 writes for routed traffic.
    expect(arrived[0].dtn).toBe(true);
    expect(c.inbox.some((m) => m.id === msg!.id)).toBe(true);

    // What the ACK does and does not clean up. It goes to the carrier that handed the
    // bundle over, so carriers on that reverse path prune; the originator is not on it,
    // and its copy waits for the seven-day TTL. The safety property is that the copy
    // cannot produce a second delivery, because the destination dedupes on the id.
    sim.runFor(120000);
    expect(sim.deliveries.filter((d) => d.msgId === msg!.id)).toHaveLength(1);
    expect(c.inbox.filter((m) => m.id === msg!.id)).toHaveLength(1);
  });

  it("never puts more than three copies of one bundle on air", () => {
    // skills/04 acceptance: "Spray limit: same msg not duplicated >3x in network capture".
    const sim = carryWorld();
    const [a, , c] = sim.nodes;
    sim.toggleNodeOnline(c.id);
    const msg = sim.sendMessage(a.id, c.id, "spray me", "text")!;
    sim.runFor(30000);
    sim.toggleNodeOnline(c.id);
    sim.runFor(120000);

    // Copies handed on by carriers, counted from the capture log rather than from the
    // queue: this is the network's view, which is what the criterion asks about.
    const carrierCopies = sim.log.filter(
      (l) => l.kind === "tx" && l.msgId === msg.id && l.nodeId !== a.id
    ).length;
    expect(carrierCopies).toBeLessThanOrEqual(SPRAY_LIMIT);
    const bundle = [...sim.nodes.flatMap((n) => n.oppQueue), ...[]].find(
      (q) => q.msg.id === msg.id
    );
    if (bundle) expect(bundle.copyCount).toBeLessThanOrEqual(SPRAY_LIMIT);
  });

  it("hands a bundle to a SUPER when the carrier has no route of its own", () => {
    // skills/04: "DO prefer SUPER as bundle carrier (more storage/battery)". In a
    // partitioned world this is pure cost — docs/06 §20 measures both halves — so the
    // assertion here is about the mechanism firing, not about delivery improving.
    const sim = new MeshSimulation({
      ...buildScenario("partitioned_pair", 42),
      captureLog: false,
      dtnPreferSuper: true,
    });
    sim.runFor(90000);
    sim.clearRecords();
    const online = sim.nodes.filter((n) => n.isOnline);
    for (let i = 0; i < 40; i++) {
      const from = online[i % online.length];
      let to = online[(i * 5 + 3) % online.length];
      if (to.id === from.id) to = online[(i + 1) % online.length];
      sim.sendMessage(from.id, to.id, `dtn-${i}`, "text");
      sim.runFor(1500);
    }
    sim.runFor(60000);
    const stats = sim.refresh();
    expect(stats.dtnSuperCarries).toBeGreaterThan(0);
    // Still bounded: the spray limit applies to opportunistic copies too.
    expect(sim.nodes.every((n) => n.oppQueue.every((q) => q.copyCount <= SPRAY_LIMIT))).toBe(true);
    expect(sim.nodes.every((n) => n.oppQueue.length <= OPP_QUEUE_MAX)).toBe(true);

    // Off by default, because it costs delivery in a crowd once carried bundles are
    // parked rather than suppressed (docs/06 §20.4).
    const off = new MeshSimulation({ ...buildScenario("partitioned_pair", 42) });
    expect(off.config.dtnPreferSuper).toBe(false);
    off.runFor(90000);
    off.clearRecords();
    expect(off.refresh().dtnSuperCarries).toBe(0);
  });

  it("prunes a bundle when its ACK is overheard, and evicts by priority then age", () => {
    const node = makeNode("carrier", 0, 0);
    const low = createMessage("old-low", 0, "a", "c", "x", "text");
    const fresh = createMessage("new-low", 100, "a", "c", "y", "text");
    const normal = createMessage("normal", 50, "a", "c", "z", "text");
    node.oppQueue = [];
    enqueueOpp(node, { ...low, priority: "low" }, 0);
    enqueueOpp(node, normal, 50);
    enqueueOpp(node, { ...fresh, priority: "low" }, 100);
    expect(node.oppQueue.map((q) => q.msg.id)).toEqual(["old-low", "normal", "new-low"]);

    // skills/04: "On ackReceived from dest: remove + gossip ACK (so relays can prune)".
    expect(pruneAcked(node, "normal")).toBe(1);
    expect(node.oppQueue.map((q) => q.msg.id)).toEqual(["old-low", "new-low"]);
    expect(pruneAcked(node, "normal")).toBe(0); // idempotent, and quiet when there is nothing

    // The cap keeps the newest 500 by priority: the oldest *low-priority* bundle goes
    // first, not simply the oldest.
    for (let i = 0; i < OPP_QUEUE_MAX; i++) {
      enqueueOpp(node, createMessage(`fill-${i}`, 200 + i, "a", "c", "f", "text"), 200 + i);
    }
    expect(node.oppQueue.length).toBeLessThanOrEqual(OPP_QUEUE_MAX);
    // "LRU by priority" means priority first and age second: both sprayed-out bundles go
    // before any normal one, however fresh, and the older of the two goes first.
    expect(node.oppQueue.some((q) => q.msg.id === "old-low")).toBe(false);
    expect(node.oppQueue.some((q) => q.msg.id === "new-low")).toBe(false);
    // The pruned bundle stays pruned, and the 500 fresh ones all fit.
    expect(node.oppQueue.some((q) => q.msg.id === "normal")).toBe(false);
    expect(node.oppQueue.some((q) => q.msg.id === "fill-0")).toBe(true);
    expect(node.oppQueue.some((q) => q.msg.id === "fill-499")).toBe(true);
    expect(node.oppQueue).toHaveLength(OPP_QUEUE_MAX);

    // Expiry is a real seven days of simulation time, which is not runnable event by
    // event, so the boundary is asserted on the sweeper itself.
    const stale = makeNode("stale", 0, 0);
    enqueueOpp(stale, createMessage("week-old", 0, "a", "c", "w", "text"), 0);
    pruneOppQueue(stale, OPP_TTL_MS);
    expect(stale.oppQueue).toHaveLength(1);
    pruneOppQueue(stale, OPP_TTL_MS + 1);
    expect(stale.oppQueue).toHaveLength(0);
  });
});

describe("media under load, measured without confounding the A/B (docs/08 §9)", () => {
  const MESSAGES = 40;
  const GAP_MS = 2000;

  /** One plan, replayed identically in both arms. Letting each arm draw its own traffic
   *  is what produced the first, wrong contention table: the arms were not the same
   *  experiment, and a media run consumes randomness that shifts every later loss draw. */
  function plan(seed: number, nodeCount: number): Array<[number, number]> {
    const rng = createRng((seed ^ 0x2f6e2b1) >>> 0);
    const out: Array<[number, number]> = [];
    for (let i = 0; i < MESSAGES; i++) {
      const a = Math.floor(rng() * nodeCount);
      let b = Math.floor(rng() * nodeCount);
      let guard = 0;
      while (b === a && guard++ < 32) b = Math.floor(rng() * nodeCount);
      if (a !== b) out.push([a, b]);
    }
    return out;
  }

  function arm(seed: number, withFile: boolean) {
    const sim = new MeshSimulation({ ...campusQuad(seed), trafficIntervalMs: 0 });
    sim.runFor(90000);
    sim.clearRecords();
    const p = plan(seed, sim.nodes.length);
    let transfer: ReturnType<MeshSimulation["sendFile"]> = null;
    if (withFile) {
      transfer = sim.sendFile(sim.nodes[p[0][0]].id, sim.nodes[p[0][1]].id, 10 * 1048576);
    }
    let sent = 0;
    for (let i = 1; i < p.length; i++) {
      const from = sim.nodes[p[i][0]];
      const to = sim.nodes[p[i][1]];
      if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `c-${i}`, "text")) sent++;
      sim.runFor(GAP_MS);
    }
    const stats = sim.refresh();
    const uni = sim.deliveries.filter(
      (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
    );
    return {
      sent,
      delivered: uni.length,
      within5: uni.filter((d) => d.hops <= 5).length,
      relayTx: stats.totalForwarded,
      queued: stats.totalQueued,
      exhausted: stats.retriesExhausted,
      transfer,
    };
  }

  it("costs radio work and nothing else: text delivery is identical, seed for seed", () => {
    for (const seed of [42, 7]) {
      const quiet = arm(seed, false);
      const busy = arm(seed, true);

      // The point of the test: with one fixed plan, a 10 MB file in flight does not move
      // ordinary traffic at all. Not "barely" — identically.
      expect(busy.sent).toBe(quiet.sent);
      expect(busy.delivered).toBe(quiet.delivered);
      expect(busy.within5).toBe(quiet.within5);

      // Not every counter is bit-identical, and it is worth being precise about why: the
      // media run consumes randomness for each chunk's jitter and loss, so the text
      // messages' later draws differ between arms. A parked bundle can move by one. That
      // is an RNG-path difference, not contention — the structural reason is asserted in
      // the next test, which is why this one is allowed a tolerance at all.
      expect(Math.abs(busy.queued - quiet.queued)).toBeLessThanOrEqual(1);
      expect(Math.abs(busy.exhausted - quiet.exhausted)).toBeLessThanOrEqual(1);

      // What it does cost is the media's own radio work.
      expect(busy.relayTx).toBeGreaterThan(quiet.relayTx);
      expect(busy.transfer!.received).toBe(busy.transfer!.chunks);
    }
  });

  it("has no mechanism by which media could harm text, and says so", () => {
    // Loss is a pure function of geometry: `packetLossProbability` reads the link margin
    // and nothing else — not the packet delivery feedback, not how many transmissions are
    // in flight, not what anybody else is doing. And two transmissions at the same instant
    // both succeed, because there is no shared medium. So the null result above is a
    // property of the model rather than a lucky draw, and a load gate on transfers would
    // have nothing to protect until a channel-access model exists (docs/08 §9.1-9.2, §11).
    //
    // Mobility is off so that "before" and "after" differ in one variable only: the media.
    const sim = new MeshSimulation({ ...campusQuad(42), enableMobility: false });
    sim.runFor(90000);
    const a = sim.nodes[0];
    const b = sim.nodes[5];
    const loss = () => effectiveLossProbability(a, b, sim.rf, sim.config.linkRetries);
    const quiet = loss();

    const t = sim.sendFile(a.id, b.id, 10 * 1048576)!;
    expect(t.chunks).toBe(160);
    expect(loss()).toBe(quiet); // 160 chunks committed, radio as busy as this model gets

    let elapsed = 0;
    while (t.state === "active" && elapsed < 180000) {
      sim.runFor(250);
      elapsed += 250;
    }
    expect(t.state).toBe("complete");
    expect(sim.refresh().sentChunks).toBeGreaterThanOrEqual(160);
    expect(loss()).toBe(quiet); // ... and unchanged on the other side of it
  });
});

describe("channel access: one radio, half-duplex (docs/08 §12)", () => {
  /** The same 20 m line the media tests use: hop count is the index distance, so every
   *  assertion here is about the radio rather than about who happened to be in range. */
  function lineWorld(n = 4, over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: n,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
      node.txPower = DEFAULT_CONFIG.txPowerDbm;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  function runUntil(sim: MeshSimulation, done: () => boolean, budgetMs: number): boolean {
    let elapsed = 0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(100);
      elapsed += 100;
    }
    return done();
  }

  it("occupies no radio by default: nothing is ever deferred, and nothing is ever dropped", () => {
    // `channelAccess: "free"` is an infinitely wide radio, and it is what every other
    // number in this repository was measured under. Asserting the counters are exactly
    // zero is what keeps that from drifting by accident.
    const sim = new MeshSimulation({ ...campusQuad(42), trafficIntervalMs: 1000 });
    sim.runFor(120000);
    const stats = sim.refresh();
    expect(stats.totalForwarded).toBeGreaterThan(100);
    expect(stats.channelDeferrals).toBe(0);
    expect(stats.channelDeferMs).toBe(0);
    expect(stats.channelDrops).toBe(0);
  });

  it("makes a packet wait its turn, and still delivers it", () => {
    const sim = lineWorld(2, { channelAccess: "halfDuplex" });
    const [a, b] = sim.nodes;
    for (let i = 0; i < 4; i++) sim.sendMessage(a.id, b.id, `hd-${i}`, "text");
    runUntil(sim, () => sim.deliveries.filter((d) => d.to === b.id).length >= 4, 10000);

    const stats = sim.refresh();
    expect(sim.deliveries.filter((d) => d.to === b.id).length).toBe(4);
    expect(stats.channelDeferrals).toBeGreaterThan(0);
    expect(stats.channelDeferMs).toBeGreaterThan(0);
    // One radio, so the four copies land one air time apart rather than together. The
    // same burst under the default model arrives inside a single hop latency.
    const lat = sim.deliveries.filter((d) => d.to === b.id).map((d) => d.latencyMs).sort((x, y) => x - y);
    expect(lat[3] - lat[0]).toBeGreaterThan(DEFAULT_CONFIG.hopLatencyBleMs);
  });

  it("wakes a radio that went busy with an empty queue", () => {
    // Regression. The first implementation only scheduled a drain when it left packets
    // behind, so a radio that finished its queue while still busy had nothing to wake it:
    // the next packet handed to it waited for some *other* transmission to come along. In
    // a quiet mesh that is forever, and the symptom was a delivery ratio of 0.37 on a
    // campus with no media in flight at all.
    const sim = lineWorld(2, { channelAccess: "halfDuplex" });
    const [a, b] = sim.nodes;
    const texts = () => sim.deliveries.filter((d) => d.to === b.id && d.type === "text").length;
    sim.sendMessage(a.id, b.id, "first", "text");
    sim.runFor(50); // on air, queue drained, radio still busy
    sim.sendMessage(a.id, b.id, "second", "text");
    expect(runUntil(sim, () => texts() >= 2, 5000)).toBe(true);
  });

  it("sheds load when the queue is full instead of promising air time it does not have", () => {
    const sim = lineWorld(2, { channelAccess: "halfDuplex", channelQueueDepth: 1 });
    const [a, b] = sim.nodes;
    for (let i = 0; i < 6; i++) sim.sendMessage(a.id, b.id, `drop-${i}`, "text");
    runUntil(sim, () => sim.refresh().channelDrops > 0, 5000);

    const stats = sim.refresh();
    expect(stats.channelDrops).toBeGreaterThan(0);
    // Bounded is the point: an unbounded queue does not deliver those packets later, it
    // delivers them after the run is over.
    expect(sim.deliveries.filter((d) => d.to === b.id).length).toBeLessThan(6);
  });

  it("takes the parallelism out of the sliding window, which is the whole finding", () => {
    // On an infinitely wide radio a window of 4 is four transmissions at once, and it is
    // worth 15x. On one radio they are four transmissions in a row, so the window can
    // only hide ACK latency -- and under load it fills the queue and loses chunks, which
    // is why docs/08 §12 recommends window 1 for the model that has a real radio.
    const MB = 1048576;
    const time = (channelAccess: SimConfig["channelAccess"], window: number) => {
      const sim = lineWorld(2, { channelAccess });
      const [a, b] = sim.nodes;
      const t = sim.sendFile(a.id, b.id, 10 * MB, { window })!;
      runUntil(sim, () => t.state === "complete", 900000);
      expect(t.state).toBe("complete");
      return (t.completedAt ?? 0) - t.startedAt;
    };

    const free1 = time("free", 1);
    const free4 = time("free", 4);
    const hd1 = time("halfDuplex", 1);
    const hd4 = time("halfDuplex", 4);

    // Measured on this pair: 35.0 s -> 9.2 s with the window open, 105.4 s -> 96.4 s on
    // one radio. The window is worth 3.8x on an infinitely wide radio and 1.1x on a real
    // one -- and the real one is ten times slower overall, which is the actual cost.
    expect(free1 / free4).toBeGreaterThan(3);
    expect(hd1 / hd4).toBeLessThan(1.5);
    expect(hd4).toBeGreaterThan(free4 * 5);
  });

  it("keeps up with the capture clock at one hop and falls behind at three", () => {
    // A 500 ms frame is 750 B, which is one BLE packet, so its air time is hop latency
    // plus jitter: about 245 ms a hop. At one hop that is half the capture clock and
    // streaming holds. At three hops it is 735 ms of radio for every 500 ms recorded, so
    // the queue grows for as long as you keep talking. Nothing is lost -- the note arrives
    // complete -- but it arrives long after you let go.
    const delayAfterRelease = (hops: number, channelAccess: SimConfig["channelAccess"]) => {
      const sim = lineWorld(hops + 1, { channelAccess });
      const note = sim.sendVoice(sim.nodes[0].id, sim.nodes[hops].id, 10, { stream: true })!;
      expect(runUntil(sim, () => note.state === "complete", 200000)).toBe(true);
      expect(note.received).toBe(note.chunks);
      return (note.completedAt ?? 0) - (note.releasedAt ?? note.startedAt);
    };

    expect(delayAfterRelease(1, "halfDuplex")).toBeLessThan(1000); // measured 307 ms
    const threeOnOneRadio = delayAfterRelease(3, "halfDuplex"); // measured 17.8 s
    const threeOnFreeRadio = delayAfterRelease(3, "free"); // measured 757 ms
    expect(threeOnOneRadio).toBeGreaterThan(10000);
    expect(threeOnFreeRadio).toBeLessThan(2000);
    expect(threeOnOneRadio).toBeGreaterThan(threeOnFreeRadio * 10);
  });
});

describe("which packet a busy radio takes next (docs/08 §12.8)", () => {
  function lineWorld(n = 2, over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: n,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  function runUntil(sim: MeshSimulation, done: () => boolean, budgetMs: number): boolean {
    let elapsed = 0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(100);
      elapsed += 100;
    }
    return done();
  }

  /** One radio, one sender, a 2 MB file already committed to it, and then something
   *  else arriving: the arrival order is the same in every arm, so whatever differs is
   *  the queue discipline. */
  function busyRadio(priority: SimConfig["channelPriority"], then: (sim: MeshSimulation, a: NodeId, b: NodeId) => void) {
    const sim = lineWorld(2, { channelAccess: "halfDuplex", channelPriority: priority });
    const a = sim.nodes[0].id;
    const b = sim.nodes[1].id;
    const file = sim.sendFile(a, b, 2 * 1048576)!;
    sim.runFor(1000); // some chunks are queued and the radio is committed
    then(sim, a, b);
    runUntil(sim, () => file.state === "complete", 600000);
    return { sim, file };
  }

  it("lets a voice note overtake the bulk transfer, and charges the transfer for it", () => {
    const arms = (["fifo", "class"] as const).map((priority) => {
      const { sim, file } = busyRadio(priority, (s, a, b) => {
        s.sendVoice(a, b, 5, { stream: true });
      });
      const note = [...sim.transfers.values()].find((t) => t.id !== file.id)!;
      // `busyRadio` runs until the *file* is done; under FIFO the note is still behind
      // it, so give the note its own budget before measuring either.
      runUntil(sim, () => note.state === "complete", 600000);
      const fileDone = file.completedAt ?? Number.POSITIVE_INFINITY;
      return {
        noteFirst: (note.completedAt ?? Number.POSITIVE_INFINITY) < fileDone,
        framesBeforeFile: sim.deliveries.filter(
          (d) => d.transferId === note.id && d.timestamp < fileDone
        ).length,
        frames: note.chunks,
        noteSeconds: ((note.completedAt ?? 0) - note.startedAt) / 1000,
      };
    });
    const [fifo, cls] = arms;

    // Under FIFO the note's frames sit behind the chunks already queued, so it takes as long
    // as the transfer does to clear them; under `class` the same ten frames go first and the
    // note is done less than half as long after it started (6.1 s against 13.6 s).
    expect(fifo.framesBeforeFile).toBe(fifo.frames);
    expect(cls.framesBeforeFile).toBe(cls.frames);
    expect(cls.noteSeconds).toBeLessThan(fifo.noteSeconds / 2);
    // The frames that jump the queue are frames the file did not send, so the transfer is
    // not the winner here either way — it just finishes sooner when the note is done with
    // the radio (16.3 s against 21.4 s).
    expect(cls.noteFirst).toBe(true);
  });

  it("promoting acknowledgements moves them, and the bulk transfer pays for it", () => {
    const arms = (["fifo", "ackFirst"] as const).map((priority) => {
      const { sim, file } = busyRadio(priority, (s, a, b) => {
        s.sendMessage(a, b, "probe-ack", "ack");
      });
      const ackAt = sim.deliveries.find((d) => d.type === "ack" && d.to === sim.nodes[1].id)?.timestamp ?? -1;
      return {
        chunksBeforeAck: sim.deliveries.filter(
          (d) => d.transferId === file.id && d.timestamp < ackAt
        ).length,
        fileSeconds: ((file.completedAt ?? 0) - file.startedAt) / 1000,
        chunks: file.chunks,
      };
    });
    const [fifo, ackFirst] = arms;

    // The mechanism: an ACK handed to the radio after six 64 KB chunks goes on air after
    // two of them instead of after all eight.
    expect(ackFirst.chunksBeforeAck).toBeLessThan(fifo.chunksBeforeAck);
    expect(fifo.chunksBeforeAck).toBe(8);
    expect(ackFirst.chunksBeforeAck).toBe(5);
    // And the cost, which is why the flag ships off: every slice the ACK overtakes is a
    // slice the transfer waits for, so the same 2 MB file takes 21.2 s instead of 13.4 s.
    // The campus measurement (docs/08 §12.8) is the same trade at scale — text delivery
    // 0.9661 -> 0.9774 and the file 2.12 -> 2.42 min — and it is a trade, not a win.
    expect(ackFirst.fileSeconds).toBeGreaterThan(fifo.fileSeconds);
    expect(ackFirst.chunks).toBe(fifo.chunks);
  });

  it("is never consulted on the shipped radio, because nothing ever waits there", () => {
    for (const channelPriority of ["fifo", "class"] as const) {
      const sim = lineWorld(2, { channelPriority });
      const a = sim.nodes[0].id;
      const b = sim.nodes[1].id;
      for (let i = 0; i < 5; i++) sim.sendMessage(a, b, `m${i}`, "text");
      sim.runFor(20000);
      expect(sim.refresh().channelDeferrals).toBe(0);
      expect(sim.deliveries.filter((d) => d.to === b && d.type === "text").length).toBe(5);
    }
  });
});

describe("cap-aware community-relay promotion, measured and rejected (docs/06 §19.4)", () => {
  /** The same crowd harness as the block above, trimmed to the two questions that decide
   *  the lever: who gets elected, and what did the ones that did not lose to? */
  function crowdArm(seed: number, relays: number, quota: number) {
    const sim = new MeshSimulation({ ...festivalCrowd(seed), communityRelayQuota: quota });
    sim.runFor(20000);
    const online = sim.nodes.filter((n) => n.isOnline);
    const ranked = [...online].sort(
      (a, b) =>
        peersInRange(b, online, sim.rf).length - peersInRange(a, online, sim.rf).length ||
        (a.id < b.id ? -1 : 1)
    );
    const tablets = ranked.slice(0, relays);
    for (const n of tablets) {
      n.charging = true;
      n.stationary = true;
      n.battery = 1;
      n.superOptOut = false;
      n.batterySaver = false;
      n.uptimeMin = 600;
    }
    sim.runFor(60000);
    return {
      sim,
      tablets,
      elected: tablets.filter((n) => n.role === "SUPER").length,
      supers: sim.nodes.filter((n) => n.role === "SUPER").length,
      blocked: tablets
        .filter((n) => n.role !== "SUPER")
        .map((n) => {
          const better = peersInRange(n, sim.nodes, sim.rf).filter((p) => p.score > n.score);
          return {
            reason: n.reasonTrace,
            betterTablets: better.filter((p) => p.charging && p.stationary).length,
            betterPhones: better.filter((p) => !(p.charging && p.stationary)).length,
          };
        }),
    };
  }

  it("the cap a tablet loses is being spent on other tablets, not on phones", () => {
    // docs/06 §19.2 proposed making promotion cap-aware so a plugged tablet *displaces* a
    // battery-powered SUPER. This is why that cannot work: with six tablets in one crowd
    // they all hear each other, so the five top-20% slots they are competing for are
    // already theirs, and the two that stay NORMAL lost to their own kind.
    const arm = crowdArm(42, 6, 0);
    expect(arm.elected).toBe(4);
    expect(arm.blocked.length).toBe(2);
    for (const b of arm.blocked) {
      expect(b.betterTablets).toBeGreaterThan(b.betterPhones);
      expect(b.betterPhones).toBe(0);
    }
    // And at three tablets the one that sometimes loses is stopped by the 30 m proximity
    // guard — two plugged nodes in the same café should not both be routers — which is
    // the guard doing its job (docs/03 §5), not a cap that needs widening.
    const backed = crowdArm(7, 3, 0);
    expect(backed.elected).toBe(2);
    expect(backed.blocked[0].reason).toContain("Backed off");
  });

  it("exempting tablets from the cap elects all six and pushes the ratio to the top of the band", () => {
    const capped = crowdArm(42, 6, 0);
    const exempt = crowdArm(42, 6, 1);
    expect(capped.elected).toBe(4);
    expect(exempt.elected).toBe(6);
    // 15/60 is exactly 25.0%, the ceiling of skills/02's 15-25% band, reached by adding
    // routers rather than by moving work onto better ones.
    expect(exempt.supers).toBe(15);
    expect(exempt.supers / exempt.sim.nodes.length).toBeCloseTo(0.25, 6);
    expect(exempt.supers).toBeGreaterThan(capped.supers);
    // Three tablets are all elected either way, so the exemption buys nothing at the
    // scale a real café programme would start at.
    expect(crowdArm(42, 3, 1).elected).toBe(crowdArm(42, 3, 0).elected);
  });

  it("reserving half the cap does not reserve it for tablets — it hands a slot to a phone", () => {
    // A tablet already outscores every phone in range, so the reserved slots were theirs
    // before the reservation existed. Taking those slots out of the open pool therefore
    // *loosens* the rule for phones: one more SUPER, and it is not a tablet.
    const plain = crowdArm(42, 3, 0);
    const reserved = crowdArm(42, 3, 0.5);
    expect(reserved.elected).toBe(plain.elected);
    expect(reserved.supers).toBe(plain.supers + 1);
    const extra = reserved.sim.nodes.filter(
      (n) => n.role === "SUPER" && !(n.charging && n.stationary)
    ).length;
    expect(extra).toBeGreaterThan(
      plain.sim.nodes.filter((n) => n.role === "SUPER" && !(n.charging && n.stationary)).length
    );
  });
});

describe("observed-maximum peer normalisation, measured and rejected (docs/06 §18.4)", () => {
  /** The most open position in the world, found rather than assumed: the node that reaches
   *  the most peers with the least wall attenuation. */
  function mostOpenNode(sim: MeshSimulation): MeshNode {
    const online = sim.nodes.filter((n) => n.isOnline);
    let best = online[0];
    let bestScore = -1;
    for (const n of online) {
      const peers = peersInRange(n, online, sim.rf);
      let rssiSum = 0;
      for (const p of peers) rssiSum += rssiModel(n, p, sim.rf);
      const avg = peers.length > 0 ? rssiSum / peers.length : -120;
      const score = peers.length * 100 + avg;
      if (score > bestScore) {
        bestScore = score;
        best = n;
      }
    }
    return best;
  }

  /** Run one world under one normalisation and report both the score and the thing the
   *  election actually decides on: where that score ranks inside the node's own 1-hop
   *  candidacy list. */
  function atriumArm(name: string, peerNorm: PeerNorm) {
    const sim = new MeshSimulation({
      ...buildScenario(name, 42),
      enableMobility: false,
      peerNorm,
    });
    sim.runFor(20000);
    const atrium = mostOpenNode(sim);
    sim.runFor(60000);
    const online = sim.nodes.filter((n) => n.isOnline);
    const candidates = [
      atrium,
      ...peersInRange(atrium, online, sim.rf).filter((p) => !(p.superOptOut || p.batterySaver)),
    ];
    const better = candidates.filter((c) => c.score > atrium.score).length;
    return {
      sim,
      atrium,
      score: atrium.score,
      rank: better + 1,
      candidates: candidates.length,
      cap: Math.max(1, Math.ceil(candidates.length * 0.2)),
      role: atrium.role,
      supers: sim.nodes.filter((n) => n.role === "SUPER").length,
    };
  }

  it("raises every open node's score and leaves the ranking exactly where it was", () => {
    // docs/06 §18.2 predicted that normalising against the observed maximum would make
    // openness decisive in sparse worlds. It does not, and the reason is that an election
    // is a ranking while this is a level change: every well-placed neighbour gains the
    // same way, so the most open node in the world is beaten by the same six people it was
    // beaten by before, and stays NORMAL in three worlds out of four.
    for (const name of scenarioNames()) {
      const fixed = atriumArm(name, "fixed");
      const observed = atriumArm(name, "observed");
      expect(observed.score).toBeGreaterThan(fixed.score);
      expect(observed.rank).toBe(fixed.rank);
      expect(observed.cap).toBe(fixed.cap);
      expect(observed.role).toBe(fixed.role);
    }
  });

  it("what it does move is the promote gate and the size of the elected set", () => {
    // sparse_village: the atrium phone's score crosses docs/03 §3's 0.60 promote threshold
    // only under the observed denominator (0.529 -> 0.723), and one more node in the world
    // crosses it with him — 2 SUPERs become 3. It still does not win, because the cap in a
    // four-candidate view is one and its neighbour is healthier.
    const villageFixed = atriumArm("sparse_village", "fixed");
    const villageObserved = atriumArm("sparse_village", "observed");
    expect(villageFixed.score).toBeLessThan(0.6);
    expect(villageObserved.score).toBeGreaterThan(0.6);
    expect(villageObserved.supers).toBe(villageFixed.supers + 1);

    // festival_crowd: the observed maximum *is* the crowd, so mid-open nodes lose score and
    // the elected set shrinks instead — 13 SUPERs become 11.
    const crowdFixed = atriumArm("festival_crowd", "fixed");
    const crowdObserved = atriumArm("festival_crowd", "observed");
    expect(crowdObserved.supers).toBe(crowdFixed.supers - 2);
  });

  it("holds skills/02's band on the campus world, and puts one seed on its floor", () => {
    const ratios: number[] = [];
    for (const seed of [42, 7, 1234, 99, 2026, 555]) {
      const sim = new MeshSimulation({
        ...campusQuad(seed),
        peerNorm: "observed",
        trafficIntervalMs: 1000,
      });
      sim.runFor(20000);
      sim.runFor(180000);
      ratios.push(sim.refresh().superRatio);
    }
    for (const r of ratios) {
      expect(r).toBeGreaterThanOrEqual(0.15);
      expect(r).toBeLessThanOrEqual(0.25);
    }
    // Seed 99 lands exactly on the floor, which is the practical objection: the lever buys
    // nothing measurable and spends the band's margin doing it.
    expect(Math.min(...ratios)).toBeCloseTo(0.15, 6);
  });
});

describe("preferring a community relay, measured and rejected (docs/06 §19.5)", () => {
  it("wins an equal-coverage MPR tie, which is the only thing it can change", () => {
    // Two peers that cover exactly the same 2-hop node, neither a SUPER, neither with a
    // route entry, so every tie-break below the coverage gain is a draw except the one this
    // flag adds and the node id at the end of the chain.
    const me = makeNode("me", 0, 0);
    const phone = makeNode("phone", 20, 0);
    const plug = makeNode("plug", 10, 0, { charging: true, stationary: true });
    me.peerIds = ["phone", "plug"];
    me.twoHopView = { phone: ["far"], plug: ["far"] };

    expect(isCommunityRelay(plug)).toBe(true);
    expect(isCommunityRelay(phone)).toBe(false);
    // Without the flag the chain runs to the id tie-break and "phone" sorts first.
    expect(selectMprSet(me, [me, phone, plug], false)).toEqual(["phone"]);
    // With it, the plugged node takes the same slot: identical coverage, identical
    // transmissions, and nobody's battery pays for them.
    expect(selectMprSet(me, [me, phone, plug], true)).toEqual(["plug"]);
    // And it changes nothing when the coverage is not equal — gain still outranks it, which
    // is why a crowd measurement of this flag comes out flat (§19.5).
    const greedy = makeNode("greedy", 30, 0);
    me.twoHopView = { phone: ["far", "far2"], plug: ["far"] };
    expect(selectMprSet(me, [me, phone, plug, greedy], true)).toEqual(["phone"]);
  });

  /** A-B-C in a line, 20 m apart, so A cannot reach C. C is offline from t=0 rather than
   *  walking away mid-run: a destination nobody ever heard from has no route anywhere, which
   *  is the only situation in which the carrier preference is consulted at all. A bundle
   *  whose holder still has a route travels on that route, and the preference never fires. */
  function routelessWorld(over: Partial<SimConfig> = {}) {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 3,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    const b = sim.nodes[1];
    b.charging = true; // the café tablet in the middle
    b.stationary = true;
    sim.toggleNodeOnline(sim.nodes[2].id); // C is gone before anybody hears it
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  it("hands a routeless bundle to a plugged carrier when asked, and parks it when not", () => {
    const park = (prefer: boolean) => {
      const sim = routelessWorld({ dtnPreferCommunity: prefer });
      const a = sim.nodes[0];
      const b = sim.nodes[1];
      const c = sim.nodes[2];
      sim.sendMessage(a.id, c.id, "carry me", "text");
      sim.runFor(120000);
      return { a, b, stats: sim.refresh() };
    };

    const off = park(false);
    expect(off.stats.dtnCommunityCarries).toBe(0);
    expect(off.a.oppQueue.length).toBe(1);
    expect(off.b.oppQueue.length).toBe(0); // nobody else ever holds it

    const on = park(true);
    // skills/04's "prefer SUPER as bundle carrier" read for the community-relay programme:
    // a plugged node has the storage and the mains power, so it is the better guess about
    // who will still be here. It does get the bundle, and it gets copies until the spray
    // limit stops it.
    expect(on.stats.dtnCommunityCarries).toBeGreaterThan(0);
    expect(on.b.oppQueue.length).toBe(1);
    expect(on.stats.totalQueued).toBe(off.stats.totalQueued + 1);
  });

  it("and that is where the benefit stops: the bundle waits on a node that never moves", () => {
    // The same tablet that is a good place to *leave* a bundle is a bad place to *carry*
    // one, because carrying is movement. Measured over three seeds in the 60-node crowd
    // (docs/06 §19.5): 40-51 hand-overs a run, parked bundles up 27-55%, delivery flat to
    // 1.1 points worse, p95 up 2.1 s at three tablets. Asserted here on one seed as the
    // direction, not the magnitude.
    const run = (prefer: boolean) => {
      const sim = new MeshSimulation({
        ...festivalCrowd(42),
        dtnPreferCommunity: prefer,
        trafficIntervalMs: 0,
      });
      sim.runFor(20000);
      const online = sim.nodes.filter((n) => n.isOnline);
      const ranked = [...online].sort(
        (x, y) =>
          peersInRange(y, online, sim.rf).length - peersInRange(x, online, sim.rf).length ||
          (x.id < y.id ? -1 : 1)
      );
      for (const n of ranked.slice(0, 6)) {
        n.charging = true;
        n.stationary = true;
        n.battery = 1;
        n.uptimeMin = 600;
      }
      sim.clearRecords();
      const rng = createRng((42 ^ 0x5bf03635) >>> 0);
      let sent = 0;
      for (let i = 0; i < 40; i++) {
        const f = Math.floor(rng() * sim.nodes.length);
        let t = Math.floor(rng() * sim.nodes.length);
        let g = 0;
        while (t === f && g++ < 32) t = Math.floor(rng() * sim.nodes.length);
        const from = sim.nodes[f];
        const to = sim.nodes[t];
        if (f !== t && from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `pc-${i}`, "text")) sent++;
        sim.runFor(1000);
      }
      sim.runFor(120000); // give store-carry-forward time to be wrong
      const stats = sim.refresh();
      const uni = sim.deliveries.filter(
        (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
      );
      return {
        carries: stats.dtnCommunityCarries,
        parked: stats.totalQueued,
        ratio: uni.length / Math.max(1, sent),
        dtn: sim.deliveries.filter((d) => d.dtn).length,
      };
    };

    const off = run(false);
    const on = run(true);
    expect(off.carries).toBe(0);
    // The preference fires, and fires often: forty-one hand-overs in one run.
    expect(on.carries).toBeGreaterThan(20);
    // What it buys is nothing that arrives. Parked bundles do not fall, and not one extra
    // message is delivered opportunistically: the bundle is now sitting on a node that does
    // not move, in a mesh where movement is the delivery mechanism.
    expect(on.parked).toBeGreaterThanOrEqual(off.parked);
    expect(on.dtn).toBe(0);
    expect(off.dtn).toBe(0);
  });
});

describe("the capture effect: a stronger packet takes a busy receiver over (docs/08 §12.15)", () => {
  /** A-B-C in a line, but not symmetrically: A is 10 m from B and C is 25 m, so A arrives
   *  about 8 dB stronger — over the 6 dB margin the model ships with, and under the 12 dB one.
   *  A and C are 35 m apart, past the 31.6 m line-of-sight budget, so neither hears the other
   *  and both talk over B: the hidden terminal the capture effect exists to describe.
   *
   *  `linkRetries: 6` is not a tuning choice, it is isolation. At 25 m the weak sender's raw
   *  link loss is 39%, and with the shipped two retries that is 6% of packets — enough to turn
   *  "did a takeover happen" into a coin flip and make this test flaky on a seed. Six retries
   *  takes it to 0.1%, so what is left to measure is the capture rule and nothing else. */
  function lopsidedWorld(over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 3,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      linkRetries: 6,
      // Fewer beacons, so the OGMs contesting the same receiver do not drown the twenty data
      // pairs this measures. Routes still form inside the 20 s settle.
      ogmIntervalMs: 8000,
      channelCaptureRatioDb: 6,
      ...over,
    });
    const xs = [10, 20, 45];
    sim.nodes.forEach((node, i) => {
      node.pos = { x: xs[i], y: 10 };
      node.home = { x: xs[i], y: 10 };
      node.target = { x: xs[i], y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  /** Twenty contested pairs. `strongFirst` decides which of the two senders is handed to the
   *  engine first, and therefore which one the receiver is locked onto when the other lands. */
  function contest(
    capture: SimConfig["channelCapture"],
    opts: { strongFirst?: boolean; margin?: number; pairs?: number } = {}
  ) {
    const { strongFirst = false, margin = 6, pairs = 20 } = opts;
    const sim = lopsidedWorld({ channelCapture: capture, channelCaptureRatioDb: margin });
    const [strong, rx, weak] = sim.nodes;
    for (let i = 0; i < pairs; i++) {
      const order = strongFirst ? [strong, weak] : [weak, strong];
      for (const from of order) {
        sim.sendMessage(from.id, rx.id, `${from.id === strong.id ? "s" : "w"}-${i}`, "text");
      }
      sim.runFor(5000);
    }
    sim.runFor(60000); // let every retry the collisions forced land
    const stats = sim.refresh();
    return {
      sim,
      stats,
      effects: stats.channelCaptureEffects,
      captured: stats.channelCaptured,
      rx,
      strong,
      weak,
    };
  }

  it("takes the receiver over for a stronger newcomer, and never for a weaker one", () => {
    // The weak packet is the incumbent and the strong one lands 8 dB up, over the 6 dB
    // margin: every pair is a takeover. Not exactly twenty, because the beacons contest the
    // same receiver and a packet that lands while B is transmitting is deaf rather than
    // captured — so assert the mechanism plainly fired rather than an exact count.
    const weakIncumbent = contest("strongest");
    expect(weakIncumbent.effects).toBeGreaterThanOrEqual(12);
    // A takeover is not a rescue: it moves the loss from the newcomer to the incumbent, so
    // the collision counter carries both.
    expect(weakIncumbent.captured).toBeGreaterThanOrEqual(weakIncumbent.effects);

    // Reverse the order and the strong packet is the incumbent. A weaker newcomer can never
    // take a receiver over, so the only takeovers left are between beacons — which are the
    // same beacons in both arms, and the difference is what isolates the data pairs.
    const strongIncumbent = contest("strongest", { strongFirst: true });
    expect(strongIncumbent.effects).toBeLessThan(weakIncumbent.effects);
    expect(weakIncumbent.effects - strongIncumbent.effects).toBeGreaterThanOrEqual(12);
    // …and the collisions did not stop happening, they just stopped being takeovers.
    expect(strongIncumbent.captured).toBeGreaterThan(0);
  });

  it("is first-packet-wins under a margin the geometry cannot reach, and inert when shipped", () => {
    // 8 dB of asymmetry cannot clear a 12 dB margin, so nothing is ever taken over — the model
    // reduces to `first`, which is the sanity check on the knob.
    expect(contest("strongest", { margin: 12 }).effects).toBe(0);
    // A zero margin is loudest-wins with no protection, so it takes over at least as often.
    // Both saturate at one takeover per contested pair here — the beacons do not add any —
    // which is why this is a floor and not a strict increase: the geometry offers 8 dB, so
    // every margin from 0 to 8 clears it and the knob only starts biting above that.
    expect(contest("strongest", { margin: 0 }).effects).toBeGreaterThanOrEqual(
      contest("strongest", { margin: 6 }).effects
    );
    expect(contest("strongest", { margin: 6 }).effects).toBe(20);
    // `first` never compares signal strengths, so it never takes a receiver over. That is the
    // whole difference between the two models, and why §12.9's figure was a bound.
    const first = contest("first");
    expect(first.effects).toBe(0);
    expect(first.captured).toBeGreaterThan(0);
    // And the shipped model counts nothing at all, which is what keeps the golden vectors
    // where they were.
    const shipped = contest("none");
    expect(shipped.effects).toBe(0);
    expect(shipped.captured).toBe(0);
  });

  it("does not condemn a retry of the message it took over", () => {
    // The bookkeeping is per *transmission*, not per message. Keyed by message id, the
    // incumbent that lost would have its retry dropped on arrival too, and a message that was
    // merely overtaken would never land — which is the difference between modelling a
    // collision and modelling a blackhole.
    const run = contest("strongest");
    expect(run.effects).toBeGreaterThanOrEqual(12);
    const arrived = run.sim.deliveries.filter((d) => d.type === "text" && d.to === run.rx.id);
    const bodies = new Set(arrived.map((d) => d.msgId));
    expect(bodies.size).toBe(40); // every pair: the strong one, and the weak one it displaced
    // The weak sender's packets are the ones being displaced, so they are also the ones whose
    // retries have to work: without them the capture effect would be a way of silencing the
    // distant node permanently rather than a way of choosing between two packets. Twenty of
    // the forty arrivals are its own.
    expect(arrived.filter((d) => d.from === run.weak.id).length).toBe(20);
    expect(arrived.filter((d) => d.from === run.strong.id).length).toBe(20);
    expect(run.stats.retriesSent).toBeGreaterThan(0);
  });
});

describe("receiver contention: what a busy receiver does (docs/08 §12.9)", () => {
  /** A-B-C in a line, 20 m apart: A and C both reach B, and neither reaches the other. */
  function lineWorld(over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 3,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  it("loses the second of two packets that arrive together, and only when asked to", () => {
    const run = (capture: SimConfig["channelCapture"]) => {
      const sim = lineWorld({ channelCapture: capture });
      const [a, b, c] = sim.nodes;
      // Two senders, one receiver, the same instant: the air time of a text packet is
      // ~245 ms, so the second arrival lands while B is still locked onto the first.
      sim.sendMessage(a.id, b.id, "from-a", "text");
      sim.sendMessage(c.id, b.id, "from-c", "text");
      sim.runFor(20000);
      const stats = sim.refresh();
      return {
        captured: stats.channelCaptured,
        deaf: stats.channelDeafRx,
        arrived: sim.deliveries.filter((d) => d.to === b.id && d.type === "text").length,
      };
    };

    const none = run("none");
    expect(none.captured).toBe(0);
    expect(none.deaf).toBe(0);
    expect(none.arrived).toBe(2); // both arrive: this is the model §9's null result lives in

    const first = run("first");
    expect(first.captured).toBe(1);
    // ... and the message is not lost, only late: the sender's ACK timeout re-sends it into
    // an idle radio. That is why receiver contention in the crowd costs p95 (4.5 s -> 7.5 s)
    // before it costs delivery (docs/08 §12.9).
    expect(first.arrived).toBe(2);
  });

  it("loses a packet that arrives while its receiver is transmitting", () => {
    const run = (capture: SimConfig["channelCapture"]) => {
      const sim = lineWorld({ channelCapture: capture });
      const [a, b] = sim.nodes;
      sim.sendMessage(a.id, b.id, "a-to-b", "text");
      sim.sendMessage(b.id, a.id, "b-to-a", "text");
      sim.runFor(20000);
      const stats = sim.refresh();
      return {
        deaf: stats.channelDeafRx,
        arrived: sim.deliveries.filter((d) => d.type === "text").length,
      };
    };

    // A half-duplex radio cannot hear over its own transmitter. The two transmissions are
    // not exactly simultaneous — each message is scheduled by its own sender — so one
    // packet lands inside the other's transmit window and the other lands just after it:
    // one collision, and the retry recovers it.
    expect(run("none").deaf).toBe(0);
    const first = run("first");
    expect(first.deaf).toBe(1);
    expect(first.arrived).toBe(2);
  });

  it("counts nothing at all in the shipped model, whatever the transmitter does", () => {
    for (const channelAccess of ["free", "halfDuplex"] as const) {
      const sim = new MeshSimulation({ ...campusQuad(42), trafficIntervalMs: 1000, channelAccess });
      sim.runFor(120000);
      const stats = sim.refresh();
      expect(stats.channelCaptured).toBe(0);
      expect(stats.channelDeafRx).toBe(0);
      expect(stats.totalForwarded).toBeGreaterThan(100);
    }
  });
});

describe("carrier sense, and the hidden terminal it cannot fix (docs/08 §12.10)", () => {
  /** A line of nodes 20 m apart, so a node hears its neighbours and nobody else: at three
   *  nodes the two ends are 40 m apart, outside the 31.6 m line-of-sight budget. */
  function lineWorld(n: number, over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: n,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.home = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  it("turns a collision into a wait, and the retry goes away with it", () => {
    const run = (channelAccess: SimConfig["channelAccess"]) => {
      const sim = lineWorld(2, { channelAccess, channelCapture: "first" });
      const [a, b] = sim.nodes;
      sim.sendMessage(a.id, b.id, "a-to-b", "text");
      sim.sendMessage(b.id, a.id, "b-to-a", "text");
      sim.runFor(20000);
      const stats = sim.refresh();
      return {
        deaf: stats.channelDeafRx,
        retries: stats.retriesSent,
        deferrals: stats.channelDeferrals,
        deferMs: stats.channelDeferMs,
        arrived: sim.deliveries.filter((d) => d.type === "text").length,
      };
    };

    // Blind: each node transmits while the other is on air, so one packet lands on a deaf
    // receiver and its sender retransmits four seconds later.
    const blind = run("halfDuplex");
    expect(blind.deaf).toBe(1);
    expect(blind.retries).toBe(1);
    expect(blind.deferrals).toBe(0);

    // Listening: the same two packets, and nobody collides. What the collision became is
    // 573 ms of waiting, and the retry it would have caused disappears with it.
    const listening = run("csma");
    expect(listening.deaf).toBe(0);
    expect(listening.retries).toBe(0);
    expect(listening.deferrals).toBeGreaterThan(0);
    expect(listening.deferMs).toBeGreaterThan(0);
    expect(listening.arrived).toBe(blind.arrived);
  });

  it("cannot help a hidden terminal, which is the limitation the geometry reproduces", () => {
    // A and C are 40 m apart with B between them: neither can hear the other, and both can
    // hear B. Carrier sense listens to the medium it can hear, so it does not fire here and
    // the collision survives it — the case RTS/CTS exists for, which this model does not
    // have (docs/08 §12.10).
    const run = (channelAccess: SimConfig["channelAccess"]) => {
      const sim = lineWorld(3, { channelAccess, channelCapture: "first" });
      const [a, b, c] = sim.nodes;
      expect(canReach(a, b, sim.rf)).toBe(true);
      expect(canReach(c, b, sim.rf)).toBe(true);
      expect(canReach(a, c, sim.rf)).toBe(false); // hidden from each other
      sim.sendMessage(a.id, b.id, "from-a", "text");
      sim.sendMessage(c.id, b.id, "from-c", "text");
      sim.runFor(20000);
      return sim.refresh().channelCaptured;
    };

    expect(run("halfDuplex")).toBe(1);
    expect(run("csma")).toBe(1);
  });
});

describe("the contention window carrier sense was missing (docs/08 §12.13)", () => {
  /** Three nodes 20 m apart in a triangle, so every pair is inside the 31.6 m line-of-sight
   *  budget and every node can sense every other. This is the geometry carrier sense is
   *  supposed to work in — no hidden terminal to excuse it. */
  function triangleWorld(over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 3,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    const at = [
      { x: 10, y: 10 },
      { x: 30, y: 10 },
      { x: 20, y: 27.32 },
    ];
    sim.nodes.forEach((node, i) => {
      node.pos = at[i];
      node.home = at[i];
      node.target = at[i];
      node.stationary = true;
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  /** Every node transmits at once, each to a different one, so all three radios want the
   *  medium in the same instant. */
  function allTalkAtOnce(over: Partial<SimConfig>) {
    const sim = triangleWorld({ channelAccess: "csma", channelCapture: "first", ...over });
    const [a, b, c] = sim.nodes;
    // Every pair is inside the line-of-sight budget, so this is the geometry carrier sense is
    // supposed to work in: nothing here is a hidden terminal.
    for (const [x, y] of [
      [a, b],
      [b, c],
      [a, c],
    ]) {
      expect(canReach(x, y, sim.rf)).toBe(true);
    }
    sim.sendMessage(a.id, b.id, "a-b", "text");
    sim.sendMessage(b.id, c.id, "b-c", "text");
    sim.sendMessage(c.id, a.id, "c-a", "text");
    sim.runFor(60000);
    const stats = sim.refresh();
    return {
      collisions: stats.channelCaptured + stats.channelDeafRx,
      retries: stats.retriesSent,
      draws: stats.channelBackoffs,
      deferMs: stats.channelDeferMs,
      deferrals: stats.channelDeferrals,
      arrived: sim.deliveries.filter((d) => d.type === "text").length,
    };
  }

  it("fires where carrier sense defers, and costs waiting to do it", () => {
    const herd = allTalkAtOnce({ channelBackoff: "none" });
    const spread = allTalkAtOnce({ channelBackoff: "binary", channelCwMin: 16, channelSlotMs: 5 });

    // The control never draws, so every deferring node is released at the same instant the
    // medium clears and they meet again there.
    expect(herd.draws).toBe(0);
    expect(spread.draws).toBe(8);
    expect(spread.deferrals).toBeGreaterThan(herd.deferrals);
    // Measured, not hoped for: at three nodes the wait is real (1250 ms becomes 2054 ms) and
    // the collision count does not move — one collision either way, and all three messages
    // arrive either way. The mechanism fires; at this scale it does not yet pay, which is the
    // same thing §12.13 finds across a whole campus.
    expect(spread.deferMs).toBeGreaterThan(herd.deferMs);
    expect(spread.collisions).toBe(herd.collisions);
    expect(spread.arrived).toBe(3);
    expect(herd.arrived).toBe(3);
  });

  it("doubles the window after a collision, which is the exponential half of the backoff", () => {
    // A one-slot window can only ever draw zero, so if the window never grew the price of a
    // slot could not matter. It does matter here — which is the collision having doubled the
    // window, observed from outside a private field.
    const grow = (slotMs: number) =>
      allTalkAtOnce({ channelBackoff: "binary", channelCwMin: 1, channelCwMax: 64, channelSlotMs: slotMs });
    const cheap = grow(5);
    const dear = grow(500);
    expect(cheap.draws).toBeGreaterThan(0);
    expect(dear.deferMs).toBeGreaterThan(cheap.deferMs);

    // The same run with the ceiling at one slot: the window cannot widen, the draw cannot
    // exceed zero, and now the price of a slot is irrelevant. Same draws, same totals.
    const capped = (slotMs: number) =>
      allTalkAtOnce({ channelBackoff: "binary", channelCwMin: 1, channelCwMax: 1, channelSlotMs: slotMs });
    const cappedCheap = capped(5);
    const cappedDear = capped(500);
    expect(cappedCheap.draws).toBe(cheap.draws);
    expect(cappedDear.deferMs).toBe(cappedCheap.deferMs);
    expect(cappedDear.collisions).toBe(cappedCheap.collisions);
    expect(cappedDear.arrived).toBe(3);

    // A window that starts wide pays the slot price from its first attempt, so the same
    // comparison holds without needing a collision to widen it. Comparing across *window
    // widths* at a fixed slot price does not: the wait changes when transmissions happen,
    // which changes how many of them there are, so two widths diverge chaotically and their
    // totals are not ordered. The width sweep is a measurement (docs/08 §12.13), not an
    // invariant, and is asserted nowhere here.
    const wide = (slotMs: number) =>
      allTalkAtOnce({ channelBackoff: "binary", channelCwMin: 64, channelSlotMs: slotMs });
    expect(wide(500).deferMs).toBeGreaterThan(wide(5).deferMs);
    expect(wide(5).draws).toBeGreaterThan(0);
  });

  it("is carrier sense's lever: a radio with no shared medium does not move", () => {
    const run = (channelBackoff: SimConfig["channelBackoff"]) => {
      const sim = triangleWorld({
        channelAccess: "halfDuplex",
        channelCapture: "first",
        channelBackoff,
        channelCwMin: 64,
        channelSlotMs: 5,
      });
      const [a, b] = sim.nodes;
      sim.sendMessage(a.id, b.id, "x", "text");
      sim.sendMessage(b.id, a.id, "y", "text");
      sim.runFor(30000);
      const stats = sim.refresh();
      return {
        draws: stats.channelBackoffs,
        deferMs: stats.channelDeferMs,
        arrived: sim.deliveries.filter((d) => d.type === "text").length,
      };
    };
    const off = run("none");
    const on = run("binary");
    expect(off.draws).toBe(0);
    expect(on.draws).toBe(0);
    expect(on).toEqual(off);
  });
});

describe("a retry timer cannot run out before the packet exists (docs/08 §12.11)", () => {
  function lineWorld(over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 2,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  /** Three messages into one radio at once. Each air time is about 440 ms with jitter, so
   *  the third of them waits roughly 888 ms for the medium — longer than the 600 ms timer
   *  it is measured against below, and shorter than the 4 s one that ships for text. */
  function burst(ackTimeoutMs: number) {
    const sim = lineWorld({ channelAccess: "halfDuplex", ackTimeoutMs });
    const a = sim.nodes[0].id;
    const b = sim.nodes[1].id;
    for (let i = 0; i < 3; i++) sim.sendMessage(a, b, `t-${i}`, "text");
    let elapsed = 0;
    while (
      sim.deliveries.filter((d) => d.to === b && d.type === "text").length < 3 &&
      elapsed < 30000
    ) {
      sim.runFor(100);
      elapsed += 100;
    }
    const stats = sim.refresh();
    return {
      deferMs: stats.channelDeferMs,
      retries: stats.retriesSent,
      delivered: sim.deliveries.filter((d) => d.to === b && d.type === "text").length,
    };
  }

  it("measures silence after a transmission, not after a hand-over", () => {
    const timed = burst(600);

    // The queue really does hold a packet longer than the timer: 888 ms of waiting against
    // a 600 ms clock. Before this fix the clock started when the message was handed to the
    // radio, so the third message timed out at 600 ms — 288 ms before it ever went on air —
    // and was retransmitted while its original was still queued. That duplicate is the
    // mechanism §12.10 measured as "waiting turns into load".
    expect(timed.deferMs).toBeGreaterThan(600);
    expect(timed.retries).toBe(0);
    expect(timed.delivered).toBe(3);

    // And the timer still does its job when there is genuine silence: at 300 ms, which is
    // shorter than one round trip on this radio, packets really do go unacknowledged and
    // really are retransmitted.
    const short = burst(300);
    expect(short.retries).toBeGreaterThan(0);
    expect(short.delivered).toBe(3);
  });
});

describe("sender-side backpressure (docs/08 §12.12)", () => {
  function lineWorld(over: Partial<SimConfig> = {}): MeshSimulation {
    const sim = new MeshSimulation({
      ...DEFAULT_CONFIG,
      nodeCount: 2,
      stationaryRatio: 1,
      chargingRatio: 0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: [],
      channelAccess: "halfDuplex",
      ...over,
    });
    sim.nodes.forEach((node, i) => {
      node.pos = { x: 10 + i * 20, y: 10 };
      node.target = { x: 10 + i * 20, y: 10 };
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1;
    });
    sim.runFor(20000);
    sim.clearRecords();
    return sim;
  }

  /** One megabyte through a window of 8 into a queue 4 deep: the transfer is committed
   *  twice as far ahead as the radio can hold, which is the situation backpressure exists
   *  for. */
  function overrun(mediaBackpressure: boolean, channelQueueDepth = 4) {
    const sim = lineWorld({ mediaBackpressure, channelQueueDepth });
    const t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 1048576, { window: 8 })!;
    let elapsed = 0;
    while (t.state === "active" && elapsed < 900000) {
      sim.runFor(100);
      elapsed += 100;
    }
    expect(t.state).toBe("complete");
    const stats = sim.refresh();
    return {
      seconds: ((t.completedAt ?? 0) - t.startedAt) / 1000,
      drops: stats.channelDrops,
      retransmitted: t.retransmitted,
      stalls: t.stalls,
      blocks: stats.transferBlocks,
    };
  }

  it("stops a transfer overrunning its own queue, and the transfer is faster for it", () => {
    const blind = overrun(false);
    const throttled = overrun(true);

    // Without it, a window of 8 keeps handing chunks to a radio that can hold 4, so the tail
    // drops them, the window stalls waiting for chunks that were never sent, and the chunks
    // are retransmitted: 25 dropped, 6 retransmitted, one stall, 9.37 s.
    expect(blind.drops).toBeGreaterThan(20);
    expect(blind.stalls).toBeGreaterThan(0);
    expect(blind.blocks).toBe(0); // nothing throttles it, so nothing ever refuses it air
    // With it, the sender fills only the slots the radio has: 5 dropped, none retransmitted,
    // no stall, and the same file arrives in 6.04 s instead of 9.37 s, because a chunk that
    // was never dropped never had to be sent twice.
    expect(throttled.drops).toBeLessThan(blind.drops / 4);
    expect(throttled.stalls).toBe(0);
    expect(throttled.seconds).toBeLessThan(blind.seconds);
    // The window has to be allowed to reach zero, and the sender has to be woken when a slot
    // frees. Floored at one it still hands a packet to a full queue and has it shed at the
    // tail, which is not backpressure but a slower way of dropping — measured, it *raised* the
    // drop count (1441 → 1637 on the campus half-duplex arm) and left a retransmission behind.
    // Blocking shows up in `blocks`, and resuming on drain is what makes the retransmissions
    // and the stalls both go to zero rather than merely shrink.
    expect(throttled.blocks).toBeGreaterThan(0);
    expect(throttled.retransmitted).toBe(0);
  });

  it("is inert on the shipped radio, where nothing ever queues", () => {
    const run = (mediaBackpressure: boolean) => {
      const sim = new MeshSimulation({
        ...DEFAULT_CONFIG,
        nodeCount: 2,
        stationaryRatio: 1,
        chargingRatio: 0,
        trafficIntervalMs: 0,
        enableSuperElection: false,
        warmupMs: 0,
        obstacles: [],
        mediaBackpressure,
      });
      sim.nodes.forEach((node, i) => {
        node.pos = { x: 10 + i * 20, y: 10 };
        node.target = { x: 10 + i * 20, y: 10 };
        node.mobility = 0;
        node.isOnline = true;
        node.battery = 1;
      });
      sim.runFor(20000);
      sim.clearRecords();
      const t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 1048576, { window: 8 })!;
      let elapsed = 0;
      while (t.state === "active" && elapsed < 900000) {
        sim.runFor(100);
        elapsed += 100;
      }
      return { seconds: ((t.completedAt ?? 0) - t.startedAt) / 1000, drops: sim.refresh().channelDrops };
    };
    expect(run(true).seconds).toBe(run(false).seconds);
    expect(run(true).drops).toBe(0);
  });
});
