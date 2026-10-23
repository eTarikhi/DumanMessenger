/// The transport seam every platform implementation codes against.
///
/// Roadmap Phase 1 item 15 asks for `MeshTransport {advertise(), scan(), connect(), send()}`
/// and its note says the interface is app work. It is not: the four verbs are the part of
/// Phase 1 that does not need a phone. What [selectTransport] picks and at what size, how
/// big a discovery beacon is, whether a payload is refused or handed to the mesh, and what
/// a scan is allowed to report — those are decisions, and they are testable. The BLE GATT
/// server and the CoreBluetooth peripheral that implement [MeshTransport.advertise] on real
/// hardware are not decisions, they are bridges.
///
/// Splitting them this way is what lets the app layer be written against
/// [SimulatedMeshTransport] before either bridge exists, and it is why this file imports
/// nothing but the SDK: it lifts into the mono-repo's `core/` (item 13) unchanged, and the
/// interface cannot acquire a platform dependency by accident. [SimulatedMeshTransport] is
/// the one implementation that reaches for the engine, so it sits below the interface.
library;

import 'dart:async';
import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'rf.dart';
import 'routing.dart';
import 'simulation.dart';
import 'types.dart';

/// One peer this device can currently hear, as its own scan reported it.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.rssiDbm,
    required this.isSuper,
    required this.at,
  });

  final NodeId id;
  final String name;

  /// Signal strength in dBm. A real radio measures this off the beacon it received, so this
  /// comes from the same model the engine's link loss uses rather than from anything the
  /// scan could not have observed.
  final double rssiDbm;

  /// Whether the peer advertised itself as a router. False until a beacon saying so has
  /// actually arrived: a scan result is not a routing table, and an app that treats an
  /// unheard-from peer as a known NORMAL one is making the same mistake in the other
  /// direction.
  final bool isSuper;

  /// Engine clock, in ms, when the scan last saw this peer.
  final double at;
}

/// A scan edge: the peer appeared ([found] true), or stopped being seen ([found] false).
///
/// Edges rather than a polled list, because that is what a platform scanner hands an app —
/// and because a list invites an app to assume the peer set is fresh, which on hardware it
/// never is.
class ScanEvent {
  const ScanEvent(this.peer, this.found);

  final Peer peer;
  final bool found;
}

/// The discovery beacon Phase 1 item 20 puts on air: 12 bytes, a database hash and an id.
///
/// The hash is what makes a greeting cheap. A peer that recognises the id can compare the
/// 8-byte digest against its own and learn whether the other side holds messages it is
/// missing, without either device sending a list — which is the same trick the group
/// history beacons use at scale (`docs/06` §17), shrunk to one packet.
class Advertisement {
  const Advertisement({
    required this.localId,
    required this.beacon,
    required this.at,
  });

  final NodeId localId;

  /// Exactly 12 bytes: the database digest big-endian in 0..7, the id hash in 8..11.
  final Uint8List beacon;

  final double at;

  int get sizeBytes => beacon.lengthInBytes;
}

/// What happened to a payload handed to the mesh.
enum SendStatus {
  /// The mesh accepted it. This is *not* delivery — the acknowledgement is what says that,
  /// and treating "sent" as "arrived" is the mistake an offline messenger cannot afford.
  sent,

  /// Refused locally: this device is offline, or is not a node the engine knows about. A
  /// refusal is reported rather than thrown, because an app has to be able to show the user
  /// "could not send" instead of crashing on a radio that went away.
  refused,
}

/// The outcome of one [MeshTransport.send].
class SendResult {
  const SendResult({
    required this.status,
    required this.transport,
    required this.wireBytes,
    required this.at,
    this.messageId,
  });

  final SendStatus status;

  /// The radio the packet was sized onto. Reported rather than assumed, because it is what
  /// sets per-hop latency in this model and an app that shows "sending over BLE" for a
  /// payload that actually rode Wi-Fi Direct will mislead the user about why it was slow.
  final TransportType transport;

  /// The packet on the wire, after encryption overhead and padding — not the payload length.
  final int wireBytes;

  final double at;

  /// The engine's message id, so a caller can find the acknowledgement or the hop trace.
  /// Null when the send was refused.
  final String? messageId;

  bool get ok => status == SendStatus.sent;
}

