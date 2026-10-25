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
import {
  BEST_HOP_ADVERTISE_LIMIT,
  MPR_NEIGHBOR_ADVERTISE_LIMIT,
} from "../src/election";
import {
  BLE_MAX_BYTES,
  OGM_FIXED_BYTES,
  OGM_MAX_WIRE_BYTES,
  ogmWireBytes,
} from "../src/routing";
import { NEIGHBOR_SCORE_TTL_MS } from "../src/election";
import { campusQuad, festivalCrowd, sparseVillage } from "../src/scenarios";
import { canReach, effectiveLossProbability, peersInRange } from "../src/rf";
import { createRng } from "../src/rng";
import type { RelayPolicy } from "../src/types";
import type {
  ChannelAccess,
  ChannelBackoff,
  ChannelCapture,
  ChannelPriority,
  MeshNode,
  NodeId,
  TransportType,
} from "../src/types";

/** skills/05: "chunked BLE 512B MTU" — what a file is sliced into when there is no
 *  Wi-Fi Direct group owner to carry it. */
const BLE_MTU_BYTES = 512;

const MB = 1048576;
const SEEDS = [42, 7, 1234];
/** The six seeds `src/__tests__/acceptance.test.ts` gates on. Used wherever a claim is a few
 *  points wide on a system that is chaotic in the seed: three of them have already reversed a
 *  conclusion in this file once. */
const SIX_SEEDS = [42, 7, 1234, 99, 2026, 555];

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
  if (bytes >= MB) return `${(bytes / MB).toFixed(1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${bytes} B`;
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
  /** Transmissions that had to wait for a radio, and the total wait (docs/08 §12).
   *  Zero under the default `channelAccess: "free"`. */
  deferrals: number;
  deferMs: number;
  drops: number;
}

