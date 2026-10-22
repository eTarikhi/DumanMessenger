import 'dart:math' as math;

import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Media transport: chunked files, streamed push-to-talk, and the air time a large
/// payload occupies the radio with (docs/05 §3.2-3.3, roadmap Phase 3, docs/08).
///
/// Mirrors the `media transport` block in `src/__tests__/simulation.test.ts` so a
/// divergence between the two engines fails CI in whichever language moved.
void main() {
  /// A line of nodes 20 m apart: inside the 31.6 m line-of-sight budget for a
  /// neighbour and outside it for the next one along (at 40 m the model gives
  /// −87 dBm against a −85 dBm sensitivity), so hop count is exactly the distance
  /// in indices and every assertion is about the media plane rather than about who
  /// happened to be in range.
  MeshSimulation lineWorld({
    int n = 4,
    int transferWindow = 4,
    int transferChunkBytes = 65536,
    double voiceKbps = 12,
    bool adaptiveMediaAck = false,
    bool captureLog = false,
  }) {
    final sim = MeshSimulation(SimConfig(
      nodeCount: n,
      stationaryRatio: 1.0,
      chargingRatio: 0.0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      // defaultConfig carries walls, and a wall between two nodes 20 m apart turns
      // the "line" into a partition. The geometry has to be the only variable here.
      obstacles: const <Obstacle>[],
      transferWindow: transferWindow,
      transferChunkBytes: transferChunkBytes,
      voiceKbps: voiceKbps,
      adaptiveMediaAck: adaptiveMediaAck,
      captureLog: captureLog,
    ));
    for (var i = 0; i < sim.nodes.length; i++) {
      final node = sim.nodes[i];
      node.pos = Vec2(10.0 + i * 20, 10);
      node.target = Vec2(10.0 + i * 20, 10);
      node.mobility = 0;
      node.isOnline = true;
      node.battery = 1.0;
    }
    sim.runFor(20000); // beacons settle, routes form
    sim.clearRecords();
    return sim;
  }

  bool runUntil(MeshSimulation sim, bool Function() done, double budgetMs) {
    var elapsed = 0.0;
    while (!done() && elapsed < budgetMs) {
      sim.runFor(100);
      elapsed += 100;
    }
    return done();
  }

  group('media transport', () {
    test('charges air time only for the part of a payload above one packet', () {
      final sim = lineWorld(n: 2);
      // A text message, an OGM and an ACK all sit under the 1024 B ceiling, so the
      // hop latency they were calibrated with is untouched — that is what keeps the
      // golden vectors byte-identical.
      expect(sim.serializationMs(0, TransportType.ble), equals(0.0));
      expect(sim.serializationMs(bleMaxBytes, TransportType.ble), equals(0.0));
      expect(sim.serializationMs(bleMaxBytes, TransportType.wifiDirect), equals(0.0));
      expect(
        sim.serializationMs(65536, TransportType.wifiDirect),
        closeTo(((65536 - 1024) * 8) / 20000, 1e-9),
      );
      expect(
        sim.serializationMs(65536, TransportType.ble),
        closeTo(((65536 - 1024) * 8) / 80, 1e-9),
      );
      // docs/05 §3.2's "250x faster than BLE" is what the two rates reproduce.
      expect(
        sim.serializationMs(65536, TransportType.ble) /
            sim.serializationMs(65536, TransportType.wifiDirect),
        closeTo(250.0, 1e-9),
      );
      expect(sim.config.wifiDirectKbps / sim.config.bleKbps, equals(250.0));
    });

    test('sends a file as 64 KB chunks and completes the transfer', () {
      final sim = lineWorld(n: 3);
      final a = sim.nodes[0];
      final c = sim.nodes[2];
      final t = sim.sendFile(a.id, c.id, 256 * 1024)!;
      expect(t.chunks, equals(4)); // 256 KB / 64 KB
      expect(t.kind, equals(TransferKind.file));
      expect(runUntil(sim, () => t.state == TransferState.complete, 120000), isTrue);
      expect(t.received, equals(4));
      expect(t.completedAt, isNotNull);
      expect(c.inbox.where((m) => m.type == MsgType.file).length, equals(4));

      final stats = sim.refresh();
      expect(stats.transfersStarted, equals(1));
      expect(stats.transfersCompleted, equals(1));
      expect(stats.bytesDelivered, equals(256 * 1024));
      expect(stats.sentChunks, greaterThanOrEqualTo(4));
      // Two hops apart, so the chunks rode the radio that can actually carry them.
      expect(t.transport, equals(TransportType.wifiDirect));
    });

    test('keeps media out of the 1:1 delivery metrics', () {
      final sim = lineWorld(n: 3);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[2].id, 256 * 1024)!;
      runUntil(sim, () => t.state == TransferState.complete, 120000);
      final stats = sim.refresh();
      // A 10 MB file is 160 chunks: folded into deliveryRatio it would make the
      // metric about the file instead of about the mesh.
      expect(stats.sentUnicast, equals(0));
      expect(stats.sentChunks, greaterThanOrEqualTo(4));
      expect(sim.sentRecords.where((r) => r.transferId == null).isEmpty, isTrue);
      expect(
        sim.deliveries
            .where((d) => d.type != MsgType.ack)
            .every((d) => d.transferId != null),
        isTrue,
      );
    });

    test('slides a window instead of putting the whole file on air at once', () {
      final sim = lineWorld(n: 4, transferWindow: 2);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[3].id, 8 * 64 * 1024)!;
      expect(t.chunks, equals(8));
      expect(t.window, equals(2));
      // Nothing has arrived yet, so only the window is in flight.
      expect(sim.refresh().sentChunks, equals(2));
      expect(runUntil(sim, () => t.state == TransferState.complete, 300000), isTrue);
      expect(t.received, equals(8));

      // A deeper window is measurably faster: this is the lever docs/08 §4 reports.
      final wide = lineWorld(n: 4, transferWindow: 8);
      final t2 = wide.sendFile(wide.nodes[0].id, wide.nodes[3].id, 8 * 64 * 1024)!;
      expect(runUntil(wide, () => t2.state == TransferState.complete, 300000), isTrue);
      expect(t2.completedAt! - t2.startedAt, lessThan(t.completedAt! - t.startedAt));
    });

    test('slices to the BLE ceiling when there is no Wi-Fi Direct capacity', () {
      final sim = lineWorld(n: 2, transferChunkBytes: 1024);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 64 * 1024)!;
      expect(t.chunks, equals(64));
      expect(t.transport, equals(TransportType.ble));
      expect(runUntil(sim, () => t.state == TransferState.complete, 300000), isTrue);
      expect(t.received, equals(64));
    });

    test('keeps a 500 ms Opus frame inside one BLE packet at 12 kbps, and not at 24',
        () {
      // frameBytes = frameMs x kbps / 8. Under the 1024 B ceiling the frame rides
      // BLE, which is the radio that is guaranteed to be up; over it, the note would
      // silently need Wi-Fi Direct. That is why docs/05 §3.3 says 6-12 kbps.
      final ble = lineWorld(n: 2);
      final note = ble.sendVoice(ble.nodes[0].id, ble.nodes[1].id, 1.0)!;
      expect(note.chunkBytes, equals(750));
      expect(note.transport, equals(TransportType.ble));

      final wifi = lineWorld(n: 2, voiceKbps: 24);
      final loud = wifi.sendVoice(wifi.nodes[0].id, wifi.nodes[1].id, 1.0)!;
      expect(loud.chunkBytes, equals(1500));
      expect(loud.transport, equals(TransportType.wifiDirect));
      expect((bleMaxBytes * 8) / wifi.config.voiceFrameMs, closeTo(16.384, 1e-9));
    });

    test('streams a note while it is being recorded, so audio starts before release',
        () {
      final sim = lineWorld(n: 2);
      final t = sim.sendVoice(sim.nodes[0].id, sim.nodes[1].id, 3.0)!;
      expect(t.chunks, equals(6)); // 3 s / 500 ms
      expect(t.releasedAt, closeTo(t.startedAt + 3000, 1e-6));
      expect(runUntil(sim, () => t.state == TransferState.complete, 30000), isTrue);
      // The first frame is playable long before the button is let go — that is the
      // whole point of streaming, and the blob's disadvantage.
      expect(t.firstChunkAt!, lessThan(t.releasedAt!));
      expect(t.firstChunkAt! - t.startedAt, lessThan(1500.0));

      final blobSim = lineWorld(n: 2);
      final blob =
          blobSim.sendVoice(blobSim.nodes[0].id, blobSim.nodes[1].id, 3.0, stream: false)!;
      expect(blob.chunks, equals(1));
      expect(blob.totalBytes, equals(6 * 750));
      expect(runUntil(blobSim, () => blob.state == TransferState.complete, 30000), isTrue);
      expect(blob.firstChunkAt!, greaterThanOrEqualTo(blob.releasedAt!));
    });

    test("meets the roadmap's push-to-talk budget at 1 and 3 hops", () {
      // "PTT Opus note plays in <3s 1-hop / <8s 3-hop", measured from release to the
      // last frame arriving plus the 200 ms jitter buffer.
      final sim = lineWorld();
      final near = sim.sendVoice(sim.nodes[0].id, sim.nodes[1].id, 3.0)!;
      expect(runUntil(sim, () => near.state == TransferState.complete, 30000), isTrue);
      final nearDelay =
          near.completedAt! + sim.config.jitterBufferMs - near.releasedAt!;
      expect(nearDelay, greaterThan(0.0));
      expect(nearDelay, lessThan(3000.0));

      final far = sim.sendVoice(sim.nodes[0].id, sim.nodes[3].id, 3.0)!;
      expect(runUntil(sim, () => far.state == TransferState.complete, 30000), isTrue);
      final farDelay = far.completedAt! + sim.config.jitterBufferMs - far.releasedAt!;
      expect(farDelay, lessThan(8000.0));
      expect(farDelay, greaterThan(nearDelay));
    });

    test('carries a 10 MB image three hops on Wi-Fi Direct inside a minute', () {
      // The roadmap's exit criterion: "2 phones exchange image <10 MB over WiFi
      // Direct mesh". Three hops is the distance the criterion's latency budget is
      // written for.
      final sim = lineWorld();
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[3].id, 10 * 1024 * 1024)!;
      expect(t.chunks, equals(160));
      expect(runUntil(sim, () => t.state == TransferState.complete, 180000), isTrue);
      expect(t.transport, equals(TransportType.wifiDirect));
      expect(t.received, equals(160));
      expect(t.completedAt! - t.startedAt, lessThan(60000.0));
      expect(sim.refresh().bytesDelivered, equals(10 * 1024 * 1024));
    });

    test('cannot carry a 10 MB image over BLE in any reasonable time', () {
      // Which is what docs/05 §3.2's "auto-reject files >5 MB on BLE-only with a
      // 'move closer to SUPER' hint" is protecting the user from.
      final sim = lineWorld(n: 2, transferChunkBytes: 1024);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1024 * 1024)!;
      expect(t.chunks, equals(10240));
      expect(t.transport, equals(TransportType.ble));
      sim.runFor(60000);
      expect(t.state, equals(TransferState.active));
      expect(t.received / t.chunks, lessThan(0.2));
    });

    test('re-sends the chunks a stalled window is missing, and resumes when the peer returns',
        () {
      final sim = lineWorld(n: 3, transferWindow: 2);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[2].id, 8 * 64 * 1024)!;
      // The receiver walks away: the window stops moving. Without a watchdog the
      // transfer would hang forever, because a chunk whose retries ran out sits in
      // the OppQueue and its logical id is never seen again.
      sim.toggleNodeOnline(sim.nodes[2].id);
      expect(runUntil(sim, () => t.stalls > 0, 60000), isTrue);
      expect(sim.refresh().transferStalls, greaterThan(0));
      expect(t.state, equals(TransferState.active));

      // "Resume on reconnect" (docs/05 §3.2): the peer comes back and the missing
      // chunks are re-sent, so the transfer finishes rather than being abandoned.
      sim.toggleNodeOnline(sim.nodes[2].id);
      expect(runUntil(sim, () => t.state == TransferState.complete, 300000), isTrue);
      expect(t.received, equals(8));
    });

    test("retries a chunk on the media timer, not the text plane's", () {
      final sim = lineWorld(n: 2);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 64 * 1024)!;
      // Cold start, before any ACK has measured the path.
      expect(sim.mediaTimeoutMs(t), equals(sim.config.mediaAckTimeoutMs));
      expect(sim.config.mediaAckTimeoutMs, lessThan(sim.config.ackTimeoutMs));
      expect(runUntil(sim, () => t.state == TransferState.complete, 60000), isTrue);

      // With the adaptive rule on, the timer is built from the round trips this
      // transfer's own ACKs reported: 2 x minRtt + 200, clamped to [300, ackTimeoutMs].
      final adaptive = lineWorld(adaptiveMediaAck: true);
      final t2 = adaptive.sendFile(
          adaptive.nodes[0].id, adaptive.nodes[3].id, 4 * 64 * 1024)!;
      expect(runUntil(adaptive, () => t2.state == TransferState.complete, 120000), isTrue);
      expect(t2.minRttMs, isNotNull);
      expect(
        adaptive.mediaTimeoutMs(t2),
        equals(math.min(adaptive.config.ackTimeoutMs,
            math.max(300.0, 2 * t2.minRttMs! + 200))),
      );
      expect(t2.srttMs, isNotNull);
    });

    test('refuses media from a node that is offline or to nobody', () {
      final sim = lineWorld(n: 3);
      sim.toggleNodeOnline(sim.nodes[0].id);
      expect(sim.sendFile(sim.nodes[0].id, sim.nodes[2].id, 64 * 1024), isNull);
      expect(sim.sendVoice(sim.nodes[0].id, sim.nodes[2].id, 3.0), isNull);
      expect(sim.sendFile(sim.nodes[1].id, sim.nodes[2].id, 0), isNull);
      expect(sim.sendVoice(sim.nodes[1].id, sim.nodes[2].id, 0), isNull);
      expect(sim.refresh().transfersStarted, equals(0));
    });
  });

  group('media against skills/05 (Voice PTT & Media)', () {
    test('sends voice chunks as VOICE_CHUNK: type voice, priority high, ttl 3', () {
      final sim = lineWorld(n: 3, captureLog: true);
      final t = sim.sendVoice(sim.nodes[0].id, sim.nodes[2].id, 1.0)!;
      runUntil(sim, () => t.state == TransferState.complete, 60000);
      final frames =
          sim.nodes[2].inbox.where((m) => m.transferId == t.id).toList();
      expect(frames.length, equals(2));
      for (final f in frames) {
        expect(f.type, equals(MsgType.voice));
        expect(f.priority, equals(Priority.high));
        // skills/05: "VOICE_CHUNK packets prio=high, ttl=3". A frame that needs
        // four hops is stale on arrival, so it is not worth the radio time.
        expect(f.ttl, lessThanOrEqualTo(3));
        expect(f.sizeBytes, equals(750));
        expect(f.transport, equals(TransportType.ble));
      }
      // A file chunk is not a voice chunk: it keeps the data plane's ttl.
      final file = sim.sendFile(sim.nodes[0].id, sim.nodes[2].id, 128 * 1024)!;
      runUntil(sim, () => file.state == TransferState.complete, 60000);
      final slices =
          sim.nodes[2].inbox.where((m) => m.transferId == file.id).toList();
      expect(slices.every((m) => m.type == MsgType.file), isTrue);
      expect(slices.first.ttl, lessThanOrEqualTo(5));
    });

    test('rides Wi-Fi Direct for a voice note when the group owner is connected', () {
      // skills/05: "Send: VOICE_CHUNK packets ... via best transport (WiFi Direct if
      // GO connected, else chunked BLE 512B MTU)". The transport is a property of
      // what has been negotiated, not only of the payload size.
      final sim = lineWorld(n: 2);
      final t = sim.sendVoice(sim.nodes[0].id, sim.nodes[1].id, 1.0,
          transport: TransportType.wifiDirect)!;
      expect(t.forcedTransport, equals(TransportType.wifiDirect));
      expect(runUntil(sim, () => t.state == TransferState.complete, 60000), isTrue);
      expect(t.transport, equals(TransportType.wifiDirect));
      final delay = t.completedAt! + sim.config.jitterBufferMs - t.releasedAt!;
      // skills/05 acceptance: "1-hop WiFi: PTT round-trip <1s".
      expect(delay, lessThan(1000.0));
      // Its modes table puts streaming PTT at 150-300 ms on one Wi-Fi Direct hop;
      // the model's floor is the 40 ms hop plus 50-200 ms of jitter.
      expect(delay - sim.config.jitterBufferMs, lessThan(300.0));
    });

    test('refuses a transfer over the 10 MB ceiling', () {
      final sim = lineWorld(n: 2, captureLog: true);
      expect(sim.config.maxTransferBytes, equals(10 * 1048576));
      expect(sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1048576), isNotNull);
      expect(sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1048576 + 1), isNull);
      expect(
        sim.log.any((l) =>
            l.kind == MeshLogKind.transfer && l.detail.contains('ceiling')),
        isTrue,
      );
    });

    test('resumes a 10 MB Wi-Fi Direct image after a mid-transfer disconnect', () {
      // skills/05 acceptance, verbatim: "10 MB image: delivered over WiFi Direct with
      // resume after mid-transfer disconnect". Three hops, receiver gone for 20 s at
      // about a third of the way in.
      final sim = lineWorld(captureLog: true);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[3].id, 10 * 1024 * 1024,
          transport: TransportType.wifiDirect)!;
      expect(t.chunks, equals(160));
      expect(
          runUntil(sim, () => t.received >= (t.chunks * 0.3).floor(), 120000), isTrue);
      final atDisconnect = t.received;

      sim.toggleNodeOnline(sim.nodes[3].id);
      sim.runFor(20000);
      expect(t.state, equals(TransferState.active));
      expect(t.received, equals(atDisconnect)); // nothing arrives while it is away
      expect(t.stalls, greaterThan(0)); // ... and the watchdog notices

      sim.toggleNodeOnline(sim.nodes[3].id);
      expect(runUntil(sim, () => t.state == TransferState.complete, 600000), isTrue);
      expect(t.received, equals(160));
      expect(t.transport, equals(TransportType.wifiDirect));
      expect(sim.refresh().bytesDelivered, greaterThanOrEqualTo(10 * 1024 * 1024));
    });

    test('slices to the 512 B BLE MTU when there is no Wi-Fi Direct capacity', () {
      // skills/05: "else chunked BLE 512B MTU". Half the packet ceiling, so a slice
      // stays on BLE with room for its header, and a 10 MB image becomes 20480 of
      // them — which is what docs/05's auto-reject rule is for (docs/08 §8).
      final sim = lineWorld(n: 2);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * 1024 * 1024,
          chunkBytes: 512)!;
      expect(t.chunks, equals(20480));
      expect(t.transport, equals(TransportType.ble));
      sim.runFor(60000);
      expect(t.state, equals(TransferState.active));
      expect(t.received / t.chunks, lessThan(0.1));
    });
  });
}
