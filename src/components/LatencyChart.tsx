import type { DeliveryRecord } from "../simulation";

interface Props {
  deliveries: DeliveryRecord[];
  maxPoints: number;
}

const TARGET_1_HOP_MS = 2000;
const TARGET_3_HOP_MS = 5000;

/** Latency per delivery, measured on the simulation clock (docs/02 §6 targets). */
export function LatencyChart({ deliveries, maxPoints }: Props) {
  const recent = deliveries.slice(-maxPoints);
  const w = 300;
  const h = 92;
  const padding = 10;

  if (recent.length < 2) {
    return (
      <div style={panelStyle}>
        <Header />
        <div style={{ height: h, display: "grid", placeItems: "center", color: "#5a6a7a", fontSize: 12 }}>
          Send messages to see latency data
        </div>
      </div>
    );
  }

  const maxLatency = Math.max(TARGET_1_HOP_MS, ...recent.map((d) => d.latencyMs)) * 1.1;
  const yOf = (v: number) => h - padding - (v / maxLatency) * (h - padding * 2);

  const points = recent.map((d, i) => ({
    x: padding + (i / (recent.length - 1)) * (w - padding * 2),
    y: yOf(d.latencyMs),
    latency: d.latencyMs,
    hops: d.hops,
    id: d.msgId,
  }));

  const pathD = points.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x.toFixed(1)} ${p.y.toFixed(1)}`).join(" ");
  const breaches = recent.filter((d) => (d.hops <= 1 ? d.latencyMs > TARGET_1_HOP_MS : d.hops <= 3 ? d.latencyMs > TARGET_3_HOP_MS : false)).length;

  return (
    <div style={panelStyle}>
      <Header count={recent.length} />
      <svg width={w} height={h} style={{ display: "block" }} role="img" aria-label="Latency trend">
        <line x1={padding} y1={h - padding} x2={w - padding} y2={h - padding} stroke="#1e2a3a" />
        <line x1={padding} y1={padding} x2={padding} y2={h - padding} stroke="#1e2a3a" />
        {/* documented latency budgets */}
        <line x1={padding} y1={yOf(TARGET_1_HOP_MS)} x2={w - padding} y2={yOf(TARGET_1_HOP_MS)}
          stroke="rgba(182,255,74,0.35)" strokeDasharray="3 3" />
        <line x1={padding} y1={yOf(TARGET_3_HOP_MS)} x2={w - padding} y2={yOf(TARGET_3_HOP_MS)}
          stroke="rgba(255,184,77,0.35)" strokeDasharray="3 3" />
        <path d={pathD} fill="none" stroke="#4de0ff" strokeWidth={1.5} />
        {points.map((p) => (
          <circle key={`${p.id}-${p.x.toFixed(1)}`} cx={p.x} cy={p.y} r={2.5}
            fill={p.hops <= 1 ? "#b6ff4a" : p.hops <= 3 ? "#4de0ff" : "#ffb84d"}>
            <title>{`${p.id}: ${p.hops} hops, ${p.latency.toFixed(0)} ms`}</title>
          </circle>
        ))}
      </svg>
      <div style={{ display: "flex", gap: 10, marginTop: 6, fontSize: 10, color: "#9fb0c3", flexWrap: "wrap" }}>
        <span><i style={{ color: "#b6ff4a" }}>●</i> 1 hop</span>
        <span><i style={{ color: "#4de0ff" }}>●</i> 2–3 hops</span>
        <span><i style={{ color: "#ffb84d" }}>●</i> 4+ hops</span>
        <span style={{ marginLeft: "auto" }}>max {maxLatency.toFixed(0)} ms</span>
        <span style={{ color: breaches === 0 ? "#b6ff4a" : "#ff4d6d" }}>
          {breaches === 0 ? "within budget" : `${breaches} over budget`}
        </span>
      </div>
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  padding: 14, borderRadius: 14, border: "1px solid #1e2a3a", background: "rgba(17, 24, 35, 0.95)",
};

function Header({ count }: { count?: number }) {
  return (
    <div style={{ fontSize: 11, color: "#9fb0c3", textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>
      Latency trend{count ? ` (${count} deliveries)` : ""} · dashed = 2 s / 5 s budget
    </div>
  );
}
