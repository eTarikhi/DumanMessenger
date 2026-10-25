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

// --- abuse limits (docs/04 §6), mirroring `src/routing.ts` ---------------------

/// docs/04 §6: "Max 5 broadcasts / minute per node; SUPERs drop excess."
///
/// Named with a `Default` suffix because `SimConfig` has a field of the plain name,
/// and `this.broadcastPerMinuteCap = broadcastPerMinuteCap` in a constructor default
/// would be self-referential. Same reason `mprWaitDefaultMs` is spelled that way.
const int broadcastPerMinuteCapDefault = 5;

/// docs/04 §6: "Cap relay to 30 msgs/min per source; ignore floods."
const int relayPerSourcePerMinuteCapDefault = 30;

/// Both caps in docs/04 §6 are stated per minute. Written as the same expression as
/// the TypeScript engine so `check-parity.py` compares them textually.
const double rateWindowMs = 60 * 1000;

/// One token bucket, per (enforcer, source) pair.
class RateBucket {
  RateBucket(this.tokens, this.atMs);

  double tokens;
  double atMs;
}

/// Outcome of one [admitByRate] call.
class RateDecision {
  const RateDecision(this.ok, this.reason, this.tokensLeft, this.retryInMs);

  final bool ok;

  /// Empty when admitted; otherwise the reason, for the capture log.
  final String reason;
  final double tokensLeft;
  final double retryInMs;
}

/// Take one token from `buckets[key]`, creating the bucket full if it is new.
///
/// A token bucket rather than a per-minute tally because docs/04 §6 states a *rate*:
/// a tumbling counter admits 5 broadcasts in the last second of one minute and 5 in
/// the first second of the next, which is ten in two milliseconds without ever
/// breaking a per-minute count. The bucket refills continuously at [cap] per
/// [rateWindowMs] and bursts up to [cap].
///
/// Pure except for the map it is handed, which is what makes the two limits
/// unit-testable without constructing a mesh. Mirror of `admitByRate` in
/// `src/routing.ts`.
RateDecision admitByRate(
    Map<String, RateBucket> buckets, String key, int cap, double nowMs) {
  if (cap <= 0) {
    return const RateDecision(true, '', double.infinity, 0);
  }
  var bucket = buckets[key];
  if (bucket == null) {
    bucket = RateBucket(cap.toDouble(), nowMs);
    buckets[key] = bucket;
  }
  final elapsed = nowMs - bucket.atMs;
  if (elapsed > 0) {
    bucket.tokens =
        math.min(cap.toDouble(), bucket.tokens + elapsed * cap / rateWindowMs);
    bucket.atMs = nowMs;
  } else if (elapsed < 0) {
    // The clock went backwards — a metrics reset, or a map reused across runs.
    // Grant no refill and resynchronise rather than subtracting tokens.
    bucket.atMs = nowMs;
  }
  if (bucket.tokens < 1) {
    final retry = (1 - bucket.tokens) / cap * rateWindowMs;
    return RateDecision(
        false,
        'rate limit: $cap per minute exceeded, next token in '
            '${(retry / 1000).toStringAsFixed(1)} s',
        bucket.tokens,
        retry);
  }
  bucket.tokens -= 1;
  return RateDecision(true, '', bucket.tokens, 0);
}

/// Whether a message counts against the relay cap.
///
/// Control-plane traffic does not, and the arithmetic is why: docs/03 §1 beacons an
/// OGM every 2 s, which is exactly 30 per minute per source — the cap docs/04 §6
/// states. Counting beacons does not drop a source's first data message; it does
/// something slower and worse. The bucket refills one token per 2 s and the beacon
/// spends it, so the sustained budget for everything else is zero and data traffic
/// runs off the initial burst alone: 29 messages in ten minutes instead of 300, a
/// 90 % cut caused by the node's own routing protocol. `ack` and `sync` are exempt
/// for the same reason — a rate-limited acknowledgement turns one lost packet into a
/// retransmission storm. Mirror of `countsAgainstRelayCap` in `src/routing.ts`.
bool countsAgainstRelayCap(MeshMessage msg) =>
    msg.type != MsgType.ogm &&
    msg.type != MsgType.ack &&
    msg.type != MsgType.sync;

