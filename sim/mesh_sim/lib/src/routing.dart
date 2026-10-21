/// Data plane (docs/03 §6, docs/05 §2.1), mirroring `src/routing.ts`.
///
/// These functions are pure *decisions*: they say what a node should do with a
/// message. `simulation.dart` owns time, link loss and bookkeeping. Keeping the
/// split this way is what makes the routing rules unit-testable — and what makes
/// the TypeScript and Dart engines mechanical translations of one another.
library;

import 'election.dart';
import 'rf.dart';
import 'types.dart';

const double seenCacheTtlMs = 5 * 60 * 1000;
const int seenCacheMax = 5000;
const int oppQueueMax = 500;
const double oppTtlMs = 7 * 24 * 60 * 60 * 1000;
const int sprayLimit = 3;
const double mprWaitDefaultMs = 300;
const int inboxMax = 200;

/// Text < 1 KB rides BLE; larger payloads need Wi-Fi Direct (docs/02 §3.1).
const int bleMaxBytes = 1024;

const String broadcastAddress = 'BROADCAST';

TransportType selectTransport(int sizeBytes) =>
    sizeBytes > bleMaxBytes ? TransportType.wifiDirect : TransportType.ble;

/// Same 32-bit string hash as the TypeScript engine, so `destHint` matches
/// across languages (it appears in golden vectors).
String hashHint(String id) {
  var h = 0;
  for (var i = 0; i < id.length; i++) {
    // (h << 5) - h == h * 31, kept in 32-bit space like JS's `| 0`.
    h = (h * 31 + id.codeUnitAt(i)) & 0xFFFFFFFF;
  }
  if (h >= 0x80000000) h -= 0x100000000;
  final hex = h.abs().toRadixString(16);
  return hex.length > 8 ? hex.substring(0, 8) : hex;
}

/// Dedup key: a source retry must be allowed to travel again.
String seenKey(MeshMessage msg) => '${msg.id}#${msg.attempt}';

/// Build a message. [id] comes from the caller's monotonic counter rather than
/// the wall clock, so identical seeds produce identical message ids in both
/// language implementations.
MeshMessage createMessage(
  String id,
  double nowMs,
  NodeId from,
  String to,
  String body, {
  MsgType type = MsgType.text,
  int ttl = 5,
  Priority priority = Priority.normal,
}) {
  final sizeBytes = 64 + body.length * 4;
  return MeshMessage(
    id: id,
    type: type,
    from: from,
    to: to,
    destHint: to == broadcastAddress ? 'broadcast' : hashHint(to),
    body: body,
    ttl: ttl,
    hopCount: 0,
    attempt: 0,
    carried: false,
    priority: priority,
    timestamp: nowMs,
    encrypted: type != MsgType.broadcast,
    transport: selectTransport(sizeBytes),
    sizeBytes: sizeBytes,
  );
}

// --- dedup cache -------------------------------------------------------------

bool isSeen(MeshNode node, String key) => node.seenCache.containsKey(key);

void markSeen(MeshNode node, String key, double nowMs) {
  if (node.seenCache.length >= seenCacheMax) {
    node.seenCache.remove(node.seenCache.keys.first);
  }
  node.seenCache[key] = nowMs;
}

void pruneSeenCache(MeshNode node, double nowMs) {
  node.seenCache.removeWhere((_, ts) => nowMs - ts > seenCacheTtlMs);
  if (node.mprHeardSuper.length > seenCacheMax) node.mprHeardSuper.clear();
  // Relay evidence is only useful while the message itself is dedup-relevant.
  node.heardRelays.removeWhere((key, _) => !node.seenCache.containsKey(key));
  if (node.heardRelays.length > seenCacheMax) node.heardRelays.clear();
}

// --- delivery ----------------------------------------------------------------

bool deliverToInbox(MeshNode node, MeshMessage msg) {
  for (final m in node.inbox) {
    if (m.id == msg.id) return false;
  }
  node.inbox.add(msg.copyWith());
  if (node.inbox.length > inboxMax) node.inbox.removeAt(0);
  return true;
}

// --- store-carry-forward (DTN) ----------------------------------------------

bool enqueueOpp(MeshNode node, MeshMessage msg, double nowMs) {
  if (msg.to == broadcastAddress) return false; // broadcasts are not queued
  for (final q in node.oppQueue) {
    if (q.msg.id == msg.id) return false;
  }
  if (node.oppQueue.length >= oppQueueMax) {
    node.oppQueue.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    node.oppQueue.removeAt(0);
  }
  // Opportunistic from here on: the bundle waits for a contact rather than being
  // routed, so its end-to-end latency is a meeting time, not a transport time.
  // Marking the *stored copy* keeps the flag with the object that is eventually
  // forwarded or handed to the destination.
  node.oppQueue.add(QueuedMessage(
    msg: msg.copyWith(carried: true),
    createdAt: nowMs,
    copyCount: 0,
    ttlMs: oppTtlMs,
  ));
  return true;
}

/// Drop expired bundles. [nowMs] is simulation time, so a 7-day TTL is real.
void pruneOppQueue(MeshNode node, double nowMs) {
  node.oppQueue.removeWhere((q) => nowMs - q.createdAt > q.ttlMs);
}

enum ForwardMode { direct, route, flood, waitMpr, queue, drop }

class ForwardDecision {
  const ForwardDecision(this.mode, this.targets, this.reason);

  final ForwardMode mode;
  final List<NodeId> targets;
  final String reason;
}

