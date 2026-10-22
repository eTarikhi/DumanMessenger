/**
 * Measures the media transport roadmap Phase 3 asks for: a chunked file transfer
 * and a streamed push-to-talk note, at 1/2/3 hops, on both radios.
 *
 * The exit criteria being tested are the roadmap's own —
 *   "2 phones exchange image <10 MB over WiFi Direct mesh"
 *   "PTT Opus note plays in <3 s 1-hop / <8 s 3-hop"
 * — plus the design claims docs/05 §3.2-3.3 makes about how they are met (64 KB
 * slices with a sliding window, 500 ms Opus frames at 6-12 kbps, a 200 ms jitter
 * buffer, and "auto-reject >5 MB on BLE-only").
 *
 * Everything here is measured, not assumed: the numbers printed are what the
 * engine did, and docs/08 quotes them.
 *
 * Run with `npm run media`.
 */
import { MeshSimulation, DEFAULT_CONFIG, type SimConfig } from "../src/simulation";
import { campusQuad, festivalCrowd } from "../src/scenarios";
import { canReach, effectiveLossProbability, peersInRange } from "../src/rf";
import type { MeshNode, NodeId, TransportType } from "../src/types";

const MB = 1048576;
const SEEDS = [42, 7, 1234];

/** Shortest hop count from `from` to every online node, over links that can carry
 *  a packet right now. Used to place a sender and receiver an exact distance apart. */
function bfsHops(sim: MeshSimulation, from: MeshNode): Map<NodeId, number> {
  const online = sim.nodes.filter((n) => n.isOnline);
  const dist = new Map<NodeId, number>([[from.id, 0]]);
  const queue: MeshNode[] = [from];
  while (queue.length > 0) {
    const n = queue.shift()!;
    const d = dist.get(n.id)!;
    for (const p of peersInRange(n, online, sim.rf)) {
      if (!dist.has(p.id)) {
        dist.set(p.id, d + 1);
        queue.push(p);
      }
    }
  }
  return dist;
}

/** A pair exactly `hops` apart, preferring a clean first and last leg so the
 *  measurement is about distance rather than about retransmission. */
function pairAtHops(sim: MeshSimulation, hops: number): [MeshNode, MeshNode] | null {
  let best: { a: MeshNode; b: MeshNode; loss: number } | null = null;
  for (const a of sim.nodes.filter((n) => n.isOnline)) {
    const dist = bfsHops(sim, a);
    for (const b of sim.nodes.filter((n) => n.isOnline && n.id !== a.id)) {
      if (dist.get(b.id) !== hops) continue;
      if (hops === 1 && !canReach(a, b, sim.rf)) continue;
      // Loss on the legs we can see: the endpoints' own radios.
      const legA = peersInRange(a, sim.nodes.filter((n) => n.isOnline), sim.rf)
        .map((p) => effectiveLossProbability(a, p, sim.rf, sim.config.linkRetries))
        .sort((x, y) => x - y)[0] ?? 1;
      const legB = peersInRange(b, sim.nodes.filter((n) => n.isOnline), sim.rf)
        .map((p) => effectiveLossProbability(b, p, sim.rf, sim.config.linkRetries))
        .sort((x, y) => x - y)[0] ?? 1;
      const loss = Math.max(legA, legB);
      if (!best || loss < best.loss) best = { a, b, loss };
    }
  }
  return best ? [best.a, best.b] : null;
}

function settle(sim: MeshSimulation): void {
  sim.runFor(90_000);
  sim.clearRecords();
}

function fmt(ms: number): string {
  if (ms < 1000) return `${ms.toFixed(0)} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(2)} s`;
  return `${(ms / 60_000).toFixed(2)} min`;
}

function fmtSize(bytes: number): string {
  return bytes >= MB ? `${(bytes / MB).toFixed(1)} MB` : `${(bytes / 1024).toFixed(0)} KB`;
}

function simFor(config: SimConfig): MeshSimulation {
  const sim = new MeshSimulation(config);
  settle(sim);
  return sim;
}

