import type { DeliveryRecord } from "../simulation";

interface Props {
  deliveries: DeliveryRecord[];
  maxPoints: number;
}

export function LatencyChart({ deliveries, maxPoints }: Props) {
  const recent = deliveries.slice(-maxPoints);
  const maxLatency = Math.max(100, ...recent.map((d) => d.latencyMs));

  const w = 280;
  const h = 80;
  const padding = 8;

  if (recent.length < 2) {
    return (
      <div style={{
        padding: 14, borderRadius: 14, border: "1px solid #1e2a3a",
        background: "rgba(17, 24, 35, 0.95)",
      }}>
        <div style={{ fontSize: 11, color: "#9fb0c3", textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>
          Latency Trend
        </div>
        <div style={{ height: h, display: "grid", placeItems: "center", color: "#5a6a7a", fontSize: 12 }}>
          Send messages to see latency data
        </div>
      </div>
    );
  }

  const points = recent.map((d, i) => {
    const x = padding + (i / (recent.length - 1)) * (w - padding * 2);
    const y = h - padding - (d.latencyMs / maxLatency) * (h - padding * 2);
    return { x, y, latency: d.latencyMs, hops: d.hops };
  });

  const pathD = points.map((p, i) => `${i === 0 ? "M" : "L"} ${p.x} ${p.y}`).join(" ");

  return (
    <div style={{
      padding: 14, borderRadius: 14, border: "1px solid #1e2a3a",
      background: "rgba(17, 24, 35, 0.95)",
    }}>
      <div style={{ fontSize: 11, color: "#9fb0c3", textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>
        Latency Trend ({recent.length} deliveries)
      </div>
      <svg width={w} height={h} style={{ display: "block" }}>
        <line x1={padding} y1={h - padding} x2={w - padding} y2={h - padding} stroke="#1e2a3a" />
        <line x1={padding} y1={padding} x2={padding} y2={h - padding} stroke="#1e2a3a" />
        <path d={pathD} fill="none" stroke="#4de0ff" strokeWidth={1.5} />
        {points.map((p, i) => (
          <circle
            key={i}
            cx={p.x}
            cy={p.y}
            r={2.5}
            fill={p.hops <= 1 ? "#b6ff4a" : p.hops <= 3 ? "#4de0ff" : "#ffb84d"}
          />
        ))}
      </svg>
      <div style={{ display: "flex", gap: 12, marginTop: 6, fontSize: 10, color: "#9fb0c3" }}>
        <span><i style={{ color: "#b6ff4a" }}>●</i> 1 hop</span>
        <span><i style={{ color: "#4de0ff" }}>●</i> 2-3 hops</span>
        <span><i style={{ color: "#ffb84d" }}>●</i> 4+ hops</span>
        <span style={{ marginLeft: "auto" }}>max: {maxLatency.toFixed(0)}ms</span>
      </div>
    </div>
  );
}
