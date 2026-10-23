/// The transport seam every platform implementation codes against.
///
/// `skills/01` specifies it — `MeshTransport {startAdvertising, scan, connect, send,
/// onReceive, stop}` — and roadmap Phase 1 item 15 asks for it. Its note used to say the
/// interface was app work; it is not. The four decisions the verbs encode are the part of
/// Phase 1 that does not need a phone: what [selectTransport] picks and at what size, how
/// big a discovery beacon is, when a connection is refused rather than attempted, and what a
/// scan is allowed to report. The GATT server (item 20) and the CoreBluetooth peripheral
/// (item 21) that implement `startAdvertising` on hardware are bridges, not decisions.
///
/// So the signatures below are `skills/01`'s, in its order, and this file imports nothing
/// but the SDK: it lifts into the mono-repo's `core/` (item 13) unchanged, and the interface
/// cannot acquire a platform dependency by accident. [SimulatedMeshTransport] is the one
/// implementation that reaches for the engine, so it sits below the interface.
///
/// One name differs from the skill on purpose. `skills/01` lists
/// `enum TransportType { bleGatt, wifiDirect, wifiAware, multipeer }`, and the engine
/// already has `TransportType { ble, wifiDirect, multipeer }` — the data-plane selector that
/// `docs/07` §3 and `docs/08` §5.3 measure against, and a field in every [MeshMessage].
/// Renaming it to satisfy the skill would rewrite the measured record for no behaviour, so
/// the seam reuses the engine's enum and the mapping is `bleGatt` → [TransportType.ble].
/// `wifiAware` is roadmap item 307, a feature-flagged experiment that nothing here models.
library;

import 'dart:async';
import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'rf.dart';
import 'routing.dart';
import 'simulation.dart';
import 'types.dart';

/// `skills/01` calls it `PeerId`; the engine calls the same string `NodeId`. One typedef so
/// the seam reads the way the skill specifies and the two names cannot drift apart.
typedef PeerId = NodeId;

/// The service UUID a scanner filters on (`skills/01`: `DUMAN_MESH_SVC`).
const String dumanMeshServiceUuid = 'DUMAN_MESH_SVC';

/// The discovery beacon of roadmap item 20: 12 bytes plus the service UUID to advertise it
/// under.
///
/// The digest is what makes a greeting cheap. A peer that recognises the id can compare 8
/// bytes against its own and learn whether the other side holds messages it is missing,
/// without either device sending a list — the same trick the group history beacons use at
/// scale (`docs/06` §17), shrunk to one packet.
class AdvertPayload {
  const AdvertPayload({
    required this.localId,
    required this.dbHash,
    this.serviceUuid = dumanMeshServiceUuid,
  });

  final PeerId localId;

  /// Digest of the local database, big-endian in beacon bytes 0..7. An app refreshes it as
  /// its store changes, which is why it is a parameter here and not a constant.
  final int dbHash;

  final String serviceUuid;

  /// The beacon's size on air, which item 20 fixes at 12 bytes.
  static const int beaconBytes = 12;

  /// 12 bytes: the digest in 0..7, a hash of [localId] in 8..11.
  ///
  /// Big-endian, so the beacon reads the same on both platforms — which is the point of
  /// fixing a byte order before either bridge exists.
  Uint8List get beacon {
    final bytes = Uint8List(beaconBytes);
    final view = ByteData.view(bytes.buffer);
    view.setUint32(0, (dbHash >> 32).toUnsigned(32), Endian.big);
    view.setUint32(4, dbHash.toUnsigned(32), Endian.big);
    view.setUint32(8, beaconIdHash(localId), Endian.big);
    return bytes;
  }
}

/// A peer this device has heard, as `skills/01` specifies: with rssi and txPower.
class Peer {
  const Peer({
    required this.id,
    required this.name,
    required this.rssiDbm,
    required this.txPowerDbm,
    required this.isSuper,
    required this.at,
  });

  final PeerId id;
  final String name;

  /// Signal strength in dBm. A real radio measures this off the beacon it received, so here
  /// it comes from the same model the engine's link loss uses rather than from anything a
  /// scan could not have observed.
  final double rssiDbm;

