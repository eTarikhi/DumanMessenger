import type { MeshNode } from "../types";
import { peersInRange, rssiModel } from "../rf";

interface Props {
  node: MeshNode | null;
  allNodes: MeshNode[];
  onToggleOnline: (id: string) => void;
  onToggleCharging: (id: string) => void;
  onClose: () => void;
}

export function NodeInspector({ node, allNodes, onToggleOnline, onToggleCharging, onClose }: Props) {
  if (!node) return null;

  const peers = peersInRange(node, allNodes);
  const batteryPct = (node.battery * 100).toFixed(0);
  const scorePct = (node.score * 100).toFixed(0);

  return (
    <div style={{
      padding: 16,
      borderRadius: 14,
      border: "1px solid #1e2a3a",
      background: "rgba(17, 24, 35, 0.95)",
      backdropFilter: "blur(8px)",
      maxHeight: "100%",
      overflowY: "auto",
    }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 800, color: "#eaf2ff" }}>{node.name}</div>
          <div style={{ fontSize: 11, color: "#9fb0c3", fontFamily: "monospace" }}>{node.id}</div>
        </div>
        <button onClick={onClose} style={{
          background: "none", border: "none", color: "#9fb0c3",
          cursor: "pointer", fontSize: 18, padding: 4,
        }}>✕</button>
      </div>

      <div style={{
        display: "inline-block",
        padding: "4px 10px",
        borderRadius: 999,
        fontSize: 11,
        fontWeight: 700,
        marginBottom: 12,
        ...node.role === "SUPER"
          ? { background: "#b6ff4a", color: "#0b1a00" }
          : { background: "rgba(255,184,77,0.15)", color: "#ffb84d", border: "1px solid rgba(255,184,77,0.3)" }
      }}>
        {node.role === "SUPER" ? "SUPER NODE" : "NORMAL"}
        {!node.isOnline && " • OFFLINE"}
      </div>

      <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 14, lineHeight: 1.5 }}>
        {node.reasonTrace}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 14 }}>
        <Metric label="Battery" value={`${batteryPct}%`} color={node.battery > 0.4 ? "#b6ff4a" : node.battery > 0.25 ? "#ffb84d" : "#ff4d6d"} />
        <Metric label="Score" value={scorePct} color="#8b7dff" />
        <Metric label="Peers" value={`${peers.length}`} color="#4de0ff" />
        <Metric label="Avg RSSI" value={`${node.avgRssi.toFixed(0)} dBm`} color="#4de0ff" />
        <Metric label="Uptime" value={`${node.uptimeMin.toFixed(1)} min`} color="#eaf2ff" />
        <Metric label="PDR" value={`${(node.pdr * 100).toFixed(0)}%`} color="#eaf2ff" />
        <Metric label="Mobility" value={node.mobility.toFixed(2)} color="#eaf2ff" />
        <Metric label="Charging" value={node.charging ? "Yes" : "No"} color={node.charging ? "#b6ff4a" : "#9fb0c3"} />
      </div>

      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>Position</div>
        <div style={{ fontSize: 13, color: "#cfe0f2", fontFamily: "monospace" }}>
          ({node.pos.x.toFixed(0)}, {node.pos.y.toFixed(0)})
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>
          Peers in Range ({peers.length})
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          {peers.length === 0 && (
            <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>No peers in range</div>
          )}
          {peers.map((p) => {
            const rssi = rssiModel(node, p);
            const q = Math.max(0, Math.min(1, (rssi + 100) / 70));
            return (
              <div key={p.id} style={{
                display: "flex", justifyContent: "space-between", alignItems: "center",
                padding: "6px 8px", borderRadius: 6,
                background: "rgba(255,255,255,0.03)",
                fontSize: 12,
              }}>
                <span style={{ color: p.role === "SUPER" ? "#b6ff4a" : "#cfe0f2" }}>
                  {p.name} {p.role === "SUPER" && "★"}
                </span>
                <span style={{ color: "#9fb0c3", fontFamily: "monospace" }}>
                  {rssi.toFixed(0)} dBm
                </span>
                <div style={{
                  width: 40, height: 4, borderRadius: 2,
                  background: "#1e2a3a", overflow: "hidden",
                }}>
                  <div style={{
                    width: `${q * 100}%`, height: "100%",
                    background: q > 0.6 ? "#b6ff4a" : q > 0.3 ? "#ffb84d" : "#ff4d6d",
                  }} />
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>
          Routing Table ({Object.keys(node.nextHopTable).length})
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
          {Object.entries(node.nextHopTable).slice(0, 10).map(([dest, entry]) => (
            <div key={dest} style={{
              display: "flex", justifyContent: "space-between",
              fontSize: 11, color: "#9fb0c3", fontFamily: "monospace",
              padding: "3px 6px", background: "rgba(255,255,255,0.02)", borderRadius: 4,
            }}>
              <span>{dest.slice(0, 12)}</span>
              <span>via {entry.bestNeighbor.slice(0, 12)}</span>
              <span style={{ color: entry.tq > 0.6 ? "#b6ff4a" : "#ffb84d" }}>tq={entry.tq.toFixed(2)}</span>
            </div>
          ))}
          {Object.keys(node.nextHopTable).length === 0 && (
            <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>No routes known</div>
          )}
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>
          DTN Queue ({node.oppQueue.length})
        </div>
        {node.oppQueue.length === 0 ? (
          <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>Queue empty</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 3 }}>
            {node.oppQueue.slice(0, 5).map((q) => (
              <div key={q.msg.id} style={{
                fontSize: 11, color: "#ff4d6d", fontFamily: "monospace",
                padding: "3px 6px", background: "rgba(255,77,109,0.08)", borderRadius: 4,
              }}>
                {q.msg.id.slice(0, 20)} → {q.msg.to.slice(0, 12)} (copies: {q.copyCount}/{3})
              </div>
            ))}
          </div>
        )}
      </div>

      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>
          Inbox ({node.inbox.length})
        </div>
        {node.inbox.length === 0 ? (
          <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>No messages</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 3, maxHeight: 120, overflowY: "auto" }}>
            {node.inbox.slice(-8).map((m) => (
              <div key={m.id} style={{
                fontSize: 11, color: "#cfe0f2",
                padding: "4px 8px", background: "rgba(77,224,255,0.06)", borderRadius: 6,
              }}>
                <span style={{ color: "#4de0ff" }}>{m.from.slice(0, 10)}</span>: {m.body.slice(0, 40)}
                <span style={{ color: "#5a6a7a", marginLeft: 4 }}>({m.hopCount}h)</span>
              </div>
            ))}
          </div>
        )}
      </div>

      <div style={{ display: "flex", gap: 8, marginTop: 16 }}>
        <button
          onClick={() => onToggleOnline(node.id)}
          style={{
            flex: 1, padding: "8px 12px", borderRadius: 8, cursor: "pointer",
            border: "1px solid #1e2a3a", fontSize: 12, fontWeight: 600,
            background: node.isOnline ? "rgba(255,77,109,0.1)" : "rgba(182,255,74,0.1)",
            color: node.isOnline ? "#ff4d6d" : "#b6ff4a",
          }}
        >
          {node.isOnline ? "Take Offline" : "Bring Online"}
        </button>
        <button
          onClick={() => onToggleCharging(node.id)}
          style={{
            flex: 1, padding: "8px 12px", borderRadius: 8, cursor: "pointer",
            border: "1px solid #1e2a3a", fontSize: 12, fontWeight: 600,
            background: node.charging ? "rgba(255,184,77,0.1)" : "rgba(255,255,255,0.04)",
            color: node.charging ? "#ffb84d" : "#eaf2ff",
          }}
        >
          {node.charging ? "Unplug" : "Plug In ⚡"}
        </button>
      </div>
    </div>
  );
}

function Metric({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div style={{
      padding: "8px 10px", borderRadius: 8,
      background: "rgba(255,255,255,0.03)",
      border: "1px solid #1e2a3a",
    }}>
      <div style={{ fontSize: 15, fontWeight: 700, color }}>{value}</div>
      <div style={{ fontSize: 10, color: "#9fb0c3", marginTop: 2 }}>{label}</div>
    </div>
  );
}