/// An open link to one peer.
///
/// Discovery always opens on BLE, because BLE is the radio that found the peer in the first
/// place. A bulk payload above [bleMaxBytes] does not reuse this link's radio: it is carried
/// by chunks, and each chunk picks its own, which is roadmap item 215's "auto-select for
/// payloads >1 KB". The handle from [MeshTransport.transfer] says which one it used.
class Connection {
  const Connection({
    required this.peerId,
    required this.transport,
    required this.openedAt,
  });

  final NodeId peerId;
  final TransportType transport;
  final double openedAt;
}

/// A bulk transfer that has been started, identified so its progress can be polled.
class TransferHandle {
  const TransferHandle({
    required this.id,
    required this.peerId,
    required this.totalBytes,
    required this.chunks,
    required this.chunkBytes,
    required this.window,
    required this.transport,
    required this.startedAt,
  });

  final String id;
  final NodeId peerId;
  final int totalBytes;
  final int chunks;
  final int chunkBytes;
  final int window;

  /// The radio each chunk rides, which for any real file is Wi-Fi Direct: a 64 KB chunk is
  /// far past the 1 KB ceiling, and `docs/08` §5.3 pins the crossing.
  final TransportType transport;

  final double startedAt;
}

/// How far a transfer has got. Polled rather than streamed, because the thing that changes
/// it is the engine's clock and an app asking is the only reliable moment to look.
class TransferProgress {
  const TransferProgress({
    required this.id,
    required this.totalBytes,
    required this.chunks,
    required this.chunksSent,
    required this.chunksReceived,
    required this.retransmitted,
    required this.stalls,
    required this.complete,
    required this.elapsedMs,
  });

  final String id;
  final int totalBytes;
  final int chunks;
  final int chunksSent;
  final int chunksReceived;
  final int retransmitted;
  final int stalls;
  final bool complete;
  final double elapsedMs;
}

/// The transport every platform implementation satisfies.
///
/// Four verbs, as roadmap Phase 1 item 15 specifies. They are deliberately asynchronous
/// even though [SimulatedMeshTransport] answers immediately: the point of the seam is that
/// the app codes against the shape a GATT server and a CoreBluetooth peripheral actually
/// have, so swapping the simulated transport for a real one is a constructor change and not
/// a rewrite.
abstract class MeshTransport {
  /// This device's mesh id.
  NodeId get localId;

  /// Puts the discovery beacon on air and returns what went out.
  ///
  /// Idempotent: a device advertises, it does not accumulate advertisements, so calling this
  /// again refreshes the beacon (the database digest will have moved) rather than adding a
  /// second one.
  Future<Advertisement> advertise();

  /// Peers this device can hear, as edges.
  ///
  /// Listen before driving the clock or the edges that already happened are missed; a real
  /// scanner has the same property, which is why this is a stream and not a getter.
  Stream<ScanEvent> scan();

  /// Opens a link to [peerId], or returns null when the peer is not currently heard.
  ///
  /// Null rather than a failure: a radio cannot connect to something it has not scanned, and
  /// an implementation that reaches a node the local scan has not reported is handing the
  /// app an oracle it will then depend on.
  Future<Connection?> connect(NodeId peerId);

  /// Hands [payload] to the mesh, choosing the radio by wire size.
  ///
  /// [type] is the project's own message taxonomy rather than a transport-local one, because
  /// it is what the engine derives TTL, priority and acknowledgement timing from: calling
  /// something `voice` is not a label, it is a request for the 600 ms retry timer and the
  /// three-hop TTL a voice frame needs (`docs/08` §6).
  Future<SendResult> send(NodeId toId, Uint8List payload,
      {MsgType type = MsgType.text});

  /// Starts a bulk transfer to [connection]'s peer, or returns null if the engine refused it
  /// — the peer is no longer heard, or [totalBytes] is over its ceiling.
  Future<TransferHandle?> transfer(Connection connection, int totalBytes,
      {int? chunkBytes, int? window});

  /// Progress of a transfer this transport started, or null if the engine has forgotten it.
  TransferProgress? progressOf(String transferId);

  /// Stops advertising and closes every open link. Idempotent.
  Future<void> close();
}

/// The reference implementation, driving the mesh engine in this package.
///
/// Everything about it is synchronous underneath and asynchronous on the surface, which is
/// the useful fiction: an app written against this one has already had to handle "the peer
/// is not there", "the send was refused", "the transfer is not finished yet" and "the radio
/// changed under me", so the real transport only has to be slower.
class SimulatedMeshTransport implements MeshTransport {
  SimulatedMeshTransport(this.sim, this.localId, {this.dbHash = 0})
      : _scan = StreamController<ScanEvent>.broadcast();

  final MeshSimulation sim;

