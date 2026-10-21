import { describe, expect, it } from "vitest";
import { createRng, randRange } from "../rng";
import {
  canReach,
  countWallCrossings,
  distance,
  effectiveLossProbability,
  insideAnyObstacle,
  integrateMotion,
  linkQuality,
  maxRangeM,
  normRssi,
  packetLossProbability,
  peersInRange,
  rssiModel,
  batteryDrain,
  NORMAL_DRAIN_PER_HOUR,
  SUPER_DRAIN_PER_HOUR,
} from "../rf";
import {
  buildOGM,
  computeScore,
  electRole,
  getNextHop,
  ogmToGossip,
  pruneStaleEntries,
  receiveOGM,
  WEIGHTS,
} from "../election";
import {
  createMessage,
  decideForward,
  enqueueOpp,
  isSeen,
  markSeen,
  pruneOppQueue,
  pruneSeenCache,
  resolveMprWait,
  scanOppQueue,
  selectTransport,
  seenKey,
  SEEN_CACHE_TTL_MS,
  SPRAY_LIMIT,
  OPP_TTL_MS,
} from "../routing";
import type { MeshNode, Obstacle } from "../types";
import { makeNode, rfWith } from "./helpers";

describe("seeded RNG", () => {
  it("is deterministic for a given seed", () => {
    const a = createRng(1234);
    const b = createRng(1234);
    for (let i = 0; i < 64; i++) expect(a()).toBe(b());
  });

  it("produces different streams for different seeds", () => {
    const a = createRng(1);
    const b = createRng(2);
    expect(a()).not.toBe(b());
  });

  it("stays inside [0, 1) over a long stream", () => {
    const rng = createRng(7);
    for (let i = 0; i < 20000; i++) {
      const v = rng();
      expect(v).toBeGreaterThanOrEqual(0);
      expect(v).toBeLessThan(1);
    }
  });

  it("matches the fixed-point vectors shared with the Dart port", () => {
    const rng = createRng(42);
    // These exact values are asserted by sim/mesh_sim/test/golden_test.dart.
    expect(Math.round(rng() * 1e9)).toBe(601103752);
    expect(Math.round(rng() * 1e9)).toBe(448290559);
    expect(Math.round(rng() * 1e9)).toBe(852465793);
  });
});