// ---------------------------------------------------------------------------
// 1. The serialization model on its own
// ---------------------------------------------------------------------------
function serializationTable(): void {
  console.log("\n=== 1. Air time per hop: what a payload costs on top of hop latency ===");
  console.log(
    `hopLatencyBleMs ${DEFAULT_CONFIG.hopLatencyBleMs} already includes one full BLE packet ` +
      `(${DEFAULT_CONFIG.transferChunkBytes >= 1024 ? 1024 : "?"} B), so only the excess is charged.`
  );
  const probe = simFor({ ...campusQuad(42), captureLog: false });
  const sizes = [1024, 4096, 65536, 7500, 45_000, 10 * MB];
  console.log("payload        BLE 80 kbit/s     Wi-Fi 20 Mbit/s   ratio");
  for (const bytes of sizes) {
    const ble = probe.serializationMs(bytes, "ble");
    const wifi = probe.serializationMs(bytes, "wifiDirect");
    const ratio = wifi > 0 ? (ble / wifi).toFixed(0) : "n/a (both 0)";
    console.log(
      `${fmtSize(bytes).padEnd(14)} ${fmt(ble).padEnd(17)} ${fmt(wifi).padEnd(17)} ${ratio}`
    );
  }
  // The codec ceiling docs/05 §3.3 states without justifying.
  const frameMs = DEFAULT_CONFIG.voiceFrameMs;
  const maxKbps = (1024 * 8) / frameMs;
  console.log(
    `\nA ${frameMs} ms voice frame stays inside one BLE packet up to ${maxKbps.toFixed(1)} kbit/s ` +
      `(frameBytes = frameMs × kbps / 8 ≤ 1024). docs/05's "6-12 kbps" therefore is not a taste ` +
      `choice: 12 kbps is the fastest documented rate that keeps push-to-talk off the Wi-Fi radio.`
  );
  for (const kbps of [6, 12, 16, 24]) {
    const bytes = Math.ceil((frameMs * kbps) / 8);
    const t: TransportType = bytes > 1024 ? "wifiDirect" : "ble";
    console.log(`  ${String(kbps).padStart(2)} kbit/s → ${String(bytes).padStart(4)} B/frame → ${t}`);
  }
}

// ---------------------------------------------------------------------------
// 2. Chunked file transfer
// ---------------------------------------------------------------------------
interface FileResult {
  hops: number;
  window: number;
  chunkBytes: number;
  bytes: number;
  ms: number | null;
  chunks: number;
  received: number;
  retransmitted: number;
  stalls: number;
  timeoutMs: number;
  transport: TransportType;
}

function runFile(
  config: SimConfig,
  hops: number,
  bytes: number,
  opts: { window?: number; chunkBytes?: number; budgetMs?: number } = {}
): FileResult {
  const sim = simFor(config);
  const pair = pairAtHops(sim, hops);
  if (!pair) throw new Error(`no pair ${hops} hops apart`);
  const [a, b] = pair;
  const t = sim.sendFile(a.id, b.id, bytes, {
    window: opts.window,
    chunkBytes: opts.chunkBytes,
  });
  if (!t) throw new Error("sendFile refused");
  const budget = opts.budgetMs ?? 900_000;
  let elapsed = 0;
  while (t.state === "active" && elapsed < budget) {
    sim.runFor(250);
    elapsed += 250;
  }
  return {
    hops,
    window: t.window,
    chunkBytes: t.chunkBytes,
    bytes: t.totalBytes,
    ms: t.completedAt === null ? null : t.completedAt - t.startedAt,
    chunks: t.chunks,
    received: t.received,
    retransmitted: t.retransmitted,
    stalls: t.stalls,
    timeoutMs: t.minRttMs === null ? config.mediaAckTimeoutMs : sim.mediaTimeoutMs(t),
    transport: t.transport,
  };
}

