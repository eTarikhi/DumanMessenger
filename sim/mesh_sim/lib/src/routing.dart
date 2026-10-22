/// Data plane (docs/03 §6, docs/05 §2.1), mirroring `src/routing.ts`.
///
/// These functions are pure *decisions*: they say what a node should do with a
/// message. `simulation.dart` owns time, link loss and bookkeeping. Keeping the
/// split this way is what makes the routing rules unit-testable — and what makes
/// the TypeScript and Dart engines mechanical translations of one another.
library;

import 'dart:math' as math;

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

/// Padding block, per `skills/03`: "DO pad to 256B blocks".
const int padBlockBytes = 256;

/// Everything around the body in one encrypted packet, from `skills/03`'s layout:
/// `header {msgId16, ttl, type, destHint8, hop}` = 27 B, `aead {nonce12, tag16}` =
/// 28 B, and inside the ciphertext `from` 32 B + `ts` 8 B. 95 B before the body.
const int packetOverheadBytes = 27 + 12 + 16 + 32 + 8;

/// Wire size of one message, in bytes, as the transport selector sees it.
///
/// This used to be a `64 + 4 bytes per character` heuristic, which crossed the 1 KB
/// BLE ceiling at 241 characters. The documented packet crosses it at 930: encryption
/// adds 95 B and padding rounds *up* to a 256 B block, so a 900-character body is a
/// 1 024 B packet that still rides BLE. The heuristic therefore flipped long texts
/// onto Wi-Fi Direct about four times too early — and since transport is what sets
/// per-hop latency in this model, it made long messages look faster than they are
/// (docs/07 §3).
int wireSizeOf(int bodyChars) {
  final raw = packetOverheadBytes + (bodyChars < 0 ? 0 : bodyChars);
  return ((raw + padBlockBytes - 1) ~/ padBlockBytes) * padBlockBytes;
}

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
  String? sosId,
  int? sosRepeat,
  Vec2? sosPos,
  TransportType? transport,
  String? groupId,
  int? groupEpoch,
  int? sizeBytes,
  String? transferId,
  int? chunkIndex,
}) {
  // A chunk's size is the payload it carries, not the empty body it was built
  // from — and that size is what picks the transport and the air time.
  final wireBytes = sizeBytes ?? wireSizeOf(body.length);
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
    transport: transport ?? selectTransport(wireBytes),
    sizeBytes: wireBytes,
    sosId: sosId,
    sosRepeat: sosRepeat,
    sosPos: sosPos,
    groupId: groupId,
    groupEpoch: groupEpoch,
    transferId: transferId,
    chunkIndex: chunkIndex,
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
  // A repeated SOS flood is a new radio event but the same emergency: it replaces
  // the existing alert, with its fresher GPS fix, instead of raising a second
  // notification (docs/04: "SOS misuse — the channel is opt-in", and four
  // identical alerts for one emergency is exactly the spam that rule guards
  // against). The receipt still counts at radio level, which is what
  // broadcastReach measures.
  if (msg.sosId != null) {
    for (var i = 0; i < node.inbox.length; i++) {
      if (node.inbox[i].sosId != msg.sosId) continue;
      // Copies arrive out of order, so only ever move the alert forward in time —
      // a late flood 1 must not overwrite the fix from flood 3. It is still a
      // receipt, and it still must not raise a second notification.
      if (msg.timestamp >= node.inbox[i].timestamp) {
        node.inbox[i] = msg.copyWith();
      }
      return true;
    }
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
  RelayPolicy policy,
) {
  final peers = peersInRange(node, allNodes, rf);
  if (peers.isEmpty) {
    return const ForwardDecision(ForwardMode.queue, <NodeId>[], 'no peers in range');
  }

  final peerIds = peers.map((p) => p.id).toList();

  // An SOS is the one payload the network optimises for reach instead of
  // efficiency: docs/02 §"Broadcast SOS | All transports flooding | Maximize
  // reach" and docs/05 §"SOS mode | Repeated flood of GPS + text over all
  // transports". MPR suppression exists to delete the duplicate copies that an
  // emergency broadcast is *made of*, and a route lookup would hand the alert to
  // one neighbour instead of all of them, so SOS bypasses both — at every hop,
  // not just at the originator.
  if (msg.type == MsgType.sos) {
    return ForwardDecision(ForwardMode.flood, peerIds,
        'SOS: flood every peer — reach over efficiency');
  }

  // Naive epidemic flooding. Deliberately consulted *before* the route table: a
  // baseline that quietly unicasts along known routes is not the "naive flood"
  // the acceptance criteria compare against.
  if (policy == RelayPolicy.floodAll) {
    return ForwardDecision(
        ForwardMode.flood, peerIds, 'naive flood baseline');
  }

  // A group flood is addressed to nobody in particular: the network does not know
  // the membership, so it forwards on the normal policy (MPR included, unlike SOS)
  // and delivery is decided at the recipient. Routing it as a unicast would send a
  // group message to one neighbour and strand the rest.
  if (msg.to != broadcastAddress && msg.to != groupAddress) {
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

  // Flood branch: SUPER relays everything, NORMAL applies MPR suppression —
  // unless the policy switches suppression off, which is what `routeFlood` is
  // for (routing kept, MPR removed).
  if (node.role == Role.superNode || policy == RelayPolicy.routeFlood) {
    return ForwardDecision(
        ForwardMode.flood,
        peerIds,
        node.role == Role.superNode
            ? 'SUPER relay-all'
            : 'routing without MPR suppression');
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
  final why = heardSuper
      ? 'MPR fallback: SUPER heard but my neighbours are not covered'
      : 'MPR fallback: no relay heard';

  // At density the coverage question is unanswerable from the wire, because a beacon
  // advertises at most [mprNeighborAdvertiseLimit] of a node's neighbours. This node
  // still has to forward — it cannot prove anyone else did — but forwarding to all
  // 179 peers is how one message becomes 7,038 transmissions. Forward instead to the
  // strongest link in each of K angular sectors: the nearest peers are all on one
  // side of a node, so choosing by RSSI alone fans out into a wedge, while one peer
  // per direction covers the world. Measured at 200 nodes: 98.3% delivery at 125
  // transmissions per message against 96.7% at 205 for the same K chosen by RSSI,
  // and 100% at 531 unbounded (docs/06 §15). Where the peer list is complete this
  // branch is not taken and nothing changes.
  if (peers.length > mprNeighborAdvertiseLimit) {
    final scored = peers
        .map((p) => _PeerChoice(
            p.id,
            rssiModel(node, p, rf),
            math.atan2(p.pos.y - node.pos.y, p.pos.x - node.pos.x)))
        .toList();
    final sectors = <int, _PeerChoice>{};
    for (final sc in scored) {
      final idx = (((sc.ang + math.pi) / (2 * math.pi)) * denseFallbackFanout).floor() %
          denseFallbackFanout;
      final current = sectors[idx];
      if (current == null || sc.rssi > current.rssi) sectors[idx] = sc;
    }
    final best = sectors.values.map((sc) => sc.id).toList();
    if (best.length < denseFallbackFanout) {
      // Tie-break on the id as well as the link: JS and Dart sort differently when
      // two keys are equal, and the two engines must pick the same peers.
      final byRssi = scored.toList()
        ..sort((a, b) {
          final c = b.rssi.compareTo(a.rssi);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      for (final sc in byRssi) {
        if (best.length >= denseFallbackFanout) break;
        if (!best.contains(sc.id)) best.add(sc.id);
      }
    }
    return ForwardDecision(
        ForwardMode.flood,
        best,
        '$why — capped at ${best.length} of ${peers.length} peers (density)');
  }

  return ForwardDecision(
      ForwardMode.flood, peers.map((p) => p.id).toList(), why);
}

/// One candidate peer for the density-capped fallback: link budget and bearing.
class _PeerChoice {
  _PeerChoice(this.id, this.rssi, this.ang);

  final NodeId id;
  final double rssi;
  final double ang;
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