describe("RF model", () => {
  const rf = rfWith();

  it("gives the documented BLE hop range for the default calibration", () => {
    // tx -55 dBm, sensitivity -85 dBm -> 10^(30/20) = 31.6 m, inside the
    // documented "10-30 m indoors, ~100 m open air" BLE budget.
    expect(maxRangeM(rf)).toBeCloseTo(31.6, 0);
    const near = makeNode("a", 0, 0);
    const atEdge = makeNode("b", 31, 0);
    const beyond = makeNode("c", 33, 0);
    expect(canReach(near, atEdge, rf)).toBe(true);
    expect(canReach(near, beyond, rf)).toBe(false);
  });

  it("never treats a node as its own peer", () => {
    const a = makeNode("a", 0, 0);
    expect(canReach(a, a, rf)).toBe(false);
    expect(peersInRange(a, [a], rf)).toHaveLength(0);
  });

  it("follows inverse-square path loss", () => {
    const a = makeNode("a", 0, 0);
    const b = makeNode("b", 10, 0);
    expect(rssiModel(a, b, rf)).toBeCloseTo(-55 - 20 * Math.log10(10), 9);
  });

  it("attenuates by one wall penalty per obstacle boundary crossed", () => {
    const building: Obstacle = { x: 10, y: -10, w: 10, h: 20, label: "hall" };
    const walled = rfWith([building]);
    const a = makeNode("a", 0, 0);
    const b = makeNode("b", 30, 0); // segment passes straight through the building
    expect(countWallCrossings(a.pos, b.pos, [building])).toBe(2);
    expect(rssiModel(a, b, walled)).toBeCloseTo(rssiModel(a, b, rf) - 2 * walled.wallPenaltyDb, 9);
  });

  it("does not attenuate a link that misses every obstacle", () => {
    const building: Obstacle = { x: 10, y: 40, w: 10, h: 20, label: "hall" };
    const a = makeNode("a", 0, 0);
    const b = makeNode("b", 30, 0);
    expect(countWallCrossings(a.pos, b.pos, [building])).toBe(0);
  });

  it("flags points inside a building so spawning can reject them", () => {
    const building: Obstacle = { x: 10, y: 10, w: 10, h: 10, label: "hall" };
    expect(insideAnyObstacle({ x: 15, y: 15 }, [building])).toBe(true);
    expect(insideAnyObstacle({ x: 5, y: 5 }, [building])).toBe(false);
  });

  it("normalises RSSI onto 0..1 across -100..-30 dBm and clamps", () => {
    expect(normRssi(-30)).toBe(1);
    expect(normRssi(-100)).toBe(0);
    expect(normRssi(-65)).toBeCloseTo(0.5, 9);
    expect(normRssi(-200)).toBe(0);
    expect(normRssi(0)).toBe(1);
    expect(linkQuality(makeNode("a", 0, 0), makeNode("b", 1, 0), rf)).toBeGreaterThan(0);
  });

  it("makes lossy links worse as margin shrinks, and retries multiply out the loss", () => {
    const a = makeNode("a", 0, 0);
    const strong = makeNode("s", 2, 0);
    const weak = makeNode("w", 30, 0);
    expect(packetLossProbability(a, strong, rf)).toBeLessThan(packetLossProbability(a, weak, rf));
    expect(packetLossProbability(a, strong, rf)).toBeLessThan(0.05);
    // BLE GATT / Wi-Fi Direct are reliable bearers: p^(retries+1).
    const raw = packetLossProbability(a, weak, rf);
    expect(effectiveLossProbability(a, weak, rf, 2)).toBeCloseTo(raw ** 3, 12);
    expect(effectiveLossProbability(a, weak, rf, 0)).toBeCloseTo(raw, 12);
  });

  it("keeps nodes wandering around their waypoint instead of drifting away", () => {
    const rng = createRng(5);
    const n = makeNode("m", 50, 50, { stationary: false, mobility: 0.8, wanderRadius: 12 });
    for (let i = 0; i < 2000; i++) integrateMotion(n, rng, 0.25, 100, 100, true);
    expect(distance(n.pos, n.home)).toBeLessThanOrEqual(n.wanderRadius + 2);
    expect(n.pos.x).toBeGreaterThanOrEqual(2);
    expect(n.pos.x).toBeLessThanOrEqual(98);
  });

  it("never moves a stationary node", () => {
    const rng = createRng(5);
    const n = makeNode("s", 20, 20, { stationary: true });
    for (let i = 0; i < 100; i++) integrateMotion(n, rng, 0.25, 100, 100, true);
    expect(n.pos).toEqual({ x: 20, y: 20 });
  });

  it("drains battery at the documented 15%/8h for NORMAL and ~4x for SUPER", () => {
    expect(NORMAL_DRAIN_PER_HOUR).toBeCloseTo(0.15 / 8, 12);
    expect(SUPER_DRAIN_PER_HOUR).toBeCloseTo((0.15 / 8) * 4, 12);
    const normal = makeNode("n", 0, 0, { role: "NORMAL", battery: 1 });
    batteryDrain(normal, 8 * 3600, 1);
    expect(normal.battery).toBeCloseTo(0.85, 6);
    const dead = makeNode("d", 0, 0, { role: "NORMAL", battery: 0.001 });
    batteryDrain(dead, 8 * 3600, 1);
    expect(dead.battery).toBe(0);
    const plugged = makeNode("c", 0, 0, { charging: true, battery: 0.9 });
    batteryDrain(plugged, 3600, 1);
    expect(plugged.battery).toBeGreaterThan(0.9);
  });
});

