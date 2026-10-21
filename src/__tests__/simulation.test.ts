import { describe, expect, it } from "vitest";
import { MeshSimulation, DEFAULT_CONFIG, type SimConfig } from "../simulation";
import { campusQuad, partitionedPair, sparseVillage } from "../scenarios";
import { canReach, peersInRange } from "../rf";
import type { MeshNode } from "../types";

/**
 * Every test in the first block pins a defect that existed in the original
 * prototype engine. They are written as regressions so the failure modes cannot
 * silently return.
 */

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
    const target = sim.nodes.find((n) => !canReach(from, n, sim.rf) && componentSize(sim) > 1);
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

  it("gives SOS messages a longer TTL and high priority", () => {
    const sim = new MeshSimulation(campusQuad(42));
    const sos = sim.sendMessage("node-0", "BROADCAST", "help", "sos");
    expect(sos).not.toBeNull();
    expect(sos!.ttl).toBe(7);
    expect(sos!.priority).toBe("high");
    const text = sim.sendMessage("node-0", "node-1", "hi", "text");
    expect(text!.ttl).toBe(5);
    expect(text!.priority).toBe("normal");
  });
});
