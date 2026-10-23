import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

/// Channel access: what happens when a device has the one radio it actually has
/// (docs/08 §12).
///
/// Mirrors the `channel access` block in `src/__tests__/simulation.test.ts`, so a
/// divergence between the two engines fails CI in whichever language moved. The point
/// of the flag is that `ChannelAccess.free` — the default, and the model every other
/// number in this repository was measured under — has no shared medium at all, so media
/// has no mechanism by which it could harm text. These tests pin both halves of that.
void main() {
  /// A line of nodes 20 m apart: inside the 31.6 m line-of-sight budget for a neighbour
  /// and outside it for the next one along, so hop count is exactly the distance in
  /// indices and every assertion is about the radio rather than about who happened to be
  /// in range.
  MeshSimulation lineWorld({
    int n = 4,
    ChannelAccess channelAccess = ChannelAccess.free,
    int channelQueueDepth = 8,
    ChannelPriority channelPriority = ChannelPriority.fifo,
    ChannelCapture channelCapture = ChannelCapture.none,
  }) {
    final sim = MeshSimulation(SimConfig(
      nodeCount: n,
      stationaryRatio: 1.0,
      chargingRatio: 0.0,
      trafficIntervalMs: 0,
      enableSuperElection: false,
      warmupMs: 0,
      obstacles: const <Obstacle>[],
      channelAccess: channelAccess,
      channelQueueDepth: channelQueueDepth,
      channelPriority: channelPriority,
      channelCapture: channelCapture,
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

  test('occupies no radio by default: nothing is deferred and nothing is dropped', () {
    final sim = MeshSimulation(campusQuad(42).copyWith(trafficIntervalMs: 1000.0));
    sim.runFor(120000);
    final stats = sim.refresh();
    expect(stats.totalForwarded, greaterThan(100));
    expect(stats.channelDeferrals, 0);
    expect(stats.channelDeferMs, 0.0);
    expect(stats.channelDrops, 0);
  });

  test('makes a packet wait its turn, and still delivers it', () {
    final sim = lineWorld(n: 2, channelAccess: ChannelAccess.halfDuplex);
    final a = sim.nodes[0];
    final b = sim.nodes[1];
    for (var i = 0; i < 4; i++) {
      sim.sendMessage(a.id, b.id, 'hd-$i');
    }
    int texts() => sim.deliveries
        .where((d) => d.to == b.id && d.type == MsgType.text)
        .length;
    expect(runUntil(sim, () => texts() >= 4, 10000), isTrue);

    final stats = sim.refresh();
    expect(stats.channelDeferrals, greaterThan(0));
    expect(stats.channelDeferMs, greaterThan(0.0));
    // One radio, so the four copies land one air time apart rather than together.
    final lat = sim.deliveries
        .where((d) => d.to == b.id && d.type == MsgType.text)
        .map((d) => d.latencyMs)
        .toList()
      ..sort();
    expect(lat.last - lat.first, greaterThan(defaultConfig.hopLatencyBleMs));
  });

  test('wakes a radio that went busy with an empty queue', () {
    // Regression. The first implementation only scheduled a drain when it left packets
    // behind, so a radio that finished its queue while still busy had nothing to wake it
    // and the next packet waited for some *other* transmission to come along. In a quiet
    // mesh that is forever, and the symptom was a delivery ratio of 0.37 on a campus with
    // no media in flight at all.
    final sim = lineWorld(n: 2, channelAccess: ChannelAccess.halfDuplex);
    final a = sim.nodes[0];
    final b = sim.nodes[1];
    int texts() =>
        sim.deliveries.where((d) => d.to == b.id && d.type == MsgType.text).length;
    sim.sendMessage(a.id, b.id, 'first');
    sim.runFor(50); // on air, queue drained, radio still busy
    sim.sendMessage(a.id, b.id, 'second');
    expect(runUntil(sim, () => texts() >= 2, 5000), isTrue);
  });

  test('sheds load when the queue is full instead of promising air time it lacks', () {
    final sim = lineWorld(
        n: 2, channelAccess: ChannelAccess.halfDuplex, channelQueueDepth: 1);
    final a = sim.nodes[0];
    final b = sim.nodes[1];
    for (var i = 0; i < 6; i++) {
      sim.sendMessage(a.id, b.id, 'drop-$i');
    }
    expect(runUntil(sim, () => sim.refresh().channelDrops > 0, 5000), isTrue);
    final delivered =
        sim.deliveries.where((d) => d.to == b.id && d.type == MsgType.text).length;
    expect(delivered, lessThan(6));
  });

  test('takes the parallelism out of the sliding window, which is the whole finding', () {
    const mb = 1048576;
    double transferMs(ChannelAccess channelAccess, int window) {
      final sim = lineWorld(n: 2, channelAccess: channelAccess);
      final t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 10 * mb,
          window: window)!;
      expect(runUntil(sim, () => t.state == TransferState.complete, 900000), isTrue);
      return (t.completedAt ?? 0) - t.startedAt;
    }

    final free1 = transferMs(ChannelAccess.free, 1);
    final free4 = transferMs(ChannelAccess.free, 4);
    final hd1 = transferMs(ChannelAccess.halfDuplex, 1);
    final hd4 = transferMs(ChannelAccess.halfDuplex, 4);

    // On an infinitely wide radio a window of four is four transmissions at once and is
    // worth 3.8x here; on one radio they are four transmissions in a row and it is worth
    // 1.1x -- while the whole transfer takes ten times longer.
    expect(free1 / free4, greaterThan(3.0));
    expect(hd1 / hd4, lessThan(1.5));
    expect(hd4, greaterThan(free4 * 5));
  });

  test('keeps up with the capture clock at one hop and falls behind at three', () {
    // A 500 ms frame is 750 B, which is one BLE packet, so its air time is hop latency
    // plus jitter: about 245 ms a hop. At one hop that is half the capture clock and
    // streaming holds. At three hops it is 735 ms of radio for every 500 ms recorded, so
    // the queue grows for as long as you keep talking. Nothing is lost — the note arrives
    // complete — but it arrives long after you let go.
    double delayAfterRelease(int hops, ChannelAccess channelAccess) {
      final sim = lineWorld(n: hops + 1, channelAccess: channelAccess);
      final note = sim.sendVoice(
          sim.nodes[0].id, sim.nodes[hops].id, 10.0,
          stream: true)!;
      expect(runUntil(sim, () => note.state == TransferState.complete, 200000), isTrue);
      expect(note.received, note.chunks);
      return (note.completedAt ?? 0) - (note.releasedAt ?? note.startedAt);
    }

    expect(delayAfterRelease(1, ChannelAccess.halfDuplex), lessThan(1000.0));
    final threeOnOneRadio = delayAfterRelease(3, ChannelAccess.halfDuplex);
    final threeOnFreeRadio = delayAfterRelease(3, ChannelAccess.free);
    expect(threeOnOneRadio, greaterThan(10000.0));
    expect(threeOnFreeRadio, lessThan(2000.0));
    expect(threeOnOneRadio, greaterThan(threeOnFreeRadio * 10));
  });

  /// One radio, one sender, a 2 MB file already committed to it, and then something else
  /// arriving. The arrival order is the same in every arm, so whatever differs is the
  /// queue discipline.
  /// When the acknowledgement this test injected (A -> B) arrived. The transfer's own
  /// acknowledgements run the other way (B -> A), so the recipient is what tells them
  /// apart; without that filter the measurement picks up somebody else's ACK.
  double? injectedAckAt(MeshSimulation sim) {
    final b = sim.nodes[1].id;
    for (final d in sim.deliveries) {
      if (d.type == MsgType.ack && d.to == b) return d.timestamp;
    }
    return null;
  }

  ({MeshSimulation sim, Transfer file}) busyRadio(ChannelPriority priority) {
    final sim = lineWorld(
        n: 2,
        channelAccess: ChannelAccess.halfDuplex,
        channelPriority: priority);
    final a = sim.nodes[0].id;
    final b = sim.nodes[1].id;
    final file = sim.sendFile(a, b, 2 * 1048576)!;
    sim.runFor(1000); // some chunks are queued and the radio is committed
    return (sim: sim, file: file);
  }

  test('lets a voice note overtake the bulk transfer, and only when asked to', () {
    // Arrival order: the note's frames sit behind the chunks already queued, so the note
    // finishes when the file does.
    final fifo = busyRadio(ChannelPriority.fifo);
    final fifoNote = fifo.sim.sendVoice(
        fifo.sim.nodes[0].id, fifo.sim.nodes[1].id, 5.0,
        stream: true)!;
    runUntil(fifo.sim, () => fifoNote.state == TransferState.complete, 600000);
    runUntil(fifo.sim, () => fifo.file.state == TransferState.complete, 600000);
    final fifoFileDone = fifo.file.completedAt ?? double.infinity;
    final fifoFramesFirst = fifo.sim.deliveries
        .where((d) =>
            d.transferId == fifoNote.id && d.timestamp < fifoFileDone)
        .length;
    expect(fifoNote.state, TransferState.complete);
    expect((fifoNote.completedAt ?? double.infinity) < fifoFileDone, isFalse);
    expect(fifoFramesFirst, lessThan(fifoNote.chunks));

    // Under the class ranking the same ten frames all go first and the note is done
    // about nine seconds sooner.
    final cls = busyRadio(ChannelPriority.byClass);
    final clsNote = cls.sim.sendVoice(
        cls.sim.nodes[0].id, cls.sim.nodes[1].id, 5.0,
        stream: true)!;
    runUntil(cls.sim, () => clsNote.state == TransferState.complete, 600000);
    runUntil(cls.sim, () => cls.file.state == TransferState.complete, 600000);
    final clsFileDone = cls.file.completedAt ?? double.infinity;
    final clsFramesFirst = cls.sim.deliveries
        .where((d) => d.transferId == clsNote.id && d.timestamp < clsFileDone)
        .length;
    expect(clsNote.state, TransferState.complete);
    expect((clsNote.completedAt ?? double.infinity) < clsFileDone, isTrue);
    expect(clsFramesFirst, clsNote.chunks);
    expect((clsNote.completedAt ?? 0) - clsNote.startedAt,
        lessThan((fifoNote.completedAt ?? 0) - fifoNote.startedAt - 5000));
  });

  test('promoting acknowledgements is what pays for the bulk transfer', () {
    final fifo = busyRadio(ChannelPriority.fifo);
    fifo.sim
        .sendMessage(fifo.sim.nodes[0].id, fifo.sim.nodes[1].id, 'probe-ack', MsgType.ack);
    runUntil(fifo.sim, () => fifo.file.state == TransferState.complete, 600000);
    final fifoAckAt = injectedAckAt(fifo.sim);
    expect(fifoAckAt, isNotNull);
    final fifoChunksBefore = fifo.sim.deliveries
        .where((d) => d.transferId == fifo.file.id && d.timestamp < fifoAckAt!)
        .length;

    final ack = busyRadio(ChannelPriority.ackFirst);
    ack.sim
        .sendMessage(ack.sim.nodes[0].id, ack.sim.nodes[1].id, 'probe-ack', MsgType.ack);
    runUntil(ack.sim, () => ack.file.state == TransferState.complete, 600000);
    final ackAt = injectedAckAt(ack.sim);
    expect(ackAt, isNotNull);
    final ackChunksBefore = ack.sim.deliveries
        .where((d) => d.transferId == ack.file.id && d.timestamp < ackAt!)
        .length;

    expect(ackChunksBefore, lessThan(fifoChunksBefore));
    // An ACK is ~100 bytes and it releases the next chunk, so letting it overtake a few
    // 64 KB slices takes about 17% off the transfer.
    expect((ack.file.completedAt ?? 0) - ack.file.startedAt,
        lessThan((fifo.file.completedAt ?? 0) - fifo.file.startedAt));
  });

  test('is never consulted on the shipped radio, because nothing ever waits there', () {
    for (final priority in <ChannelPriority>[
      ChannelPriority.fifo,
      ChannelPriority.byClass
    ]) {
      final sim = lineWorld(n: 2, channelPriority: priority);
      final a = sim.nodes[0].id;
      final b = sim.nodes[1].id;
      for (var i = 0; i < 5; i++) {
        sim.sendMessage(a, b, 'm$i');
      }
      sim.runFor(20000);
      expect(sim.refresh().channelDeferrals, 0);
      expect(
          sim.deliveries
              .where((d) => d.to == b && d.type == MsgType.text)
              .length,
          5);
    }
  });

  test('loses the second of two packets that arrive together, and only when asked to', () {
    /// A-B-C in a line, 20 m apart: A and C both reach B, and neither reaches the other.
    ({int captured, int deaf, int arrived}) run(ChannelCapture capture) {
      final sim = lineWorld(n: 3, channelCapture: capture);
      final a = sim.nodes[0];
      final b = sim.nodes[1];
      final c = sim.nodes[2];
      // Two senders, one receiver, the same instant: the air time of a text packet is about
      // 245 ms, so the second arrival lands while B is still locked onto the first.
      sim.sendMessage(a.id, b.id, 'from-a');
      sim.sendMessage(c.id, b.id, 'from-c');
      sim.runFor(20000);
      final st = sim.refresh();
      return (
        captured: st.channelCaptured,
        deaf: st.channelDeafRx,
        arrived: sim.deliveries
            .where((d) => d.to == b.id && d.type == MsgType.text)
            .length,
      );
    }

    final none = run(ChannelCapture.none);
    expect(none.captured, 0);
    expect(none.deaf, 0);
    expect(none.arrived, 2); // both arrive: this is the model §9's null result lives in

    final first = run(ChannelCapture.first);
    expect(first.captured, 1);
    // ... and the message is not lost, only late: the sender's ACK timeout re-sends it into
    // an idle radio. That is why receiver contention costs p95 before it costs delivery.
    expect(first.arrived, 2);
  });

  test('loses a packet that arrives while its receiver is transmitting', () {
    ({int deaf, int arrived}) run(ChannelCapture capture) {
      final sim = lineWorld(n: 2, channelCapture: capture);
      final a = sim.nodes[0];
      final b = sim.nodes[1];
      sim.sendMessage(a.id, b.id, 'a-to-b');
      sim.sendMessage(b.id, a.id, 'b-to-a');
      sim.runFor(20000);
      final st = sim.refresh();
      return (
        deaf: st.channelDeafRx,
        arrived: sim.deliveries.where((d) => d.type == MsgType.text).length,
      );
    }

    // A half-duplex radio cannot hear over its own transmitter. The two transmissions are not
    // exactly simultaneous — each message is scheduled by its own sender — so one packet lands
    // inside the other's transmit window and the other lands just after it: one collision, and
    // the retry recovers it.
    expect(run(ChannelCapture.none).deaf, 0);
    final first = run(ChannelCapture.first);
    expect(first.deaf, 1);
    expect(first.arrived, 2);
  });

  test('counts nothing at all in the shipped model, whatever the transmitter does', () {
    for (final channelAccess in <ChannelAccess>[
      ChannelAccess.free,
      ChannelAccess.halfDuplex
    ]) {
      final sim = MeshSimulation(campusQuad(42)
          .copyWith(trafficIntervalMs: 1000, channelAccess: channelAccess));
      sim.runFor(120000);
      final stats = sim.refresh();
      expect(stats.channelCaptured, 0);
      expect(stats.channelDeafRx, 0);
      expect(stats.totalForwarded, greaterThan(100));
    }
  });
}
