/**
 * Field-test report: the same metrics from a rack of phones that the simulator reports
 * from a run (`docs/09-field-test-plan.md`).
 *
 * Input is the JSONL capture schema in §4 of that document — one JSON object per line,
 * `kind` one of meta|tx|deliver|loss|duplicate|decision|queue|election|sample|calibration.
 * `npm run field:capture` writes that schema from a simulated run, which is how this
 * analyzer is tested: against a log whose ground truth is already known.
 *
 *   npm run field:report -- /tmp/capture.jsonl [/tmp/flood-all-baseline.jsonl]
 */
import { readFileSync } from "node:fs";

interface Rec {
  v: number;
  kind: string;
  atMs: number;
  device: string;
  peerId?: string;
  msgId?: string;
  msgType?: string;
  hop?: number;
  rssi?: number;
  detail?: string;
  role?: string;
  battery?: number;
  charging?: boolean;
  online?: boolean;
  /** `topology` records: the radio graph at one sample boundary (`docs/09` §4). */
  nodes?: number;
  components?: number;
  largest?: number;
  connected?: boolean;
  awake?: boolean;
  distanceM?: number;
  walls?: number;
  [key: string]: unknown;
}

function load(path: string): Rec[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim().length > 0)
    .map((l) => JSON.parse(l) as Rec);
}

function quantile(sorted: number[], q: number): number {
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.floor(sorted.length * q)));
  return sorted[idx];
}

/** Solve a small symmetric linear system by Gaussian elimination (3x3 at most). */
function solve(a: number[][], b: number[]): number[] {
  const n = b.length;
  const m = a.map((row, i) => [...row, b[i]]);
  for (let col = 0; col < n; col++) {
    let pivot = col;
    for (let r = col + 1; r < n; r++) if (Math.abs(m[r][col]) > Math.abs(m[pivot][col])) pivot = r;
    [m[col], m[pivot]] = [m[pivot], m[col]];
    if (Math.abs(m[col][col]) < 1e-12) return [];
    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const f = m[r][col] / m[col][col];
      for (let c = col; c <= n; c++) m[r][c] -= f * m[col][c];
    }
  }
  return m.map((row, i) => row[n] / row[i]);
}

interface Delivery {
  sent: number;
  delivered: number;
  ratio: number;
  relayTx: number;
  txPerMessage: number;
  within5: number;
  p50Ms: number;
  p95Ms: number;
  losses: number;
  duplicates: number;
}

/**
 * The traffic half of the report.
 *
 * A message counts as *sent* when its originator put it on air (`tx` at hop 0), and as
 * *delivered* when a `deliver` record exists for it. That is the same definition the
 * engines use, computed from the log rather than from engine state, because on the day
 * of a field test the log is all there is.
 */
interface Connectivity {
  samples: number;
  /** Samples at which every node could reach every other. */
  connected: number;
  connectedShare: number;
  /** Mean share of the network inside the largest component across the samples. */
  meanLargestShare: number;
  /** The worst single sample, because a mean hides the split that bounded a broadcast. */
  worstLargestShare: number;
}

const NO_CONNECTIVITY: Connectivity = {
  samples: 0,
  connected: 0,
  connectedShare: NaN,
  meanLargestShare: NaN,
  worstLargestShare: NaN,
};

/**
 * What the `topology` records say about the walk.
 *
 * This exists because a capture cannot be read without it. `docs/06` §24.10 measured a
 * 60-node crowd splitting and re-joining inside a window, so broadcast reach lands near 98%
 * when the network stays in one piece and 50-79% when it does not — and §24.9 drew the wrong
 * conclusion from a graph reconstructed *after* the run, because a partition that has healed
 * looks exactly like one that never happened. A field capture has the same failure mode
 * available to it, so the analyzer reports the in-window timeline rather than leaving reach to
 * be interpreted against a topology nobody recorded.
 */
function connectivity(recs: Rec[]): Connectivity {
  const t = recs.filter(
    (r) => r.kind === "topology" && typeof r.nodes === "number" && r.nodes > 0
  );
  if (t.length === 0) return NO_CONNECTIVITY;
  const connected = t.filter((r) => r.connected === true).length;
  const shares = t.map((r) => (r.largest ?? 0) / (r.nodes ?? 1));
  return {
    samples: t.length,
    connected,
    connectedShare: connected / t.length,
    meanLargestShare: shares.reduce((a, b) => a + b, 0) / shares.length,
    worstLargestShare: Math.min(...shares),
  };
}

