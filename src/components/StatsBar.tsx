import type { SimulationStats } from "../simulation";

interface Props {
  stats: SimulationStats;
  isRunning: boolean;
  onToggleRun: () => void;
  onStep: () => void;
  onReset: () => void;
  speed: number;
  onSpeedChange: (s: number) => void;
}

export function StatsBar({ stats, isRunning, onToggleRun, onStep, onReset, speed, onSpeedChange }: Props) {
  const fmtPct = (v: number) => `${(v * 100).toFixed(0)}%`;
  const fmtMs = (v: number) => v < 1000 ? `${v.toFixed(0)}ms` : `${(v / 1000).toFixed(1)}s`;

  const cards = [
    { label: "Tick", value: stats.tick.toString(), color: "#eaf2ff" },
    { label: "Online", value: `${stats.onlineNodes}`, color: "#4de0ff" },
    { label: "SUPER Nodes", value: `${stats.superNodes}`, color: "#b6ff4a" },
    { label: "Avg Score", value: stats.avgScore.toFixed(2), color: "#8b7dff" },
    { label: "Avg Battery", value: fmtPct(stats.avgBattery), color: stats.avgBattery > 0.4 ? "#b6ff4a" : "#ffb84d" },
    { label: "Delivered", value: `${stats.totalDelivered}`, color: "#4de0ff" },
    { label: "Delivery Ratio", value: fmtPct(stats.deliveryRatio), color: stats.deliveryRatio > 0.8 ? "#b6ff4a" : "#ffb84d" },
    { label: "Overhead", value: `${stats.overheadRatio.toFixed(1)}×`, color: "#ffb84d" },
    { label: "Avg Latency", value: fmtMs(stats.avgLatencyMs), color: "#eaf2ff" },
    { label: "Queued (DTN)", value: `${stats.totalQueued}`, color: "#ff4d6d" },
  ];

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
      <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
        <button
          onClick={onToggleRun}
          style={{
            padding: "8px 16px",
            borderRadius: 8,
            border: "1px solid #1e2a3a",
            background: isRunning ? "rgba(255,77,109,0.15)" : "rgba(77,224,255,0.15)",
            color: isRunning ? "#ff4d6d" : "#4de0ff",
            fontWeight: 700,
            fontSize: 13,
            cursor: "pointer",
          }}
        >
          {isRunning ? "⏸ Pause" : "▶ Run"}
        </button>
        <button
          onClick={onStep}
          style={{
            padding: "8px 14px",
            borderRadius: 8,
            border: "1px solid #1e2a3a",
            background: "rgba(255,255,255,0.04)",
            color: "#eaf2ff",
            fontWeight: 600,
            fontSize: 13,
            cursor: "pointer",
          }}
        >
          ⏭ Step
        </button>
        <button
          onClick={onReset}
          style={{
            padding: "8px 14px",
            borderRadius: 8,
            border: "1px solid #1e2a3a",
            background: "rgba(255,255,255,0.04)",
            color: "#eaf2ff",
            fontWeight: 600,
            fontSize: 13,
            cursor: "pointer",
          }}
        >
          ↺ Reset
        </button>
        <div style={{ display: "flex", alignItems: "center", gap: 6, marginLeft: 8 }}>
          <span style={{ fontSize: 12, color: "#9fb0c3" }}>Speed</span>
          <input
            type="range"
            min={100}
            max={2000}
            step={100}
            value={speed}
            onChange={(e) => onSpeedChange(Number(e.target.value))}
            style={{ width: 100 }}
          />
          <span style={{ fontSize: 12, color: "#9fb0c3" }}>{(1000 / speed).toFixed(1)}fps</span>
        </div>
      </div>

      <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
        {cards.map((c) => (
          <div
            key={c.label}
            style={{
              padding: "10px 14px",
              borderRadius: 10,
              border: "1px solid #1e2a3a",
              background: "rgba(255,255,255,0.03)",
              minWidth: 90,
            }}
          >
            <div style={{ fontSize: 18, fontWeight: 800, color: c.color }}>{c.value}</div>
            <div style={{ fontSize: 11, color: "#9fb0c3", marginTop: 2 }}>{c.label}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