describe("coverage score (docs/03 §3)", () => {
  const rf = rfWith();

  function ring(count: number, radius = 12): MeshNode[] {
    const centre = makeNode("centre", 50, 50);
    const peers: MeshNode[] = [];
    for (let i = 0; i < count; i++) {
      const a = (i / count) * Math.PI * 2;
      peers.push(makeNode(`p${i}`, 50 + Math.cos(a) * radius, 50 + Math.sin(a) * radius));
    }
    return [centre, ...peers];
  }

  it("applies the documented weights exactly", () => {
    const nodes = ring(8);
    const centre = nodes[0];
    centre.battery = 0.8;
    centre.uptimeMin = 120;
    centre.mobility = 0;
    centre.pdr = 0.9;
    centre.charging = false;

    const peers = peersInRange(centre, nodes, rf);
    let sum = 0;
    for (const p of peers) sum += rssiModel(centre, p, rf);
    const expected =
      WEIGHTS.peers * (Math.log(1 + peers.length) / Math.log(51)) +
      WEIGHTS.rssi * normRssi(sum / peers.length) +
      WEIGHTS.battery * 0.8 +
      WEIGHTS.stability * (Math.min(120 / 60, 1) * 1) +
      WEIGHTS.pdr * 0.9;

    expect(computeScore(centre, nodes, rf)).toBeCloseTo(expected, 12);
  });

  it("adds the charging bonus and caps at 1", () => {
    const nodes = ring(10, 8);
    const centre = nodes[0];
    centre.battery = 1;
    centre.uptimeMin = 600;
    centre.mobility = 0;
    centre.pdr = 1;
    const plain = computeScore(centre, nodes, rf);
    centre.charging = true;
    const boosted = computeScore(centre, nodes, rf);
    expect(boosted).toBeGreaterThan(plain);
    expect(boosted).toBeLessThanOrEqual(1);
  });

  it("scores 0 when isolated or below the battery floor", () => {
    const lone = makeNode("lone", 0, 0);
    expect(computeScore(lone, [lone], rf)).toBe(0);
    const nodes = ring(6);
    nodes[0].battery = 0.24;
    expect(computeScore(nodes[0], nodes, rf)).toBe(0);
    nodes[0].battery = 0.25;
    expect(computeScore(nodes[0], nodes, rf)).toBeGreaterThan(0);
  });

  it("penalises mobility through the stability term", () => {
    const nodes = ring(6);
    nodes[0].mobility = 0;
    const stable = computeScore(nodes[0], nodes, rf);
    nodes[0].mobility = 0.8;
    const restless = computeScore(nodes[0], nodes, rf);
    expect(restless).toBeLessThan(stable);
  });
});

describe("super-node election (docs/03 §3-5, skills/02)", () => {
  const rf = rfWith();

  function cluster(n: number, over: Partial<MeshNode> = {}): MeshNode[] {
    const nodes = [makeNode("me", 50, 50, over)];
    for (let i = 0; i < n; i++) {
      const a = (i / n) * Math.PI * 2;
      nodes.push(makeNode(`p${i}`, 50 + Math.cos(a) * 12, 50 + Math.sin(a) * 12));
    }
    return nodes;
  }

  it("refuses to promote a node with fewer than 3 peers", () => {
    const nodes = cluster(2, { score: 0.95, battery: 1, uptimeMin: 600 });
    const out = electRole(nodes[0], nodes, rf);
    expect(out.role).toBe("NORMAL");
    expect(out.reason).toMatch(/Too few peers/);
  });

  it("refuses to promote below the 25% battery floor", () => {
    const nodes = cluster(6, { score: 0.95, battery: 0.2 });
    const out = electRole(nodes[0], nodes, rf);
    expect(out.role).toBe("NORMAL");
    expect(out.reason).toMatch(/Battery/);
  });

  it("promotes above 0.60 when ranked in the top 20%", () => {
    const nodes = cluster(6, { score: 0.75 });
    for (const p of nodes.slice(1)) p.score = 0.3;
    const out = electRole(nodes[0], nodes, rf);
    expect(out.role).toBe("SUPER");
    expect(out.reason).toMatch(/Promoted/);
  });

  it("does not promote above 0.60 when outranked by the neighbourhood", () => {
    const nodes = cluster(9, { score: 0.61 });
    for (const p of nodes.slice(1)) p.score = 0.9;
    const out = electRole(nodes[0], nodes, rf);
    expect(out.role).toBe("NORMAL");
    expect(out.reason).toMatch(/NORMAL/);
  });

  it("needs two consecutive low cycles to demote (hysteresis)", () => {
    const nodes = cluster(6, { role: "SUPER", score: 0.4 });
    for (const p of nodes.slice(1)) p.score = 0.1;
    const first = electRole(nodes[0], nodes, rf);
    expect(first.role).toBe("SUPER");
    expect(first.reason).toMatch(/pending demote 1\/2/);
    const second = electRole(nodes[0], nodes, rf);
    expect(second.role).toBe("NORMAL");
    expect(second.reason).toMatch(/Demoted/);
    expect(nodes[0].demoteCounter).toBe(0);
  });

  it("backs off when a clearly better SUPER is very close (30 m guard)", () => {
    const nodes = cluster(6, { role: "SUPER", score: 0.7 });
    const rival = makeNode("rival", 51.5, 50, { role: "SUPER", score: 0.95 });
    nodes.push(rival);
    const out = electRole(nodes[0], nodes, rf);
    expect(out.role).toBe("NORMAL");
    expect(out.reason).toMatch(/Backed off/);
  });

  it("does not back off from a distant SUPER", () => {
    const nodes = cluster(6, { role: "SUPER", score: 0.7 });
    // 25 m away: reachable, but outside the ~30 m "one SUPER per radius" guard
    // only if the guard radius is smaller; assert the guard does not fire for a
    // peer whose score is not clearly better.
    const rival = makeNode("rival", 50, 50, { role: "SUPER", score: 0.72 });
    nodes[0].pos = { x: 50, y: 50 };
    rival.pos = { x: 75, y: 50 };
    nodes.push(rival);
    const out = electRole(nodes[0], nodes, rf);
    expect(out.role).toBe("SUPER");
  });
});

