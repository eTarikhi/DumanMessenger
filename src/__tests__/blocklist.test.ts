/**
 * `docs/04` §6, first bullet: *"Block/mute peer locally (ignore msgs from pubKey)."*
 *
 * There is no moderation server, so a block is one device's decision about what its own
 * user sees. Three properties make it that and not something worse:
 *
 * 1. **It is local.** The list never leaves the device, and blocking somebody never
 *    changes what anybody else receives — under the default `blockScope: "delivery"`.
 * 2. **It filters user traffic, not the protocol.** Control plane and SOS are exempt,
 *    because blocking an ACK makes the blocked peer retransmit (more airtime, the opposite
 *    of the point) and blocking an OGM removes the peer from the blocker's routing table,
 *    which is a routing change disguised as a privacy setting.
 * 3. **It is inert while empty**, so no shipped run and no golden vector moves.
 *
 * `blockScope: "relay"` is the other reading of §6 — its battery-drain bullet says
 * *"ignore floods"*, and a blocker that keeps paying airtime for someone it blocked is not
 * ignoring anything. It is measured against the default in `docs/06` §22 rather than
 * asserted better.
 */
import { describe, expect, it } from "vitest";
import {
  isBlockableTraffic,
  countsAgainstRelayCap,
  createMessage,
} from "../routing";
import { MeshSimulation } from "../simulation";
import { campusQuad } from "../scenarios";
import type { MsgType } from "../types";

/** A settled world: elections done, so roles and routes are stable before the test acts. */
function world(scope: "delivery" | "relay" = "delivery") {
  const sim = new MeshSimulation({ ...campusQuad(42), blockScope: scope });
  sim.runFor(60_000);
  sim.refresh();
  return sim;
}

const from = (sim: MeshSimulation, id: string) =>
  sim.nodes.filter((n) => n.inbox.some((m) => m.from === id)).length;

describe("isBlockableTraffic", () => {
  const msg = (type: MsgType) => createMessage("m", 0, "a", "b", "", type);

  it("covers exactly the traffic a user would call harassment", () => {
    for (const type of ["text", "broadcast", "voice", "file"] as MsgType[]) {
      expect(isBlockableTraffic(msg(type)), type).toBe(true);
    }
  });

  it("exempts control plane, because blocking it costs airtime instead of saving it", () => {
    for (const type of ["ogm", "ack", "sync"] as MsgType[]) {
      expect(isBlockableTraffic(msg(type)), type).toBe(false);
    }
  });

  it("exempts SOS, which docs/04 §6 gives its own two mechanisms instead", () => {
    expect(isBlockableTraffic(msg("sos"))).toBe(false);
    // SOS is still user traffic for the relay cap's purposes, so the two predicates are
    // not the same set — which is the point of having both.
    expect(countsAgainstRelayCap(msg("sos"))).toBe(true);
  });
});