function delivery(recs: Rec[]): Delivery {
  const firstTx = new Map<string, number>();
  let relayTx = 0;
  for (const r of recs) {
    if (r.kind !== "tx" || !r.msgId) continue;
    if (r.msgType === "ack" || r.msgType === "ogm" || r.msgType === "sync") continue;
    if ((r.hop ?? 0) === 0) {
      if (!firstTx.has(r.msgId)) firstTx.set(r.msgId, r.atMs);
    } else {
      relayTx++;
    }
  }
  const firstDeliver = new Map<string, number>();
  const hops = new Map<string, number>();
  for (const r of recs) {
    if (r.kind !== "deliver" || !r.msgId) continue;
    if (r.msgType === "ack" || r.msgType === "ogm" || r.msgType === "sync") continue;
    if (!firstDeliver.has(r.msgId)) {
      firstDeliver.set(r.msgId, r.atMs);
      hops.set(r.msgId, r.hop ?? 0);
    }
  }
  const delivered = [...firstDeliver.keys()].filter((id) => firstTx.has(id));
  const latencies = delivered
    .map((id) => firstDeliver.get(id)! - firstTx.get(id)!)
    .filter((ms) => ms >= 0)
    .sort((a, b) => a - b);
  const within5 = delivered.filter((id) => (hops.get(id) ?? 0) + 1 <= 5).length;
  return {
    sent: firstTx.size,
    delivered: delivered.length,
    ratio: firstTx.size > 0 ? delivered.length / firstTx.size : 0,
    relayTx,
    txPerMessage: firstTx.size > 0 ? relayTx / firstTx.size : 0,
    within5,
    p50Ms: quantile(latencies, 0.5),
    p95Ms: quantile(latencies, 0.95),
    losses: recs.filter((r) => r.kind === "loss").length,
    duplicates: recs.filter((r) => r.kind === "duplicate").length,
  };
}

/** Role timeline from periodic samples: SUPER ratio, first election, flapping. */
function elections(recs: Rec[]): {
  devices: number;
  superRatio: number;
  firstSampleMs: number;
  transitionsPerNodeMin: number;
  superDevices: string[];
} {
  const samples = recs.filter((r) => r.kind === "sample" && r.role);
  if (samples.length === 0) {
    return { devices: 0, superRatio: NaN, firstSampleMs: NaN, transitionsPerNodeMin: NaN, superDevices: [] };
  }
  const byDevice = new Map<string, { atMs: number; role: string }[]>();
  for (const s of samples) {
    const list = byDevice.get(s.device) ?? [];
    list.push({ atMs: s.atMs, role: s.role! });
    byDevice.set(s.device, list);
  }
  let superSamples = 0;
  let transitions = 0;
  const superDevices: string[] = [];
  for (const [device, list] of byDevice) {
    list.sort((a, b) => a.atMs - b.atMs);
    let everSuper = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].role === "SUPER") {
        superSamples++;
        everSuper = true;
      }
      if (i > 0 && list[i].role !== list[i - 1].role) transitions++;
    }
    if (everSuper) superDevices.push(device);
  }
  const spanMs = Math.max(...samples.map((s) => s.atMs)) - Math.min(...samples.map((s) => s.atMs));
  const minutes = Math.max(1e-9, spanMs / 60000);
  return {
    devices: byDevice.size,
    superRatio: superSamples / samples.length,
    firstSampleMs: Math.min(...samples.map((s) => s.atMs)),
    transitionsPerNodeMin: transitions / byDevice.size / minutes,
    superDevices,
  };
}

/** Battery drain per role, from samples that are not charging (skills/07). */
function battery(recs: Rec[]): { normal: number; super: number; hours: number } {
  const samples = recs
    .filter((r) => r.kind === "sample" && typeof r.battery === "number" && !r.charging)
    .sort((a, b) => a.atMs - b.atMs);
  if (samples.length < 2) return { normal: NaN, super: NaN, hours: 0 };
  const hours = (samples[samples.length - 1].atMs - samples[0].atMs) / 3600000;
  const drain = (role: string): number => {
    const rows = samples.filter((s) => s.role === role);
    if (rows.length < 2) return NaN;
    // Per device, then averaged: devices join and leave a field test at different times.
    const byDevice = new Map<string, number[]>();
    for (const r of rows) {
      const list = byDevice.get(r.device) ?? [];
      list.push(r.battery!);
      byDevice.set(r.device, list);
    }
    const rates: number[] = [];
    for (const list of byDevice.values()) {
      if (list.length < 2) continue;
      rates.push(((list[0] - list[list.length - 1]) * 100) / Math.max(1e-9, hours));
    }
    if (rates.length === 0) return NaN;
    return rates.reduce((a, b) => a + b, 0) / rates.length;
  };
  return { normal: drain("NORMAL"), super: drain("SUPER"), hours };
}