  /// What the peer said it transmits at. With [rssiDbm] it is what lets a device estimate
  /// distance and link asymmetry — and the reason it is on the peer rather than computed is
  /// that a real scanner gets it from the advertisement, not from the geometry.
  final double txPowerDbm;

  /// Whether the peer advertised itself as a router. False until a beacon saying so has
  /// actually arrived: a scan result is not a routing table, and treating an unheard-from
  /// peer as a known NORMAL one is the same mistake in the other direction.
  final bool isSuper;

  /// Engine clock, in ms, when this peer was last heard. A consumer ages peers out on it,
  /// which is how a stream of advertisements becomes a peer list without the transport
  /// having to decide how long a peer stays valid.
  final double at;
}

/// An open link to one peer.
///
/// Discovery always opens on BLE, because BLE is the radio that found the peer. A bulk
/// payload does not reuse that radio: it is carried in chunks and each chunk picks its own,
/// which is roadmap item 215's "auto-select for payloads >1 KB".
class Connection {
  const Connection({
    required this.peerId,
    required this.transport,
    required this.openedAt,
  });

  final PeerId peerId;
  final TransportType transport;
  final double openedAt;
}

/// Why a transport call failed. Reported as an exception rather than a nullable return,
/// because `skills/01` types `connect` and `send` as non-nullable: the seam has to be able
/// to say *which* refusal happened, and an app has to be able to show "could not send"
/// instead of crashing on a radio that went away.
enum TransportFailure {
  /// The peer is not in this device's scan result. Not the same as "not in range": it means
  /// not *heard*, which is the only thing a radio can know.
  notHeard,

  /// This device's own radio is gone — offline, or out of battery.
  offline,

  /// The transport has been stopped.
  closed,

  /// The connection is no longer open, because the peer stopped being heard.
  disconnected,

  /// The engine took the call and refused it.
  refused,

  /// The payload is over the engine's transfer ceiling (`skills/05`: max 10 MB).
  tooLarge,
}

class TransportException implements Exception {
  const TransportException(this.failure, {this.peerId, this.detail = ''});

  final TransportFailure failure;
  final PeerId? peerId;
  final String detail;

  @override
  String toString() {
    final who = peerId == null ? '' : ' peer=$peerId';
    final why = detail.isEmpty ? '' : ': $detail';
    return 'TransportException(${failure.name}$who)$why';
  }
}

/// The transport every platform implementation satisfies — `skills/01`'s six verbs.
///
/// They are asynchronous even though [SimulatedMeshTransport] can answer immediately, which
/// is the point of the seam: app code is written against the shape a GATT server and a
/// CoreBluetooth peripheral actually have, so swapping the simulated transport for a real
/// one is a constructor change and not a rewrite.
abstract class MeshTransport {
  /// This device's id. `skills/01`'s listing does not include it, because a platform
  /// transport gets its identity from the device; the seam states it explicitly so a caller
  /// can tell which of several transports it is holding.
  PeerId get localId;

  /// Puts [payload]'s beacon on air under its service UUID.
  ///
  /// Calling it again replaces the beacon rather than adding one: a device advertises, it
  /// does not accumulate advertisements.
  Future<void> startAdvertising(AdvertPayload payload);

  /// Peers this device hears — one event per advertisement received, carrying a fresh rssi
  /// and [Peer.at]. A stream of sightings rather than a polled list, because that is what a
  /// platform scanner hands an app, and because a list invites the assumption that the peer
  /// set is current, which on hardware it never is.
  Stream<Peer> scan();

  /// Opens a link to [id].
  ///
  /// Throws [TransportException] with [TransportFailure.notHeard] for a peer this device's
  /// scan has not reported, even one that exists in the world. Reaching it anyway would hand
  /// the app an oracle, and an app built on an oracle passes every test here and then fails
  /// on a phone in a pocket.
  Future<Connection> connect(PeerId id);

  /// Hands [bytes] to the mesh over [c], reliably: the engine's own acknowledgement and
  /// retry, which is what "reliable" costs and why completing does not mean the far end has
  /// read it.
  Future<void> send(Connection c, Uint8List bytes);

  /// Payloads that arrive from [c]'s peer.
  Stream<Uint8List> onReceive(Connection c);

  /// Stops advertising and closes every link. Idempotent.
  Future<void> stop();
}