function fileTable(): void {
  console.log("\n=== 2. A 10 MB image over the mesh (docs/05 §3.2: 64 KB slices) ===");
  const rows: FileResult[] = [];
  for (const hops of [1, 2, 3]) {
    rows.push(runFile({ ...campusQuad(42) }, hops, 10 * MB));
  }
  console.log("hops  window  chunk    chunks  retrans  transport    time        throughput");
  for (const r of rows) {
    const kbps = r.ms ? ((r.bytes * 8) / r.ms).toFixed(0) : "—";
    console.log(
      `${String(r.hops).padEnd(5)} ${String(r.window).padEnd(7)} ${fmtSize(r.chunkBytes).padEnd(8)} ` +
        `${String(r.chunks).padEnd(7)} ${String(r.retransmitted).padEnd(8)} ${r.transport.padEnd(12)} ` +
        `${(r.ms === null ? "TIMEOUT" : fmt(r.ms)).padEnd(11)} ${kbps} kbit/s`
    );
  }

  console.log("\n--- sliding-window depth, same 10 MB at 1 and 3 hops ---");
  console.log("window  hops  time        throughput   retrans   per-chunk");
  for (const hops of [1, 3]) {
    for (const w of [1, 2, 4, 8, 16]) {
      const r = runFile({ ...campusQuad(42) }, hops, 10 * MB, { window: w });
      const per = r.ms ? r.ms / r.chunks : NaN;
      console.log(
        `${String(w).padEnd(7)} ${String(hops).padEnd(5)} ${(r.ms === null ? "TIMEOUT" : fmt(r.ms)).padEnd(11)} ` +
          `${(r.ms ? ((r.bytes * 8) / r.ms).toFixed(0) : "—").padEnd(4)} kbit/s   ${String(r.retransmitted).padEnd(9)} ` +
          `${per.toFixed(0)} ms`
      );
    }
  }

  console.log("\n--- the same file with no Wi-Fi Direct peer: BLE only ---");
  console.log("A BLE-only mesh cannot carry a 64 KB slice, so the app would slice to the packet");
  console.log("ceiling instead (docs/05 §3.2: 'auto-reject files >5 MB on BLE-only').");
  for (const hops of [1, 2]) {
    const r = runFile({ ...campusQuad(42) }, hops, 10 * MB, { chunkBytes: 1024, window: 4 });
    console.log(
      `  ${hops} hop${hops > 1 ? "s" : ""}: ${r.chunks} × ${fmtSize(r.chunkBytes)} chunks over ${r.transport} → ` +
        `${r.ms === null ? "did not finish in 15 min" : fmt(r.ms)}` +
        `${r.ms ? ` (${((r.bytes * 8) / r.ms).toFixed(1)} kbit/s)` : ""}`
    );
  }
  console.log("\n--- what size a BLE-only mesh can still do in a minute ---");
  for (const size of [0.25 * MB, MB, 2 * MB, 5 * MB]) {
    const r = runFile({ ...campusQuad(42) }, 1, size, { chunkBytes: 1024, window: 4, budgetMs: 300_000 });
    console.log(
      `  ${fmtSize(size).padEnd(9)} → ${r.ms === null ? ">5 min" : fmt(r.ms).padEnd(9)} ` +
        `(${r.received}/${r.chunks} chunks${r.retransmitted ? `, ${r.retransmitted} retransmitted` : ""})`
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Push-to-talk
// ---------------------------------------------------------------------------
interface VoiceResult {
  hops: number;
  seconds: number;
  stream: boolean;
  /** ms from pressing the button to the first frame being playable at the receiver. */
  firstPlayableMs: number | null;
  releasedAt: number;
  firstChunkAt: number | null;
  completedAt: number | null;
  playDelayMs: number | null;
  transport: TransportType;
  underruns: number;
  maxGapMs: number;
  frames: number;
  received: number;
  stalls: number;
  retransmitted: number;
  /** The retry timer the transfer converged on, once ACKs have measured the path. */
  timeoutMs: number;
}

function runVoice(
  config: SimConfig,
  hops: number,
  seconds: number,
  stream: boolean
): VoiceResult {
  const sim = simFor(config);
  const pair = pairAtHops(sim, hops);
  if (!pair) throw new Error(`no pair ${hops} hops apart`);
  const [a, b] = pair;
  const t = sim.sendVoice(a.id, b.id, seconds, { stream });
  if (!t) throw new Error("sendVoice refused");
  const budget = seconds * 1000 + 120_000;
  let elapsed = 0;
  while (t.state === "active" && elapsed < budget) {
    sim.runFor(100);
    elapsed += 100;
  }
  const arrivals = sim.deliveries
    .filter((d) => d.transferId === t.id && d.chunkIndex !== undefined)
    .sort((x, y) => (x.chunkIndex ?? 0) - (y.chunkIndex ?? 0));
  let maxGap = 0;
  let underruns = 0;
  for (let i = 1; i < arrivals.length; i++) {
    const gap = arrivals[i].timestamp - arrivals[i - 1].timestamp;
    maxGap = Math.max(maxGap, gap);
    // Playback underruns when the next frame is not in the buffer by the time the
    // current one finishes: the gap exceeds one frame plus the jitter buffer.
    if (gap > config.voiceFrameMs + config.jitterBufferMs) underruns++;
  }
  const released = t.releasedAt ?? t.startedAt;
  return {
    hops,
    seconds,
    stream,
    firstPlayableMs:
      t.firstChunkAt === null ? null : t.firstChunkAt + config.jitterBufferMs - t.startedAt,
    releasedAt: released,
    firstChunkAt: t.firstChunkAt,
    completedAt: t.completedAt,
    playDelayMs:
      t.completedAt === null ? null : t.completedAt + config.jitterBufferMs - released,
    transport: t.transport,
    underruns,
    maxGapMs: maxGap,
    frames: t.chunks,
    received: t.received,
    stalls: t.stalls,
    retransmitted: t.retransmitted,
    timeoutMs: t.minRttMs === null ? config.mediaAckTimeoutMs : sim.mediaTimeoutMs(t),
  };
}

function voiceTable(): void {
  console.log("\n=== 3. Push-to-talk: does the note play in time? ===");
  console.log(
    "Criterion (roadmap Phase 3): plays in <3 s at 1 hop, <8 s at 3 hops. Measured from the"
  );
  console.log(
    "moment the button is released to the moment the whole note is playable (last frame in + 200 ms buffer)."
  );
  const cfg = { ...campusQuad(42) };
  console.log("\nnote   mode      hops  transport    frames  first audio  play delay   max gap  underruns  retrans");
  for (const seconds of [3, 10, 30]) {
    for (const stream of [true, false]) {
      for (const hops of [1, 2, 3]) {
        const r = runVoice(cfg, hops, seconds, stream);
        const budget = hops >= 3 ? 8000 : 3000;
        const ok = r.playDelayMs !== null && r.playDelayMs < budget ? "PASS" : "FAIL";
        console.log(
          `${(seconds + " s").padEnd(6)} ${(stream ? "streamed" : "blob").padEnd(9)} ${String(hops).padEnd(5)} ` +
            `${r.transport.padEnd(12)} ${String(r.frames).padEnd(7)} ` +
            `${(r.firstPlayableMs === null ? "—" : fmt(r.firstPlayableMs)).padEnd(12)} ` +
            `${(r.playDelayMs === null ? "TIMEOUT" : fmt(r.playDelayMs)).padEnd(12)} ` +
            `${(r.maxGapMs ? fmt(r.maxGapMs) : "—").padEnd(8)} ${String(r.underruns).padEnd(10)} ` +
            `${String(r.retransmitted).padEnd(7)} ${ok}(budget ${fmt(budget)})`
        );
      }
    }
  }
  console.log("\n--- streaming against a crowd, where the path is longer and lossier ---");
  for (const hops of [1, 2, 3]) {
    const r = runVoice({ ...festivalCrowd(42) }, hops, 3, true);
    console.log(
      `  ${hops} hop${hops > 1 ? "s" : ""}: first audio ${r.firstPlayableMs === null ? "—" : fmt(r.firstPlayableMs)}, ` +
        `play delay ${r.playDelayMs === null ? "TIMEOUT" : fmt(r.playDelayMs)}, ` +
        `max gap ${fmt(r.maxGapMs)}, ${r.underruns} underruns, ${r.retransmitted} retransmitted`
    );
  }
}

// ---------------------------------------------------------------------------
// 4. The media retry timer
// ---------------------------------------------------------------------------
function retryTimerTable(): void {
  console.log("\n=== 4. The retry timer: why media cannot use the text plane's 4 s ===");
  console.log(
    "One lost frame is one hole in the audio. With `ackTimeoutMs` the hole is as long as the"
  );
  console.log("timer; `mediaAckTimeoutMs` is the media-specific one the engine now uses for chunks.");
  console.log("\n30 s note, streamed, at 2 hops, mean of three seeds (one pair is not a sample):");
  console.log("timer       play delay   max gap   underruns  retrans  stalls  notes finished");
  const timers: (number | "adaptive")[] = [4000, 1200, 600, 300, "adaptive"];
  for (const timer of timers) {
    const cfgFor = (seed: number): SimConfig =>
      timer === "adaptive"
        ? { ...campusQuad(seed), adaptiveMediaAck: true }
        : { ...campusQuad(seed), mediaAckTimeoutMs: timer, adaptiveMediaAck: false };
    const rs = SEEDS.map((seed) => runVoice(cfgFor(seed), 2, 30, true));
    const done = rs.filter((r) => r.playDelayMs !== null);
    const mean = (f: (r: VoiceResult) => number) => done.reduce((s, r) => s + f(r), 0) / Math.max(1, done.length);
    const worst = (f: (r: VoiceResult) => number) => done.reduce((s, r) => Math.max(s, f(r)), 0);
    console.log(
      `${label(timer, rs).padEnd(11)} ${fmt(mean((r) => r.playDelayMs ?? 0)).padEnd(12)} ` +
        `${fmt(worst((r) => r.maxGapMs)).padEnd(9)} ${String(rs.reduce((s, r) => s + r.underruns, 0)).padEnd(10)} ` +
        `${String(rs.reduce((s, r) => s + r.retransmitted, 0)).padEnd(8)} ${String(rs.reduce((s, r) => s + r.stalls, 0)).padEnd(7)} ` +
        `${done.length}/${rs.length}`
    );
  }
  // The timer has to outlast a round trip, and a round trip grows with the path: this
  // is the same sweep at 3 hops, where 600 ms is shorter than an ACK can possibly take
  // and every retransmission is a duplicate of a chunk that is still in flight.
  console.log("\nsame sweep at 3 hops (a round trip there is longer than 600 ms):");
  console.log("timer       play delay   max gap   underruns  retrans  stalls  notes finished");
  for (const timer of [4000, 2500, 1200, 600, 300, "adaptive"] as (number | "adaptive")[]) {
    const cfgFor = (seed: number): SimConfig =>
      timer === "adaptive"
        ? { ...campusQuad(seed), adaptiveMediaAck: true }
        : { ...campusQuad(seed), mediaAckTimeoutMs: timer, adaptiveMediaAck: false };
    const rs = SEEDS.map((seed) => runVoice(cfgFor(seed), 3, 30, true));
    const done = rs.filter((r) => r.playDelayMs !== null);
    const mean = (f: (r: VoiceResult) => number) => done.reduce((s, r) => s + f(r), 0) / Math.max(1, done.length);
    const worst = (f: (r: VoiceResult) => number) => done.reduce((s, r) => Math.max(s, f(r)), 0);
    console.log(
      `${label(timer, rs).padEnd(11)} ${fmt(mean((r) => r.playDelayMs ?? 0)).padEnd(12)} ` +
        `${fmt(worst((r) => r.maxGapMs)).padEnd(9)} ${String(rs.reduce((s, r) => s + r.underruns, 0)).padEnd(10)} ` +
        `${String(rs.reduce((s, r) => s + r.retransmitted, 0)).padEnd(8)} ${String(rs.reduce((s, r) => s + r.stalls, 0)).padEnd(7)} ` +
        `${done.length}/${rs.length}`
    );
  }

  console.log("\n10 MB file at 2 hops, same sweep, mean of three seeds:");
  console.log("timer       time        throughput   retrans  stalls  files finished");
  for (const timer of timers) {
    const cfgFor = (seed: number): SimConfig =>
      timer === "adaptive"
        ? { ...campusQuad(seed), adaptiveMediaAck: true }
        : { ...campusQuad(seed), mediaAckTimeoutMs: timer, adaptiveMediaAck: false };
    const rs = SEEDS.map((seed) => runFile(cfgFor(seed), 2, 10 * MB));
    const done = rs.filter((r) => r.ms !== null);
    const meanMs = done.reduce((s, r) => s + (r.ms ?? 0), 0) / Math.max(1, done.length);
    console.log(
      `${label(timer, rs).padEnd(11)} ${fmt(meanMs).padEnd(11)} ` +
        `${((10 * MB * 8) / meanMs).toFixed(0).padEnd(4)} kbit/s   ` +
        `${String(rs.reduce((s, r) => s + r.retransmitted, 0)).padEnd(8)} ` +
        `${String(rs.reduce((s, r) => s + r.stalls, 0)).padEnd(7)} ${done.length}/${rs.length}`
    );
  }
}

// ---------------------------------------------------------------------------
// 5. Does media break the mesh for everybody else?
// ---------------------------------------------------------------------------
function contentionTable(): void {
  console.log("\n=== 5. Contention: a 10 MB transfer running beside normal traffic ===");
  const base = { ...campusQuad(42), trafficIntervalMs: 4000 };
  const quiet = simFor(base);
  quiet.runFor(300_000);
  // `stats` is a field, not a getter: refresh() has to run first or every number
  // below reads as zero.
  const quietStats = { ...quiet.refresh(), within5: withinFiveRatio(quiet) };

  const busy = simFor(base);
  const pair = pairAtHops(busy, 3);
  let transfer = null as ReturnType<MeshSimulation["sendFile"]>;
  if (pair) transfer = busy.sendFile(pair[0].id, pair[1].id, 10 * MB);
  busy.runFor(300_000);
  const busyStats = { ...busy.refresh(), within5: withinFiveRatio(busy) };

  console.log("                        quiet        with a 10 MB file in flight");
  const row = (label: string, a: number, b: number, digits = 1) =>
    console.log(
      `${label.padEnd(24)}${a.toFixed(digits).padEnd(13)}${b.toFixed(digits)}`
    );
  row("relay transmissions", quietStats.totalForwarded, busyStats.totalForwarded, 0);
  row("unicast sent", quietStats.sentUnicast, busyStats.sentUnicast, 0);
  row("delivery ratio %", quietStats.deliveryRatio * 100, busyStats.deliveryRatio * 100);
  row("within 5 hops %", quietStats.within5 * 100, busyStats.within5 * 100);
  row("p95 latency ms", quietStats.p95LatencyMs, busyStats.p95LatencyMs, 0);
  row("retries sent", quietStats.retriesSent, busyStats.retriesSent, 0);
  row("OppQueue holds", quietStats.totalQueued, busyStats.totalQueued, 0);
  console.log(
    `  transfer: ${transfer ? `${transfer.received}/${transfer.chunks} chunks, ` +
      `${transfer.completedAt === null ? "still running" : fmt(transfer.completedAt - transfer.startedAt)}` : "none"}`
  );
  console.log(
    `  chunks put on air: quiet ${quietStats.sentChunks}, busy ${busyStats.sentChunks}; ` +
      `payload delivered ${fmtSize(busyStats.bytesDelivered)}`
  );
}

/** Row label for a timer sweep: a fixed value, or what the adaptive timer converged on. */
function label(timer: number | "adaptive", rs: { timeoutMs: number }[]): string {
  if (timer !== "adaptive") return `${timer} ms`;
  const mean = rs.reduce((s, r) => s + r.timeoutMs, 0) / Math.max(1, rs.length);
  return `adapt ${mean.toFixed(0)}`;
}

/** The acceptance-test definition of "within 5 hops": delivered 1:1 copies whose
 *  path was no longer than five hops, over everything sent. */
function withinFiveRatio(sim: MeshSimulation): number {
  const sent = sim.sentRecords.filter(
    (s) => s.type !== "ack" && s.type !== "broadcast" && !s.groupId && !s.transferId
  );
  if (sent.length === 0) return 1;
  const within = sim.deliveries.filter(
    (d) =>
      d.type !== "ack" &&
      d.type !== "broadcast" &&
      !d.groupId &&
      !d.transferId &&
      d.path.length - 1 <= 5
  );
  return within.length / sent.length;
}

function main(): void {
  console.log("Duman media transport probe — every number below is measured, not assumed.");
  console.log(
    `Radios: BLE ${DEFAULT_CONFIG.bleKbps} kbit/s, Wi-Fi Direct ${DEFAULT_CONFIG.wifiDirectKbps} kbit/s ` +
      `(${Math.round(DEFAULT_CONFIG.wifiDirectKbps / DEFAULT_CONFIG.bleKbps)}×, the ratio docs/05 §3.2 claims). ` +
      `Hop latency BLE ${DEFAULT_CONFIG.hopLatencyBleMs} ms / Wi-Fi ${DEFAULT_CONFIG.hopLatencyWifiMs} ms, ` +
      `jitter ${DEFAULT_CONFIG.jitterMinMs}-${DEFAULT_CONFIG.jitterMaxMs} ms.`
  );
  serializationTable();
  fileTable();
  voiceTable();
  retryTimerTable();
  contentionTable();
  console.log("\nDone.");
}

main();
