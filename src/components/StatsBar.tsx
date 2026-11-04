import type { SimulationStats } from "../simulation";

interface Props {
  stats: SimulationStats;
  isRunning: boolean;
  onToggleRun: () => void;
  onStep: () => void;
  onReset: () => void;
  onNewSeed: () => void;
  speed: number;
  onSpeedChange: (s: number) => void;
}

function fmtClock(ms: number): string {
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  if (h > 0) return `${h}h${String(m).padStart(2, "0")}m`;
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export function StatsBar({
  stats,
  isRunning,
  onToggleRun,
  onStep,
  onReset,
  onNewSeed,
  speed,
  onSpeedChange,
}: Props) {
  const pct = (v: number) => `${(v * 100).toFixed(0)}%`;
  const ms = (v: number) => (v < 1000 ? `${v.toFixed(0)}ms` : `${(v / 1000).toFixed(2)}s`);

  const cards = [
    { label: "Sim clock", value: fmtClock(stats.simTimeMs), color: "#eaf2ff" },
    { label: "Online", value: `${stats.onlineNodes}`, color: "#4de0ff" },
    {
      label: "SUPER nodes",
      value: `${stats.superNodes} (${pct(stats.superRatio)})`,
      color: "#b6ff4a",
    },
    { label: "Avg score", value: stats.avgScore.toFixed(2), color: "#8b7dff" },
    {
      label: "Avg battery",
      value: pct(stats.avgBattery),
      color: stats.avgBattery > 0.4 ? "#b6ff4a" : "#ffb84d",
    },
    {
      label: "Delivery (unicast)",
      value: `${stats.totalDelivered}/${stats.sentUnicast} · ${pct(stats.deliveryRatio)}`,
      color: stats.deliveryRatio > 0.8 ? "#b6ff4a" : "#ffb84d",
    },
    {
      label: "Broadcast reach",
      value: pct(stats.broadcastReach),
      color: stats.broadcastReach > 0.6 ? "#b6ff4a" : "#ffb84d",
    },
    {
      // Beside reach on purpose, and not in the telemetry panel: docs/06 §24.10 measured a
      // 60-node crowd splitting and re-joining inside a window, so reach reads as two modes
      // (98% against 54-79%) unless the reader can see how much of the window the network was
      // in one piece. A graph measured after the window cannot show that — a partition that
      // healed looks like one that never happened.
      label: "Connected in-window",
      value:
        stats.connectivitySamples === 0
          ? "not sampled"
          : `${pct(stats.connectedSampleShare)} · largest ${pct(stats.meanLargestComponent)}`,
      color:
        stats.connectivitySamples === 0 || stats.connectedSampleShare > 0.9
          ? "#b6ff4a"
          : "#ffb84d",
    },
    { label: "Relay overhead", value: `${stats.overheadRatio.toFixed(2)}×`, color: "#ffb84d" },
    { label: "Avg latency", value: ms(stats.avgLatencyMs), color: "#eaf2ff" },
    { label: "p95 latency", value: ms(stats.p95LatencyMs), color: "#eaf2ff" },
    { label: "Avg hops", value: stats.avgHops.toFixed(2), color: "#4de0ff" },
    { label: "MPR suppressed", value: `${stats.mprSuppressed}`, color: "#b6ff4a" },
    { label: "Queued (DTN)", value: `${stats.totalQueued}`, color: "#ff4d6d" },
    {
      label: "Role changes",
      value: `${stats.roleChangesPerNodeMin.toFixed(2)}/node·min`,
      color: stats.roleChangesPerNodeMin < 1 ? "#b6ff4a" : "#ff4d6d",
    },
  ];

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div className="duman-stats-row" style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <button onClick={onToggleRun} style={btn(isRunning ? "#ff4d6d" : "#4de0ff", isRunning)}>
          {isRunning ? "⏸ Pause" : "▶ Run"}
        </button>
        <button onClick={onStep} style={btn("#eaf2ff")}>⏭ Step</button>
        <button onClick={onReset} style={btn("#eaf2ff")}>↺ Reset</button>
        <button onClick={onNewSeed} style={btn("#8b7dff")}>🎲 New world</button>
        <div style={{ display: "flex", alignItems: "center", gap: 6, marginLeft: 8 }}>
          <label htmlFor="speed" style={{ fontSize: 12, color: "#9fb0c3" }}>Speed</label>
          <input
            id="speed"
            type="range"
            min={50}
            max={2000}
            step={50}
            value={speed}
            onChange={(e) => onSpeedChange(Number(e.target.value))}
            style={{ width: 100, accentColor: "#4de0ff" }}
          />
          <span style={{ fontSize: 12, color: "#9fb0c3" }}>{(1000 / speed).toFixed(1)}×</span>
        </div>
      </div>

      <div className="duman-stats-cards" style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {cards.map((c) => (
          <div
            key={c.label}
            style={{
              padding: "10px 14px",
              borderRadius: 10,
              border: "1px solid #1e2a3a",
              background: "rgba(255,255,255,0.03)",
              minWidth: 96,
            }}
          >
            <div style={{ fontSize: 16, fontWeight: 800, color: c.color }}>{c.value}</div>
            <div style={{ fontSize: 11, color: "#9fb0c3", marginTop: 2 }}>{c.label}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

function btn(color: string, active = false): React.CSSProperties {
  return {
    padding: "8px 14px",
    borderRadius: 8,
    border: "1px solid #1e2a3a",
    background: active ? "rgba(255,77,109,0.15)" : "rgba(255,255,255,0.04)",
    color,
    fontWeight: 650,
    fontSize: 13,
    cursor: "pointer",
  };
}
