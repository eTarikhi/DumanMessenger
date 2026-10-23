import type { SimConfig, SimulationStats } from "../simulation";
import { HISTORY_BUCKETS, type MeshNode } from "../types";

/** Human-readable payload size, for the media row. */
/** Characters in one digest beacon: `HB|group|epoch|count|` plus 16 eight-character
 *  bucket hashes. Measured, and constant — the beacon does not grow with the history
 *  (docs/06 §17). */
const BEACON_CHARS = 156;

/** Cumulative radio waiting, which runs to minutes once a file is in flight. */
function fmtWait(ms: number): string {
  if (ms >= 3600000) return `${(ms / 3600000).toFixed(1)} h`;
  if (ms >= 60000) return `${(ms / 60000).toFixed(1)} min`;
  if (ms >= 1000) return `${(ms / 1000).toFixed(1)} s`;
  return `${ms.toFixed(0)} ms`;
}

function fmtBytes(bytes: number): string {
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(bytes >= 10485760 ? 0 : 1)} MB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${bytes} B`;
}

interface Props {
  stats: SimulationStats;
  /** Whether the duty cycle is on — the awake ratio is meaningless without it. */
  dutyCycleEnabled: boolean;
  /** Needed for the SOS row: which nodes are holding an alert right now. */
  nodes?: MeshNode[];
  /** Media sizing and link throughput, quoted in the media row's footnote. */
  config?: SimConfig;
}

/**
 * The Phase 2 metrics dashboard the roadmap asks for: "delivery ratio, overhead
 * ratio, latency by hop, battery %/h". Delivery and overhead already live in the
 * stats bar; this panel carries the two that need room to be read properly —
 * per-role battery burn (skills/07's telemetry row) and the latency distribution
 * broken out by hop count instead of blended into one p95.
 */
export function MetricsPanel({ stats, dutyCycleEnabled, nodes, config }: Props) {
  const chunkKb = Math.round((config?.transferChunkBytes ?? 65536) / 1024);
  // skills/07 acceptance: "Android 8h NORMAL: <15% extra drain vs idle".
  const BUDGET_8H = 15;
  const hopRows = stats.latencyByHop;
  const maxP95 = hopRows.reduce((m, r) => Math.max(m, r.p95Ms), 0);
  const totalHopped = hopRows.reduce((n, r) => n + r.count, 0);

  // One emergency, however many floods it took: receivers collapse on sosId, so
  // the live picture is "how many alerts exist, who is holding one, and where was
  // the sender last seen".
  const online = (nodes ?? []).filter((n) => n.isOnline).length;
  const alerts = new Map<string, { x: number; y: number; repeat: number }>();
  let holders = 0;
  for (const n of nodes ?? []) {
    const held = n.inbox.filter((m) => m.sosId);
    if (held.length > 0) holders++;
    for (const m of held) {
      const id = m.sosId!;
      const prev = alerts.get(id);
      if (!prev || (m.sosRepeat ?? 0) > prev.repeat) {
        alerts.set(id, { x: m.sosPos?.x ?? 0, y: m.sosPos?.y ?? 0, repeat: m.sosRepeat ?? 0 });
      }
    }
  }
  let newest: { x: number; y: number; repeat: number } | null = null;
  for (const a of alerts.values()) {
    if (!newest || a.repeat > newest.repeat) newest = a;
  }

  return (
    <div style={panelStyle}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
        <div style={headerStyle}>Metrics dashboard</div>
        <div style={{ fontSize: 11, color: "#5a6a7a" }}>roadmap Phase 2 · skills/07 telemetry</div>
      </div>

      <div className="duman-metrics-grid" style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14 }}>
        <section>
          <div style={sectionStyle}>Battery burn per role</div>
          <RoleDrain
            label="NORMAL"
            percentPerHour={stats.batteryPercentPerHourNormal}
            budget8h={BUDGET_8H}
            note={"skills/07 budget: <15% per 8 h"}
          />
          <RoleDrain
            label="SUPER"
            percentPerHour={stats.batteryPercentPerHourSuper}
            budget8h={BUDGET_8H}
            note="continuous scan · why the role is opt-out-able"
            accent="#ffb84d"
          />
          <div style={{ display: "flex", gap: 6, marginTop: 8, flexWrap: "wrap" }}>
            <Counter label="Scans/s" value={stats.scansPerSec.toFixed(1)} />
            <Counter label="Relays/s" value={stats.relaysPerSec.toFixed(1)} />
            <Counter label="Elections" value={`${stats.electionEvents}`} />
            {dutyCycleEnabled && (
              <>
                <Counter label="Awake" value={`${(stats.awakeRatio * 100).toFixed(0)}%`} accent="#4de0ff" />
                <Counter label="Scans slept" value={`${stats.scansSkippedAsleep}`} accent="#8b7dff" />
              </>
            )}
          </div>
        </section>

        <section>
          <div style={sectionStyle}>
            Latency by hop ({totalHopped} first-attempt deliveries)
          </div>
          {hopRows.length === 0 ? (
            <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>
              No routed deliveries yet — send a message or enable auto traffic.
            </div>
          ) : (
            <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 12 }}>
              <thead>
                <tr style={{ color: "#9fb0c3", fontSize: 10, textTransform: "uppercase", letterSpacing: 0.6 }}>
                  <th style={thStyle}>Hops</th>
                  <th style={thStyle}>n</th>
                  <th style={thStyle}>avg</th>
                  <th style={{ ...thStyle, textAlign: "left" }}>p95</th>
                </tr>
              </thead>
              <tbody>
                {hopRows.map((r) => {
                  // docs/05: "each hop adds 100-200 ms" and "after 4-5 hops,
                  // round-trip exceeds 1 s" — the point where text is fine and
                  // real-time voice is not. Flag it rather than invent a budget.
                  const overSecond = r.p95Ms > 1000;
                  return (
                    <tr key={r.hops}>
                      <td style={{ ...tdStyle, fontFamily: "monospace", color: "#4de0ff" }}>{r.hops}</td>
                      <td style={{ ...tdStyle, color: "#9fb0c3" }}>{r.count}</td>
                      <td style={{ ...tdStyle, color: "#cfe0f2" }}>{fmtMs(r.avgMs)}</td>
                      <td style={tdStyle}>
                        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
                          <div style={{ flex: 1, height: 5, borderRadius: 3, background: "#1e2a3a", overflow: "hidden" }}>
                            <div
                              style={{
                                width: `${maxP95 > 0 ? (r.p95Ms / maxP95) * 100 : 0}%`,
                                height: "100%",
                                background: overSecond ? "#ffb84d" : "#b6ff4a",
                              }}
                            />
                          </div>
                          <span style={{ fontFamily: "monospace", color: overSecond ? "#ffb84d" : "#b6ff4a", minWidth: 52, textAlign: "right" }}>
                            {fmtMs(r.p95Ms)}
                          </span>
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
            Retries and DTN hand-offs are excluded: this is the first-attempt routed path, so a
            bucket is the cost of the geometry, not of a recovery. docs/05 puts 100–200 ms on each
            hop; amber marks a p95 past the 1 s where full-duplex voice stops being viable.
          </div>
        </section>
      </div>

      {stats.sentGroup > 0 && (
        <section style={{ marginTop: 14 }}>
          <div style={sectionStyle}>👥 Group channels (docs/04 §4, roadmap Phase 1)</div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <Counter label="Group sends" value={`${stats.sentGroup}`} accent="#26d0a8" />
            <Counter
              label="Member receipts"
              value={`${stats.groupReceipts}/${stats.groupExpected}`}
              accent="#b6ff4a"
            />
            <Counter
              label="Group delivery"
              value={`${(stats.groupDeliveryRatio * 100).toFixed(0)}%`}
              accent={stats.groupDeliveryRatio >= 0.99 ? "#b6ff4a" : "#ffb84d"}
            />
            <Counter label="Stale key epoch" value={`${stats.groupEpochRejected}`} accent="#ff9f4d" />
          </div>
          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
            Counted apart from 1:1 traffic, so a 10-member group can neither flatter{" "}
            <code>deliveryRatio</code> nor deflate <code>broadcastReach</code>. "Stale key epoch" is
            the security property doing work: copies a member cannot decrypt because the key rotated
            when somebody left or joined — the node still relayed them, it just could not read them.
          </div>
        </section>
      )}

      {stats.historyBeacons > 0 && (
        <section style={{ marginTop: 14 }}>
          <div style={sectionStyle}>🧬 Group history anti-entropy (roadmap Phase 1)</div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <Counter label="Digest beacons" value={`${stats.historyBeacons}`} accent="#e0b3ff" />
            <Counter label="Bucket requests" value={`${stats.historyRequests}`} accent="#e0b3ff" />
            <Counter label="Replies" value={`${stats.historyReplies}`} accent="#e0b3ff" />
            <Counter
              label="Messages recovered"
              value={`${stats.historyEntriesSynced}`}
              accent={stats.historyEntriesSynced > 0 ? "#b6ff4a" : "#9fb0c3"}
            />
            <Counter label="Sync packets" value={`${stats.sentSync}`} accent="#9fb0c3" />
            <Counter label="Sync payload" value={fmtBytes(stats.historyBytes)} accent="#9fb0c3" />
            <Counter
              label="Unreadable after rotation"
              value={`${stats.historyEpochDropped}`}
              accent={stats.historyEpochDropped === 0 ? "#b6ff4a" : "#ff9f4d"}
            />
          </div>
          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
            Every {(config?.historyBeaconMs ?? 10000) / 1000} s a member offers each co-member it can hear a
            digest of the history it holds: {HISTORY_BUCKETS} XOR-folded hashes, {BEACON_CHARS} characters
            whatever the group has said, so one beacon is one {fmtBytes(256)} BLE packet. A peer whose buckets
            differ asks for those buckets and lists the ids it already has; the reply is capped at{" "}
            {config?.historyReplyMax ?? 32} entries, so a long absence is repaired in bounded rounds rather
            than one huge transmission. Merging is a set union — a grow-only CRDT — so beacons can be lost,
            duplicated or reordered without the protocol caring, and a copy one member lost can reach it
            through another. None of it is acknowledged: the next beacon is the retry.
          </div>
        </section>
      )}

      {(stats.channelDeferrals > 0 ||
        stats.channelDrops > 0 ||
        stats.channelCaptured > 0 ||
        stats.channelDeafRx > 0) && (
        <section style={{ marginTop: 14 }}>
          <div style={sectionStyle}>📻 Radio channel (docs/08 §12)</div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <Counter label="Transmissions deferred" value={`${stats.channelDeferrals}`} accent="#7fb3ff" />
            <Counter label="Time spent waiting" value={fmtWait(stats.channelDeferMs)} accent="#7fb3ff" />
            <Counter
              label="Dropped at the queue"
              value={`${stats.channelDrops}`}
              accent={stats.channelDrops === 0 ? "#b6ff4a" : "#ff6b6b"}
            />
            <Counter
              label="Collided at the receiver"
              value={`${stats.channelCaptured}`}
              accent={stats.channelCaptured === 0 ? "#b6ff4a" : "#ff6b6b"}
            />
            <Counter
              label="Lost to a deaf receiver"
              value={`${stats.channelDeafRx}`}
              accent={stats.channelDeafRx === 0 ? "#b6ff4a" : "#ff6b6b"}
            />
          </div>
          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
            Only the channel flags produce these. A device with one transmitter (<code>channelAccess</code>) queues
            each packet until the radio is free and drops it when the {config?.channelQueueDepth ?? 8}-deep queue is
            full, because a real radio sheds load rather than promising air time does not have;{" "}
            <code>channelCapture: "first"</code> adds the receiver, which loses whatever arrives while it is locked
            onto an earlier packet or while it is itself transmitting. Under the shipped model every counter stays at
            zero by construction — there is no shared medium and no inattentive receiver, so a transmission cannot
            delay or lose another one. That is why a 10 MB file costs nobody else anything there, and costs 1.7 points
            of delivery with a queue and 13.6 with a receiver (docs/08 §12.9).
          </div>
        </section>
      )}

      {stats.transfersStarted > 0 && (
        <section style={{ marginTop: 14 }}>
          <div style={sectionStyle}>📦 Media transport (docs/05 §3.2–3.3, roadmap Phase 3)</div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <Counter
              label="Transfers done"
              value={`${stats.transfersCompleted}/${stats.transfersStarted}`}
              accent={stats.transfersCompleted === stats.transfersStarted ? "#b6ff4a" : "#7fb3ff"}
            />
            <Counter label="Chunks on air" value={`${stats.sentChunks}`} accent="#4de0ff" />
            <Counter
              label="Window stalls"
              value={`${stats.transferStalls}`}
              accent={stats.transferStalls === 0 ? "#b6ff4a" : "#ff9f4d"}
            />
            <Counter label="Payload delivered" value={fmtBytes(stats.bytesDelivered)} accent="#b6ff4a" />
          </div>
          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
            A file is sliced into {chunkKb} KB chunks and pushed through a{" "}
            {config?.transferWindow ?? 4}-deep sliding window. Each chunk is an ordinary unicast, so it inherits ACKs,
            retransmission and the OppQueue — which is what makes "resume on reconnect" need no media-specific code.
            Chunks are counted apart from 1:1 traffic: one 10 MB file is {Math.max(1, Math.round(10485760 / (config?.transferChunkBytes ?? 65536)))} of
            them, and folding them into <code>deliveryRatio</code> would make the metric about the file rather than
            the mesh. Air time is charged per hop above {chunkKb} KB at {config?.bleKbps ?? 80} kbit/s (BLE) /{" "}
            {((config?.wifiDirectKbps ?? 20000) / 1000).toFixed(0)} Mbit/s (Wi-Fi Direct) — the{" "}
            {Math.round((config?.wifiDirectKbps ?? 20000) / (config?.bleKbps ?? 80))}× ratio docs/05 §3.2 claims. A
            chunk retries after {config?.mediaAckTimeoutMs ?? 600} ms rather than the{" "}
            {((config?.ackTimeoutMs ?? 4000) / 1000).toFixed(0)} s a text message waits, because one lost voice frame
            is a hole in the audio; "window stalls" counts the times nothing arrived for that long and the missing
            chunks had to be re-sent.
          </div>
        </section>
      )}

      {stats.sosFloods > 0 && (
        <section style={{ marginTop: 14 }}>
          <div style={sectionStyle}>🆘 SOS — repeated flood (roadmap Phase 3, docs/05)</div>
          <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            <Counter label="Floods on air" value={`${stats.sosFloods}`} accent="#ff2d55" />
            <Counter label="Alerts live" value={`${alerts.size}`} accent="#ff8fa3" />
            <Counter label="Nodes alerted" value={`${holders}`} accent="#b6ff4a" />
            <Counter label="Online" value={`${online}`} />
            {newest && (
              <Counter
                label={`Newest fix (flood ${(newest.repeat ?? 0) + 1})`}
                value={`${newest.x.toFixed(1)}, ${newest.y.toFixed(1)}`}
                accent="#4de0ff"
              />
            )}
          </div>
          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
            {stats.sosFloods} floods, {alerts.size} alert{alerts.size === 1 ? "" : "s"}: receivers
            collapse on the alert id, so a re-flood refreshes the GPS fix instead of raising a
            second notification (docs/04 §"SOS misuse"). TTL sets the radius an SOS can reach; the
            repeats absorb loss and movement. SOS bypasses MPR at every hop — suppression exists to
            delete duplicate copies, and an emergency broadcast is made of them.
          </div>
        </section>
      )}
    </div>
  );
}

function RoleDrain({
  label,
  percentPerHour,
  budget8h,
  note,
  accent = "#b6ff4a",
}: {
  label: string;
  percentPerHour: number;
  budget8h: number;
  note: string;
  accent?: string;
}) {
  const per8h = percentPerHour * 8;
  const over = per8h > budget8h;
  const fill = Math.min(1, per8h / (budget8h * 4)); // SUPER is ~4x, so scale to that
  return (
    <div style={{ marginBottom: 8 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: "#cfe0f2" }}>{label}</span>
        <span style={{ fontSize: 12, fontFamily: "monospace", color: over ? "#ff4d6d" : accent }}>
          {percentPerHour.toFixed(2)} %/h · {per8h.toFixed(1)} %/8h
        </span>
      </div>
      <div style={{ height: 6, borderRadius: 3, background: "#1e2a3a", overflow: "hidden", marginTop: 4 }}>
        <div
          style={{
            width: `${fill * 100}%`,
            height: "100%",
            background: over ? "#ff4d6d" : accent,
            transition: "width 0.3s",
          }}
        />
      </div>
      {/* The 15% budget sits at a quarter of the bar, so overshoot is visible. */}
      <div style={{ position: "relative", height: 0 }}>
        <div style={{ position: "absolute", left: "25%", top: -8, width: 1, height: 10, background: "#5a6a7a" }} />
      </div>
      <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 2 }}>{note}</div>
    </div>
  );
}

function Counter({ label, value, accent = "#eaf2ff" }: { label: string; value: string; accent?: string }) {
  return (
    <div style={{ padding: "5px 9px", borderRadius: 8, background: "rgba(255,255,255,0.03)", border: "1px solid #1e2a3a" }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: accent, fontFamily: "monospace" }}>{value}</div>
      <div style={{ fontSize: 10, color: "#9fb0c3" }}>{label}</div>
    </div>
  );
}

function fmtMs(v: number): string {
  return v < 1000 ? `${v.toFixed(0)} ms` : `${(v / 1000).toFixed(2)} s`;
}

const panelStyle: React.CSSProperties = {
  padding: 14,
  borderRadius: 14,
  border: "1px solid #1e2a3a",
  background: "rgba(17, 24, 35, 0.95)",
};

const headerStyle: React.CSSProperties = {
  fontSize: 13,
  fontWeight: 700,
  color: "#eaf2ff",
  letterSpacing: 0.5,
};

const sectionStyle: React.CSSProperties = {
  fontSize: 11,
  color: "#9fb0c3",
  textTransform: "uppercase",
  letterSpacing: 1,
  marginBottom: 8,
};

const thStyle: React.CSSProperties = {
  textAlign: "right",
  padding: "0 4px 4px",
  fontWeight: 600,
};

const tdStyle: React.CSSProperties = {
  padding: "3px 4px",
  textAlign: "right",
  borderTop: "1px solid rgba(30,42,58,0.7)",
};