function runFile(
  config: SimConfig,
  hops: number,
  bytes: number,
  opts: { window?: number; chunkBytes?: number; budgetMs?: number; transport?: TransportType } = {}
): FileResult {
  const sim = simFor(config);
  const pair = pairAtHops(sim, hops);
  if (!pair) throw new Error(`no pair ${hops} hops apart`);
  const [a, b] = pair;
  const t = sim.sendFile(a.id, b.id, bytes, {
    window: opts.window,
    chunkBytes: opts.chunkBytes,
    transport: opts.transport,
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
    deferrals: sim.refresh().channelDeferrals,
    deferMs: sim.refresh().channelDeferMs,
    drops: sim.refresh().channelDrops,
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
  console.log("A BLE-only mesh cannot carry a 64 KB slice, so skills/05 slices to the BLE MTU");
  console.log(`(${BLE_MTU_BYTES} B) instead, and docs/05 §3.2 has the app auto-reject >5 MB with a`);
  console.log("'move closer to SUPER' hint. This is what that rule protects the user from.");
  for (const hops of [1, 2]) {
    const r = runFile({ ...campusQuad(42) }, hops, 10 * MB, { chunkBytes: BLE_MTU_BYTES, window: 4 });
    console.log(
      `  ${hops} hop${hops > 1 ? "s" : ""}: ${r.chunks} × ${fmtSize(r.chunkBytes)} chunks over ${r.transport} → ` +
        `${r.ms === null ? "did not finish in 15 min" : fmt(r.ms)}` +
        `${r.ms ? ` (${((r.bytes * 8) / r.ms).toFixed(1)} kbit/s)` : ""}`
    );
  }
  console.log("\n--- what size a BLE-only mesh can still do in a minute ---");
  for (const size of [0.25 * MB, MB, 2 * MB, 5 * MB]) {
    const r = runFile({ ...campusQuad(42) }, 1, size, { chunkBytes: BLE_MTU_BYTES, window: 4, budgetMs: 300_000 });
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
  stream: boolean,
  transport?: TransportType
): VoiceResult {
  const sim = simFor(config);
  const pair = pairAtHops(sim, hops);
  if (!pair) throw new Error(`no pair ${hops} hops apart`);
  const [a, b] = pair;
  const t = sim.sendVoice(a.id, b.id, seconds, { stream, transport });
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
  console.log("\n--- one hop with a Wi-Fi Direct group owner already negotiated ---");
  console.log("skills/05's modes table puts streaming PTT at 150-300 ms here, and its acceptance");
  console.log("box at <1 s round trip. The buffer-excluded figure is the one to compare.");
  for (const seconds of [3, 30]) {
    const r = runVoice(cfg, 1, seconds, true, "wifiDirect");
    console.log(
      `  ${seconds} s note: ${r.transport}, first audio ${fmt(r.firstPlayableMs ?? NaN)}, ` +
        `play delay ${fmt(r.playDelayMs ?? NaN)}, buffer excluded ` +
        `${((r.playDelayMs ?? NaN) - 200).toFixed(0)} ms, ${r.underruns} underruns`
    );
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
// 5. skills/05's three acceptance boxes, measured
// ---------------------------------------------------------------------------
function acceptanceTable(): void {
  console.log("\n=== 5. skills/05 acceptance, measured ===");

  // Box 1: "1-hop WiFi: PTT round-trip <1s, intelligible (MOS proxy test)".
  // The modes table above it puts streaming PTT at 150-300 ms on one Wi-Fi Direct
  // hop, which reads as excluding the jitter buffer; both numbers are reported.
  const wifi = runVoice({ ...campusQuad(42) }, 1, 3, true, "wifiDirect");
  const wifiDelay = wifi.playDelayMs ?? Number.POSITIVE_INFINITY;
  const hopOnly = wifiDelay - 200;
  console.log(
    `[1] 1-hop Wi-Fi PTT round trip ${fmt(wifiDelay)} (buffer excluded: ${hopOnly.toFixed(0)} ms) ` +
      `→ ${wifiDelay < 1000 ? "PASS <1 s" : "FAIL"}; modes table 150-300 ms → ` +
      `${hopOnly >= 150 && hopOnly <= 300 ? "inside" : "outside"} the band. ` +
      `"Intelligible" is not simulatable: no codec runs here.`
  );

  // Box 2: "3-hop BLE: voice note arrives intact, Opus decode clean".
  const ble = runVoice({ ...campusQuad(42) }, 3, 3, true);
  console.log(
    `[2] 3-hop BLE voice note over ${ble.transport}: ${ble.received}/${ble.frames} frames arrived ` +
      `→ ${ble.received === ble.frames ? "intact PASS" : "INCOMPLETE"}; play delay ` +
      `${fmt(ble.playDelayMs ?? NaN)}, ${ble.underruns} arrival gaps longer than frame+buffer, ` +
      `which is the only proxy available for "decode clean": a gap is a hole the decoder conceals.`
  );

  // Box 3: "10 MB image: delivered over WiFi Direct with resume after mid-transfer
  // disconnect". The disconnect is the interesting half.
  const sim = simFor({ ...campusQuad(42), captureLog: true });
  const pair = pairAtHops(sim, 3);
  if (!pair) throw new Error("no 3-hop pair");
  const [a, b] = pair;
  const t = sim.sendFile(a.id, b.id, 10 * MB, { transport: "wifiDirect" })!;
  const started = sim.now;
  while (t.received < Math.floor(t.chunks * 0.3) && sim.now - started < 120_000) {
    sim.runFor(100);
  }
  const progressed = t.received;
  sim.toggleNodeOnline(b.id); // the receiver walks away mid-transfer
  sim.runFor(20_000);
  const stallsWhileAway = t.stalls;
  sim.toggleNodeOnline(b.id); // ... and comes back
  let elapsed = 0;
  while (t.state === "active" && elapsed < 600_000) {
    sim.runFor(250);
    elapsed += 250;
  }
  console.log(
    `[3] 10 MB over Wi-Fi Direct, receiver offline at ${progressed}/${t.chunks} chunks for 20 s: ` +
      `${t.received}/${t.chunks} arrived, ${t.stalls} window stalls (${stallsWhileAway} while it was ` +
      `away), ${t.retransmitted} retransmitted → ` +
      `${t.state === "complete" ? `resumed and completed in ${fmt((t.completedAt ?? 0) - t.startedAt)} PASS` : "DID NOT RESUME"}`
  );

  // The ceiling itself.
  const ceiling = simFor({ ...campusQuad(42), captureLog: true });
  const cp = pairAtHops(ceiling, 1);
  const refused = cp ? ceiling.sendFile(cp[0].id, cp[1].id, 11 * MB) : null;
  console.log(
    `[ ] 11 MB send → ${refused === null ? "refused" : "accepted"} (skills/05 "Max 10 MB"); ` +
      `log: ${ceiling.log.find((l) => l.kind === "transfer")?.detail ?? "(none)"}`
  );
}

// ---------------------------------------------------------------------------
// 6. Does media break the mesh for everybody else?
// ---------------------------------------------------------------------------

/**
 * A fixed traffic plan, replayed identically in both arms.
 *
 * The first version of this section let each arm draw its own traffic from the
 * simulation's RNG, which made it two different experiments: the "quiet" arm and the
 * "busy" arm did not send the same messages, and the media run consumed randomness that
 * shifted every later loss draw. It reported delivery 100% -> 98.2% and 0 -> 35 parked
 * messages, and both differences were the confound (docs/06 §7's rule, and §9 of docs/08
 * records the correction).
 */
function contentionPlan(seed: number, nodeCount: number, messages: number): Array<[number, number]> {
  const rng = createRng((seed ^ 0x2f6e2b1) >>> 0);
  const out: Array<[number, number]> = [];
  for (let i = 0; i < messages; i++) {
    const a = Math.floor(rng() * nodeCount);
    let b = Math.floor(rng() * nodeCount);
    let guard = 0;
    while (b === a && guard++ < 32) b = Math.floor(rng() * nodeCount);
    if (a !== b) out.push([a, b]);
  }
  return out;
}

interface ContentionArm {
  sent: number;
  ratio: number;
  within5: number;
  p95: number;
  relayTx: number;
  queued: number;
  retries: number;
  exhausted: number;
  transferMs: number | null;
  /** Radio-side waiting: transmissions deferred, total wait, packets the transmit
   *  queue could not hold. All zero under `channelAccess: "free"`. */
  deferrals: number;
  deferMs: number;
  drops: number;
}

function contentionArm(
  seed: number,
  withFile: boolean,
  messages = 60,
  gapMs = 2000,
  channelAccess: ChannelAccess = "free",
  mediaWindow?: number,
  budgetMs = 0
): ContentionArm {
  const sim = simFor({ ...campusQuad(seed), trafficIntervalMs: 0, channelAccess });
  const plan = contentionPlan(seed, sim.nodes.length, messages);

  let transfer: ReturnType<MeshSimulation["sendFile"]> = null;
  if (withFile) {
    const a = sim.nodes[plan[0][0]];
    const b = sim.nodes[plan[0][1]];
    transfer = sim.sendFile(a.id, b.id, 10 * MB, { window: mediaWindow });
  }

  let sent = 0;
  for (let i = 1; i < plan.length; i++) {
    const from = sim.nodes[plan[i][0]];
    const to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `c-${i}`, "text")) sent++;
    sim.runFor(gapMs);
  }
  // Text metrics are snapshotted at the end of the plan, in every arm, over the same
  // window: a transfer that takes three minutes must not dilute its own damage across a
  // tail where nothing is competing any more.
  const stats = sim.refresh();
  const uni = sim.deliveries.filter(
    (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
  );
  const lat = uni.map((d) => d.latencyMs).sort((x, y) => x - y);
  // ... and only then is the file given the time to finish, so its own duration is
  // measured rather than censored.
  if (budgetMs > 0 && transfer && transfer.state === "active") {
    let waited = 0;
    while (transfer.state === "active" && waited < budgetMs) {
      sim.runFor(250);
      waited += 250;
    }
  }
  return {
    sent,
    ratio: uni.length / Math.max(1, sent),
    within5: uni.filter((d) => d.hops <= 5).length / Math.max(1, sent),
    p95: lat.length ? lat[Math.floor(lat.length * 0.95)] : 0,
    relayTx: stats.totalForwarded,
    queued: stats.totalQueued,
    retries: stats.retriesSent,
    exhausted: stats.retriesExhausted,
    transferMs:
      transfer && transfer.completedAt !== null ? transfer.completedAt - transfer.startedAt : null,
    deferrals: stats.channelDeferrals,
    deferMs: stats.channelDeferMs,
    drops: stats.channelDrops,
  };
}

function contentionTable(): void {
  console.log("\n=== 6. Contention: does a 10 MB transfer hurt anybody else? ===");
  console.log("One fixed traffic plan, replayed identically in both arms, mean of three seeds.");
  console.log("(The first version of this table let each arm draw its own traffic and reported");
  console.log(" harm that turned out to be the two arms not being the same experiment.)");

  const arms: [string, boolean][] = [
    ["quiet", false],
    ["with a 10 MB file", true],
  ];
  const results = new Map<string, ContentionArm[]>();
  for (const [label, withFile] of arms) {
    results.set(label, SEEDS.map((seed) => contentionArm(seed, withFile)));
  }
  const mean = (rows: ContentionArm[], f: (r: ContentionArm) => number) =>
    rows.reduce((a, r) => a + f(r), 0) / Math.max(1, rows.length);

  const quiet = results.get("quiet")!;
  const busy = results.get("with a 10 MB file")!;
  console.log("\n" + "                        quiet          with a 10 MB file in flight".padEnd(24));
  const row = (label: string, f: (r: ContentionArm) => number, digits = 1) =>
    console.log(
      `${label.padEnd(24)}${mean(quiet, f).toFixed(digits).padEnd(15)}${mean(busy, f).toFixed(digits)}`
    );
  row("messages sent", (r) => r.sent, 1);
  row("delivery ratio", (r) => r.ratio, 4);
  row("within 5 hops", (r) => r.within5, 4);
  row("p95 latency ms", (r) => r.p95, 0);
  row("relay transmissions", (r) => r.relayTx, 0);
  row("retries sent", (r) => r.retries, 0);
  row("messages parked", (r) => r.queued, 1);
  row("retries exhausted", (r) => r.exhausted, 1);
  console.log(
    `  per-seed delivery: quiet ${quiet.map((r) => r.ratio.toFixed(3)).join(", ")} | ` +
      `busy ${busy.map((r) => r.ratio.toFixed(3)).join(", ")}`
  );
  console.log(
    `  the transfer itself: ${fmt(mean(busy, (r) => r.transferMs ?? NaN))} at 3 hops, ` +
      `${mean(busy, (r) => r.relayTx) - mean(quiet, (r) => r.relayTx) > 0 ? "" : "no "}extra relay work`
  );
  console.log(
    "\nRead: delivery, within-5, parked messages and exhausted retries are the same in both arms,\n" +
      "seed for seed. The only differences are the media's own work — relay transmissions and retries —\n" +
      "and a p95 that moves because the media run consumes randomness, changing later loss draws.\n" +
      "That is not an accident of this model being generous: loss is per packet and independent of\n" +
      "volume, and there is no shared medium, so a chunk occupies the radio in *time* without stopping\n" +
      "anybody else's transmission from succeeding. Until a channel-access model exists (docs/08 §11),\n" +
      "media cannot harm text here, and a load gate on transfers would have nothing to protect."
  );
}

// ---------------------------------------------------------------------------
// 7. Channel access: what happens when the radio is actually one radio
// ---------------------------------------------------------------------------

/**
 * §6's null result is a property of the model, not a virtue of the design: with
 * `channelAccess: "free"` a transmission occupies no exclusive resource, so media has no
 * way to compete with text. This section flips the one switch that gives a device a real
 * radio — one transmitter, half-duplex, doing one thing at a time — and re-measures the
 * same questions. Everything here is behind that flag and none of it changes the shipped
 * default (docs/08 §12).
 */

/** Delivery/overhead on the 20-node campus under a given channel model, same plan both
 *  relay policies, so the overhead ratio is comparable to skills/02's "≤70% of flood-all". */
interface GateRow {
  ratio: number;
  within5: number;
  relayTx: number;
  overhead: number;
  superRatio: number;
  deferrals: number;
  deferMs: number;
  drops: number;
  backoffs: number;
}

function gateRow(
  seed: number,
  channelAccess: ChannelAccess,
  messages = 60,
  channelCapture: ChannelCapture = "none",
  backoff?: ChannelBackoff,
  cwMin?: number
): GateRow {
  const run = (policy: SimConfig["relayPolicy"]) => {
    const sim = simFor({
      ...campusQuad(seed),
      trafficIntervalMs: 0,
      channelAccess,
      channelCapture,
      ...(backoff === undefined ? {} : { channelBackoff: backoff }),
      ...(cwMin === undefined ? {} : { channelCwMin: cwMin }),
      relayPolicy: policy,
    });
    const plan = contentionPlan(seed, sim.nodes.length, messages);
    let sent = 0;
    for (const [a, b] of plan) {
      const from = sim.nodes[a];
      const to = sim.nodes[b];
      if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `g-${a}-${b}`, "text")) sent++;
      sim.runFor(1000);
    }
    const stats = sim.refresh();
    const uni = sim.deliveries.filter(
      (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
    );
    return {
      ratio: uni.length / Math.max(1, sent),
      within5: uni.filter((d) => d.hops <= 5).length / Math.max(1, sent),
      relayTx: stats.totalForwarded,
      superRatio: stats.superRatio,
      deferrals: stats.channelDeferrals,
      deferMs: stats.channelDeferMs,
      drops: stats.channelDrops,
      backoffs: stats.channelBackoffs,
      sent,
    };
  };
  const mpr = run("mpr");
  const flood = run("flood-all");
  return {
    ratio: mpr.ratio,
    within5: mpr.within5,
    relayTx: mpr.relayTx,
    overhead: mpr.relayTx / Math.max(1, flood.relayTx),
    superRatio: mpr.superRatio,
    deferrals: mpr.deferrals,
    deferMs: mpr.deferMs,
    drops: mpr.drops,
    backoffs: mpr.backoffs,
  };
}

// ---------------------------------------------------------------------------
// 9. Receiver contention: the other half of a real radio
// ---------------------------------------------------------------------------

const CAPTURES: ChannelCapture[] = ["none", "first"];
/** The three receiver models, from the one that ships to the one that bounds the loss. */
const RECEIVER_ARMS: ChannelCapture[] = ["none", "first", "strongest"];
/** Capture margins to sweep, in dB. 6 is the ratio usually quoted for an angle-modulated
 *  receiver; 0 is loudest-wins with no margin; 20 collapses back onto first-packet-wins. */
const CAPTURE_MARGINS = [0, 3, 6, 12, 20];

function cellMean(rows: CaptureCell[], f: (r: CaptureCell) => number | null): number {
  const vals = rows.map(f).filter((v): v is number => v !== null);
  return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : NaN;
}
const ACCESSES: ChannelAccess[] = ["free", "halfDuplex", "csma"];

interface CaptureCell {
  ratio: number;
  within5: number;
  p95: number;
  relayTx: number;
  retries: number;
  parked: number;
  captured: number;
  deaf: number;
  drops: number;
  deferMs: number;
  backoffs: number;
  dropsRelayed: number;
  dropsMedia: number;
  dropsWithAlternative: number;
  blocks: number;
  effects: number;
  fileMs: number | null;
}

function captureCell(
  access: ChannelAccess,
  capture: ChannelCapture,
  seed: number,
  withFile: boolean,
  queueDepth?: number,
  backoff?: ChannelBackoff,
  cwMin?: number,
  mediaBackpressure?: boolean,
  captureRatioDb?: number
): CaptureCell {
  const sim = simFor({
    ...campusQuad(seed),
    trafficIntervalMs: 0,
    channelAccess: access,
    channelCapture: capture,
    ...(queueDepth === undefined ? {} : { channelQueueDepth: queueDepth }),
    ...(backoff === undefined ? {} : { channelBackoff: backoff }),
    ...(cwMin === undefined ? {} : { channelCwMin: cwMin }),
    ...(mediaBackpressure === undefined ? {} : { mediaBackpressure }),
    ...(captureRatioDb === undefined ? {} : { channelCaptureRatioDb: captureRatioDb }),
  });
  const plan = contentionPlan(seed, sim.nodes.length, 60);
  const t = withFile ? sim.sendFile(sim.nodes[plan[0][0]].id, sim.nodes[plan[0][1]].id, 10 * MB) : null;
  let sent = 0;
  for (let i = 1; i < plan.length; i++) {
    const from = sim.nodes[plan[i][0]];
    const to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `r-${i}`, "text")) sent++;
    sim.runFor(2000);
  }
  // Text metrics are snapshotted at the end of the plan, in every arm, over the same window.
  const stats = sim.refresh();
  const uni = sim.deliveries.filter(
    (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
  );
  const lat = uni.map((d) => d.latencyMs).sort((x, y) => x - y);
  if (t) {
    let waited = 0;
    while (t.state === "active" && waited < 900_000) {
      sim.runFor(250);
      waited += 250;
    }
  }
  return {
    ratio: uni.length / Math.max(1, sent),
    within5: uni.filter((d) => d.hops <= 5).length / Math.max(1, sent),
    p95: lat.length ? lat[Math.floor(lat.length * 0.95)] : 0,
    relayTx: stats.totalForwarded,
    retries: stats.retriesSent,
    parked: stats.totalQueued,
    captured: stats.channelCaptured,
    deaf: stats.channelDeafRx,
    drops: stats.channelDrops,
    deferMs: stats.channelDeferMs,
    backoffs: stats.channelBackoffs,
    dropsRelayed: stats.channelDropsRelayed,
    dropsMedia: stats.channelDropsMedia,
    dropsWithAlternative: stats.channelDropsWithAlternative,
    blocks: stats.transferBlocks,
    effects: stats.channelCaptureEffects,
    fileMs: t && t.completedAt !== null ? t.completedAt - t.startedAt : null,
  };
}

function captureTable(): void {
  console.log("\n=== 9. Receiver contention: the other half of a real radio (docs/08 §12.9) ===");
  console.log(
    "§12 gave the device one transmitter. The receiver was still infinitely attentive: a node\n" +
      "on air could hear, and two packets arriving together both landed. `channelCapture: \"first\"`\n" +
      "closes both — the receiver locks onto whichever packet arrived first, and a node that is\n" +
      "transmitting hears nothing — as losses rather than deferrals, because that is what a\n" +
      "collision is. It is independent of `channelAccess`, so the two mechanisms can be separated."
  );
  for (const withFile of [false, true]) {
    console.log(
      `\n--- ${withFile ? "60 messages at 2 s, with a 10 MB file in flight" : "60 messages at 2 s, nothing else"} (3 seeds) ---`
    );
    console.log(
      "transmitter  receiver   delivery   within5   p95 ms   retries  parked  captured  deaf  queue drops  file"
    );
    for (const access of ACCESSES) {
      for (const capture of CAPTURES) {
        const rows = SEEDS.map((seed) => captureCell(access, capture, seed, withFile));
        const mean = (f: (r: CaptureCell) => number | null) => {
          const vals = rows.map(f).filter((v): v is number => v !== null);
          return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : NaN;
        };
        console.log(
          `${access.padEnd(12)} ${capture.padEnd(10)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ` +
            `${mean((r) => r.within5).toFixed(4).padEnd(9)} ${mean((r) => r.p95).toFixed(0).padEnd(8)} ` +
            `${mean((r) => r.retries).toFixed(0).padEnd(8)} ${mean((r) => r.parked).toFixed(1).padEnd(7)} ` +
            `${mean((r) => r.captured).toFixed(0).padEnd(9)} ${mean((r) => r.deaf).toFixed(0).padEnd(5)} ` +
            `${mean((r) => r.drops).toFixed(0).padEnd(12)} ` +
            `${withFile ? fmt(mean((r) => r.fileMs)) : "—"}`
        );
      }
    }
  }

  console.log("\n--- the acceptance gates under all six radios (20-node campus, 3 seeds) ---");
  console.log("transmitter  receiver   delivery   within5   overhead vs flood-all   SUPER ratio   collisions");
  for (const access of ACCESSES) {
    for (const capture of CAPTURES) {
      const rows = SEEDS.map((seed) => gateRow(seed, access, 60, capture));
      const mean = (f: (r: GateRow) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
      console.log(
        `${access.padEnd(12)} ${capture.padEnd(10)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ` +
          `${mean((r) => r.within5).toFixed(4).padEnd(9)} ` +
          `${(mean((r) => r.overhead) * 100).toFixed(1).padStart(5)} %                 ` +
          `${(mean((r) => r.superRatio) * 100).toFixed(1).padStart(5)} %          ` +
          `${mean((r) => r.drops).toFixed(0)} dropped`
      );
    }
  }
  console.log(
    "\nRead: the receiver is where contention lives. With a file in flight a transmitter queue\n" +
      "alone costs text 2.8 points and receiver collisions alone cost 13.6; both together cost 8.5,\n" +
      "so once collisions exist the queue earns its keep and is worth 4.9 points back, because\n" +
      "serialising a node's own transmissions removes the overlaps it was causing everybody else.\n" +
      "Collisions are paid in latency before delivery, because a lost packet is re-sent into an\n" +
      "idle radio four seconds later. Carrier sense is the third transmitter arm and the surprising\n" +
      "one: it removes almost every collision a node can hear (§12.10) and still loses delivery\n" +
      "under load, because waiting is not free in an engine with no backpressure."
  );

  console.log("\n--- carrier sense against queue depth: waiting is not free (docs/08 §12.10) ---");
  console.log(
    "Both transmitters that queue, a receiver in the model, a 10 MB file in flight, and the transmit\n" +
      "queue deepened. The intuition is that a deeper queue holds what carrier sense makes you wait\n" +
      "for. It does not: depth holds packets past the point where anybody is waiting for them, so the\n" +
      "transfer slows and the text tail grows. Retry timers now start when a packet goes on air\n" +
      "(§12.11), so this is queueing delay rather than duplicate load — and it is still monotonic."
  );
  console.log("transmitter  depth   delivery   p95 ms   parked  captured  deaf  queue drops  deferred   file");
  for (const access of ["halfDuplex", "csma"] as ChannelAccess[]) {
    for (const depth of [8, 32, 128]) {
      const rows = SEEDS.map((seed) => captureCell(access, "first", seed, true, depth));
      const mean = (f: (r: CaptureCell) => number | null) => {
        const vals = rows.map(f).filter((v): v is number => v !== null);
        return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : NaN;
      };
      console.log(
        `${access.padEnd(12)} ${String(depth).padEnd(7)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ` +
          `${mean((r) => r.p95).toFixed(0).padEnd(8)} ${mean((r) => r.parked).toFixed(1).padEnd(7)} ` +
          `${mean((r) => r.captured).toFixed(0).padEnd(9)} ${mean((r) => r.deaf).toFixed(0).padEnd(5)} ` +
          `${mean((r) => r.drops).toFixed(0).padEnd(12)} ${fmt(mean((r) => r.deferMs)).padEnd(10)} ` +
          `${fmt(mean((r) => r.fileMs))}`
      );
    }
  }
}

function channelTable(): void {
  console.log("\n=== 7. Channel access: one radio, half-duplex (docs/08 §12) ===");
  console.log(
    "`channelAccess: \"free\"` — the default, and the model every number above was measured\n" +
      "under — gives a device an infinitely wide radio. `\"halfDuplex\"` gives it the one radio a\n" +
      "phone actually has: it cannot start transmitting while a previous packet is on air, and\n" +
      "cannot receive while transmitting. Nothing else changes."
  );

  console.log("\n--- one 10 MB file alone, no other traffic: does the window still buy parallelism? ---");
  console.log("hops  channel      window  time        throughput   retrans  deferrals  deferred   dropped");
  for (const hops of [1, 2, 3]) {
    for (const ch of ["free", "halfDuplex"] as ChannelAccess[]) {
      const r = runFile({ ...campusQuad(42), channelAccess: ch }, hops, 10 * MB);
      const kbps = r.ms ? ((r.bytes * 8) / r.ms).toFixed(0) : "—";
      console.log(
        `${String(hops).padEnd(5)} ${ch.padEnd(12)} ${String(r.window).padEnd(7)} ` +
          `${(r.ms === null ? "TIMEOUT" : fmt(r.ms)).padEnd(11)} ${String(kbps).padEnd(12)} ` +
          `${String(r.retransmitted).padEnd(8)} ${String(r.deferrals).padEnd(10)} ` +
          `${fmt(r.deferMs).padEnd(10)} ${r.drops}`
      );
    }
  }

  console.log("\n--- window depth under half-duplex: air time is serial, so depth cannot help ---");
  console.log("window  channel      time        throughput   retrans  stalls  dropped");
  for (const w of [1, 2, 4, 8, 16]) {
    for (const ch of ["free", "halfDuplex"] as ChannelAccess[]) {
      const r = runFile({ ...campusQuad(42), channelAccess: ch }, 1, 10 * MB, { window: w });
      const kbps = r.ms ? ((r.bytes * 8) / r.ms).toFixed(0) : "—";
      console.log(
        `${String(w).padEnd(7)} ${ch.padEnd(12)} ${(r.ms === null ? "TIMEOUT" : fmt(r.ms)).padEnd(11)} ` +
          `${String(kbps).padEnd(12)} ${String(r.retransmitted).padEnd(8)} ${String(r.stalls).padEnd(7)} ${r.drops}`
      );
    }
  }

  console.log("\n--- a 30 s voice note: half-duplex air time against a 500 ms frame clock ---");
  console.log("hops  channel      transport    play delay   max gap   underruns  retrans");
  console.log(
    "One frame is 500 ms of capture and, at 750 B, fits inside a single BLE packet: its air time\n" +
      "is hop latency plus jitter, about 245 ms a hop. So a note streamed over N hops needs about\n" +
      "245N ms of radio for every 500 ms of recording — under half the clock at 1 hop, 490 ms at 2\n" +
      "(no slack left for jitter or a single retransmission), and more than the clock at 3, where\n" +
      "the queue grows faster than the radio drains it. That is the prediction; the measurement of\n" +
      "it is below, and it is the sharpest result in this section."
  );
  for (const hops of [1, 2, 3]) {
    for (const ch of ["free", "halfDuplex"] as ChannelAccess[]) {
      const v = runVoice({ ...campusQuad(42), channelAccess: ch }, hops, 30, true);
      console.log(
        `${String(hops).padEnd(5)} ${ch.padEnd(12)} ${v.transport.padEnd(12)} ` +
          `${fmt(v.playDelayMs ?? NaN).padEnd(12)} ${fmt(v.maxGapMs).padEnd(9)} ` +
          `${String(v.underruns).padEnd(10)} ${v.retransmitted}`
      );
    }
  }

  console.log("\n--- the §6 A/B again, this time on a real radio: quiet vs 10 MB in flight ---");
  console.log(
    "channel        arm                    delivery   within5   p95 ms   relayTx  retries  parked  deferred  dropped"
  );
  for (const ch of ["free", "halfDuplex"] as ChannelAccess[]) {
    for (const [armName, withFile] of [["quiet", false], ["with a 10 MB file", true]] as [string, boolean][]) {
      const rows = SEEDS.map((seed) => contentionArm(seed, withFile, 60, 2000, ch));
      const mean = (f: (r: ContentionArm) => number) =>
        rows.reduce((a, r) => a + f(r), 0) / rows.length;
      console.log(
        `${ch.padEnd(14)} ${armName.padEnd(22)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ` +
          `${mean((r) => r.within5).toFixed(4).padEnd(9)} ${mean((r) => r.p95).toFixed(0).padEnd(8)} ` +
          `${mean((r) => r.relayTx).toFixed(0).padEnd(8)} ${mean((r) => r.retries).toFixed(0).padEnd(8)} ` +
          `${mean((r) => r.queued).toFixed(1).padEnd(7)} ${fmt(mean((r) => r.deferMs)).padEnd(9)} ` +
          `${mean((r) => r.drops).toFixed(0)}`
      );
      if (withFile) {
        console.log(
          `               per-seed delivery ${rows.map((r) => r.ratio.toFixed(3)).join(", ")}; ` +
            `transfer ${fmt(mean((r) => r.transferMs ?? NaN))}`
        );
      }
    }
  }

  console.log("\n--- so is a load gate motivated? Shrink the window and ask again ---");
  console.log(
    "Under `free` there was nothing for a gate to protect (§6). Under a real radio there is, so the\n" +
      "obvious knob — send the file one chunk at a time instead of four, committing less air time\n" +
      "ahead — is measured here against both the text traffic and the file itself. Same plan, same\n" +
      "three seeds, and each run waits for the transfer to finish so both sides are one experiment."
  );
  console.log("window          delivery   within5   p95 ms   retries  parked  file time    dropped");
  const gateArms: Array<[string, boolean, number | undefined]> = [
    ["no file", false, undefined],
    ["file, window 4", true, undefined],
    ["file, window 1", true, 1],
  ];
  for (const [name, withFile, win] of gateArms) {
    const rows = SEEDS.map((seed) => contentionArm(seed, withFile, 60, 2000, "halfDuplex", win, 900_000));
    const mean = (f: (r: ContentionArm) => number) =>
      rows.reduce((a, r) => a + f(r), 0) / rows.length;
    console.log(
      `${name.padEnd(15)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ${mean((r) => r.within5).toFixed(4).padEnd(9)} ` +
        `${mean((r) => r.p95).toFixed(0).padEnd(8)} ${mean((r) => r.retries).toFixed(0).padEnd(8)} ` +
        `${mean((r) => r.queued).toFixed(1).padEnd(7)} ` +
        `${(withFile ? fmt(mean((r) => r.transferMs ?? NaN)) : "—").padEnd(12)} ${mean((r) => r.drops).toFixed(0)}`
    );
  }

  console.log("\n--- the other knob: chunk size, i.e. how much air time one packet commits ---");
  console.log(
    "A window of 1 still puts a whole 64 KB chunk on air at once. Slicing smaller interleaves text\n" +
      "between chunks instead of behind them, which is what adaptive fragmentation would do. Same\n" +
      "plan and seeds, transfer allowed to finish, window held at 4 so the two knobs are separable."
  );
  console.log("chunk           delivery   within5   p95 ms   retries  parked  file time    dropped");
  for (const chunk of [64 * 1024, 16 * 1024, 4 * 1024]) {
    const rows = SEEDS.map((seed) => {
      const sim = simFor({ ...campusQuad(seed), trafficIntervalMs: 0, channelAccess: "halfDuplex" });
      const plan = contentionPlan(seed, sim.nodes.length, 60);
      const a = sim.nodes[plan[0][0]];
      const b = sim.nodes[plan[0][1]];
      const t = sim.sendFile(a.id, b.id, 10 * MB, { chunkBytes: chunk });
      let sent = 0;
      for (let i = 1; i < plan.length; i++) {
        const from = sim.nodes[plan[i][0]];
        const to = sim.nodes[plan[i][1]];
        if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `k-${i}`, "text")) sent++;
        sim.runFor(2000);
      }
      const stats = sim.refresh();
      const uni = sim.deliveries.filter(
        (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
      );
      const lat = uni.map((d) => d.latencyMs).sort((x, y) => x - y);
      let waited = 0;
      while (t && t.state === "active" && waited < 900_000) {
        sim.runFor(250);
        waited += 250;
      }
      return {
        ratio: uni.length / Math.max(1, sent),
        within5: uni.filter((d) => d.hops <= 5).length / Math.max(1, sent),
        p95: lat.length ? lat[Math.floor(lat.length * 0.95)] : 0,
        retries: stats.retriesSent,
        queued: stats.totalQueued,
        drops: stats.channelDrops,
        ms: t && t.completedAt !== null ? t.completedAt - t.startedAt : NaN,
      };
    });
    const mean = (f: (r: (typeof rows)[number]) => number) =>
      rows.reduce((s, r) => s + f(r), 0) / rows.length;
    console.log(
      `${fmtSize(chunk).padEnd(15)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ${mean((r) => r.within5).toFixed(4).padEnd(9)} ` +
        `${mean((r) => r.p95).toFixed(0).padEnd(8)} ${mean((r) => r.retries).toFixed(0).padEnd(8)} ` +
        `${mean((r) => r.queued).toFixed(1).padEnd(7)} ${fmt(mean((r) => r.ms)).padEnd(12)} ${mean((r) => r.drops).toFixed(0)}`
    );
  }

  console.log("\n--- the acceptance gates themselves, under a real radio (20-node campus, 3 seeds) ---");
  console.log("channel        delivery   within5   overhead vs flood-all   SUPER ratio   deferred              dropped");
  for (const ch of ["free", "halfDuplex"] as ChannelAccess[]) {
    const rows = SEEDS.map((seed) => gateRow(seed, ch));
    const mean = (f: (r: GateRow) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
    console.log(
      `${ch.padEnd(14)} ${mean((r) => r.ratio).toFixed(4).padEnd(10)} ${mean((r) => r.within5).toFixed(4).padEnd(9)} ` +
        `${(mean((r) => r.overhead) * 100).toFixed(1).padEnd(6)}%${"".padEnd(18)} ` +
        `${(mean((r) => r.superRatio) * 100).toFixed(1).padEnd(6)}%${"".padEnd(7)} ` +
        `${fmt(mean((r) => r.deferMs))} over ${mean((r) => r.deferrals).toFixed(0)} tx`.padEnd(21) +
        ` ${mean((r) => r.drops).toFixed(0)}`
    );
  }
  console.log(
    "\nGates: skills/02 wants delivery ≥90% at 3 hops and overhead ≤70% of flood-all; skills/08 wants\n" +
      "delivery ≥90% within 5 hops and overhead down 30% versus naive flood. Both were written against\n" +
      "an infinitely wide radio, which is why `channelAccess` ships as `free`."
  );
}

// ---------------------------------------------------------------------------
// 8. Which packet a busy radio takes next
// ---------------------------------------------------------------------------

/**
 * §12.5 found the gate that pays is committing less air time ahead. This asks the other
 * queue question: when a radio has to choose, does choosing well help? Three disciplines
 * — arrival order, acknowledgements first, and a WMM-like class ranking that also puts an
 * SOS and a voice frame ahead of a bulk chunk — against the two loads that actually
 * compete on this mesh: a 10 MB file, and a streamed note.
 */

const PRIORITIES: ChannelPriority[] = ["fifo", "ackFirst", "class"];

interface PrioRow {
  delivery: number;
  p95: number;
  fileMs: number | null;
  noteDelayMs: number | null;
  underruns: number;
  sosMs: number;
  drops: number;
}

function textWithFile(prio: ChannelPriority, seed: number): PrioRow {
  const sim = simFor({
    ...campusQuad(seed),
    trafficIntervalMs: 0,
    channelAccess: "halfDuplex",
    channelPriority: prio,
  });
  const plan = contentionPlan(seed, sim.nodes.length, 60);
  const t = sim.sendFile(sim.nodes[plan[0][0]].id, sim.nodes[plan[0][1]].id, 10 * MB)!;
  let sent = 0;
  for (let i = 1; i < plan.length; i++) {
    const from = sim.nodes[plan[i][0]];
    const to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `p-${i}`, "text")) sent++;
    sim.runFor(2000);
  }
  const stats = sim.refresh();
  const uni = sim.deliveries.filter(
    (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
  );
  const lat = uni.map((d) => d.latencyMs).sort((x, y) => x - y);
  let waited = 0;
  while (t.state === "active" && waited < 600_000) {
    sim.runFor(250);
    waited += 250;
  }
  return {
    delivery: uni.length / Math.max(1, sent),
    p95: lat.length ? lat[Math.floor(lat.length * 0.95)] : 0,
    fileMs: t.completedAt === null ? null : t.completedAt - t.startedAt,
    noteDelayMs: null,
    underruns: 0,
    sosMs: 0,
    drops: stats.channelDrops,
  };
}

function noteWithFile(prio: ChannelPriority, seed: number): PrioRow {
  const sim = simFor({
    ...campusQuad(seed),
    trafficIntervalMs: 0,
    channelAccess: "halfDuplex",
    channelPriority: prio,
  });
  const plan = contentionPlan(seed, sim.nodes.length, 8);
  const t = sim.sendFile(sim.nodes[plan[0][0]].id, sim.nodes[plan[0][1]].id, 10 * MB)!;
  const note = sim.sendVoice(sim.nodes[plan[1][0]].id, sim.nodes[plan[1][1]].id, 30, { stream: true })!;
  let elapsed = 0;
  while ((t.state === "active" || note.state === "active") && elapsed < 600_000) {
    sim.runFor(250);
    elapsed += 250;
  }
  const arrivals = sim.deliveries
    .filter((d) => d.transferId === note.id)
    .map((d) => d.timestamp)
    .sort((x, y) => x - y);
  let underruns = 0;
  for (let i = 1; i < arrivals.length; i++) {
    if (arrivals[i] - arrivals[i - 1] > sim.config.voiceFrameMs + sim.config.jitterBufferMs) underruns++;
  }
  const released = note.releasedAt ?? note.startedAt;
  return {
    delivery: 0,
    p95: 0,
    fileMs: t.completedAt === null ? null : t.completedAt - t.startedAt,
    noteDelayMs: note.completedAt === null ? null : note.completedAt - released,
    underruns,
    sosMs: 0,
    drops: 0,
  };
}

function textWithNote(prio: ChannelPriority, seed: number): PrioRow {
  const sim = simFor({
    ...campusQuad(seed),
    trafficIntervalMs: 0,
    channelAccess: "halfDuplex",
    channelPriority: prio,
  });
  const plan = contentionPlan(seed, sim.nodes.length, 40);
  sim.sendVoice(sim.nodes[plan[0][0]].id, sim.nodes[plan[0][1]].id, 30, { stream: true });
  let sent = 0;
  for (let i = 1; i < plan.length; i++) {
    const from = sim.nodes[plan[i][0]];
    const to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `n-${i}`, "text")) sent++;
    sim.runFor(2000);
  }
  const uni = sim.deliveries.filter(
    (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
  );
  return {
    delivery: uni.length / Math.max(1, sent),
    p95: 0,
    fileMs: null,
    noteDelayMs: null,
    underruns: 0,
    sosMs: 0,
    drops: 0,
  };
}

function sosWithFile(prio: ChannelPriority, seed: number): PrioRow {
  const sim = simFor({
    ...campusQuad(seed),
    trafficIntervalMs: 0,
    channelAccess: "halfDuplex",
    channelPriority: prio,
  });
  const plan = contentionPlan(seed, sim.nodes.length, 8);
  sim.sendFile(sim.nodes[plan[0][0]].id, sim.nodes[plan[0][1]].id, 10 * MB);
  sim.runFor(5000);
  const t0 = sim.now;
  const edge = sim.nodes[sim.nodes.length - 1];
  sim.sendMessage(edge.id, "BROADCAST", "injured, need help", "sos");
  sim.runFor(30000);
  const got = sim.deliveries.filter((d) => d.type === "sos" && d.timestamp >= t0);
  return {
    delivery: 0,
    p95: 0,
    fileMs: null,
    noteDelayMs: null,
    underruns: 0,
    sosMs: got.length ? got.reduce((a, d) => a + (d.timestamp - t0), 0) / got.length : 30000,
    drops: 0,
  };
}

function priorityTable(): void {
  console.log("\n=== 8. Which packet a busy radio takes next (docs/08 §12.8) ===");
  console.log(
    "All arms are `channelAccess: \"halfDuplex\"` — with a free radio nothing waits, so there is\n" +
      "no order to choose. `fifo` is arrival order and ships; `ackFirst` promotes acknowledgements;\n" +
      "`class` also promotes an SOS and a voice frame above a bulk chunk. Mean of three seeds."
  );

  const cases: Array<[string, (p: ChannelPriority, s: number) => PrioRow, string[]]> = [
    ["text + a 10 MB file", textWithFile, ["delivery", "p95", "file", "drops"]],
    ["a 30 s note + a 10 MB file", noteWithFile, ["note delay", "underruns", "file"]],
    ["text + a 30 s note", textWithNote, ["delivery"]],
    ["an SOS + a 10 MB file", sosWithFile, ["sos latency"]],
  ];

  for (const [name, run, cols] of cases) {
    console.log(`\n--- ${name} ---`);
    console.log(
      `priority    ${cols.map((c) => c.padEnd(13)).join("")}`
    );
    for (const prio of PRIORITIES) {
      const rows = SEEDS.map((seed) => run(prio, seed));
      const mean = (f: (r: PrioRow) => number | null) => {
        const vals = rows.map(f).filter((v): v is number => v !== null);
        return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : NaN;
      };
      const cell = (key: string): string => {
        switch (key) {
          case "delivery":
            return mean((r) => r.delivery).toFixed(4);
          case "p95":
            return mean((r) => r.p95).toFixed(0) + " ms";
          case "file":
            return fmt(mean((r) => r.fileMs));
          case "drops":
            return mean((r) => r.drops).toFixed(0);
          case "note delay":
            return fmt(mean((r) => r.noteDelayMs));
          case "underruns":
            return mean((r) => r.underruns).toFixed(1);
          default:
            return fmt(mean((r) => r.sosMs));
        }
      };
      console.log(`${prio.padEnd(11)} ${cols.map((c) => cell(c).padEnd(13)).join("")}`);
    }
  }

  console.log(
    "\nRead: no ordering is free, and each one trades a flow against another. Promoting\n" +
      "acknowledgements buys text 1.1 points of delivery and 158 ms of p95 and charges the file\n" +
      "14% for it, because every slice an ACK overtakes is a slice the transfer waits for.\n" +
      "Promoting voice and an SOS on top of that is the best arm for a note competing with a\n" +
      "file — 49.26 s of play delay against 1.33 min, and the file itself is fastest there too,\n" +
      "because bulk chunks are the lowest class of all — and it costs 1.7 points of text delivery\n" +
      "when a note is in flight instead. What none of them do is rescue push-to-talk on its own:\n" +
      "the note's air time is the bottleneck at three hops, and no queue order creates air time.\n" +
      "An SOS is unaffected in every arm, because four floods of a 100-byte packet are not what a\n" +
      "busy radio is waiting on. Arrival order ships."
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

// ---------------------------------------------------------------------------
// 10. The contention window: does listening need a random wait to pay?
// ---------------------------------------------------------------------------

const BACKOFFS: ChannelBackoff[] = ["none", "binary"];

/** One 20-node campus run with a 10 MB file in flight, under carrier sense, at a given
 *  contention window. Shared by the sweep and by the six-seed robustness check below, so
 *  the two cannot disagree about what they measured. */
function csmaFileRun(
  seed: number,
  backoff: ChannelBackoff,
  cwMin: number,
  slotMs: number
): {
  ratio: number;
  p95: number;
  captured: number;
  deaf: number;
  drops: number;
  deferMs: number;
  backoffs: number;
  dropsRelayed: number;
  dropsMedia: number;
  dropsWithAlternative: number;
  fileMs: number | null;
} {
  const sim = simFor({
    ...campusQuad(seed),
    trafficIntervalMs: 0,
    channelAccess: "csma",
    channelCapture: "first",
    channelBackoff: backoff,
    channelCwMin: cwMin,
    channelSlotMs: slotMs,
  });
  const plan = contentionPlan(seed, sim.nodes.length, 60);
  const t = sim.sendFile(sim.nodes[plan[0][0]].id, sim.nodes[plan[0][1]].id, 10 * MB);
  let sent = 0;
  for (let i = 1; i < plan.length; i++) {
    const from = sim.nodes[plan[i][0]];
    const to = sim.nodes[plan[i][1]];
    if (from.isOnline && to.isOnline && sim.sendMessage(from.id, to.id, `b-${i}`, "text")) sent++;
    sim.runFor(2000);
  }
  const st = sim.refresh();
  const uni = sim.deliveries.filter(
    (d) => d.type !== "ack" && d.type !== "broadcast" && !d.groupId && !d.transferId
  );
  const lat = uni.map((d) => d.latencyMs).sort((x, y) => x - y);
  let waited = 0;
  while (t && t.state === "active" && waited < 900_000) {
    sim.runFor(250);
    waited += 250;
  }
  return {
    ratio: uni.length / Math.max(1, sent),
    p95: lat.length ? lat[Math.floor(lat.length * 0.95)] : 0,
    captured: st.channelCaptured,
    deaf: st.channelDeafRx,
    drops: st.channelDrops,
    deferMs: st.channelDeferMs,
    backoffs: st.channelBackoffs,
    dropsRelayed: st.channelDropsRelayed,
    dropsMedia: st.channelDropsMedia,
    dropsWithAlternative: st.channelDropsWithAlternative,
    fileMs: t && t.completedAt !== null ? t.completedAt - t.startedAt : null,
  };
}

function backoffTable(): void {
  console.log("\n=== 10. Contention window: the thing carrier sense was missing (docs/08 §12.13) ===");
  console.log(
    "§12.10 measured carrier sense and found it made things worse, which is not what listening is\n" +
      "supposed to do. The reason is in the wake-up: every node waiting on a busy medium is woken at\n" +
      "the instant it clears, so they all find it free together and transmit together. Carrier sense\n" +
      "synchronised the herd instead of dispersing it. `channelBackoff: \"binary\"` draws a random\n" +
      "number of slots before taking a medium that is already free, and doubles the window it draws\n" +
      "from after a collision — the 802.11 answer, which §12.10 noted it had not modelled."
  );

  console.log("\n--- the acceptance gates, with and without the random wait (20-node campus, 3 seeds) ---");
  console.log("transmitter  backoff  receiver   delivery   within5   overhead   SUPER    drops   deferred   draws");
  for (const capture of CAPTURES) {
    for (const backoff of BACKOFFS) {
      const rows = SEEDS.map((seed) => gateRow(seed, "csma", 60, capture, backoff));
      const mean = (f: (r: GateRow) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
      console.log(
        `${"csma".padEnd(12)} ${backoff.padEnd(8)} ${capture.padEnd(10)} ${mean((r) => r.ratio)
          .toFixed(4)
          .padEnd(10)} ${mean((r) => r.within5).toFixed(4).padEnd(9)} ` +
          `${(mean((r) => r.overhead) * 100).toFixed(1).padStart(5)} %   ` +
          `${(mean((r) => r.superRatio) * 100).toFixed(1).padStart(5)} %  ` +
          `${mean((r) => r.drops).toFixed(0).padStart(5)}   ` +
          `${(mean((r) => r.deferMs) / 1000).toFixed(1).padStart(6)} s   ` +
          `${mean((r) => r.backoffs).toFixed(0).padStart(6)}`
      );
    }
  }
  console.log(
    "\nThe gate is delivery ≥0.90. `backoff: none` is §12.10's csma arm, repeated here as the control."
  );

  console.log("\n--- how wide a window, and against a 10 MB file (3 seeds) ---");
  console.log(
    "A window that is too narrow does not separate anybody; one that is too wide makes every node\n" +
      "wait longer than the transmission it is waiting for. Swept against the case that matters: a\n" +
      "file in flight, collisions modelled, which is where §12.10 lost the most."
  );
  console.log("cwMin  slotMs  delivery   p95 ms   captured  deaf  drops  deferred   draws   file");
  for (const cwMin of [2, 4, 16, 64]) {
    for (const slotMs of [1, 5]) {
      const rows = SEEDS.map((seed) => csmaFileRun(seed, "binary", cwMin, slotMs));
      const mean = (f: (r: (typeof rows)[number]) => number) =>
        rows.reduce((a, r) => a + f(r), 0) / rows.length;
      console.log(
        `${String(cwMin).padEnd(6)} ${String(slotMs).padEnd(7)} ${mean((r) => r.ratio)
          .toFixed(4)
          .padEnd(10)} ${mean((r) => r.p95).toFixed(0).padStart(6)}   ` +
          `${mean((r) => r.captured).toFixed(0).padStart(7)}  ${mean((r) => r.deaf).toFixed(0).padStart(4)}  ` +
          `${mean((r) => r.drops).toFixed(0).padStart(5)}   ${(mean((r) => r.deferMs) / 60000).toFixed(1).padStart(6)} m   ` +
          `${mean((r) => r.backoffs).toFixed(0).padStart(6)}   ` +
          `${mean((r) => (r.fileMs === null ? Number.NaN : r.fileMs / 60000)).toFixed(2)} min`
      );
    }
  }

  console.log("\n--- does the best arm hold up? Six seeds, and the spread, not just the mean ---");
  console.log(
    "The sweep above is not monotonic in either knob: cwMin 2 beats 16 at a 5 ms slot and loses\n" +
      "to it at a 1 ms slot, and 64 beats 4 at one slot width and loses at the other. A lever whose\n" +
      "effect reverses when a neighbouring setting changes is a lever whose effect is noise. This\n" +
      "repository has been wrong that way before — §6's faster-beacon idea looked like +2.6 points\n" +
      "on three seeds and measured -1.1 on six — so the two arms that cleared the gate are re-run\n" +
      "on the acceptance suite's six seeds with every seed printed."
  );
  const ROBUST_SEEDS = [42, 7, 1234, 99, 2026, 555];
  const arms: Array<[string, ChannelBackoff, number, number]> = [
    ["control (no backoff)", "none", DEFAULT_CONFIG.channelCwMin, DEFAULT_CONFIG.channelSlotMs],
    ["binary cwMin 2 slot 5 ms", "binary", 2, 5],
    ["binary cwMin 16 slot 5 ms", "binary", 16, 5],
  ];
  console.log("arm".padEnd(26) + "mean     per-seed delivery".padEnd(12) + "  drops   file");
  for (const [name, backoff, cwMin, slotMs] of arms) {
    const rows = ROBUST_SEEDS.map((seed) => csmaFileRun(seed, backoff, cwMin, slotMs));
    const mean = (f: (r: (typeof rows)[number]) => number) =>
      rows.reduce((a, r) => a + f(r), 0) / rows.length;
    console.log(
      name.padEnd(26) +
        mean((r) => r.ratio).toFixed(4).padEnd(9) +
        rows.map((r) => r.ratio.toFixed(3)).join(" ") +
        "  " +
        mean((r) => r.drops).toFixed(0).padStart(5) +
        "   " +
        mean((r) => (r.fileMs === null ? Number.NaN : r.fileMs / 60000)).toFixed(2) +
        " min"
    );
  }
  console.log(
    "\nRead the per-seed column before the mean. If an arm's seeds straddle the control's, the\n" +
      "difference between their means is not a property of the backoff."
  );

  console.log("\n--- the lever is carrier-sense-only: `halfDuplex` must not move ---");
  console.log(
    "A node whose own radio is busy is already serialised by its FIFO, and with no shared medium\n" +
      "there is nobody to contend with. Backoff under `halfDuplex` would be delay for its own sake,\n" +
      "so the engine ignores it — asserted here rather than assumed."
  );
  for (const backoff of BACKOFFS) {
    const rows = SEEDS.map((seed) => captureCell("halfDuplex", "first", seed, true, undefined, backoff));
    const mean = (f: (r: CaptureCell) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
    console.log(
      `halfDuplex + ${backoff.padEnd(7)} delivery ${mean((r) => r.ratio).toFixed(4)}   draws ${mean((r) =>
        r.backoffs
      ).toFixed(0)}   file ${(mean((r) => (r.fileMs === null ? Number.NaN : r.fileMs / 60000))).toFixed(2)} min`
    );
  }
}

// ---------------------------------------------------------------------------
// 11. Where the queue actually overflows, and whether it could have gone round
// ---------------------------------------------------------------------------

function sheddingTable(): void {
  console.log("\n=== 11. Where the shedding happens (docs/08 §12.14) ===");
  console.log(
    "§12.12 argued that the queue which overflows in a mesh belongs to a relay, and §12.13 found\n" +
      "that queue drops outnumber receiver collisions about eight to one under carrier sense. Both\n" +
      "were read off totals. This attributes them: who sheds, what they shed, and — the question\n" +
      "that decides whether congestion-aware forwarding is even available — whether the shedding\n" +
      "relay had a peer in range at least as close to the destination as the next hop it chose. If\n" +
      "it did, the packet could have gone round the congestion. If it did not, the only mechanism\n" +
      "left is to stop generating the packet, which means propagating pressure to the source."
  );
  console.log("transmitter  receiver   media  drops   at a relay   file/voice   alternative existed   file");
  for (const access of ["halfDuplex", "csma"] as ChannelAccess[]) {
    for (const withFile of [false, true]) {
      const rows = SEEDS.map((seed) => captureCell(access, "first", seed, withFile));
      const mean = (f: (r: CaptureCell) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
      const drops = mean((r) => r.drops);
      const relayed = mean((r) => r.dropsRelayed);
      console.log(
        `${access.padEnd(12)} ${"first".padEnd(10)} ${(withFile ? "yes" : "no").padEnd(6)} ` +
          `${drops.toFixed(0).padStart(5)}   ` +
          `${((relayed / Math.max(1, drops)) * 100).toFixed(0).padStart(6)} %      ` +
          `${((mean((r) => r.dropsMedia) / Math.max(1, drops)) * 100).toFixed(0).padStart(6)} %      ` +
          `${((mean((r) => r.dropsWithAlternative) / Math.max(1, relayed)) * 100).toFixed(0).padStart(11)} %          ` +
          `${mean((r) => (r.fileMs === null ? Number.NaN : r.fileMs / 60000)).toFixed(2)} min`
      );
    }
  }
  console.log(
    "\nRead the third column first: if the shed packets are mostly file or voice chunks, the thing\n" +
      "generating the pressure is a transfer window, and the fix that reaches it is pressure\n" +
      "propagated to the source. The fourth column is the fork in the road — a high share means\n" +
      "congestion-aware forwarding has somewhere to put the packet, and a low one means it does\n" +
      "not, so rerouting around a saturated relay is not a mechanism this topology offers."
  );

  console.log("\n--- the one-peer case, which is where a sender can throttle itself ---");
  console.log(
    "Two nodes, one hop, a 1 MB file through a window of 8 into a queue 4 deep, so the transfer\n" +
      "is committed twice as far ahead as the radio can hold. This is the case §12.12 measured the\n" +
      "flag on, re-measured here because the mechanism was wrong when it was: the window was floored\n" +
      "at one, so a throttled sender still handed a packet to a full queue and had it shed, and the\n" +
      "stall path bypassed the window altogether. A window that can reach zero, a stall path that\n" +
      "consults the same gate, and a resume when the radio drains are what a socket does."
  );
  console.log("depth  backpressure  queue drops  retransmitted  stalls  blocked  file time");
  for (const depth of [4, 2]) {
    for (const bp of [false, true]) {
      const sim = new MeshSimulation({
        ...DEFAULT_CONFIG,
        nodeCount: 2,
        stationaryRatio: 1,
        chargingRatio: 0,
        trafficIntervalMs: 0,
        enableSuperElection: false,
        warmupMs: 0,
        obstacles: [],
        channelAccess: "halfDuplex",
        channelQueueDepth: depth,
        transferWindow: 8,
        mediaBackpressure: bp,
      });
      sim.nodes.forEach((node, i) => {
        node.pos = { x: 10 + i * 20, y: 10 };
        node.target = { x: 10 + i * 20, y: 10 };
        node.mobility = 0;
        node.isOnline = true;
        node.battery = 1;
      });
      sim.runFor(20000);
      sim.clearRecords();
      const t = sim.sendFile(sim.nodes[0].id, sim.nodes[1].id, 1 * MB)!;
      let waited = 0;
      while (t.state === "active" && waited < 300_000) {
        sim.runFor(50);
        waited += 50;
      }
      const st = sim.refresh();
      console.log(
        `${String(depth).padEnd(6)} ${(bp ? "on" : "off").padEnd(13)} ` +
          `${String(st.channelDrops).padStart(9)}  ${String(t.retransmitted).padStart(13)}  ` +
          `${String(t.stalls).padStart(6)}  ${String(st.transferBlocks).padStart(7)}  ` +
          `${(((t.completedAt ?? Number.NaN) - t.startedAt) / 1000).toFixed(2)} s`
      );
    }
  }

  console.log("\n--- so propagate the pressure to the source, which is where it is ---");
  console.log(
    "The columns above say the shedding is the source's and the packets are a transfer's, which is\n" +
      "the case `mediaBackpressure` was built for. §12.12 rejected it on the strength of a crowd run\n" +
      "and an argument about whose queue overflows; this is the campus arm the argument was about,\n" +
      "measured instead of reasoned."
  );
  console.log(
    "transmitter  backpressure  delivery   within5   p95 ms  parked   drops  at source  chunks  retrans  blocked   file"
  );
  for (const access of ["halfDuplex", "csma"] as ChannelAccess[]) {
    for (const bp of [false, true]) {
      const rows = SEEDS.map((seed) =>
        captureCell(access, "first", seed, true, undefined, undefined, undefined, bp)
      );
      const mean = (f: (r: CaptureCell) => number) => rows.reduce((a, r) => a + f(r), 0) / rows.length;
      const drops = mean((r) => r.drops);
      console.log(
        `${access.padEnd(12)} ${(bp ? "on" : "off").padEnd(13)} ${mean((r) => r.ratio)
          .toFixed(4)
          .padEnd(10)} ${mean((r) => r.within5).toFixed(4).padEnd(9)} ` +
          `${mean((r) => r.p95).toFixed(0).padStart(6)}  ${mean((r) => r.parked).toFixed(1).padStart(6)}   ` +
          `${drops.toFixed(0).padStart(5)}  ` +
          `${(((drops - mean((r) => r.dropsRelayed)) / Math.max(1, drops)) * 100).toFixed(0).padStart(7)} %  ` +
          `${((mean((r) => r.dropsMedia) / Math.max(1, drops)) * 100).toFixed(0).padStart(6)} %   ` +
          `${mean((r) => r.retries).toFixed(0).padStart(6)}   ` +
          `${mean((r) => r.blocks).toFixed(0).padStart(7)}   ` +
          `${mean((r) => (r.fileMs === null ? Number.NaN : r.fileMs / 60000)).toFixed(2)} min`
      );
    }
  }
  console.log(
    "\nIf the source is really where the pressure is, `on` should cut the drop count by most of the\n" +
      "share in the \"at source\" column and pay for it in file time. If it cuts the drops and does not\n" +
      "move delivery, the shed packets were ones nobody was waiting for any more."
  );
}

function captureEffectTable(): void {
  console.log("\n=== 12. The capture effect: bracketing the receiver instead of guessing it (docs/08 §12.15) ===");
  console.log(
    "§12.9 gave the receiver two models and neither is a real radio. `none` takes everything\n" +
      "however busy it is, which is optimistic; `first` locks onto whichever packet arrived first and\n" +
      "never lets a strong one survive a weak one, which is pessimistic. Real receivers do the third\n" +
      "thing: they demodulate the stronger signal *through* the weaker one when the margin is enough.\n" +
      "`strongest` models that, and the point of measuring it is not to pick a winner but to turn a\n" +
      "point estimate into a bracket — `first` bounds the loss from above, `none` from below, and a\n" +
      "field test lands somewhere between."
  );

  for (const withFile of [false, true]) {
    console.log(
      `\n--- ${withFile ? "60 messages at 2 s, with a 10 MB file in flight" : "60 messages at 2 s, nothing else"} (3 seeds) ---`
    );
    console.log(
      "transmitter  receiver     delivery   within5   p95 ms   captured  takeovers  deaf  queue drops  at source  file"
    );
    for (const access of ["halfDuplex", "csma"] as ChannelAccess[]) {
      for (const capture of RECEIVER_ARMS) {
        const rows = SEEDS.map((seed) => captureCell(access, capture, seed, withFile));
        const src =
          cellMean(rows, (r) => r.drops) > 0
            ? `${((1 - cellMean(rows, (r) => r.dropsRelayed) / cellMean(rows, (r) => r.drops)) * 100).toFixed(0)}%`
            : "—";
        console.log(
          `${access.padEnd(12)} ${capture.padEnd(12)} ${cellMean(rows, (r) => r.ratio).toFixed(4).padEnd(10)} ` +
            `${cellMean(rows, (r) => r.within5).toFixed(4).padEnd(9)} ${cellMean(rows, (r) => r.p95).toFixed(0).padEnd(8)} ` +
            `${cellMean(rows, (r) => r.captured).toFixed(0).padEnd(9)} ${cellMean(rows, (r) => r.effects).toFixed(0).padEnd(10)} ` +
            `${cellMean(rows, (r) => r.deaf).toFixed(0).padEnd(5)} ${cellMean(rows, (r) => r.drops).toFixed(0).padEnd(12)} ` +
            `${src.padEnd(10)} ${withFile ? fmt(cellMean(rows, (r) => r.fileMs)) : "—"}`
        );
      }
    }
  }

  console.log(
    "\nRead `takeovers` against `captured`: a takeover is not a rescue, it moves the loss from the\n" +
      "newcomer to the incumbent, so `captured` counts both. What the capture effect can actually\n" +
      "buy back is the part of `first`'s loss that was a strong packet being killed by a weak one."
  );

  // Three seeds is not enough for a claim of a few points on a chaotic system: at a 20 dB
  // margin the model takes over almost nothing and still lands a point away from `first`,
  // which is the size of the perturbation two takeovers make. Six seeds, with the worst one
  // printed beside the mean, is what separates a mechanism from a lucky draw.
  console.log("\n--- six seeds, 10 MB in flight: mean and worst ---");
  console.log("transmitter  receiver     mean      worst     takeovers  captured  queue drops  file");
  for (const access of ["halfDuplex", "csma"] as ChannelAccess[]) {
    for (const capture of RECEIVER_ARMS) {
      const rows = SIX_SEEDS.map((seed) => captureCell(access, capture, seed, true));
      const worst = Math.min(...rows.map((r) => r.ratio));
      console.log(
        `${access.padEnd(12)} ${capture.padEnd(12)} ${cellMean(rows, (r) => r.ratio).toFixed(4).padEnd(9)} ` +
          `${worst.toFixed(4).padEnd(9)} ${cellMean(rows, (r) => r.effects).toFixed(0).padEnd(10)} ` +
          `${cellMean(rows, (r) => r.captured).toFixed(0).padEnd(9)} ${cellMean(rows, (r) => r.drops).toFixed(0).padEnd(12)} ` +
          `${fmt(cellMean(rows, (r) => r.fileMs))}`
      );
    }
  }
}

function captureMarginTable(): void {
  console.log("\n=== 12b. How much margin the capture effect needs (csma, 10 MB in flight, six seeds) ===");
  console.log(
    "A margin of 0 dB is loudest-wins and should take the most receivers over; a large margin\n" +
      "should stop taking any over at all and converge on `first`. If the delivery column is not\n" +
      "monotone in the margin, the mechanism is not doing what it says. Six seeds and the worst\n" +
      "one beside the mean, because on three this table showed a monotone improvement toward a\n" +
      "0 dB margin that the six-seed receiver table did not confirm."
  );
  console.log("margin dB    takeovers  captured   mean      worst     p95 ms   queue drops  file");
  for (const margin of CAPTURE_MARGINS) {
    const rows = SIX_SEEDS.map((seed) =>
      captureCell("csma", "strongest", seed, true, undefined, undefined, undefined, undefined, margin)
    );
    const worst = Math.min(...rows.map((r) => r.ratio));
    console.log(
      `${String(margin).padEnd(12)} ${cellMean(rows, (r) => r.effects).toFixed(0).padEnd(10)} ` +
        `${cellMean(rows, (r) => r.captured).toFixed(0).padEnd(10)} ${cellMean(rows, (r) => r.ratio).toFixed(4).padEnd(9)} ` +
        `${worst.toFixed(4).padEnd(9)} ${cellMean(rows, (r) => r.p95).toFixed(0).padEnd(8)} ` +
        `${cellMean(rows, (r) => r.drops).toFixed(0).padEnd(12)} ${fmt(cellMean(rows, (r) => r.fileMs))}`
    );
  }
}

// ---------------------------------------------------------------------------
// 14. Occupancy: what a radio is busy for, against how long a packet takes to
//     arrive. docs/06 §24.5 asked the question; this answers it.
// ---------------------------------------------------------------------------

interface OccupancyRow {
  scenario: string;
  access: string;
  occupancy: string;
  demand: number;
  wakeMs: number;
  delivery: number;
  drops: number;
  deferrals: number;
}

function occupancyRun(
  seed: number,
  scenario: (seed: number) => SimConfig,
  name: string,
  access: SimConfig["channelAccess"],
  occupancy: SimConfig["radioOccupancy"]
): OccupancyRow {
  const sim = new MeshSimulation({
    ...scenario(seed),
    channelAccess: access,
    radioOccupancy: occupancy,
  });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  sim.runFor(60_000);
  sim.refresh();
  const st = sim.stats;
  return {
    scenario: name,
    access,
    occupancy,
    demand: st.radioDemandRatio,
    wakeMs: st.wakeLockMs,
    delivery: st.deliveryRatio,
    drops: st.channelDrops,
    deferrals: st.channelDeferrals,
  };
}

function occupancyTable(): void {
  console.log(
    "\n=== 14. Occupancy: what a radio is busy for is not how long a packet takes to arrive ==="
  );
  console.log(
    "The shipped model charges every packet a calibrated hop latency — 120 ms on BLE, which"
  );
  console.log(
    "serializationMs's own comment says already includes one full-sized GATT write — plus the"
  );
  console.log(
    "excess over 1 024 B. That is right at 1 024 B and wrong below it, so a short text pays"
  );
  console.log(
    "what a media chunk pays, and a beacon paid it too while having no size at all."
  );
  console.log(
    `\nBeacons now have one, derived from the fields docs/03 §4 says an OGM carries: fixed`
  );
  console.log(
    `  ${OGM_FIXED_BYTES} B + 32 B per advertised neighbour + 33 B per route entry, bounded by the`
  );
  console.log(
    `  advertise limits the engine enforces (${MPR_NEIGHBOR_ADVERTISE_LIMIT} neighbours, ${BEST_HOP_ADVERTISE_LIMIT} routes).`
  );
  console.log(
    `  A typical beacon (10 neighbours, 8 routes) is ${ogmWireBytes(10, 8)} B = ` +
      `${((ogmWireBytes(10, 8) * 8) / DEFAULT_CONFIG.bleKbps).toFixed(1)} ms of airtime, about half the flat`
  );
  console.log(
    `  120 ms it was charged. A fully loaded one is ${OGM_MAX_WIRE_BYTES} B, which is over the ` +
      `${BLE_MAX_BYTES} B BLE ceiling —`
  );
  console.log(
    "  so a dense node's beacon would ride Wi-Fi Direct. Nothing sized beacons before, so"
  );
  console.log("  nothing noticed. docs/06 §24.6.\n");

  const arms: Array<[string, (seed: number) => SimConfig, SimConfig["channelAccess"]]> = [
    ["campus_quad", campusQuad, "free"],
    ["campus_quad", campusQuad, "csma"],
    ["festival_crowd", festivalCrowd, "free"],
    ["festival_crowd", festivalCrowd, "halfDuplex"],
    ["festival_crowd", festivalCrowd, "csma"],
  ];
  const models: SimConfig["radioOccupancy"][] = ["hop-latency", "airtime"];
  const rows = new Map<string, OccupancyRow[]>();
  for (const [name, scenario, access] of arms) {
    for (const model of models) {
      const key = `${name}|${access}|${model}`;
      rows.set(key, SEEDS.map((seed) => occupancyRun(seed, scenario, name, access, model)));
    }
  }
  const mean = (key: string, f: (r: OccupancyRow) => number) => {
    const list = rows.get(key)!;
    return list.reduce((a, r) => a + f(r), 0) / Math.max(1, list.length);
  };

  console.log(`  mean of ${SEEDS.length} seeds, 30 messages injected over 60 s after a 90 s settle\n`);
  console.log(
    "  scenario         channel      occupancy     radio demand   wake time     delivery   queue drops   deferrals"
  );
  for (const [name, , access] of arms) {
    for (const model of models) {
      const key = `${name}|${access}|${model}`;
      console.log(
        `  ${name.padEnd(16)} ${access.padEnd(12)} ${model.padEnd(13)} ` +
          `${(mean(key, (r) => r.demand).toFixed(2) + "x").padStart(13)} ` +
          `${fmt(mean(key, (r) => r.wakeMs)).padStart(13)} ` +
          `${((mean(key, (r) => r.delivery) * 100).toFixed(1) + "%").padStart(10)} ` +
          `${mean(key, (r) => r.drops).toFixed(0).padStart(13)} ` +
          `${mean(key, (r) => r.deferrals).toFixed(0).padStart(11)}`
      );
    }
    console.log("");
  }

  console.log(
    "  Three things this says, and one it does not.\n" +
      "\n" +
      "  Sizing packets properly roughly halves the demanded radio time — campus_quad 3.9x to\n" +
      "  1.7x, festival_crowd 8.4x to 5.8x — and it does not make the demand physical. Above 1\n" +
      "  the model asks for more airtime than exists, so the over-subscription docs/06 §24.3\n" +
      "  measured is only partly the flat per-packet charge: the dominant term is the *volume*\n" +
      "  of beacon receptions and the gossip that follows them, which a per-packet correction\n" +
      "  cannot touch. At 60 nodes every node beaconing every 2 s is a real protocol finding\n" +
      "  about docs/03 §1's interval, not a simulator artefact.\n" +
      "\n" +
      "  Under the shipped free/none baseline the two models are the same world: nothing reads\n" +
      "  occupancy there except the wake-lock accounting, so delivery, latency, overhead and\n" +
      "  every count are bit-identical and only the telemetry moves. radio-occupancy.test.ts\n" +
      "  asserts that field by field, which is what makes the knob safe to ship defaulted off.\n" +
      "\n" +
      "  Where contention *is* modelled the two diverge, and §12's published numbers were\n" +
      "  measured under the flat charge — but not uniformly in one direction, which is the part\n" +
      "  worth not smoothing over. Under csma, sizing packets properly cuts crowd deferrals by\n" +
      "  about half (13 540 to 6 382) and lifts crowd delivery 71.5% to 81.9%, and on\n" +
      "  campus_quad it takes delivery from 98.7% to 100% with 29% fewer queue drops. Under\n" +
      "  half-duplex in the same crowd it goes the other way: delivery 77.9% to 75.9% and\n" +
      "  deferrals up 4%. A radio that frees sooner transmits sooner, and whether that helps\n" +
      "  depends on whether the model lets it hear anyone first — csma does, half-duplex does\n" +
      "  not. This probe reports the disagreement and does not claim to have established why.\n" +
      "  What follows is that §12's contention magnitudes are a property of the occupancy\n" +
      "  model they were measured under, not of the mesh.\n" +
      "\n" +
      "  What this does not say: that the flat model is wrong about latency. Delivery still\n" +
      "  takes a hop latency per hop under both models, because that is what docs/02 §6's budget\n" +
      "  measures and it is unchanged here. Only the busy-radio duration moved.\n"
  );
}

// ---------------------------------------------------------------------------
// 15. The beacon interval: docs/03 specifies 2 s and nothing in the corpus says
//     why. §24.6 found the control plane alone over-subscribes the radio at 60
//     nodes, which makes the interval the obvious lever — and NEIGHBOR_SCORE_TTL_MS
//     30 s the obvious ceiling on it.
// ---------------------------------------------------------------------------

interface BeaconRow {
  interval: number;
  demand: number;
  delivery: number;
  reach: number;
  overhead: number;
  hops: number;
  latency: number;
  control: number;
  suppressed: number;
  /** Route entries that expired unrenewed — the route table's churn, and the number the
   *  flap hypothesis about the 12 s arm needs (`docs/06` §24.7). */
  expiries: number;
}

function beaconRun(
  seed: number,
  scenario: (seed: number) => SimConfig,
  interval: number,
  aliasBytes = 32
): BeaconRow {
  const sim = new MeshSimulation({
    ...scenario(seed),
    // Priced with the model that charges each packet its own size, because the question is
    // physical capacity. Under the flat charge every arm would carry the same 120 ms
    // artefact §24.6 measured, and the sweep would be measuring that instead.
    radioOccupancy: "airtime",
    ogmIntervalMs: interval,
    ogmAliasBytes: aliasBytes,
  });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  sim.runFor(60_000);
  sim.refresh();
  const st = sim.stats;
  return {
    interval,
    demand: st.radioDemandRatio,
    delivery: st.deliveryRatio,
    reach: st.broadcastReach,
    overhead: st.overheadRatio,
    hops: st.avgHops,
    latency: st.avgLatencyMs,
    control: st.controlOverhead,
    suppressed: st.mprSuppressed,
    expiries: st.routeExpiries,
  };
}

const BEACON_INTERVALS = [2_000, 5_000, 12_000, 25_000];

/**
 * This section does not use the file's three seeds, and the reason is measured.
 *
 * `festival_crowd` at 60 nodes is bimodal: some seeds reach ~98 % of the network with a
 * broadcast and others reach 50-70 %, so which mode the sample happens to land in dominates
 * the mean. The first version of this table used the shared three seeds and reported delivery
 * as 96.7 % at 5 s, 93.9 % at 12 s and 97.1 % at 25 s — non-monotone, and published in
 * `docs/06` §24.7 as a result that was "reported, not explained". Over eight seeds the
 * ordering reverses and becomes monotone in the direction routing theory predicts: 94.8 %,
 * 87.5 %, 79.2 %. The non-monotonicity was the sample, not the mesh.
 *
 * The shared `SEEDS` are left alone on purpose. Every other section's numbers are published
 * against them, and widening them here would silently re-measure `docs/08` §1-§14.
 */
const BEACON_SEEDS = [42, 7, 1234, 99, 2024, 31337, 555, 8];

function beaconTable(): void {
  console.log(
    "\n=== 15. The beacon interval: docs/03 says 2 s and nothing in the corpus says why ==="
  );
  console.log(
    "§24.6 found the control plane alone asks for several times one radio's airtime at 60"
  );
  console.log(
    "nodes, priced correctly. The interval is the lever that follows, and it has a hard"
  );
  console.log(
    `ceiling: neighbour scores expire at NEIGHBOR_SCORE_TTL_MS ${NEIGHBOR_SCORE_TTL_MS / 1000} s, so an interval near`
  );
  console.log(
    "that leaves one missed beacon — and BLE links lose packets routinely — long enough to"
  );
  console.log(
    "drop a neighbour that is still there. Priced under radioOccupancy: airtime, because"
  );
  console.log(
    "the question is capacity and the flat charge would put the same artefact in every arm.\n"
  );

  for (const [name, scenario] of [
    ["campus_quad (20 nodes)", campusQuad],
    ["festival_crowd (60 nodes)", festivalCrowd],
  ] as Array<[string, (seed: number) => SimConfig]>) {
    console.log(`  ${name}, mean of ${BEACON_SEEDS.length} seeds\n`);
    console.log(
      "  interval   radio demand   delivery   broadcast reach   overhead   avg hops   avg latency   OGMs sent   MPR suppressed   route expiries   per-seed broadcast reach"
    );
    const rows: BeaconRow[] = [];
    for (const interval of BEACON_INTERVALS) {
      const perSeed = BEACON_SEEDS.map((seed) => beaconRun(seed, scenario, interval));
      const mean = (f: (r: BeaconRow) => number) =>
        perSeed.reduce((a, r) => a + f(r), 0) / Math.max(1, perSeed.length);
      rows.push({
        interval,
        demand: mean((r) => r.demand),
        delivery: mean((r) => r.delivery),
        reach: mean((r) => r.reach),
        overhead: mean((r) => r.overhead),
        hops: mean((r) => r.hops),
        latency: mean((r) => r.latency),
        control: mean((r) => r.control),
        suppressed: mean((r) => r.suppressed),
        expiries: mean((r) => r.expiries),
      });
      const r = rows[rows.length - 1];
      console.log(
        `  ${(interval === 2_000 ? "2 s (spec)" : `${interval / 1000} s`).padEnd(10)} ` +
          `${(r.demand.toFixed(2) + "x").padStart(12)} ` +
          `${((r.delivery * 100).toFixed(1) + "%").padStart(10)} ` +
          `${((r.reach * 100).toFixed(1) + "%").padStart(17)} ` +
          `${((r.overhead * 100).toFixed(0) + "%").padStart(10)} ` +
          `${r.hops.toFixed(2).padStart(10)} ` +
          `${fmt(r.latency).padStart(13)} ` +
          `${r.control.toFixed(0).padStart(11)} ` +
          `${r.suppressed.toFixed(0).padStart(16)} ` +
          `${r.expiries.toFixed(0).padStart(16)}   ` +
          // The spread, not just the mean: in a bimodal world the mean alone is what let a
          // three-seed sample publish a result the eight-seed sample contradicts.
          perSeed.map((x) => (x.reach * 100).toFixed(0)).join(" ")
      );
    }
    const spec = rows[0];
    const last = rows[rows.length - 1];
    console.log(
      `\n  Stretching the interval from the specified 2 s to ${last.interval / 1000} s cuts demanded radio time\n` +
        `  ${(spec.demand.toFixed(2) + "x").padStart(6)} → ${(last.demand.toFixed(2) + "x")} and OGM transmissions ${(spec.control / Math.max(1, last.control)).toFixed(1)}× , and it costs delivery\n` +
        `  ${((spec.delivery * 100).toFixed(1) + "%").padStart(6)} → ${((last.delivery * 100).toFixed(1) + "%")} with broadcast reach ${((spec.reach * 100).toFixed(1) + "%").padStart(6)} → ${((last.reach * 100).toFixed(1) + "%")}. Whether that trade is\n` +
        `  worth making is a density question, so both worlds are printed rather than one\n` +
        `  verdict: at 20 nodes and at 60 the same lever does not do the same thing.\n`
    );
  }
  // --- the other lever: what one advertised neighbour costs on air -------------------
  console.log(
    "  The interval is not the only lever, and docs/03 §4 already names the other one: \"a\n" +
      "  real deployment advertises 2-byte aliases (~60 B for 30 neighbours)\", where this\n" +
      "  engine advertises the full 32-byte public key. §24.6 derived what that costs — a fully\n" +
      "  loaded beacon is 1 270 B on public keys and 130 B on aliases, over the BLE ceiling in\n" +
      "  the first case and far under it in the second. Since beacon *reception* dominates\n" +
      "  demanded radio time, the encoding may be the bigger lever, so here both are measured at\n" +
      "  the specified interval rather than either being asserted.\n"
  );
  console.log(
    `  beacon size, typical (10 neighbours, 8 routes): ${ogmWireBytes(10, 8, 32)} B on public keys, ` +
      `${ogmWireBytes(10, 8, 2)} B on aliases`
  );
  console.log(
    `  beacon size, at both advertise limits (30, 8):  ${ogmWireBytes(30, 8, 32)} B on public keys, ` +
      `${ogmWireBytes(30, 8, 2)} B on aliases (BLE ceiling ${BLE_MAX_BYTES} B)\n`
  );
  console.log("  scenario                     encoding     radio demand   delivery   broadcast reach   OGMs sent");
  for (const [name, scenario] of [
    ["campus_quad (20 nodes)", campusQuad],
    ["festival_crowd (60 nodes)", festivalCrowd],
  ] as Array<[string, (seed: number) => SimConfig]>) {
    for (const [encName, aliasBytes] of [
      ["32 B public key", 32],
      ["2 B alias (§4)", 2],
    ] as Array<[string, number]>) {
      const perSeed = BEACON_SEEDS.map((seed) =>
        beaconRun(seed, scenario, 2_000, aliasBytes)
      );
      const mean = (f: (r: BeaconRow) => number) =>
        perSeed.reduce((a, r) => a + f(r), 0) / Math.max(1, perSeed.length);
      console.log(
        `  ${name.padEnd(28)} ${encName.padEnd(14)} ` +
          `${(mean((r) => r.demand).toFixed(2) + "x").padStart(12)} ` +
          `${((mean((r) => r.delivery) * 100).toFixed(1) + "%").padStart(10)} ` +
          `${((mean((r) => r.reach) * 100).toFixed(1) + "%").padStart(17)} ` +
          `${mean((r) => r.control).toFixed(0).padStart(11)}`
      );
    }
  }
  console.log(
    "\n  Aliases cut the beacon, not the number of beacons, so `OGMs sent` is the same in both\n" +
      "  rows and only the demand moves. The two levers are not interchangeable: an alias\n" +
      "  shortens every beacon in a dense world without making any route staler, while a longer\n" +
      "  interval thins them and trades freshness for airtime. Which one a deployment should\n" +
      "  pull first is answered by the two tables above rather than argued here.\n" +
      "\n" +
      "  What neither tests: an interval that *adapts* to density, which is what the two\n" +
      "  scenario tables together argue for and which docs/03 §1 does not propose. Making the\n" +
      "  beacon interval a function of peer count is a routing change with its own convergence\n" +
      "  question — a node that slows its beacons because it has many neighbours is exactly the\n" +
      "  node its neighbours most need to hear from — so it is named here as the follow-up\n" +
      "  rather than swept. docs/06 §24.7.\n"
  );
}

// ---------------------------------------------------------------------------
// 16. Why a 60-node crowd has two modes, and the two explanations that failed
// ---------------------------------------------------------------------------

interface ReachRow {
  seed: number;
  reach: number;
  delivery: number;
  suppressed: number;
  overhead: number;
  /** Component sizes of the radio graph at the end of the window, largest first. */
  components: number[];
}

function reachRun(
  seed: number,
  interval: number,
  policy: RelayPolicy
): ReachRow {
  const sim = new MeshSimulation({
    ...festivalCrowd(seed),
    radioOccupancy: "airtime",
    ogmIntervalMs: interval,
    relayPolicy: policy,
  });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  sim.runFor(60_000);
  sim.refresh();
  const components = componentSizes(sim);
  return {
    seed,
    reach: sim.stats.broadcastReach,
    delivery: sim.stats.deliveryRatio,
    suppressed: sim.stats.mprSuppressed,
    overhead: sim.stats.overheadRatio,
    components,
  };
}

const REACH_SEEDS = [42, 7, 1234, 99, 2024, 31337, 555, 8];

/**
 * Component sizes of the radio graph — who can hear whom — largest first.
 *
 * Used both at the end of a window and, in `reachSampled`, repeatedly during one, because a
 * graph measured once after 60 s of mobility is not the graph the broadcasts had to cross.
 */
function componentSizes(sim: MeshSimulation): number[] {
  const nodes = sim.nodes;
  const adj = new Map<NodeId, NodeId[]>();
  for (const n of nodes) adj.set(n.id, peersInRange(n, nodes, sim.rf).map((p) => p.id));
  const seen = new Set<NodeId>();
  const out: number[] = [];
  for (const n of nodes) {
    if (seen.has(n.id)) continue;
    let size = 0;
    const stack = [n.id];
    while (stack.length > 0) {
      const id = stack.pop()!;
      if (seen.has(id)) continue;
      seen.add(id);
      size++;
      for (const nb of adj.get(id) ?? []) if (!seen.has(nb)) stack.push(nb);
    }
    out.push(size);
  }
  out.sort((a, b) => b - a);
  return out;
}

interface SampledRow {
  seed: number;
  reach: number;
  /** Fraction of in-window samples at which every node could reach every other. */
  connectedFrac: number;
  /** Mean largest-component share of the network across those samples. */
  meanLargest: number;
  /** Largest-component share at the end of the window, for comparison. */
  finalLargest: number;
}

/** How many samples to take inside the 60 s window, and how far apart. */
const SAMPLES = 6;
const SAMPLE_STEP_MS = 10_000;

function reachSampled(seed: number, interval: number): SampledRow {
  const sim = new MeshSimulation({
    ...festivalCrowd(seed),
    radioOccupancy: "airtime",
    ogmIntervalMs: interval,
  });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  let connected = 0;
  let largestSum = 0;
  for (let i = 0; i < SAMPLES; i++) {
    sim.runFor(SAMPLE_STEP_MS);
    sim.refresh();
    const comps = componentSizes(sim);
    if (comps.length === 1) connected++;
    largestSum += comps[0] / sim.nodes.length;
  }
  const final = componentSizes(sim);
  return {
    seed,
    reach: sim.stats.broadcastReach,
    connectedFrac: connected / SAMPLES,
    meanLargest: largestSum / SAMPLES,
    finalLargest: final[0] / sim.nodes.length,
  };
}

function reachTable(): void {
  console.log(
    "\n=== 16. Why a 60-node crowd has two modes, and the two explanations that failed ==="
  );
  console.log(
    "§24.8 found `festival_crowd` bimodal: broadcast reach lands either near 98% or between"
  );
  console.log(
    "50 and 79%, and which seeds are weak differs per arm. Two explanations are obvious, and"
  );
  console.log(
    "both are testable here — one from the radio graph, one from the forwarding policy.\n"
  );

  console.log("  Hypothesis 1: the crowd partitions, so a broadcast cannot reach everyone.\n");
  console.log("  interval   seed     reach   components (largest first)");
  for (const interval of [2_000, 12_000]) {
    for (const seed of REACH_SEEDS) {
      const r = reachRun(seed, interval, "mpr");
      const split = r.components.length > 1 ? "  <-- SPLIT" : "";
      console.log(
        `  ${(interval / 1000 + " s").padEnd(10)} ${String(seed).padEnd(8)} ` +
          `${((r.reach * 100).toFixed(0) + "%").padStart(5)}   ` +
          `[${r.components.slice(0, 4).join(", ")}] of ${r.components.reduce((a, b) => a + b, 0)}${split}`
      );
    }
    console.log("");
  }
  console.log(
    "  Partly true and not the story. At 2 s two of eight seeds split 40/20, and both are\n" +
      "  weak-reach seeds — so for those the ceiling is the component the sender is in, not a\n" +
      "  routing failure. But a weak seed at 2 s (2024, 79%) is fully connected, and at 12 s\n" +
      "  **all eight worlds are connected** while reach still spans 55-98%. Partitioning\n" +
      "  explains two rows of sixteen and cannot explain the mode.\n"
  );

  console.log("  Hypothesis 2: stale two-hop views make MPR suppress the only path.\n");
  console.log("  interval   policy      reach   delivery   MPR suppressed   overhead   per-seed reach");
  for (const interval of [2_000, 12_000]) {
    for (const policy of ["mpr", "flood-all"] as RelayPolicy[]) {
      const rows = REACH_SEEDS.map((seed) => reachRun(seed, interval, policy));
      const mean = (f: (r: ReachRow) => number) =>
        rows.reduce((a, r) => a + f(r), 0) / Math.max(1, rows.length);
      console.log(
        `  ${(interval / 1000 + " s").padEnd(10)} ${policy.padEnd(11)} ` +
          `${((mean((r) => r.reach) * 100).toFixed(1) + "%").padStart(6)} ` +
          `${((mean((r) => r.delivery) * 100).toFixed(1) + "%").padStart(10)} ` +
          `${mean((r) => r.suppressed).toFixed(0).padStart(16)} ` +
          `${((mean((r) => r.overhead) * 100).toFixed(0) + "%").padStart(10)}   ` +
          rows.map((r) => (r.reach * 100).toFixed(0)).join(" ")
      );
    }
    console.log("");
  }
  console.log(
    "  Refuted. `flood-all` suppresses nothing at all and spends roughly six times the\n" +
      "  overhead, and the weak mode survives it: per-seed reach under flood-all still reads\n" +
      "  42%, 55% and 66% at 2 s, where MPR gave 79%, 54% and 87%. At 2 s flooding is\n" +
      "  *worse* on the mean (81.8% against 86.5%) despite unlimited retransmission. A\n" +
      "  forwarding policy that cannot be improved by removing the forwarding policy is not\n" +
      "  what is limiting reach.\n"
  );

  console.log(
    "  Hypothesis 3: the graph measured at the *end* of the window is not the graph the\n" +
      `  broadcasts had to cross. Sampled ${SAMPLES} times inside it, ${SAMPLE_STEP_MS / 1000} s apart.\n`
  );
  console.log("  interval   seed     reach   connected samples   mean largest component   largest at the end");
  for (const interval of [2_000, 12_000]) {
    for (const seed of REACH_SEEDS) {
      const r = reachSampled(seed, interval);
      console.log(
        `  ${(interval / 1000 + " s").padEnd(10)} ${String(seed).padEnd(8)} ` +
          `${((r.reach * 100).toFixed(0) + "%").padStart(5)} ` +
          `${`${(r.connectedFrac * 100).toFixed(0)}% of ${SAMPLES}`.padStart(21)} ` +
          `${((r.meanLargest * 100).toFixed(0) + "%").padStart(23)} ` +
          `${((r.finalLargest * 100).toFixed(0) + "%").padStart(19)}`
      );
    }
    console.log("");
  }

  console.log(
    "  Confirmed, and it reverses the verdict on hypothesis 1. Reach tracks the connectivity\n" +
      "  *inside* the window, not the snapshot after it: every seed connected for all six\n" +
      "  samples reaches 98%, and every seed that was split for any of them lands between 54%\n" +
      "  and 93%, in proportion to how much of the window was split. At 12 s seed 2024 is\n" +
      "  connected for 17% of samples with a mean largest component of 72% — and reaches 55%,\n" +
      "  while the end-of-window table reports it as fully connected, because the crowd had\n" +
      "  re-joined by then. So the two modes are one phenomenon: 60 mobile nodes in this area\n" +
      "  split and re-join repeatedly, a broadcast sent while the graph is split cannot reach\n" +
      "  the other side, and reach averaged over the window lands wherever the split left it.\n" +
      "\n" +
      "  Hypothesis 1 was not wrong about the mechanism, only about when to look for it, and\n" +
      "  the end-of-window component table it used cannot see a partition that has healed.\n" +
      "  Hypothesis 2 stays refuted: flooding does not help, because a broadcast cannot cross a\n" +
      "  gap that exists at the moment it is sent, however many copies are made.\n" +
      "\n" +
      "  What this leaves untested, and worth naming: a receiver asleep inside its duty-cycle\n" +
      "  window when the broadcast passes, which scansSkippedAsleep would quantify per seed, and\n" +
      "  queue shedding under the crowd's own load, which §12.14 measured as mostly the source's\n" +
      "  own. Neither is needed to explain the bimodality now. docs/06 §24.10.\n" +
      "\n" +
      "  One thing that fell out and is worth keeping: MPR's overhead against flood-all in the\n" +
      "  densest scenario, on eight seeds, is 2 319% against 17 728% at 2 s and 2 662% against\n" +
      "  14 857% at 12 s — **13% and 18% of flood-all**, against skills/02's acceptance target\n" +
      "  of \u226470%, while delivering *more* reach at 2 s. That target is met here by a wide\n" +
      "  margin, and this is the first place it has been measured in a 60-node world.\n"
  );
}

// ---------------------------------------------------------------------------
// 17. Deriving the beacon interval from density: §24.7's follow-up, measured and
//     rejected. The connectivity columns are why it can be rejected honestly.
// ---------------------------------------------------------------------------

interface IntervalModeRow {
  delivery: number;
  reach: number;
  demand: number;
  ogms: number;
  connected: number;
  largest: number;
}

function intervalModeRun(
  seed: number,
  scenario: (seed: number) => SimConfig,
  mode: SimConfig["ogmIntervalMode"]
): IntervalModeRow {
  const sim = new MeshSimulation({
    ...scenario(seed),
    radioOccupancy: "airtime",
    ogmIntervalMode: mode,
  });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  sim.runFor(60_000);
  sim.refresh();
  const st = sim.stats;
  return {
    delivery: st.deliveryRatio,
    reach: st.broadcastReach,
    demand: st.radioDemandRatio,
    ogms: st.controlOverhead,
    connected: st.connectedSampleShare,
    largest: st.meanLargestComponent,
  };
}

function intervalModeTable(): void {
  console.log(
    "\n=== 17. Deriving the beacon interval from density: the follow-up §24.7 argued for ==="
  );
  console.log(
    "§24.7 found no single interval serving both densities: at 20 nodes stretching 2 s to 25 s"
  );
  console.log(
    "costs nothing and cuts demanded radio time tenfold, while at 60 nodes 5 s beats the"
  );
  console.log(
    "specified 2 s and everything longer degrades delivery. The obvious follow-up is to derive"
  );
  console.log(
    "the interval per node instead of choosing one, stretching it in proportion to peer count"
  );
  console.log(
    "so the receptions a node imposes stay constant, anchored so ten peers reproduces the"
  );
  console.log(
    "specified 2 s. Eight seeds, three scenarios, priced under radioOccupancy: airtime.\n"
  );
  console.log(
    "  scenario         mode      delivery    reach   radio demand   OGMs sent   connected in-window   mean largest component"
  );
  for (const [name, scenario] of [
    ["sparse_village", sparseVillage],
    ["campus_quad", campusQuad],
    ["festival_crowd", festivalCrowd],
  ] as Array<[string, (seed: number) => SimConfig]>) {
    const means = new Map<string, IntervalModeRow>();
    for (const mode of ["fixed", "density"] as SimConfig["ogmIntervalMode"][]) {
      const rows = BEACON_SEEDS.map((seed) => intervalModeRun(seed, scenario, mode));
      const mean = (f: (r: IntervalModeRow) => number) =>
        rows.reduce((a, r) => a + f(r), 0) / Math.max(1, rows.length);
      const m = {
        delivery: mean((r) => r.delivery),
        reach: mean((r) => r.reach),
        demand: mean((r) => r.demand),
        ogms: mean((r) => r.ogms),
        connected: mean((r) => r.connected),
        largest: mean((r) => r.largest),
      };
      means.set(mode, m);
      console.log(
        `  ${name.padEnd(16)} ${mode.padEnd(9)} ` +
          `${((m.delivery * 100).toFixed(1) + "%").padStart(8)} ` +
          `${((m.reach * 100).toFixed(1) + "%").padStart(8)} ` +
          `${(m.demand.toFixed(2) + "x").padStart(14)} ` +
          `${m.ogms.toFixed(0).padStart(11)} ` +
          `${((m.connected * 100).toFixed(0) + "%").padStart(21)} ` +
          `${((m.largest * 100).toFixed(0) + "%").padStart(23)}`
      );
    }
    const f = means.get("fixed")!;
    const d = means.get("density")!;
    console.log(
      `  ${"".padEnd(16)} ${"Δ".padEnd(9)} ` +
        `${(((d.delivery - f.delivery) * 100).toFixed(1) + " pts").padStart(8)} ` +
        `${"".padStart(8)} ` +
        `${((d.demand / f.demand).toFixed(2) + "x").padStart(14)} ` +
        `${((d.ogms / f.ogms).toFixed(2) + "x").padStart(11)} ` +
        `   topology comparable: ${Math.abs(d.largest - f.largest) < 0.03 ? "yes" : "NO — read §24.10 first"}`
    );
    console.log("");
  }
  console.log(
    "  Read the last line of each pair before the rest, because it decides whether the pair\n" +
      "  means anything. §24.10 showed reach tracks the largest in-window component, so two\n" +
      "  arms whose connectivity differs are not a comparison of what was changed.\n" +
      "\n" +
      "  sparse_village and campus_quad are comparable — both modes land in the same topology\n" +
      "  — and in both the derived interval buys no delivery and costs airtime: 3.1x the\n" +
      "  demanded radio time for 1.6 points in the village, 1.2x for a loss of 0.7 on campus.\n" +
      "  The mechanism is the clamp's floor: a node with three peers beacons every 500 ms,\n" +
      "  four times the specified rate, to hold a reception load nobody was struggling with.\n" +
      "\n" +
      "  festival_crowd is where the derived interval saves airtime, 5.7x down to 3.3x, and it\n" +
      "  is exactly where the comparison cannot be read: the two modes land in different\n" +
      "  topologies (mean largest component 94% against 85%), so the 8.6-point delivery gap\n" +
      "  cannot be attributed to the interval. That is not a defence of the lever — it is the\n" +
      "  reason the verdict rests on the two scenarios where the topology is comparable.\n" +
      "\n" +
      "  So the follow-up §24.7 argued for is measured and rejected: ogmIntervalMode ships\n" +
      "  fixed, the specified 2 s stays, and the flag exists so this table is reproducible\n" +
      "  rather than so the mode can be turned on. docs/06 §24.11.\n"
  );
}

function main(): void {
  console.log("Duman media transport probe — every number below is measured, not assumed.");
  console.log(
    `Radios: BLE ${DEFAULT_CONFIG.bleKbps} kbit/s, Wi-Fi Direct ${DEFAULT_CONFIG.wifiDirectKbps} kbit/s ` +
      `(${Math.round(DEFAULT_CONFIG.wifiDirectKbps / DEFAULT_CONFIG.bleKbps)}×, the ratio docs/05 §3.2 claims). ` +
      `Hop latency BLE ${DEFAULT_CONFIG.hopLatencyBleMs} ms / Wi-Fi ${DEFAULT_CONFIG.hopLatencyWifiMs} ms, ` +
      `jitter ${DEFAULT_CONFIG.jitterMinMs}-${DEFAULT_CONFIG.jitterMaxMs} ms.`
  );
  // `npm run media` runs all thirteen sections, which is minutes of simulation. A section name as
  // the first argument runs just that one — the whole file is a build, so re-measuring §10
  // should not mean re-measuring §1-§9 to get at it.
  const only = process.argv[2];
  const sections: Array<[string, () => void]> = [
    ["serialization", serializationTable],
    ["file", fileTable],
    ["voice", voiceTable],
    ["retry", retryTimerTable],
    ["acceptance", acceptanceTable],
    ["contention", contentionTable],
    ["channel", channelTable],
    ["priority", priorityTable],
    ["capture", captureTable],
    ["backoff", backoffTable],
    ["shedding", sheddingTable],
    ["captureEffect", captureEffectTable],
    ["captureMargin", captureMarginTable],
    ["occupancy", occupancyTable],
    ["beacon", beaconTable],
    ["reach", reachTable],
    ["intervalMode", intervalModeTable],
  ];
  if (only && !sections.some(([name]) => name === only)) {
    console.error(`unknown section "${only}". one of: ${sections.map(([name]) => name).join(", ")}`);
    process.exit(2);
  }
  for (const [name, run] of sections) if (!only || name === only) run();
  console.log("\nDone.");
}

main();