describe("OGM handling (docs/03 §4, §7)", () => {
  it("advertises score, role, peer count and best hops", () => {
    const n = makeNode("a", 0, 0, { score: 0.7, role: "SUPER", peerCount: 9, battery: 0.42, seq: 5 });
    n.nextHopTable["z"] = {
      bestNeighbor: "b", tq: 0.9, lastSeq: 3, hopCount: 2, lastSeen: 0, window: [1], windowNeighbor: "b",
    };
    const ogm = buildOGM(n);
    expect(ogm).toMatchObject({ nodeId: "a", seq: 5, score: 0.7, isSuper: true, peerCount: 9, hopCount: 0 });
    expect(ogm.batteryBucket).toBe(4);
    expect(ogm.bestHopTo["z"]).toBe(2);
  });

  it("records hop distance from the beacon, not from the sender's role", () => {
    const me = makeNode("me", 0, 0);
    const ogm = { ...buildOGM(makeNode("x", 0, 0, { role: "NORMAL", seq: 1 })), hopCount: 2 };
    receiveOGM(me, ogm, "relay-1", 1000);
    expect(me.nextHopTable["x"].hopCount).toBe(3);
    expect(me.nextHopTable["x"].bestNeighbor).toBe("relay-1");
  });

  it("ignores stale sequence numbers but still refreshes liveness", () => {
    const me = makeNode("me", 0, 0);
    const origin = makeNode("x", 0, 0);
    origin.seq = 10;
    receiveOGM(me, buildOGM(origin), "x", 1000);
    const fresh = me.nextHopTable["x"];
    origin.seq = 9;
    const gossiped = receiveOGM(me, buildOGM(origin), "x", 2000);
    expect(gossiped).toBe(false);
    expect(me.nextHopTable["x"].lastSeq).toBe(fresh.lastSeq);
    expect(me.nextHopTable["x"].lastSeen).toBe(2000);
  });

  it("builds transmit quality over a sliding window", () => {
    const me = makeNode("me", 0, 0);
    const origin = makeNode("x", 0, 0);
    for (let seq = 1; seq <= 8; seq++) {
      origin.seq = seq;
      receiveOGM(me, buildOGM(origin), "x", seq * 1000);
    }
    expect(me.nextHopTable["x"].tq).toBe(1);
    // A gap of 4 sequence numbers means 3 missed beacons.
    origin.seq = 12;
    receiveOGM(me, buildOGM(origin), "x", 12000);
    expect(me.nextHopTable["x"].tq).toBeLessThan(1);
    expect(me.nextHopTable["x"].window.length).toBeLessThanOrEqual(32);
  });

  it("learns routes to nodes it has never heard a beacon from", () => {
    const me = makeNode("me", 0, 0);
    const origin = makeNode("x", 0, 0, { seq: 1 });
    const ogm = buildOGM(origin);
    ogm.bestHopTo["far-away"] = 2;
    receiveOGM(me, ogm, "x", 1000);
    expect(me.nextHopTable["far-away"].hopCount).toBe(3);
    expect(me.nextHopTable["far-away"].bestNeighbor).toBe("x");
  });

  it("decrements the gossip budget and stops at the TTL", () => {
    const ogm = { ...buildOGM(makeNode("x", 0, 0)), hopCount: 3 };
    expect(ogmToGossip(ogm, 5)?.hopCount).toBe(4);
    expect(ogmToGossip({ ...ogm, hopCount: 4 }, 5)).toBeNull();
  });

  it("expires soft state that has not been refreshed", () => {
    const me = makeNode("me", 0, 0);
    const origin = makeNode("x", 0, 0, { seq: 1 });
    receiveOGM(me, buildOGM(origin), "x", 1000);
    pruneStaleEntries(me, 1000, 30000);
    expect(me.nextHopTable["x"]).toBeDefined();
    pruneStaleEntries(me, 40000, 30000);
    expect(me.nextHopTable["x"]).toBeUndefined();
    expect(me.ogmTable["x"]).toBeUndefined();
  });

  it("only offers a next hop whose tq is usable", () => {
    const me = makeNode("me", 0, 0);
    me.nextHopTable["good"] = { bestNeighbor: "b", tq: 0.6, lastSeq: 1, hopCount: 1, lastSeen: 0, window: [], windowNeighbor: "b" };
    me.nextHopTable["bad"] = { bestNeighbor: "c", tq: 0.59, lastSeq: 1, hopCount: 1, lastSeen: 0, window: [], windowNeighbor: "c" };
    expect(getNextHop(me, "good")).toBe("b");
    expect(getNextHop(me, "bad")).toBeNull();
    expect(getNextHop(me, "unknown")).toBeNull();
  });
});