/// Whether a local block (`docs/04` §6: "Block/mute peer locally (ignore msgs from
/// pubKey)") applies to this message. Mirror of `isBlockableTraffic` in `src/routing.ts`.
///
/// Control plane is excluded because blocking an ACK makes the blocked peer retransmit —
/// more airtime, the opposite of the point — and blocking an OGM removes the peer from the
/// blocker's routing table, which is a routing change disguised as a privacy setting. SOS
/// is excluded because §6 gives it opt-in listening and §11's collapsing instead, and the
/// asymmetry is not close: showing one SOS from a blocked peer costs a notification, and
/// suppressing a real one costs a life.
bool isBlockableTraffic(MeshMessage msg) =>
    countsAgainstRelayCap(msg) && msg.type != MsgType.sos;

/// Text < 1 KB rides BLE; larger payloads need Wi-Fi Direct (docs/02 §3.1).
const int bleMaxBytes = 1024;

/// One OGM's field widths, derived from [Ogm] and docs/03 §4 the way [packetOverheadBytes]
/// derives the sealed packet's 95 B from skills/03's layout — a beacon's size has to come
/// from the fields it actually carries, not from a guess.
///
/// 32 is the X25519 public-key width docs/07 §4 specifies, the same field
/// [packetOverheadBytes] spells as `from`.
const int ogmIdBytes = 32;
const int ogmSeqBytes = 4;
const int ogmScoreBytes = 4;

/// `isSuper`, `declinedRouter` and `hopCount` at 1 B each, `peerCount` at 2 B.
const int ogmFlagBytes = 1 + 1 + 1 + 2;

/// `batteryBucket` is `(battery * 10).floor()`, so 0-10 fits one byte.
const int ogmBatteryBytes = 1;

/// One `bestHopTo` entry: a destination id and its hop count. Spelled as literals, like
/// [packetOverheadBytes], because `check-parity.py` compares the two engines' non-scalar
/// initialisers as *text* and identifier case is the one thing the two languages cannot
/// agree on. `engine_test.dart` ties each of these to the named widths, so a width change
/// fails a test instead of silently propagating.
const int ogmHopEntryBytes = 32 + 1;

/// The part of a beacon that does not depend on how much it advertises:
/// `ogmIdBytes + ogmSeqBytes + ogmScoreBytes + ogmFlagBytes + ogmBatteryBytes`.
const int ogmFixedBytes = 32 + 4 + 4 + (1 + 1 + 1 + 2) + 1;

/// What one beacon costs on air, in bytes. OGMs ride `_beacon` rather than `_onAir`, so they
/// had no size at all and every duration charged to a beacon was a hop latency by default.
/// A beacon is not a small packet: it carries the MPR neighbour set that makes two-hop
/// coverage knowable, plus up to eight route advertisements.
int ogmWireBytes(int neighborCount, int bestHopCount) =>
    ogmFixedBytes +
    math.max(0, neighborCount) * ogmIdBytes +
    math.max(0, bestHopCount) * ogmHopEntryBytes;

/// A beacon at both advertise limits, which is what a dense mesh actually sends:
/// `ogmWireBytes(mprNeighborAdvertiseLimit, bestHopAdvertiseLimit)`, spelled out for
/// `check-parity.py` and tied back to the limits by a test.
const int ogmMaxWireBytes = 46 + 30 * 32 + 8 * 33;

const String broadcastAddress = 'BROADCAST';

TransportType selectTransport(int sizeBytes) =>
    sizeBytes > bleMaxBytes ? TransportType.wifiDirect : TransportType.ble;

