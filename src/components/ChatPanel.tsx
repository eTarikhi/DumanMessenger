import { useState, useEffect, useRef } from "react";
import type { MeshNode, MeshMessage } from "../types";

interface Props {
  nodes: MeshNode[];
  selectedNodeId: string | null;
  onSendMessage: (from: string, to: string | "BROADCAST", body: string, type: "text" | "broadcast" | "sos") => MeshMessage | null;
  deliveries: { msgId: string; from: string; to: string; hops: number; latencyMs: number; path: string[] }[];
}

export function ChatPanel({ nodes, selectedNodeId, onSendMessage, deliveries }: Props) {
  const onlineNodes = nodes.filter((n) => n.isOnline);
  const [fromId, setFromId] = useState<string>("");
  const [toId, setToId] = useState<string>("BROADCAST");
  const [body, setBody] = useState("");
  const [msgType, setMsgType] = useState<"text" | "broadcast" | "sos">("text");
  const [log, setLog] = useState<{ id: string; from: string; to: string; body: string; type: string; timestamp: number; delivered: boolean; hops?: number; latency?: number }[]>([]);
  const logRef = useRef(log);
  logRef.current = log;
  const logEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!fromId && onlineNodes.length > 0) {
      setFromId(onlineNodes[0].id);
    }
  }, [onlineNodes, fromId]);

  useEffect(() => {
    if (selectedNodeId && onlineNodes.some((n) => n.id === selectedNodeId)) {
      setToId(selectedNodeId);
    }
  }, [selectedNodeId, onlineNodes]);

  useEffect(() => {
    const newDeliveries = deliveries.filter((d) => !logRef.current.some((l) => l.id === d.msgId));
    if (newDeliveries.length > 0) {
      setLog((prev) => {
        const updated = [...prev];
        for (const d of newDeliveries) {
          const existing = updated.find((l) => l.id === d.msgId);
          if (existing) {
            existing.delivered = true;
            existing.hops = d.hops;
            existing.latency = d.latencyMs;
          }
        }
        return updated;
      });
    }
  }, [deliveries]);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [log]);

  const handleSend = () => {
    if (!body.trim() || !fromId) return;
    const sentMsg = onSendMessage(fromId, toId, body, msgType);
    if (sentMsg) {
      setLog((prev) => [...prev, {
        id: sentMsg.id,
        from: fromId,
        to: toId,
        body,
        type: msgType,
        timestamp: Date.now(),
        delivered: false,
      }]);
    }
    setBody("");
  };

  const fromNode = nodes.find((n) => n.id === fromId);
  const toNode = toId === "BROADCAST" ? null : nodes.find((n) => n.id === toId);

  return (
    <div style={{
      display: "flex", flexDirection: "column", height: "100%",
      borderRadius: 14, border: "1px solid #1e2a3a",
      background: "rgba(17, 24, 35, 0.95)", overflow: "hidden",
    }}>
      <div style={{
        padding: "12px 16px", borderBottom: "1px solid #1e2a3a",
        fontSize: 14, fontWeight: 700, color: "#eaf2ff",
        display: "flex", alignItems: "center", gap: 8,
      }}>
        <span style={{ color: "#4de0ff" }}>💬</span> Mesh Chat
        <span style={{ fontSize: 11, color: "#9fb0c3", fontWeight: 400 }}>
          ({onlineNodes.length} online)
        </span>
      </div>

      <div style={{
        padding: 12, borderBottom: "1px solid #1e2a3a",
        display: "flex", flexDirection: "column", gap: 8,
      }}>
        <div style={{ display: "flex", gap: 8 }}>
          <select
            value={fromId}
            onChange={(e) => setFromId(e.target.value)}
            style={selectStyle}
          >
            {onlineNodes.map((n) => (
              <option key={n.id} value={n.id}>From: {n.name}</option>
            ))}
          </select>
          <select
            value={toId}
            onChange={(e) => setToId(e.target.value)}
            style={selectStyle}
          >
            <option value="BROADCAST">To: 📡 Broadcast</option>
            {onlineNodes.filter((n) => n.id !== fromId).map((n) => (
              <option key={n.id} value={n.id}>To: {n.name}</option>
            ))}
          </select>
        </div>

        <div style={{ display: "flex", gap: 4 }}>
          {(["text", "broadcast", "sos"] as const).map((t) => (
            <button
              key={t}
              onClick={() => {
                setMsgType(t);
                if (t === "broadcast") setToId("BROADCAST");
              }}
              style={{
                padding: "4px 10px", borderRadius: 6, fontSize: 11, fontWeight: 600,
                cursor: "pointer", border: "1px solid #1e2a3a",
                ...(msgType === t
                  ? t === "sos" ? { background: "#ff4d6d", color: "#fff" }
                    : t === "broadcast" ? { background: "#ffb84d", color: "#1a1000" }
                    : { background: "#4de0ff", color: "#001019" }
                  : { background: "rgba(255,255,255,0.03)", color: "#9fb0c3" }
                ),
              }}
            >
              {t === "text" ? "Text" : t === "broadcast" ? "Broadcast" : "🆘 SOS"}
            </button>
          ))}
        </div>

        <div style={{ display: "flex", gap: 8 }}>
          <input
            type="text"
            value={body}
            onChange={(e) => setBody(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && handleSend()}
            placeholder={msgType === "sos" ? "SOS message..." : "Type a message..."}
            style={{
              flex: 1, padding: "8px 12px", borderRadius: 8,
              border: "1px solid #1e2a3a", background: "rgba(255,255,255,0.04)",
              color: "#eaf2ff", fontSize: 13, outline: "none",
            }}
          />
          <button
            onClick={handleSend}
            disabled={!body.trim()}
            style={{
              padding: "8px 16px", borderRadius: 8, cursor: "pointer",
              border: "none", fontWeight: 700, fontSize: 13,
              background: body.trim() ? "linear-gradient(135deg, #4de0ff, #8b7dff)" : "#1e2a3a",
              color: body.trim() ? "#001019" : "#5a6a7a",
            }}
          >
            Send
          </button>
        </div>
        {fromNode && toNode && msgType === "text" && (
          <div style={{ fontSize: 11, color: "#5a6a7a" }}>
            Direct: {fromNode.name} → {toNode.name}
          </div>
        )}
      </div>

      <div style={{
        flex: 1, overflowY: "auto", padding: 12,
        display: "flex", flexDirection: "column", gap: 6,
      }}>
        {log.length === 0 && (
          <div style={{
            textAlign: "center", color: "#5a6a7a", fontSize: 13,
            marginTop: 20,
          }}>
            No messages yet. Send a message to see mesh routing in action.
          </div>
        )}
        {log.map((entry) => {
          const fromN = nodes.find((n) => n.id === entry.from);
          const toN = entry.to === "BROADCAST" ? null : nodes.find((n) => n.id === entry.to);
          const isOwn = entry.from === fromId;
          return (
            <div key={entry.id} style={{
              alignSelf: isOwn ? "flex-end" : "flex-start",
              maxWidth: "85%",
              padding: "8px 12px",
              borderRadius: 10,
              border: "1px solid",
              ...(entry.type === "sos"
                ? { background: "rgba(255,77,109,0.12)", borderColor: "rgba(255,77,109,0.3)" }
                : entry.type === "broadcast"
                ? { background: "rgba(255,184,77,0.1)", borderColor: "rgba(255,184,77,0.2)" }
                : isOwn
                ? { background: "rgba(77,224,255,0.08)", borderColor: "rgba(77,224,255,0.2)" }
                : { background: "rgba(255,255,255,0.04)", borderColor: "#1e2a3a" }
              ),
            }}>
              <div style={{ fontSize: 10, color: "#9fb0c3", marginBottom: 4 }}>
                {fromN?.name ?? entry.from} → {toN?.name ?? "📡 All"}
                {entry.type === "sos" && " 🆘"}
                {entry.type === "broadcast" && " 📢"}
              </div>
              <div style={{ fontSize: 13, color: "#eaf2ff", wordBreak: "break-word" }}>
                {entry.body}
              </div>
              <div style={{ fontSize: 10, marginTop: 4, display: "flex", gap: 8 }}>
                {entry.delivered ? (
                  <span style={{ color: "#b6ff4a" }}>
                    ✓ {entry.hops ?? 0} hops · {entry.latency ?? 0}ms
                  </span>
                ) : (
                  <span style={{ color: "#ffb84d" }}>⏳ routing...</span>
                )}
              </div>
            </div>
          );
        })}
        <div ref={logEndRef} />
      </div>
    </div>
  );
}

const selectStyle: React.CSSProperties = {
  flex: 1,
  padding: "6px 10px",
  borderRadius: 8,
  border: "1px solid #1e2a3a",
  background: "rgba(255,255,255,0.04)",
  color: "#eaf2ff",
  fontSize: 12,
  outline: "none",
  cursor: "pointer",
};