describe("data plane (docs/03 §6, §8)", () => {
  const rf = rfWith();

  it("selects transport by payload size", () => {
    expect(selectTransport(512)).toBe("ble");
    expect(selectTransport(1024)).toBe("ble");
    expect(selectTransport(1025)).toBe("wifiDirect");
    expect(createMessage("m1", 0, "a", "b", "x".repeat(400), "text").transport).toBe("wifiDirect");
  });

  it("creates routable, encrypted, attempt-zero messages", () => {
    const m = createMessage("m1", 1234, "a", "b", "hello", "text", 5, "normal");
    expect(m).toMatchObject({ id: "m1", from: "a", to: "b", ttl: 5, hopCount: 0, attempt: 0, encrypted: true, timestamp: 1234 });
    expect(m.destHint).toMatch(/^[0-9a-f]{1,8}$/);
    expect(createMessage("m2", 0, "a", "BROADCAST", "hi", "broadcast").destHint).toBe("broadcast");
    expect(createMessage("m3", 0, "a", "BROADCAST", "hi", "broadcast").encrypted).toBe(false);
  });

  it("dedups on (id, attempt) so a source retry can travel again", () => {
    const n = makeNode("n", 0, 0);
    const m = createMessage("m1", 0, "a", "b", "hi");
    expect(seenKey(m)).toBe("m1#0");
    markSeen(n, seenKey(m), 0);
    expect(isSeen(n, seenKey(m))).toBe(true);
    expect(isSeen(n, seenKey({ ...m, attempt: 1 }))).toBe(false);
  });

  it("expires the seen cache on simulation time", () => {
    const n = makeNode("n", 0, 0);
    markSeen(n, "old", 0);
    markSeen(n, "new", SEEN_CACHE_TTL_MS);
    pruneSeenCache(n, SEEN_CACHE_TTL_MS + 1);
    expect(isSeen(n, "old")).toBe(false);
    expect(isSeen(n, "new")).toBe(true);
  });

  it("sends directly when the destination is a neighbour", () => {
    const a = makeNode("a", 0, 0);
    const b = makeNode("b", 10, 0);
    const d = decideForward(a, createMessage("m", 0, "a", "b", "hi"), [a, b], rf, true);
    expect(d.mode).toBe("direct");
    expect(d.targets).toEqual(["b"]);
  });

  it("uses a known route instead of flooding", () => {
    const a = makeNode("a", 0, 0);
    const relay = makeNode("r", 10, 0);
    const far = makeNode("f", 90, 0);
    a.nextHopTable["f"] = { bestNeighbor: "r", tq: 0.9, lastSeq: 1, hopCount: 2, lastSeen: 0, window: [], windowNeighbor: "r" };
    const d = decideForward(a, createMessage("m", 0, "a", "f", "hi"), [a, relay, far], rf, true);
    expect(d.mode).toBe("route");
    expect(d.targets).toEqual(["r"]);
  });

  it("relays immediately when SUPER, waits 300 ms when NORMAL", () => {
    const a = makeNode("a", 0, 0, { role: "SUPER" });
    const peers = [a, makeNode("b", 10, 0), makeNode("c", 0, 10)];
    const msg = createMessage("m", 0, "a", "far", "hi");
    expect(decideForward(a, msg, peers, rf, true).mode).toBe("flood");
    a.role = "NORMAL";
    expect(decideForward(a, msg, peers, rf, true).mode).toBe("wait-mpr");
    // flood-all baseline never waits
    expect(decideForward(a, msg, peers, rf, false).mode).toBe("flood");
  });

  it("queues for store-carry-forward when nobody is in range", () => {
    const a = makeNode("a", 0, 0);
    const far = makeNode("f", 500, 500);
    const d = decideForward(a, createMessage("m", 0, "a", "f", "hi"), [a, far], rf, true);
    expect(d.mode).toBe("queue");
    expect(d.targets).toEqual([]);
  });

  it("suppresses a NORMAL relay that overheard a SUPER retransmission", () => {
    const a = makeNode("a", 0, 0);
    const peers = [a, makeNode("b", 10, 0)];
    const msg = createMessage("m", 0, "x", "far", "hi");
    expect(resolveMprWait(a, msg, peers, rf).mode).toBe("flood");
    a.mprHeardSuper.add(msg.id);
    const out = resolveMprWait(a, msg, peers, rf);
    expect(out.mode).toBe("drop");
    expect(a.mprSuppressed).toBe(1);
  });

  it("caps the OppQueue at the spray-and-wait limit and expires bundles", () => {
    const a = makeNode("a", 0, 0);
    const dest = makeNode("d", 500, 500);
    const msg = createMessage("m", 0, "a", "d", "hi");
    expect(enqueueOpp(a, msg, 0)).toBe(true);
    expect(enqueueOpp(a, msg, 0)).toBe(false); // dedup
    expect(a.oppQueue).toHaveLength(1);
    expect(enqueueOpp(a, createMessage("b1", 0, "a", "BROADCAST", "hi"), 0)).toBe(false);

    pruneOppQueue(a, OPP_TTL_MS - 1);
    expect(a.oppQueue).toHaveLength(1);
    pruneOppQueue(a, OPP_TTL_MS + 1);
    expect(a.oppQueue).toHaveLength(0);

    // spray limit
    enqueueOpp(a, createMessage("m2", 0, "a", "d", "hi"), 0);
    const relay = makeNode("r", 10, 0);
    a.nextHopTable["d"] = { bestNeighbor: "r", tq: 1, lastSeq: 1, hopCount: 2, lastSeen: 0, window: [], windowNeighbor: "r" };
    const forwarded: number[] = [];
    for (let i = 0; i < SPRAY_LIMIT + 3; i++) {
      const res = scanOppQueue(a, [a, relay, dest], rf, 1000 + i);
      forwarded.push(res.forward.length);
      a.oppQueue = res.keep;
    }
    expect(forwarded.slice(0, SPRAY_LIMIT)).toEqual([1, 1, 1]);
    expect(forwarded.slice(SPRAY_LIMIT)).toEqual([0, 0, 0]);
    // docs/03 §8: kept, but demoted to low priority once the budget is spent
    expect(a.oppQueue).toHaveLength(1);
    expect(a.oppQueue[0].copyCount).toBe(SPRAY_LIMIT);
    expect(a.oppQueue[0].msg.priority).toBe("low");
  });

  it("delivers a queued bundle as soon as the destination comes into range", () => {
    const a = makeNode("a", 0, 0);
    const d = makeNode("d", 500, 500);
    enqueueOpp(a, createMessage("m", 0, "a", "d", "hi"), 0);
    expect(scanOppQueue(a, [a, d], rf, 1000).deliver).toHaveLength(0);
    d.pos = { x: 8, y: 0 };
    const res = scanOppQueue(a, [a, d], rf, 2000);
    expect(res.deliver).toHaveLength(1);
    expect(res.deliver[0].msg.to).toBe("d");
  });
});

describe("helper sanity", () => {
  it("randRange stays within bounds", () => {
    const rng = createRng(3);
    for (let i = 0; i < 1000; i++) {
      const v = randRange(rng, 50, 200);
      expect(v).toBeGreaterThanOrEqual(50);
      expect(v).toBeLessThan(200);
    }
  });
});
