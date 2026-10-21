import type { SimulationStats } from "../simulation";

interface Props {
  stats: SimulationStats;
  /** Whether the duty cycle is on — the awake ratio is meaningless without it. */
  dutyCycleEnabled: boolean;
}

/**
 * The Phase 2 metrics dashboard the roadmap asks for: "delivery ratio, overhead
 * ratio, latency by hop, battery %/h". Delivery and overhead already live in the
 * stats bar; this panel carries the two that need room to be read properly —
 * per-role battery burn (skills/07's telemetry row) and the latency distribution
 * broken out by hop count instead of blended into one p95.
 */
export function MetricsPanel({ stats, dutyCycleEnabled }: Props) {
  // skills/07 acceptance: "Android 8h NORMAL: <15% extra drain vs idle".
  const BUDGET_8H = 15;
  const hopRows = stats.latencyByHop;
  const maxP95 = hopRows.reduce((m, r) => Math.max(m, r.p95Ms), 0);
  const totalHopped = hopRows.reduce((n, r) => n + r.count, 0);

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