/// A bulk transfer started through [SimulatedMeshTransport.transfer], identified so its
/// progress can be polled. Not part of [MeshTransport]: `skills/01`'s seam moves bytes over
/// a link, and a windowed file transfer is `skills/05`'s, one layer up.
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
  final PeerId peerId;
  final int totalBytes;
  final int chunks;
  final int chunkBytes;
  final int window;

  /// The radio each chunk rides, which for any real file is Wi-Fi Direct: a 64 KB chunk is
  /// far past the 1 KB ceiling, and `docs/08` §5.3 pins the crossing.
  final TransportType transport;

  final double startedAt;
}

/// How far a transfer has got. Polled rather than streamed, because what changes it is the
/// engine's clock and a caller asking is the only reliable moment to look.
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

/// The reference implementation, driving the mesh engine in this package.
///
/// Everything about it is synchronous underneath and asynchronous on the surface, which is
/// the useful fiction: an app written against this one has already had to handle "the peer
/// is not there", "the send was refused", "the transfer is not finished yet" and "the radio
/// changed under me", so the real transport only has to be slower.
class SimulatedMeshTransport implements MeshTransport {
  SimulatedMeshTransport(this.sim, this.localId)
      : _scanCtrl = StreamController<Peer>.broadcast(sync: true);

  final MeshSimulation sim;

  @override
  final PeerId localId;

  // Synchronous delivery, because the engine is: a listener added before [advance] has
  // already seen the events by the time it returns. A real transport is not synchronous and
  // an app must not rely on this — but a test can, which is why it is worth having.
  final StreamController<Peer> _scanCtrl;
  final Map<PeerId, StreamController<Uint8List>> _rxCtrls =
      <PeerId, StreamController<Uint8List>>{};
  final Map<PeerId, Set<String>> _emitted = <PeerId, Set<String>>{};
  final Map<PeerId, Connection> _links = <PeerId, Connection>{};
  final Set<PeerId> _seen = <PeerId>{};
  final Map<PeerId, Peer> _lastKnown = <PeerId, Peer>{};
  AdvertPayload? _advert;
  bool _closed = false;

  /// The engine node this transport is bound to, or null if the id is not in the world.
  MeshNode? get _node {
    for (final n in sim.nodes) {
      if (n.id == localId) return n;
    }
    return null;
  }

  /// The beacon currently on air, or null when not advertising.
  AdvertPayload? get advertisement => _advert;

  /// Peers with an open link.
  Iterable<PeerId> get openLinks => _links.keys;

  /// The last sighting of [id], or null if it has never been heard or has since left.
  ///
  /// A peer list an app renders is made of these, not of the scan stream: the stream says
  /// what arrived, and the list has to survive the gaps between arrivals. The rssi in it is
  /// the last one measured, so it ages — which is the honest thing to show, since a device
  /// cannot measure a peer it is not currently hearing.
  Peer? lastSeen(PeerId id) => _lastKnown[id];

  /// The peers this device currently believes it can hear — whatever its own scan cycle last
  /// reported. Stale by construction: under `skills/07`'s duty cycle a NORMAL node scans 3 s
  /// out of every 10, so this can lag the geometry by a whole sleep slot. That lag is the
  /// difference between a measurement and an oracle, and it is what an app has to survive.
  Set<PeerId> get heardPeers => Set<PeerId>.unmodifiable(_seen);

  @override
  Stream<Peer> scan() => _scanCtrl.stream;

  @override
  Stream<Uint8List> onReceive(Connection c) {
    final existing = _rxCtrls[c.peerId];
    if (existing != null) return existing.stream;
    final ctrl = StreamController<Uint8List>.broadcast(sync: true);
    _rxCtrls[c.peerId] = ctrl;
    return ctrl.stream;
  }

  /// Runs the engine for [ms] and delivers whatever it produced to [scan] and [onReceive].
  ///
  /// This is the simulated device loop, and it lives here rather than on [MeshTransport] on
  /// purpose: a real transport is driven by the operating system, this one by a clock
  /// somebody has to turn. Keeping the clock out of the interface is what stops app code
  /// from growing a dependency on it.
  void advance(double ms) {
    sim.runFor(ms);
    if (_closed) return;
    _pollScan();
    _pollInbox();
  }

  @override
  Future<void> startAdvertising(AdvertPayload payload) {
    return Future<void>(() {
      if (_closed) {
        throw const TransportException(TransportFailure.closed);
      }
      _advert = payload;
    });
  }

