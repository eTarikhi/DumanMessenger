/**
 * Group history anti-entropy probe (roadmap Phase 1, docs/06 §17).
 *
 * Mirrors `dart run bin/mesh_sim.dart --history`: the same world twice, once with
 * repair switched off, because "the member eventually caught up" only means something
 * against "without beacons it never does".
 *
 *   npm run history
 */
import {
  MeshSimulation,
  encodeHistoryBeacon,
  historyDigest,
  type SimConfig,
} from "../src/simulation";
import { campusQuad } from "../src/scenarios";
import { canReach } from "../src/rf";
import { selectTransport, wireSizeOf } from "../src/routing";
import type { Group, MeshNode, NodeId } from "../src/types";

const MEMBERS = 5;
const MESSAGES = 20;

interface RunResult {
  held: number;
  recovered: number;
  converged: boolean;
  seconds: number | null;
  beacons: number;
  requests: number;
  replies: number;
  packets: number;
  bytes: number;
  dropped: number;
  /** Member pairs that can hear each other, and whether that graph is connected. */
  peerEdges: number;
  peerConnected: boolean;
}

/**
 * How much of the membership can actually talk to how much of it.
 *
 * Anti-entropy is peer-to-peer by design, so the graph it repairs over is "who can hear
 * whom", not "who is in the group". A membership spread beyond radio range is not one
 * reconciliation problem but several, and no protocol that refuses to flood can bridge
 * them (docs/06 §17).
 */
function peerGraph(sim: MeshSimulation, ids: NodeId[]): { edges: number; connected: boolean } {
  const byId = new Map<string, MeshNode>(sim.nodes.map((n) => [n.id, n]));
  let edges = 0;
  const adj = new Map<NodeId, NodeId[]>();
  for (const a of ids) {
    adj.set(a, []);
    for (const b of ids) {
      if (a === b) continue;
      const na = byId.get(a);
      const nb = byId.get(b);
      if (na && nb && canReach(na, nb, sim.rf)) {
        edges++;
        adj.get(a)!.push(b);
      }
    }
  }
  const seen = new Set<NodeId>([ids[0]]);
  const queue = [ids[0]];
  while (queue.length > 0) {
    const n = queue.shift()!;
    for (const p of adj.get(n) ?? []) {
      if (!seen.has(p)) {
        seen.add(p);
        queue.push(p);
      }
    }
  }
  return { edges, connected: seen.size === ids.length };
}

/** Five members, spread across the world by default so a flood has to cross hops rather
 *  than fall out of one radio cell — or `close`, the 5 nearest nodes, for a membership
 *  that can actually hear itself. */
function groupWorld(
  config: SimConfig,
  close = false
): { sim: MeshSimulation; group: Group; ids: NodeId[] } {
  const sim = new MeshSimulation({ ...config, captureLog: true });
  sim.runFor(90000);
  sim.clearRecords();
  const online = sim.nodes.filter((n) => n.isOnline);
  const cx = online.reduce((a, n) => a + n.pos.x, 0) / online.length;
  const cy = online.reduce((a, n) => a + n.pos.y, 0) / online.length;
  const d2 = (n: { pos: { x: number; y: number } }) => (n.pos.x - cx) ** 2 + (n.pos.y - cy) ** 2;
  let ids: NodeId[];
  if (close) {
    // The most central node and its four nearest neighbours: a membership that can
    // hear itself, which is the case the protocol is actually able to converge.
    const centre = [...online].sort((a, b) => d2(a) - d2(b))[0];
    ids = [centre.id];
    for (const n of [...online].sort(
      (a, b) =>
        (a.pos.x - centre.pos.x) ** 2 +
        (a.pos.y - centre.pos.y) ** 2 -
        ((b.pos.x - centre.pos.x) ** 2 + (b.pos.y - centre.pos.y) ** 2)
    )) {
      if (ids.length >= MEMBERS) break;
      if (!ids.includes(n.id)) ids.push(n.id);
    }
  } else {
    const ranked = [...online].sort((a, b) => d2(b) - d2(a));
    const step = Math.max(1, Math.floor(ranked.length / MEMBERS));
    ids = [];
    for (let i = 0; i < ranked.length && ids.length < MEMBERS; i++) {
      const id = ranked[(i * step) % ranked.length].id;
      if (!ids.includes(id)) ids.push(id);
    }
  }
  const group = sim.createGroup("field team", ids, ids[0]);
  if (!group) throw new Error("could not form a group");
  return { sim, group, ids };
}

