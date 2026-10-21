import { useEffect, useState } from "react";
import type { SimConfig } from "../simulation";
import type { RelayPolicy } from "../types";

interface Props {
  config: SimConfig;
  /** Applies a config change. Rebuilds the world, so the panel commits on
   *  demand instead of on every pixel of slider travel. */
  onChange: (config: Partial<SimConfig>) => void;
  showLinks: boolean;
  showRanges: boolean;
  onToggleLinks: () => void;
  onToggleRanges: () => void;
  autoTraffic: boolean;
  onToggleAutoTraffic: () => void;
}

type Draft = {
  nodeCount: number;
  areaWidth: number;
  stationaryRatio: number;
  chargingRatio: number;
  seed: number;
  relayPolicy: RelayPolicy;
  enableSuperElection: boolean;
  enableMobility: boolean;
  enableDtn: boolean;
  batteryDrainMultiplier: number;
};

function toDraft(c: SimConfig): Draft {
  return {
    nodeCount: c.nodeCount,
    areaWidth: c.areaWidth,
    stationaryRatio: c.stationaryRatio,
    chargingRatio: c.chargingRatio,
    seed: c.seed,
    relayPolicy: c.relayPolicy,
    enableSuperElection: c.enableSuperElection,
    enableMobility: c.enableMobility,
    enableDtn: c.enableDtn,
    batteryDrainMultiplier: c.batteryDrainMultiplier,
  };
}

