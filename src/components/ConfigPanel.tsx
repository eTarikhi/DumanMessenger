import type { SimConfig } from "../simulation";

interface Props {
  config: SimConfig;
  onChange: (config: Partial<SimConfig>) => void;
  showLinks: boolean;
  showRanges: boolean;
  onToggleLinks: () => void;
  onToggleRanges: () => void;
}

export function ConfigPanel({ config, onChange, showLinks, showRanges, onToggleLinks, onToggleRanges }: Props) {
  return (
    <div style={{
      padding: 14, borderRadius: 14, border: "1px solid #1e2a3a",
      background: "rgba(17, 24, 35, 0.95)",
      display: "flex", flexDirection: "column", gap: 12,
    }}>
      <div style={{ fontSize: 13, fontWeight: 700, color: "#eaf2ff", letterSpacing: 0.5 }}>
        Simulation Config
      </div>

      <Slider
        label="Nodes"
        value={config.nodeCount}
        min={5} max={60} step={1}
        onChange={(v) => onChange({ nodeCount: v })}
      />
      <Slider
        label="Stationary %"
        value={Math.round(config.stationaryRatio * 100)}
        min={0} max={100} step={5}
        onChange={(v) => onChange({ stationaryRatio: v / 100 })}
      />
      <Slider
        label="Charging %"
        value={Math.round(config.chargingRatio * 100)}
        min={0} max={50} step={5}
        onChange={(v) => onChange({ chargingRatio: v / 100 })}
      />

      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <Toggle
          label="Super-Node Election"
          value={config.enableSuperElection}
          onChange={(v) => onChange({ enableSuperElection: v })}
        />
        <Toggle
          label="Mobility (random walk)"
          value={config.enableMobility}
          onChange={(v) => onChange({ enableMobility: v })}
        />
        <Toggle label="Show Links" value={showLinks} onChange={onToggleLinks} />
        <Toggle label="Show Ranges" value={showRanges} onChange={onToggleRanges} />
      </div>
    </div>
  );
}

function Slider({ label, value, min, max, step, onChange }: {
  label: string; value: number; min: number; max: number; step: number;
  onChange: (v: number) => void;
}) {
  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 4 }}>
        <span style={{ fontSize: 12, color: "#9fb0c3" }}>{label}</span>
        <span style={{ fontSize: 12, color: "#4de0ff", fontWeight: 600 }}>{value}</span>
      </div>
      <input
        type="range"
        min={min} max={max} step={step}
        value={value}
        onChange={(e) => onChange(Number(e.target.value))}
        style={{ width: "100%", accentColor: "#4de0ff" }}
      />
    </div>
  );
}

function Toggle({ label, value, onChange }: {
  label: string; value: boolean; onChange: () => void;
}) {
  return (
    <div
      onClick={onChange}
      style={{
        display: "flex", justifyContent: "space-between", alignItems: "center",
        padding: "6px 10px", borderRadius: 8, cursor: "pointer",
        background: "rgba(255,255,255,0.03)", border: "1px solid #1e2a3a",
      }}
    >
      <span style={{ fontSize: 12, color: "#cfe0f2" }}>{label}</span>
      <div style={{
        width: 32, height: 18, borderRadius: 9, position: "relative",
        background: value ? "#4de0ff" : "#1e2a3a",
        transition: "background 0.2s",
      }}>
        <div style={{
          position: "absolute", top: 2, left: value ? 16 : 2,
          width: 14, height: 14, borderRadius: "50%",
          background: "#fff",
          transition: "left 0.2s",
        }} />
      </div>
    </div>
  );
}