/**
 * Fit `rssi = txPower − 10·n·log10(d) − walls·penalty` to measured readings.
 *
 * Three unknowns, because the field test's real question is not "what is txPower" but
 * "is the model's 20 dB/decade slope right in this building". `docs/05` §1.1 and the
 * simulator use n = 2 and a 12 dB wall; a fit that lands somewhere else is a reason to
 * recalibrate before trusting any delivery prediction.
 */
function rfFit(recs: Rec[]): { txPower: number; slope: number; wallPenalty: number; rms: number; n: number; losRangeM: number } {
  const rows = recs.filter(
    (r) =>
      r.kind === "calibration" &&
      typeof r.rssi === "number" &&
      typeof r.distanceM === "number" &&
      r.distanceM > 0.5
  );
  if (rows.length < 8) {
    return { txPower: NaN, slope: NaN, wallPenalty: NaN, rms: NaN, n: rows.length, losRangeM: NaN };
  }
  // A walk that never put a wall between the two phones carries no information about
  // the wall penalty, and fitting three parameters to two would be singular. Fit two and
  // say so: the field plan asks for readings through 0, 1 and 2 walls for exactly this
  // reason (docs/09 §5).
  const hasWalls = rows.some((r) => (r.walls ?? 0) > 0);
  if (!hasWalls) {
    const x1w = rows.map((r) => -Math.log10(r.distanceM!));
    const yw = rows.map((r) => r.rssi!);
    const nw = rows.length;
    const sum = (f: (i: number) => number) => {
      let t = 0;
      for (let i = 0; i < nw; i++) t += f(i);
      return t;
    };
    const coef2 = solve(
      [
        [nw, sum((i) => x1w[i])],
        [sum((i) => x1w[i]), sum((i) => x1w[i] * x1w[i])],
      ],
      [sum((i) => yw[i]), sum((i) => x1w[i] * yw[i])]
    );
    if (coef2.length < 2) {
      return { txPower: NaN, slope: NaN, wallPenalty: NaN, rms: NaN, n: rows.length, losRangeM: NaN };
    }
    let se2 = 0;
    for (let i = 0; i < nw; i++) {
      se2 += (yw[i] - (coef2[0] + coef2[1] * x1w[i])) ** 2;
    }
    return {
      txPower: coef2[0],
      slope: coef2[1],
      wallPenalty: NaN,
      rms: Math.sqrt(se2 / nw),
      n: rows.length,
      losRangeM: Math.pow(10, (coef2[0] + 85) / Math.max(1e-9, coef2[1])),
    };
  }
  // Basis: [1, −log10(d), −walls] with coefficients [txPower, 10n, penalty].
  const x1 = rows.map((r) => -Math.log10(r.distanceM!));
  const x2 = rows.map((r) => -(r.walls ?? 0));
  const y = rows.map((r) => r.rssi!);
  const n = rows.length;
  const s = (f: (i: number) => number) => {
    let t = 0;
    for (let i = 0; i < n; i++) t += f(i);
    return t;
  };
  const a = [
    [n, s((i) => x1[i]), s((i) => x2[i])],
    [s((i) => x1[i]), s((i) => x1[i] * x1[i]), s((i) => x1[i] * x2[i])],
    [s((i) => x2[i]), s((i) => x1[i] * x2[i]), s((i) => x2[i] * x2[i])],
  ];
  const b = [s((i) => y[i]), s((i) => x1[i] * y[i]), s((i) => x2[i] * y[i])];
  const coef = solve(a, b);
  if (coef.length < 3) {
    return { txPower: NaN, slope: NaN, wallPenalty: NaN, rms: NaN, n, losRangeM: NaN };
  }
  const [txPower, tenN, wallPenalty] = coef;
  let se = 0;
  for (let i = 0; i < n; i++) {
    const pred = txPower + tenN * x1[i] + wallPenalty * x2[i];
    se += (y[i] - pred) ** 2;
  }
  const slope = tenN; // dB per decade of distance
  // Line-of-sight range at a −85 dBm sensitivity, from the fitted slope.
  const losRangeM = Math.pow(10, (txPower + 85) / Math.max(1e-9, slope));
  return { txPower, slope, wallPenalty, rms: Math.sqrt(se / n), n, losRangeM };
}