  @override
  final NodeId localId;

  /// The local database digest the beacon carries, in its first 8 bytes. An app updates it
  /// as its store changes; here it is fixed at construction because nothing in the engine
  /// has a database to summarise.
  final int dbHash;

  final StreamController<ScanEvent> _scan;
  final Set<NodeId> _seen = <NodeId>{};
  final Map<NodeId, Peer> _lastKnown = <NodeId, Peer>{};
  final Set<NodeId> _links = <NodeId>{};
  Advertisement? _advert;
  bool _closed = false;

  /// The engine node this transport is bound to, or null if the id is not in the world.
  MeshNode? get _node {
    for (final n in sim.nodes) {
      if (n.id == localId) return n;
    }
    return null;
  }

  /// Whether [advertise] has been called and [close] has not.
  bool get advertising => _advert != null;

  /// The beacon currently on air, or null when not advertising.
  Advertisement? get advertisement => _advert;

  /// Peers with an open link.
  Iterable<NodeId> get openLinks => _links;

  /// The peers this device currently believes it can hear — that is, whatever its own scan
  /// cycle last reported. Exposed because an app needs it to decide who it can send to, and
  /// because it is stale by construction: under `skills/07`'s duty cycle a NORMAL node scans
  /// 3 s out of every 10, so this set can lag the geometry by a whole sleep slot. That lag is
  /// the difference between a measurement and an oracle, and it is the thing an app has to be
  /// written to survive.
  Set<NodeId> get heardPeers => Set<NodeId>.unmodifiable(_seen);

  @override
  Stream<ScanEvent> scan() => _scan.stream;

  /// Runs the engine for [ms] and returns the scan edges that produced.
  ///
  /// This is the simulated device loop, and it lives on this class rather than on
  /// [MeshTransport] on purpose: a real transport is driven by the operating system, this one
  /// by a clock somebody has to turn. Keeping the clock out of the interface is what stops
  /// app code from growing a dependency on it.
  List<ScanEvent> advance(double ms) {
    sim.runFor(ms);
    return _pollScan();
  }

  @override
  Future<Advertisement> advertise() {
    final bytes = Uint8List(12);
    final view = ByteData.view(bytes.buffer);
    // Big-endian so the beacon reads the same on both platforms, which is the whole point of
    // fixing a byte order before either bridge exists.
    view.setUint32(0, (dbHash >> 32).toUnsigned(32), Endian.big);
    view.setUint32(4, dbHash.toUnsigned(32), Endian.big);
    view.setUint32(8, _beaconIdHash(localId), Endian.big);
    final advert =
        Advertisement(localId: localId, beacon: bytes, at: sim.now);
    _advert = advert;
    return Future<Advertisement>.value(advert);
  }

  @override
  Future<Connection?> connect(NodeId peerId) {
    // Only a peer this device's own scan is currently reporting. Reaching one that is in the
    // world but not in the scan result would be an oracle, and an app built on an oracle
    // breaks on hardware in a way no test here could catch.
    if (_closed || !_seen.contains(peerId)) {
      return Future<Connection?>.value(null);
    }
    _links.add(peerId);
    return Future<Connection?>.value(Connection(
      peerId: peerId,
      transport: TransportType.ble,
      openedAt: sim.now,
    ));
  }

  @override
  Future<SendResult> send(NodeId toId, Uint8List payload,
      {MsgType type = MsgType.text}) {
    final wire = wireSizeOf(payload.lengthInBytes);
    final sized = selectTransport(wire);
    final me = _node;
    if (_closed || me == null || !me.isOnline) {
      return Future<SendResult>.value(SendResult(
        status: SendStatus.refused,
        transport: sized,
        wireBytes: wire,
        at: sim.now,
      ));
    }
    // The engine models a body as characters and this hands it bytes. latin1 is a one-to-one
    // map between the two, so the round trip is exact and — more importantly — the engine's
    // own size model is applied to the right number of bytes rather than to a guess about
    // how wide a character is.
    final msg = sim.sendMessage(localId, toId, latin1.decode(payload), type);
    if (msg == null) {
      return Future<SendResult>.value(SendResult(
        status: SendStatus.refused,
        transport: sized,
        wireBytes: wire,
        at: sim.now,
      ));
    }
    return Future<SendResult>.value(SendResult(
      status: SendStatus.sent,
      // The engine's choice, not the one computed here: it may have been forced by the
      // caller's message type, and reporting what actually went out is the only honest option.
      transport: msg.transport,
      wireBytes: wire,
      at: sim.now,
      messageId: msg.id,
    ));
  }

