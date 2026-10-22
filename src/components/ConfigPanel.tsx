import { useEffect, useState } from "react";
import type { SimConfig } from "../simulation";
import type { ChannelAccess, RelayPolicy } from "../types";

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
  channelAccess: ChannelAccess;
  enableSuperElection: boolean;
  enableMobility: boolean;
  enableDtn: boolean;
  batteryDrainMultiplier: number;
  dutyCycleEnabled: boolean;
  normalScanWindowMs: number;
  normalScanCycleMs: number;
  sleepDrainFactor: number;
  sosRepeats: number;
  sosRepeatMs: number;
  sosTtl: number;
};

function toDraft(c: SimConfig): Draft {
  return {
    nodeCount: c.nodeCount,
    areaWidth: c.areaWidth,
    stationaryRatio: c.stationaryRatio,
    chargingRatio: c.chargingRatio,
    seed: c.seed,
    relayPolicy: c.relayPolicy,
    channelAccess: c.channelAccess,
    enableSuperElection: c.enableSuperElection,
    enableMobility: c.enableMobility,
    enableDtn: c.enableDtn,
    batteryDrainMultiplier: c.batteryDrainMultiplier,
    dutyCycleEnabled: c.dutyCycleEnabled,
    normalScanWindowMs: c.normalScanWindowMs,
    normalScanCycleMs: c.normalScanCycleMs,
    sleepDrainFactor: c.sleepDrainFactor,
    sosRepeats: c.sosRepeats,
    sosRepeatMs: c.sosRepeatMs,
    sosTtl: c.sosTtl,
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
      channelAccess: draft.channelAccess,
      enableSuperElection: draft.enableSuperElection,
      enableMobility: draft.enableMobility,
      enableDtn: draft.enableDtn,
      batteryDrainMultiplier: draft.batteryDrainMultiplier,
      dutyCycleEnabled: draft.dutyCycleEnabled,
      normalScanWindowMs: draft.normalScanWindowMs,
      normalScanCycleMs: draft.normalScanCycleMs,
      sleepDrainFactor: draft.sleepDrainFactor,
      sosRepeats: draft.sosRepeats,
      sosRepeatMs: draft.sosRepeatMs,
      sosTtl: draft.sosTtl,
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

      <Slider label="Nodes" value={draft.nodeCount} min={5} max={200} step={5}
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
              {POLICY_LABELS[p]}
            </button>
          ))}
        </div>
        <span style={{ fontSize: 10, color: "#5a6a7a", lineHeight: 1.5 }}>
          Three arms, each isolating one mechanism: <b style={{ color: "#9fb0c3" }}>mpr</b> vs{" "}
          <b style={{ color: "#9fb0c3" }}>route-flood</b> is the MPR suppression saving,{" "}
          <b style={{ color: "#9fb0c3" }}>route-flood</b> vs{" "}
          <b style={{ color: "#9fb0c3" }}>flood-all</b> is the value of route knowledge. skills/02
          measures mpr against the naive arm.
        </span>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <span style={{ fontSize: 11, color: "#9fb0c3" }}>Radio channel</span>
        <div style={{ display: "flex", gap: 6 }}>
          {(["free", "halfDuplex"] as const).map((p) => (
            <button
              key={p}
              aria-pressed={draft.channelAccess === p}
              onClick={() => set("channelAccess", p)}
              style={{
                flex: 1, padding: "6px 8px", borderRadius: 8, cursor: "pointer", fontSize: 11, fontWeight: 700,
                border: "1px solid #1e2a3a",
                background: draft.channelAccess === p ? "rgba(77,224,255,0.18)" : "rgba(255,255,255,0.03)",
                color: draft.channelAccess === p ? "#4de0ff" : "#9fb0c3",
              }}
            >
              {CHANNEL_LABELS[p]}
            </button>
          ))}
        </div>
        <span style={{ fontSize: 10, color: "#5a6a7a", lineHeight: 1.5 }}>
          <b style={{ color: "#9fb0c3" }}>Free</b> is an infinitely wide radio: two packets on air at once both
          succeed, so a 10 MB file costs nobody else anything (docs/08 §9).{" "}
          <b style={{ color: "#9fb0c3" }}>Half-duplex</b> is the one radio a phone has — a bounded transmit queue
          that drops at the tail when it is full — and on it the same file costs 2.8 points of everybody else's
          delivery (docs/08 §12). Ships free, because that is the model the roadmap's acceptance gates were
          written against.
        </span>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <Toggle label="Super-node election" value={draft.enableSuperElection}
          onChange={() => set("enableSuperElection", !draft.enableSuperElection)} />
        <Toggle label="Mobility (random walk)" value={draft.enableMobility}
          onChange={() => set("enableMobility", !draft.enableMobility)} />
        <Toggle label="DTN store-carry-forward" value={draft.enableDtn}
          onChange={() => set("enableDtn", !draft.enableDtn)} />
        <Toggle label="Duty cycle (NORMAL sleeps)" value={draft.dutyCycleEnabled}
          onChange={() => set("dutyCycleEnabled", !draft.dutyCycleEnabled)} />
      </div>

      {draft.dutyCycleEnabled && (
        <div style={{ display: "flex", flexDirection: "column", gap: 4, marginTop: -6 }}>
          <Slider label="Scan window (s)" value={draft.normalScanWindowMs / 1000} min={1} max={9} step={1}
            onChange={(v) => set("normalScanWindowMs", v * 1000)} />
          <Slider label="Cycle (s)" value={draft.normalScanCycleMs / 1000} min={2} max={30} step={1}
            onChange={(v) => set("normalScanCycleMs", v * 1000)} />
          <Slider label="Sleep drain (% of awake)" value={Math.round(draft.sleepDrainFactor * 100)} min={0} max={100} step={5}
            onChange={(v) => set("sleepDrainFactor", v / 100)} />
          <span style={{ fontSize: 10, color: "#5a6a7a", lineHeight: 1.5 }}>
            {dutySummary(draft)} — the always-on figure is 15.0% per 8 h, exactly the skills/07
            budget, so the sleep slot is what buys headroom. SUPER never sleeps.
          </span>
        </div>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: "#ff8fa3", letterSpacing: 0.4 }}>
          🆘 SOS — repeated flood (docs/05)
        </div>
        <Slider label="Repeats after the first" value={draft.sosRepeats} min={0} max={10} step={1}
          onChange={(v) => set("sosRepeats", v)} />
        <Slider label="Repeat gap (s)" value={draft.sosRepeatMs / 1000} min={1} max={30} step={1}
          onChange={(v) => set("sosRepeatMs", v * 1000)} />
        <Slider label="SOS TTL (hops)" value={draft.sosTtl} min={3} max={12} step={1}
          onChange={(v) => set("sosTtl", v)} />
        <span style={{ fontSize: 10, color: "#5a6a7a", lineHeight: 1.5 }}>
          TTL sets the <em>radius</em>; repeats absorb loss and movement. Measured on a 60-node
          crowd from an edge sender: TTL 5 reaches 93% and no repeat count closes it, TTL 7 with 3
          repeats reaches 100% — and 3 repeats alone take a TTL-7 flood from 89% to 100%. Each
          flood carries a fresh GPS fix, and receivers collapse them into one alert.
        </span>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
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

/** What the duty cycle is predicted to cost, from the draft values. */
function dutySummary(d: Draft): string {
  const cycle = Math.max(1, d.normalScanCycleMs);
  const awake = Math.min(1, d.normalScanWindowMs / cycle);
  const factor = awake + (1 - awake) * d.sleepDrainFactor;
  const perHour = 1.875 * factor; // NORMAL_DRAIN_PER_HOUR, stationary
  return (
    `Scan ${(d.normalScanWindowMs / 1000).toFixed(0)}s / sleep ${((cycle - d.normalScanWindowMs) / 1000).toFixed(0)}s` +
    ` => ${(factor * 100).toFixed(0)}% of the always-on drain, ~${perHour.toFixed(2)}%/h` +
    ` (${(perHour * 8).toFixed(1)}% per 8 h)`
  );
}

const CHANNEL_LABELS: Record<ChannelAccess, string> = {
  free: "Free (ships)",
  halfDuplex: "Half-duplex",
};

const POLICY_LABELS: Record<RelayPolicy, string> = {
  mpr: "MPR (super-node)",
  "route-flood": "Route-flood",
  "flood-all": "Flood-all (naive)",
};

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