export function ConfigPanel({
  config,
  onChange,
  showLinks,
  showRanges,
  onToggleLinks,
  onToggleRanges,
  autoTraffic,
  onToggleAutoTraffic,
}: Props) {
  const [draft, setDraft] = useState<Draft>(() => toDraft(config));

  // Re-sync when the world is rebuilt elsewhere (Reset / New world).
  useEffect(() => {
    setDraft(toDraft(config));
  }, [config]);

  const set = <K extends keyof Draft>(key: K, value: Draft[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));

  const dirty = JSON.stringify(draft) !== JSON.stringify(toDraft(config));

  const apply = () => {
    onChange({
      nodeCount: draft.nodeCount,
      areaWidth: draft.areaWidth,
      areaHeight: draft.areaWidth,
      stationaryRatio: draft.stationaryRatio,
      chargingRatio: draft.chargingRatio,
      seed: draft.seed,
      relayPolicy: draft.relayPolicy,
      enableSuperElection: draft.enableSuperElection,
      enableMobility: draft.enableMobility,
      enableDtn: draft.enableDtn,
      batteryDrainMultiplier: draft.batteryDrainMultiplier,
      trafficIntervalMs: autoTraffic ? 1500 : 0,
    });
  };

  return (
    <div style={panelStyle}>
      <div style={{ fontSize: 13, fontWeight: 700, color: "#eaf2ff", letterSpacing: 0.5 }}>
        Simulation config
      </div>
      <div style={{ fontSize: 11, color: "#5a6a7a", marginTop: -6 }}>
        Changes rebuild the world, so they are applied on demand.
      </div>

      <Slider label="Nodes" value={draft.nodeCount} min={5} max={80} step={1}
        onChange={(v) => set("nodeCount", v)} />
      <Slider label="Area (m, square)" value={draft.areaWidth} min={40} max={400} step={10}
        onChange={(v) => set("areaWidth", v)} />
      <Slider label="Stationary %" value={Math.round(draft.stationaryRatio * 100)} min={0} max={100} step={5}
        onChange={(v) => set("stationaryRatio", v / 100)} />
      <Slider label="Charging %" value={Math.round(draft.chargingRatio * 100)} min={0} max={50} step={5}
        onChange={(v) => set("chargingRatio", v / 100)} />
      <Slider label="Seed" value={draft.seed} min={1} max={9999} step={1}
        onChange={(v) => set("seed", v)} />
      <Slider label="Battery drain ×" value={draft.batteryDrainMultiplier} min={1} max={200} step={1}
        onChange={(v) => set("batteryDrainMultiplier", v)} />

      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <span style={{ fontSize: 11, color: "#9fb0c3" }}>Relay policy</span>
        <div style={{ display: "flex", gap: 6 }}>
          {(["mpr", "route-flood", "flood-all"] as const).map((p) => (
            <button
              key={p}
              aria-pressed={draft.relayPolicy === p}
              onClick={() => set("relayPolicy", p)}
              style={{
                flex: 1, padding: "6px 8px", borderRadius: 8, cursor: "pointer", fontSize: 11, fontWeight: 700,
                border: "1px solid #1e2a3a",
                background: draft.relayPolicy === p ? "rgba(77,224,255,0.18)" : "rgba(255,255,255,0.03)",
                color: draft.relayPolicy === p ? "#4de0ff" : "#9fb0c3",
              }}
            >
              {p === "mpr" ? "MPR (super-node)" : "Flood-all (baseline)"}
            </button>
          ))}
        </div>
        <span style={{ fontSize: 10, color: "#5a6a7a" }}>
          Compare the two to measure the overhead saving claimed in skills/02.
        </span>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <Toggle label="Super-node election" value={draft.enableSuperElection}
          onChange={() => set("enableSuperElection", !draft.enableSuperElection)} />
        <Toggle label="Mobility (random walk)" value={draft.enableMobility}
          onChange={() => set("enableMobility", !draft.enableMobility)} />
        <Toggle label="DTN store-carry-forward" value={draft.enableDtn}
          onChange={() => set("enableDtn", !draft.enableDtn)} />
        <Toggle label="Auto traffic (1 msg / 1.5 s)" value={autoTraffic} onChange={onToggleAutoTraffic} />
        <Toggle label="Show links" value={showLinks} onChange={onToggleLinks} />
        <Toggle label="Show radio ranges" value={showRanges} onChange={onToggleRanges} />
      </div>

      <button
        onClick={apply}
        disabled={!dirty && !autoTraffic}
        style={{
          padding: "9px 12px", borderRadius: 8, border: "none", cursor: dirty ? "pointer" : "default",
          fontWeight: 700, fontSize: 12,
          background: dirty ? "linear-gradient(135deg, #4de0ff, #8b7dff)" : "#1e2a3a",
          color: dirty ? "#001019" : "#5a6a7a",
        }}
      >
        {dirty ? "Apply & rebuild world" : "Applied"}
      </button>
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  padding: 14, borderRadius: 14, border: "1px solid #1e2a3a",
  background: "rgba(17, 24, 35, 0.95)", display: "flex", flexDirection: "column", gap: 12,
};

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
        min={min} max={max} step={step} value={value}
        aria-label={label}
        onChange={(e) => onChange(Number(e.target.value))}
        style={{ width: "100%", accentColor: "#4de0ff" }}
      />
    </div>
  );
}

function Toggle({ label, value, onChange }: { label: string; value: boolean; onChange: () => void }) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={value}
      onClick={onChange}
      style={{
        display: "flex", justifyContent: "space-between", alignItems: "center", width: "100%",
        padding: "6px 10px", borderRadius: 8, cursor: "pointer", textAlign: "left",
        background: "rgba(255,255,255,0.03)", border: "1px solid #1e2a3a",
      }}
    >
      <span style={{ fontSize: 12, color: "#cfe0f2" }}>{label}</span>
      <span style={{
        width: 32, height: 18, borderRadius: 9, position: "relative", flexShrink: 0,
        background: value ? "#4de0ff" : "#1e2a3a", transition: "background 0.2s", display: "block",
      }}>
        <span style={{
          position: "absolute", top: 2, left: value ? 16 : 2, width: 14, height: 14,
          borderRadius: "50%", background: "#fff", transition: "left 0.2s", display: "block",
        }} />
      </span>
    </button>
  );
}