/// Padding block, per `skills/03`: "DO pad to 256B blocks".
const int padBlockBytes = 256;

/// Everything around the body in one encrypted packet, from `skills/03`'s layout:
/// `header {msgId16, ttl, type, destHint8, hop}` = 27 B, `aead {nonce12, tag16}` =
/// 28 B, and inside the ciphertext `from` 32 B + `ts` 6 B + `len` 2 B. 95 B before
/// the body.
///
/// `ts` is 6 bytes and not the 8 `docs/07` §4 writes, and the 2 that frees up hold
/// the body length: zero padding is ambiguous for a binary body, and a media chunk
/// can legitimately end in `0x00`. Six-byte milliseconds run to the year 10889.
/// The total is unchanged, so every published size survives — see
/// `src/crypto/packet.ts`, which serialises this packet for real.
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

/// Length of [text] in UTF-8 bytes, not in UTF-16 code units.
///
/// A packet carries bytes and `String.length` counts code units, so the two agree
/// only for ASCII — which is why this went unnoticed: every name in the spawn
/// table, every body the traffic generator produces and every fixture body in
/// `test-fixtures/golden-vectors.json` is ASCII. They disagree the moment a user
/// types Turkish, Arabic, Devanagari, CJK or an emoji, and the disagreement is
/// optimistic, which is the dangerous direction: the number picks the transport
/// and the transport sets the per-hop latency every finding is reported against.
///
/// Counted by hand rather than through `utf8.encode` for two reasons. It allocates
/// nothing, and it writes the lone-surrogate rule down explicitly (U+FFFD, three
/// bytes) instead of depending on what `utf8.encode` does with malformed input —
/// it throws by default, and the TypeScript engine's `TextEncoder` replaces. Both
/// engines implement the replacement, so they agree by construction rather than by
/// coincidence. Mirror of `utf8ByteLength` in `src/routing.ts`.
int utf8ByteLength(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) {
      final low = text.codeUnitAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        bytes += 4; // a valid surrogate pair is one 4-byte character
        i += 1;
        continue;
      }
      bytes += 3; // a lone high surrogate encodes as U+FFFD
    } else {
      bytes += 3; // BMP above U+07FF, and any lone surrogate
    }
  }
  return bytes;
}

/// Wire size of a body given as text. This is what [createMessage] uses.
///
/// [wireSizeOf] stays for callers that already hold a byte count — media chunks,
/// whose payload size is declared rather than padded (docs/08 §8).
int wireSizeOfBody(String body) => wireSizeOf(utf8ByteLength(body));

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
  // Bytes, not code units: see [utf8ByteLength].
  final wireBytes = sizeBytes ?? wireSizeOfBody(body);
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
    // skills/04: "keep newest 500 (LRU by priority)". Priority first, then age: a bundle
    // that has already sprayed its three copies is the one to lose, and among those the
    // oldest. Evicting purely by age — what this did before — could throw away a fresh
    // bundle to keep a sprayed-out one.
    int rank(QueuedMessage q) => q.msg.priority == Priority.low ? 0 : 1;
    node.oppQueue.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.createdAt.compareTo(b.createdAt);
    });
    node.oppQueue.removeAt(0);
    node.oppQueue.sort((a, b) => a.createdAt.compareTo(b.createdAt));
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