  @override
  Future<Connection> connect(PeerId id) {
    return Future<Connection>(() {
      if (_closed) {
        throw const TransportException(TransportFailure.closed);
      }
      // Only a peer this device's own scan is currently reporting.
      if (!_seen.contains(id)) {
        throw TransportException(TransportFailure.notHeard, peerId: id);
      }
      final me = _node;
      if (me == null || !me.isOnline) {
        throw TransportException(TransportFailure.offline, peerId: id);
      }
      final conn = Connection(
        peerId: id,
        // Discovery opens on BLE: that is the radio which found the peer.
        transport: TransportType.ble,
        openedAt: sim.now,
      );
      _links[id] = conn;
      onReceive(conn); // a link with nowhere to deliver to is not a link
      return conn;
    });
  }

  @override
  Future<void> send(Connection c, Uint8List bytes) {
    return Future<void>(() {
      if (_closed) {
        throw const TransportException(TransportFailure.closed);
      }
      if (_links[c.peerId] == null) {
        throw TransportException(TransportFailure.disconnected, peerId: c.peerId);
      }
      // A peer that stopped being heard took the link with it. `_pollScan` drops it, so this
      // is the write to a peripheral that walked away.
      if (!_seen.contains(c.peerId)) {
        _links.remove(c.peerId);
        throw TransportException(TransportFailure.notHeard, peerId: c.peerId);
      }
      final me = _node;
      if (me == null || !me.isOnline) {
        throw TransportException(TransportFailure.offline, peerId: c.peerId);
      }
      // The engine models a body as characters and this hands it bytes. latin1 is a
      // one-to-one map between the two, so the round trip is exact and — more importantly —
      // the engine's own size model is applied to the right number of bytes rather than to a
      // guess about how wide a character is.
      final msg = sim.sendMessage(localId, c.peerId, latin1.decode(bytes));
      if (msg == null) {
        throw TransportException(TransportFailure.refused, peerId: c.peerId);
      }
    });
  }

  @override
  Future<void> stop() {
    _closed = true;
    _advert = null;
    _links.clear();
    _seen.clear();
    _lastKnown.clear();
    _emitted.clear();
    final pending = <Future<void>>[];
    for (final ctrl in _rxCtrls.values) {
      if (!ctrl.isClosed) pending.add(ctrl.close());
    }
    _rxCtrls.clear();
    if (!_scanCtrl.isClosed) pending.add(_scanCtrl.close());
    return Future.wait<void>(pending).then((_) {});
  }

  /// Starts a bulk transfer to [c]'s peer. Not on [MeshTransport]: this is `skills/05`'s
  /// windowed file transport riding the seam, not the seam itself.
  ///
  /// Throws [TransportException] with [TransportFailure.tooLarge] over the engine's ceiling,
  /// which is a different answer from "the peer left" and an app shows it differently.
  Future<TransferHandle> transfer(Connection c, int totalBytes,
      {int? chunkBytes, int? window}) {
    return Future<TransferHandle>(() {
      if (_closed) throw const TransportException(TransportFailure.closed);
      if (!_seen.contains(c.peerId)) {
        throw TransportException(TransportFailure.notHeard, peerId: c.peerId);
      }
      final t = sim.sendFile(localId, c.peerId, totalBytes,
          chunkBytes: chunkBytes, window: window);
      if (t == null) {
        // The engine refuses an over-ceiling file rather than attempting it, and the seam
        // passes that through instead of inventing a success.
        throw TransportException(TransportFailure.tooLarge,
            peerId: c.peerId,
            detail: '$totalBytes bytes against a ceiling of '
                '${sim.config.maxTransferBytes}');
      }
      return TransferHandle(
        id: t.id,
        peerId: c.peerId,
        totalBytes: totalBytes,
        chunks: t.chunks,
        chunkBytes: t.chunkBytes,
        window: t.window,
        // The chunk's radio, not the file's: a 10 MB transfer is 160 packets of 64 KB and
        // each is sized on its own. Sizing the whole file would put a 900 B voice frame on
        // Wi-Fi Direct, which is the error `docs/07` §3 corrected for text.
        transport: selectTransport(wireSizeOf(t.chunkBytes)),
        startedAt: t.startedAt,
      );
    });
  }