  @override
  Future<TransferHandle?> transfer(Connection connection, int totalBytes,
      {int? chunkBytes, int? window}) {
    if (_closed || !_seen.contains(connection.peerId)) {
      return Future<TransferHandle?>.value(null);
    }
    final t = sim.sendFile(localId, connection.peerId, totalBytes,
        chunkBytes: chunkBytes, window: window);
    if (t == null) return Future<TransferHandle?>.value(null);
    return Future<TransferHandle?>.value(TransferHandle(
      id: t.id,
      peerId: connection.peerId,
      totalBytes: totalBytes,
      chunks: t.chunks,
      chunkBytes: t.chunkBytes,
      window: t.window,
      // The chunk's radio, not the file's: a 10 MB transfer is 160 packets of 64 KB and each
      // one is sized on its own. Sizing the whole file would put a 900 B voice frame on
      // Wi-Fi Direct, which is the error `docs/07` §3 corrected for text.
      transport: selectTransport(wireSizeOf(t.chunkBytes)),
      startedAt: t.startedAt,
    ));
  }

  @override
  TransferProgress? progressOf(String transferId) {
    final t = sim.transfers[transferId];
    if (t == null) return null;
    return TransferProgress(
      id: t.id,
      totalBytes: t.totalBytes,
      chunks: t.chunks,
      chunksSent: t.nextToSend,
      chunksReceived: t.received,
      retransmitted: t.retransmitted,
      stalls: t.stalls,
      complete: t.state == TransferState.complete,
      elapsedMs: (t.completedAt ?? sim.now) - t.startedAt,
    );
  }

  @override
  Future<void> close() {
    _closed = true;
    _advert = null;
    _links.clear();
    _seen.clear();
    _lastKnown.clear();
    if (_scan.isClosed) return Future<void>.value();
    return _scan.close();
  }

  /// Diffs the peer set against the last poll and emits the edges.
  ///
  /// It reads `node.peerIds`, which is what this device's own scan cycle last found —
  /// refreshed on the beacon interval, and stale or empty while a NORMAL node sleeps
  /// (`skills/07`'s 3 s scan in every 10 s cycle). It deliberately does *not* read
  /// [peersInRange], which is the truth about the geometry right now. The difference is the
  /// whole point: a measurement is taken at some moment in the past and can be wrong, and an
  /// app written against the truth would pass every test here and then fail on a phone in a
  /// pocket.
  List<ScanEvent> _pollScan() {
    final me = _node;
    if (_closed || me == null) return const <ScanEvent>[];
    final heard = <NodeId>{};
    for (final id in me.peerIds) {
      heard.add(id);
      final p = _measure(id);
      if (p != null) _lastKnown[id] = p;
    }
    final edges = <ScanEvent>[];
    for (final id in heard) {
      if (_seen.contains(id)) continue;
      final p = _lastKnown[id];
      if (p != null) edges.add(ScanEvent(p, true));
    }
    for (final id in _seen.toList()) {
      if (heard.contains(id)) continue;
      final p = _lastKnown.remove(id);
      _links.remove(id); // a link to a peer that left is not a link
      if (p != null) edges.add(ScanEvent(p, false));
    }
    _seen
      ..clear()
      ..addAll(heard);
    for (final e in edges) {
      if (!_scan.isClosed) _scan.add(e);
    }
    return edges;
  }

  /// One peer, as this device would measure it. Null when the peer has gone or is offline.
  Peer? _measure(NodeId id) {
    final me = _node;
    if (me == null) return null;
    MeshNode? peer;
    for (final n in sim.nodes) {
      if (n.id == id) {
        peer = n;
        break;
      }
    }
    if (peer == null || !peer.isOnline) return null;
    final ogm = me.ogmTable[id];
    return Peer(
      id: id,
      name: peer.name,
      rssiDbm: rssiModel(me, peer, sim.rf),
      isSuper: ogm?.isSuper ?? false,
      at: sim.now,
    );
  }
}

/// FNV-1a over 32 bits, for the beacon's id field.
///
/// Chosen because it is four lines, has no dependency, and is the same on both platforms —
/// a beacon that hashes differently on Android and iOS is a beacon nobody can match. It is
/// not a security primitive: the id is public, and `docs/04` is explicit that discovery
/// carries no secret.
int _beaconIdHash(String id) {
  var h = 0x811C9DC5;
  for (var i = 0; i < id.length; i++) {
    h = (h ^ id.codeUnitAt(i)) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