/// Drop every copy of a bundle that has been acknowledged, and report how many went.
///
/// skills/04: "On ackReceived from dest: remove + gossip ACK (so relays can prune)". The
/// ACK travels back along the reverse path, and the nodes on that path are exactly the
/// nodes that were carrying copies — so overhearing one is enough to prune, with no extra
/// traffic and no new packet type. Measured, it prunes nothing in any of the four worlds
/// (docs/06 §20.5), because the carrier that delivered has already dropped its own copy
/// and the other holders are not on the reverse path; it is kept because it is free and
/// correct when it does fire.
int pruneAcked(MeshNode node, String ackedId) {
  if (node.oppQueue.isEmpty) return 0;
  final before = node.oppQueue.length;
  node.oppQueue.removeWhere((q) => q.msg.id == ackedId);
  return before - node.oppQueue.length;
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
    // A bundle already in DTN circulation has nowhere to go *right now*, which is exactly
    // why it is being carried. Flooding it would spend the neighbourhood's radio on a copy
    // with no path, and MPR suppression would delete it outright — measured in docs/06
    // §20.1 as the reason skills/04's carry test could not pass. Park it and let the next
    // contact decide.
    if (msg.carried) {
      return ForwardDecision(ForwardMode.queue, const <NodeId>[],
          'carried bundle: no route to the destination right now');
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

  /// Forwards that went to a SUPER because the carrier had no route of its own
  /// (skills/04: "prefer SUPER as bundle carrier"). Counted so the cost of the rule can be
  /// reported separately from routed forwarding — it is off by default, see docs/06 §20.4.
  int superCarries = 0;

  /// Forwards that went to a plugged, stationary carrier rather than a SUPER
  /// (`preferCommunity`). Off by default and measured as a negative: a node that does not
  /// move is the best place to leave a bundle and the worst place to carry one
  /// (docs/06 §19.5).
  int communityCarries = 0;
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
  double nowMs, {
  bool preferSuper = false,
  bool preferCommunity = false,
}) {
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
        // A copy handed to a carrier is a *later* copy of the same bundle, and bumping
        // `attempt` is what says so: intermediate nodes dedupe on `id#attempt`, so without
        // this a relay that already heard the bundle swallows every later hand-over as a
        // duplicate and the bundle never moves. The increment has to be relative to the
        // attempt the bundle is *already* on, because the source retries that put it in the
        // queue used 1 and 2 first: numbering sprayed copies from 1 collides with them and
        // the carrier's cache swallows the first two copies of every bundle (docs/06 §20).
        queued.msg = queued.msg.copyWith(attempt: queued.msg.attempt + 1);
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
    // No route of our own. skills/04: "DO prefer SUPER as bundle carrier (more
    // storage/battery)" — and a SUPER is also the node with the fullest view, since it
    // scans continuously and relays everything. Still bounded by the spray limit: this is
    // the spray half of spray-and-wait, not a flood. Off by default, because once carried
    // bundles are parked rather than suppressed this costs delivery (docs/06 §20.4).
    // skills/04's "prefer SUPER as bundle carrier" and the community-relay reading of the
    // same line: a plugged tablet has the storage and the mains power, and it is not going
    // to walk away. Both are guesses about who meets the destination next, and they guess
    // differently — a SUPER because it sees the most traffic, a community relay because it
    // stays put. Measured against each other in docs/06 §19.5.
    if ((preferCommunity || preferSuper) && queued.copyCount < sprayLimit) {
      final carriers = allNodes
          .where((p) =>
              p.id != node.id &&
              p.isOnline &&
              canReach(node, p, rf) &&
              (preferCommunity
                  ? isCommunityRelay(p)
                  : p.role == Role.superNode))
          .toList()
        ..sort((a, b) {
          final byRssi = rssiModel(node, b, rf).compareTo(rssiModel(node, a, rf));
          return byRssi != 0 ? byRssi : a.id.compareTo(b.id);
        });
      if (carriers.isNotEmpty) {
        result.forward.add(OppForward(queued, carriers.first.id));
        if (preferCommunity) {
          result.communityCarries++;
        } else {
          result.superCarries++;
        }
        queued.copyCount++;
        queued.msg = queued.msg.copyWith(attempt: queued.msg.attempt + 1);
        if (queued.copyCount >= sprayLimit) {
          queued.msg = queued.msg.copyWith(priority: Priority.low);
        }
        result.keep.add(queued);
        continue;
      }
    }
    result.keep.add(queued);
  }
  return result;
}