  /// Progress of a transfer this transport started, or null if the engine has forgotten it.
  /// Null rather than an exception: a caller polls, and "no such transfer" is an ordinary
  /// answer.
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

  /// Which radio a payload of this many bytes would ride, without sending it. Exposed
  /// because it is the decision `docs/07` §3 corrected and an app wants to show it before
  /// the user commits to a 10 MB upload on BLE.
  TransportType transportFor(int payloadBytes) =>
      selectTransport(wireSizeOf(payloadBytes));

  /// Emits one [Peer] per peer heard since the last poll.
  ///
  /// It reads `node.peerIds`, which is what this device's own scan cycle last found —
  /// refreshed on the beacon interval, and stale or empty while a NORMAL node sleeps. It
  /// deliberately does *not* read [peersInRange], which is the truth about the geometry
  /// right now. The difference is the whole point: a measurement is taken at some moment in
  /// the past and can be wrong, and an app written against the truth would pass every test
  /// here and then fail on a phone in a pocket.
  void _pollScan() {
    final me = _node;
    if (me == null) return;
    final heard = <PeerId>{};
    for (final id in me.peerIds) {
      heard.add(id);
      final p = _measure(id);
      if (p == null) continue;
      _lastKnown[id] = p;
      if (!_scanCtrl.isClosed) _scanCtrl.add(p);
    }
    for (final id in _seen.toList()) {
      if (heard.contains(id)) continue;
      // A peer that left takes its link with it: on hardware the write would fail anyway,
      // and failing here is what makes the app handle it.
      _links.remove(id);
      _lastKnown.remove(id);
    }
    _seen
      ..clear()
      ..addAll(heard);
  }

  /// Delivers whatever has arrived in the local inbox since the last poll.
  ///
  /// Filtered to the peer the connection is with, and to the message types an app cares
  /// about: `file` chunks belong to [progressOf] rather than to a byte stream, and `sync`,
  /// `ack` and `ogm` are the engine's own bookkeeping. What is left is what a chat surface
  /// would render.
  void _pollInbox() {
    final me = _node;
    if (me == null || _links.isEmpty) return;
    final inboxIds = <String>{};
    for (final m in me.inbox) {
      inboxIds.add(m.id);
    }
    for (final peerId in _links.keys.toList()) {
      final ctrl = _rxCtrls[peerId];
      if (ctrl == null || ctrl.isClosed) continue;
      final done = _emitted.putIfAbsent(peerId, () => <String>{});
      for (final m in me.inbox) {
        if (m.from != peerId) continue;
        if (!_isAppPayload(m.type)) continue;
        if (done.contains(m.id)) continue;
        done.add(m.id);
        ctrl.add(latin1.encode(m.body));
      }
      // Bounded by the inbox rather than by the length of the run: a message the engine has
      // trimmed cannot arrive again, so forgetting its id is safe and keeps this set from
      // growing for the life of the process.
      done.retainWhere(inboxIds.contains);
    }
  }

  /// One peer, as this device would measure it. Null when the peer has gone or is offline.
  Peer? _measure(PeerId id) {
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
      txPowerDbm: peer.txPower,
      isSuper: ogm?.isSuper ?? false,
      at: sim.now,
    );
  }
}

/// The message types an app would show. Everything else is either a chunk, which belongs to
/// [SimulatedMeshTransport.progressOf] rather than to a byte stream, or the engine's own
/// bookkeeping.
const Set<MsgType> _appPayloadTypes = <MsgType>{
  MsgType.text,
  MsgType.broadcast,
  MsgType.voice,
  MsgType.sos,
};

bool _isAppPayload(MsgType type) => _appPayloadTypes.contains(type);

/// FNV-1a over 32 bits, for the beacon's id field.
///
/// Chosen because it is four lines, has no dependency, and is the same on both platforms — a
/// beacon that hashes differently on Android and iOS is a beacon nobody can match. It is not
/// a security primitive: the id is public, and `docs/04` is explicit that discovery carries
/// no secret.
int beaconIdHash(PeerId id) {
  var h = 0x811C9DC5;
  for (var i = 0; i < id.length; i++) {
    h = (h ^ id.codeUnitAt(i)) & 0xFFFFFFFF;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