describe("the blocklist itself", () => {
  it("is off by default and inert while empty", () => {
    const config = campusQuad(42);
    expect(config.blockScope).toBe("delivery");
    const sim = world();
    sim.runFor(60_000);
    sim.refresh();
    expect(sim.stats.blockedDrops).toBe(0);
  });

  it("blocks, unblocks, refuses a self-block, and reports the list sorted", () => {
    const sim = world();
    const [a, b, c] = sim.nodes.map((n) => n.id);
    expect(sim.blockPeer(a, b)).toBe(true);
    expect(sim.blockPeer(a, b)).toBe(false); // already blocked: the list did not change
    expect(sim.blockPeer(a, a)).toBe(false); // a node cannot block itself
    expect(sim.isBlocked(a, b)).toBe(true);
    expect(sim.isBlocked(b, a)).toBe(false); // and it is not mutual
    sim.blockPeer(a, c);
    expect(sim.blockedPeers(a)).toEqual([b, c].sort());
    expect(sim.unblockPeer(a, b)).toBe(true);
    expect(sim.unblockPeer(a, b)).toBe(false);
    expect(sim.isBlocked(a, b)).toBe(false);
    sim.unblockPeer(a, c);
    expect(sim.blockedPeers(a)).toEqual([]);
  });

  it("keeps a blocked peer's messages out of the blocker's inbox", () => {
    const sim = world();
    const sender = sim.nodes[0].id;
    const blocker = sim.nodes[1].id;
    sim.blockPeer(blocker, sender);
    for (let i = 0; i < 8; i++) {
      sim.sendMessage(sender, "BROADCAST", `spam ${i}`, "broadcast");
      sim.runFor(1_000);
    }
    sim.runFor(20_000);
    sim.refresh();
    const inbox = sim.nodes.find((n) => n.id === blocker)!.inbox;
    expect(inbox.filter((m) => m.from === sender)).toEqual([]);
    expect(sim.stats.blockedDrops).toBeGreaterThan(0);
  });

  it("still lets everybody else hear the blocked peer — blocking is local", () => {
    const sim = world();
    const sender = sim.nodes[0].id;
    const blocker = sim.nodes[1].id;
    sim.blockPeer(blocker, sender);
    for (let i = 0; i < 8; i++) {
      sim.sendMessage(sender, "BROADCAST", `spam ${i}`, "broadcast");
      sim.runFor(1_000);
    }
    sim.runFor(20_000);
    sim.refresh();
    expect(from(sim, sender)).toBeGreaterThan(1);
  });

  it("does not stop the blocker talking to the peer it blocked", () => {
    const sim = world();
    const blocker = sim.nodes[0].id;
    const blocked = sim.nodes[1].id;
    sim.blockPeer(blocker, blocked);
    sim.sendMessage(blocker, blocked, "still allowed to send", "text");
    sim.runFor(30_000);
    sim.refresh();
    const inbox = sim.nodes.find((n) => n.id === blocked)!.inbox;
    expect(inbox.some((m) => m.body === "still allowed to send")).toBe(true);
  });

  it("lets a blocked peer's SOS through, which is the asymmetry §6 relies on", () => {
    const sim = world();
    const sender = sim.nodes[0].id;
    const blocker = sim.nodes[1].id;
    sim.blockPeer(blocker, sender);
    sim.sendMessage(sender, "BROADCAST", "sos help", "sos");
    sim.runFor(30_000);
    sim.refresh();
    const inbox = sim.nodes.find((n) => n.id === blocker)!.inbox;
    expect(inbox.some((m) => m.type === "sos")).toBe(true);
  });

  it("keeps the blocked peer in the routing table, because OGMs are not blockable", () => {
    const sim = world();
    const blockerNode = sim.nodes[1];
    const sender = sim.nodes[0].id;
    sim.blockPeer(blockerNode.id, sender);
    const peersBefore = blockerNode.peerIds.length;
    sim.runFor(30_000);
    sim.refresh();
    expect(blockerNode.peerIds.length).toBeGreaterThan(0);
    // Not a strict equality: peers come and go with mobility. The property is that
    // blocking does not empty the table, which is what filtering OGMs would do.
    expect(blockerNode.peerIds.length).toBeGreaterThanOrEqual(peersBefore - 2);
  });
});

describe("blockScope", () => {
  const flooded = (scope: "delivery" | "relay") => {
    const sim = world(scope);
    const sender = sim.nodes[0].id;
    // Every node blocks the flooder: the worst case for "relay", where the flood dies at
    // the first hop instead of being carried across the mesh.
    for (const n of sim.nodes) if (n.id !== sender) sim.blockPeer(n.id, sender);
    for (let i = 0; i < 24; i++) {
      sim.sendMessage(sender, "BROADCAST", `spam ${i}`, "broadcast");
      sim.runFor(300);
    }
    sim.runFor(20_000);
    sim.refresh();
    return {
      transmissions: sim.nodes.reduce((sum, n) => sum + n.txCount, 0),
      blockedDrops: sim.stats.blockedDrops,
      forwarded: sim.stats.totalForwarded,
    };
  };

  it("costs less airtime when the blocker also refuses to relay", () => {
    const delivery = flooded("delivery");
    const relay = flooded("relay");
    expect(delivery.transmissions).toBeGreaterThan(relay.transmissions);
    expect(delivery.forwarded).toBeGreaterThan(relay.forwarded);
  });

  it("counts fewer suppressions under relay, because the copy dies earlier", () => {
    // One broadcast heard by four blockers is four entries under "delivery"; under
    // "relay" the first one to hear it stops the other three ever hearing it. Neither
    // number is the message count, which is why the log is per node.
    expect(flooded("delivery").blockedDrops).toBeGreaterThan(flooded("relay").blockedDrops);
  });
});