function run(base: SimConfig, repair: boolean, close = false): RunResult {
  const { sim, group, ids } = groupWorld(
    { ...base, trafficIntervalMs: 0, historyBeaconMs: repair ? base.historyBeaconMs : 0 },
    close
  );
  const graph = peerGraph(sim, ids);
  const away = ids[ids.length - 1];

  sim.toggleNodeOnline(away); // out of range for the whole conversation
  for (let i = 0; i < MESSAGES; i++) {
    sim.sendMessage(ids[0], group.id, `status ${i}`);
    sim.runFor(1500);
  }
  sim.runFor(2000);
  const held = sim.groupHistoryOf(ids[0], group.id).length;

  sim.toggleNodeOnline(away);
  const from = sim.now;
  let converged = false;
  let elapsed = 0;
  while (elapsed < 300000) {
    sim.runFor(250);
    elapsed += 250;
    if (sim.historyConverged(group)) {
      converged = true;
      break;
    }
  }
  const stats = sim.refresh();
  return {
    held,
    recovered: sim.groupHistoryOf(away, group.id).length,
    converged,
    seconds: converged ? (sim.now - from) / 1000 : null,
    beacons: stats.historyBeacons,
    requests: stats.historyRequests,
    replies: stats.historyReplies,
    packets: stats.sentSync,
    bytes: stats.historyBytes,
    dropped: stats.historyEpochDropped,
    peerEdges: graph.edges,
    peerConnected: graph.connected,
  };
}

/** What the beacons cost when nobody is repairing anything. */
function idleCost(
  base: SimConfig,
  seconds: number,
  close = false
): { beacons: number; bytes: number; perMin: number } {
  const { sim } = groupWorld({ ...base, trafficIntervalMs: 0 }, close);
  sim.clearRecords();
  sim.runFor(seconds * 1000);
  const stats = sim.refresh();
  return {
    beacons: stats.historyBeacons,
    bytes: stats.historyBytes,
    perMin: (stats.historyBeacons / seconds) * 60,
  };
}

function main(): void {
  const base = campusQuad(42);
  const beacon = encodeHistoryBeacon("grp-1", 0, historyDigest([]));
  console.log("Group history anti-entropy — measured, not assumed.");
  console.log(
    `A beacon is ${beacon.length} characters -> ${wireSizeOf(beacon.length)} B on the wire ` +
      `(${selectTransport(wireSizeOf(beacon.length))}), constant in the size of the history.`
  );

  for (const close of [false, true]) {
    const label = close ? "a membership that can hear itself (5 nearest nodes)" : "spread across the world";
    const off = run(base, false, close);
    const on = run(base, true, close);
    console.log(
      `\n=== ${MEMBERS} members ${label}, ${MESSAGES} messages, one member out of range for all of them ===`
    );
    console.log(
      `member peer graph    ${on.peerEdges} of ${MEMBERS * (MEMBERS - 1)} directed links can carry a beacon, ` +
        `connected=${on.peerConnected}`
    );
    console.log(`the sender held      ${on.held} entries (the absent member missed all of them)`);
    console.log(
      `without repair       ${off.recovered} recovered, converged=${off.converged} — a missed flood is missed for good`
    );
    console.log(
      `with repair          ${on.recovered}/${on.held} recovered, converged=${on.converged} in ` +
        `${on.seconds === null ? ">300 s" : `${on.seconds.toFixed(1)} s`} ` +
        `(${on.replies} bounded rounds, ${on.dropped} dropped as unreadable)`
    );
    console.log(
      `radio cost           ${on.beacons} beacons, ${on.requests} requests, ${on.replies} replies = ` +
        `${on.packets} packets, ${on.bytes} payload bytes`
    );
  }

  const idle = idleCost(base, 120);
  console.log(
    `\n=== what it costs when there is nothing to repair ===\n` +
      `${idle.beacons} beacons in 120 s (${idle.perMin.toFixed(1)}/min for ${MEMBERS} members), ` +
      `${idle.bytes} payload bytes — ${(idle.bytes / 120).toFixed(0)} B/s of background traffic`
  );
  console.log(
    "For scale: a 20-node campus sends ~2.8k relay transmissions in 300 s of ordinary traffic,\n" +
      "so a five-member group's beacons are noise next to the routing plane they ride on."
  );
  console.log(
    "\nBeacons go to co-members in range and nowhere else, so what anti-entropy repairs is the\n" +
      "last hop of a loss — a member that was asleep, out of range or switched off. It cannot\n" +
      "bridge a membership that cannot hear itself: that is the scoped flood's job, and the\n" +
      "spread arm above is the measurement of where the two responsibilities meet."
  );
}

main();