function main(): void {
  const runPath = process.argv[2];
  const basePath = process.argv[3];
  if (!runPath) {
    console.log("usage: field-report <capture.jsonl> [baseline-flood-all.jsonl]");
    process.exit(2);
  }
  const recs = load(runPath);
  const meta = recs.find((r) => r.kind === "meta");
  const d = delivery(recs);
  const c = connectivity(recs);
  const e = elections(recs);
  const b = battery(recs);
  const rf = rfFit(recs);
  const spanMs = recs.reduce((m, r) => Math.max(m, r.atMs), 0);

  const base = basePath ? delivery(load(basePath)) : null;
  const overhead = base && base.relayTx > 0 ? d.relayTx / base.relayTx : NaN;

  const row = (label: string, measured: string, criterion: string, ok: boolean | null) =>
    console.log(
      `${label.padEnd(34)}${measured.padEnd(20)}${criterion.padEnd(28)}${
        ok === null ? "—" : ok ? "PASS" : "FAIL"
      }`
    );

  console.log(`Field-test report — ${runPath}`);
  console.log(
    `  capture: ${meta ? `${meta.device}, scenario ${meta["scenario"] ?? "?"}, seed ${meta["seed"] ?? "?"}` : "no meta record"}, ` +
      `${recs.length} records over ${(spanMs / 1000).toFixed(0)} s, ${e.devices} devices`
  );

  console.log("\nTraffic");
  // The criteria in the column to the right are skills/02's and skills/08's, and both are
  // written for a 20-node network ("Simulator 20 nodes: ... delivery >=90% at 3 hops"). Judging
  // a 60-node capture against them prints a FAIL that is a category error rather than a defect,
  // so say which network the criteria belong to before printing them. docs/06 §24.13 measured
  // what the crowd's own floor is: delivery 85.3-98.7% over nine seeds, with the weakest
  // clearing the 20-node bar by 0.3 points, which is why the wider gate asserts 0.80 there.
  const captureNodes = typeof meta?.["nodes"] === "number" ? (meta["nodes"] as number) : null;
  if (captureNodes !== null && captureNodes !== 20) {
    console.log(
      `  this capture has ${captureNodes} nodes; the criteria below are skills/02's and skills/08's,` +
        ` which are written for a 20-node network.`
    );
    console.log(
      `  A FAIL here is a category error before it is a defect — see docs/06 §24.13 for what a` +
        ` ${captureNodes}-node crowd's own floor measures.`
    );
  }
  row("messages sent / delivered", `${d.sent} / ${d.delivered}`, "—", null);
  row("delivery ratio", d.ratio.toFixed(4), "≥ 0.90 (skills/02, skills/08)", d.ratio >= 0.9);
  if (c.samples > 0 && c.connected < c.samples) {
    // Not a caveat buried at the bottom: the criterion above was just judged, and in a world
    // that spent part of the walk split, a broadcast could not have crossed the gap however
    // well the protocol behaved. §24.13 measured the two quantities diverging — one seed in
    // one piece a third of the window still delivered 93.3% — so delivery survives a split
    // better than reach does, and neither may be inferred from the other.
    console.log(
      `  the network split during ${c.samples - c.connected} of ${c.samples} samples ` +
        `(worst: ${(c.worstLargestShare * 100).toFixed(0)}% of nodes in one piece). ` +
        `Broadcast reach is bounded by that; unicast delivery is not, but read both against it.`
    );
  }
  row("within 5 hops", `${d.within5}/${d.delivered}`, "≥ 90% of sent", d.within5 / Math.max(1, d.sent) >= 0.9);
  row("latency p50 / p95", `${d.p50Ms.toFixed(0)} / ${d.p95Ms.toFixed(0)} ms`, "< 2 s 1-hop, < 5 s 3-hop", null);
  row("relay transmissions", `${d.relayTx}`, "—", null);
  row("tx per message", d.txPerMessage.toFixed(1), "—", null);
  row("losses / duplicates", `${d.losses} / ${d.duplicates}`, "—", null);
  if (base) {
    row(
      "overhead vs flood-all",
      `${(overhead * 100).toFixed(1)}%`,
      "≤ 70% (skills/02), ↓30% (skills/08)",
      overhead <= 0.7
    );
    console.log(
      `  baseline (${basePath}): ${base.sent} sent, ${base.relayTx} relay tx, delivery ${base.ratio.toFixed(4)}`
    );
  } else {
    console.log("  no flood-all baseline given: the overhead criterion cannot be judged.");
  }

  // Placed directly after Traffic because it qualifies it: a reach or delivery number from a
  // walk during which the network was sometimes in two pieces is a different quantity from the
  // same number from a walk during which it was never split, and the two should not be compared
  // with each other or with a simulator prediction without saying which one it was.
  console.log("\nConnectivity during the walk (docs/06 §24.10)");
  if (c.samples === 0) {
    console.log(
      "  no `topology` records in this capture, so nothing below can be read against the state\n" +
        "  of the network. That is not a neutral omission: a graph reconstructed after the walk\n" +
        "  cannot show a partition that healed, and §24.9 drew exactly the wrong conclusion from\n" +
        "  one. Emit a `topology` record at every `sample` boundary — docs/09 §4 has the shape,\n" +
        "  and `npm run field:capture` produces a reference file that includes them."
    );
  } else {
    row("topology samples", `${c.samples}`, "one per sample boundary", null);
    row(
      "in one piece",
      `${c.connected}/${c.samples} (${(c.connectedShare * 100).toFixed(0)}%)`,
      "—",
      null
    );
    row(
      "mean largest component",
      `${(c.meanLargestShare * 100).toFixed(0)}% of nodes`,
      "bounds broadcast reach",
      null
    );
    row(
      "worst largest component",
      `${(c.worstLargestShare * 100).toFixed(0)}% of nodes`,
      "—",
      null
    );
    if (c.connected === c.samples) {
      console.log(
        "  never split, so reach and delivery here are comparable with a connected simulator\n" +
          "  arm — which is what campus_quad is, and what festival_crowd is not."
      );
    } else {
      console.log(
        "  split during part of the walk. Broadcast reach is bounded by the largest component\n" +
          "  at the moment each broadcast was sent, so a reach below the criterion may be a\n" +
          "  topology result rather than a protocol one; unicast delivery is more robust,\n" +
          "  because a message can be queued, retried and carried between clusters. Do not\n" +
          "  infer either from the other (§24.13), and do not compare this walk with one that\n" +
          "  never split without saying which was which."
      );
    }
  }

  console.log("\nElection and power");
  row(
    "SUPER ratio (sampled)",
    Number.isNaN(e.superRatio) ? "no samples" : `${(e.superRatio * 100).toFixed(1)}%`,
    "15-25% (skills/02)",
    Number.isNaN(e.superRatio) ? null : e.superRatio >= 0.15 && e.superRatio <= 0.25
  );
  row("role changes / node / min", e.transitionsPerNodeMin.toFixed(3), "≤ 0.25 (docs/06 §5)", e.transitionsPerNodeMin <= 0.25);
  console.log(`  devices that held SUPER: ${e.superDevices.join(", ") || "(none)"}`);
  // skills/07's budget is a duty-cycled budget: an always-scanning NORMAL node in a
  // mobile population measures 18-25% per 8 h (docs/06 §7), so gating an always-on
  // capture on it would fail a run for being what it says it is.
  const dutyCycle = meta?.["dutyCycle"] === true;
  row(
    "NORMAL battery %/h",
    Number.isNaN(b.normal) ? "no samples" : `${b.normal.toFixed(2)}%/h`,
    dutyCycle ? "< 1.875%/h (= 15% per 8 h, skills/07)" : "not gated: duty cycle off",
    Number.isNaN(b.normal) || !dutyCycle ? null : b.normal < 1.875
  );
  row(
    "SUPER battery %/h",
    Number.isNaN(b.super) ? "no samples" : `${b.super.toFixed(2)}%/h`,
    "reported, not gated",
    null
  );

  console.log("\nRadio model (calibration walk)");
  if (Number.isNaN(rf.txPower)) {
    console.log(`  only ${rf.n} calibration readings — need at least 8 to fit the model.`);
  } else {
    row("txPower at 1 m", `${rf.txPower.toFixed(1)} dBm`, "−55 dBm (docs/05 §1.1)", null);
    row("path-loss slope", `${rf.slope.toFixed(1)} dB/decade`, "20 dB (n = 2)", null);
    row(
      "wall penalty",
      Number.isNaN(rf.wallPenalty) ? "no through-wall readings" : `${rf.wallPenalty.toFixed(1)} dB`,
      "8-15 dB (docs/05 §1.1)",
      Number.isNaN(rf.wallPenalty) ? null : rf.wallPenalty >= 8 && rf.wallPenalty <= 15
    );
    row("fit RMS residual", `${rf.rms.toFixed(2)} dB`, "< 6 dB to trust predictions", rf.rms < 6);
    row("implied LOS range at −85 dBm", `${rf.losRangeM.toFixed(1)} m`, "10-30 m indoor (docs/05)", null);
    console.log(`  ${rf.n} readings`);
  }

  console.log(
    "\nThe three numbers the field test exists to produce: delivery ratio against a flood-all\n" +
      "baseline, the SUPER ratio the election actually settles on, and battery %/h per role with\n" +
      "the duty cycle on. Everything above them is there to explain those three."
  );
}

main();