/// Decide how [node] should forward [msg].
///
/// Rules, in order (docs/03 §6):
///   1. destination is a neighbour          -> unicast, no wait
///   2. a route with tq >= 0.6 is known     -> unicast to best neighbour
///   3. SUPER                               -> flood immediately
///   4. NORMAL under the MPR policy         -> wait 300 ms for a SUPER
///   5. nobody in range                     -> OppQueue (store-carry-forward)
ForwardDecision decideForward(
  MeshNode node,
  MeshMessage msg,
  List<MeshNode> allNodes,
  RfParams rf,
  bool mprEnabled,
) {
  final peers = peersInRange(node, allNodes, rf);
  if (peers.isEmpty) {
    return const ForwardDecision(ForwardMode.queue, <NodeId>[], 'no peers in range');
  }

  final peerIds = peers.map((p) => p.id).toList();

  if (msg.to != broadcastAddress) {
    if (peerIds.contains(msg.to)) {
      return ForwardDecision(
          ForwardMode.direct, <NodeId>[msg.to], 'destination in range');
    }
    final nextHop = getNextHop(node, msg.to);
    if (nextHop != null && peerIds.contains(nextHop)) {
      return ForwardDecision(
          ForwardMode.route, <NodeId>[nextHop], 'route via $nextHop');
    }
  }

  // Flood branch: SUPER relays everything, NORMAL applies MPR suppression.
  if (node.role == Role.superNode || !mprEnabled) {
    return ForwardDecision(
        ForwardMode.flood,
        peerIds,
        node.role == Role.superNode ? 'SUPER relay-all' : 'flood-all policy');
  }
  return ForwardDecision(ForwardMode.waitMpr, peerIds,
      'NORMAL waiting 300ms for SUPER');
}

/// Apply the MPR decision once the 300 ms wait has elapsed.
///
/// docs/03 §6 says: "wait 300 ms; if no retransmit from SUPER heard: forward".
/// Taken literally that is unsafe, because hearing a SUPER says nothing about
/// whether that SUPER reaches *this node's* neighbours — measured on a 60-node
/// crowd it cut relays by 68-79 % but cost 16-29 points of delivery.
///
/// docs/01 and docs/03 §1 define MPR properly as a relay set "covering 2-hop
/// neighbors", so suppression is gated on coverage: stay quiet only when the
/// neighbours already heard from cover every 1-hop neighbour. Otherwise forward.
/// Same overhead win where coverage genuinely overlaps, no holes where it does
/// not.
ForwardDecision resolveMprWait(
  MeshNode node,
  MeshMessage msg,
  List<MeshNode> allNodes,
  RfParams rf,
) {
  final peers = peersInRange(node, allNodes, rf);
  if (peers.isEmpty) {
    return const ForwardDecision(ForwardMode.queue, <NodeId>[], 'no peers in range');
  }
  if (relaysCoverPeers(node, seenKey(msg))) {
    node.mprSuppressed++;
    return const ForwardDecision(ForwardMode.drop, <NodeId>[],
        'MPR: heard relays cover all my neighbours');
  }
  final heardSuper = node.mprHeardSuper.contains(msg.id);
  return ForwardDecision(
      ForwardMode.flood,
      peers.map((p) => p.id).toList(),
      heardSuper
          ? 'MPR fallback: SUPER heard but my neighbours are not covered'
          : 'MPR fallback: no relay heard');
}

/// Spray-and-wait over the OppQueue when peers are discovered (docs/03 §8).
class OppScanResult {
  OppScanResult();

  final List<QueuedMessage> deliver = <QueuedMessage>[];
  final List<OppForward> forward = <OppForward>[];
  final List<QueuedMessage> keep = <QueuedMessage>[];
}

class OppForward {
  const OppForward(this.queued, this.to);

  final QueuedMessage queued;
  final NodeId to;
}

OppScanResult scanOppQueue(
  MeshNode node,
  List<MeshNode> allNodes,
  RfParams rf,
  double nowMs,
) {
  final result = OppScanResult();
  for (final queued in node.oppQueue) {
    if (nowMs - queued.createdAt > queued.ttlMs) continue; // expired
    final dest = queued.msg.to;
    if (dest == broadcastAddress) {
      result.keep.add(queued);
      continue;
    }
    MeshNode? destNode;
    for (final n in allNodes) {
      if (n.id == dest) {
        destNode = n;
        break;
      }
    }
    if (destNode != null && destNode.isOnline && canReach(node, destNode, rf)) {
      result.deliver.add(queued);
      continue;
    }
    final nextHop = getNextHop(node, dest);
    MeshNode? neighbor;
    if (nextHop != null) {
      for (final n in allNodes) {
        if (n.id == nextHop) {
          neighbor = n;
          break;
        }
      }
    }
    if (nextHop != null &&
        neighbor != null &&
        neighbor.isOnline &&
        canReach(node, neighbor, rf)) {
      if (queued.copyCount < sprayLimit) {
        result.forward.add(OppForward(queued, nextHop));
        queued.copyCount++;
        // docs/03 §8: "if copyCount == 3: keep but lower priority". The bundle
        // stays so it can still be handed straight to the destination later;
        // only the copying stops.
        if (queued.copyCount >= sprayLimit) {
          queued.msg = queued.msg.copyWith(priority: Priority.low);
        }
      }
      result.keep.add(queued);
      continue;
    }
    result.keep.add(queued);
  }
  return result;
}
