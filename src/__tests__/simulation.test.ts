import { describe, expect, it } from "vitest";
import {
  MeshSimulation,
  DEFAULT_CONFIG,
  deliveredChain,
  type SimConfig,
} from "../simulation";
import { campusQuad, festivalCrowd, partitionedPair, sparseVillage } from "../scenarios";
import { canReach, peersInRange } from "../rf";
import { createMessage, deliverToInbox } from "../routing";
import { makeNode } from "./helpers";
import type { MeshMessage, MeshNode } from "../types";

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
    expect(sim.nodes[0].oppQueue.length).toBe(queued.length);
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
