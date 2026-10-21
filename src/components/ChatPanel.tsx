import { useEffect, useRef, useState } from "react";
import type { MeshNode, MeshMessage } from "../types";
import type { DeliveryRecord, SentRecord } from "../simulation";

interface Props {
  nodes: MeshNode[];
  selectedNodeId: string | null;
  onSendMessage: (
    from: string,
    to: string | "BROADCAST",
    body: string,
    type: "text" | "broadcast" | "sos"
  ) => MeshMessage | null;
  /** Rendered straight from simulation state, so a reset can never leave
   *  stale bubbles behind. */
  sentRecords: SentRecord[];
  deliveries: DeliveryRecord[];
  /** Opens the hop trace for a delivered message (roadmap Phase 4). */
  onTrace?: (msgId: string) => void;
  traceMsgId?: string | null;
  /** How many times the originator re-floods an SOS, so the log can show
   *  "flood 2/4" rather than a count with no total. */
  sosRepeats?: number;
}

export function ChatPanel({ nodes, selectedNodeId, onSendMessage, sentRecords, deliveries, onTrace, traceMsgId, sosRepeats }: Props) {
  const onlineNodes = nodes.filter((n) => n.isOnline);
  const [fromId, setFromId] = useState<string>("");
  const [toId, setToId] = useState<string>("BROADCAST");
  const [body, setBody] = useState("");
  const [msgType, setMsgType] = useState<"text" | "broadcast" | "sos">("text");
  const logEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if ((!fromId || !onlineNodes.some((n) => n.id === fromId)) && onlineNodes.length > 0) {
      setFromId(onlineNodes[0].id);
    }
  }, [onlineNodes, fromId]);

  useEffect(() => {
    if (selectedNodeId && onlineNodes.some((n) => n.id === selectedNodeId)) {
      setToId(selectedNodeId);
    }
  }, [selectedNodeId, onlineNodes]);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ block: "nearest" });
  }, [sentRecords.length, deliveries.length]);

  const handleSend = () => {
    if (!body.trim() || !fromId) return;
    onSendMessage(fromId, toId, body.trim(), msgType);
    setBody("");
  };

  const nameOf = (id: string) => nodes.find((n) => n.id === id)?.name ?? id;
  const deliveryFor = (msgId: string) => deliveries.find((d) => d.msgId === msgId);

  // One emergency, one card. The originator re-floods an SOS every sosRepeatMs and
  // a receiver's inbox collapses those floods onto a single alert (docs/04 keeps
  // the channel opt-in precisely so an emergency cannot spam it), so the log shows
  // the same collapse — with the flood count and the freshest GPS fix — instead of
  // four near-identical bubbles.
  const cards: { entry: SentRecord; floods: SentRecord[] }[] = [];
  const bySos = new Map<string, { entry: SentRecord; floods: SentRecord[] }>();
  for (const entry of sentRecords) {
    if (entry.type === "sos" && entry.sosId) {
      const existing = bySos.get(entry.sosId);
      if (existing) {
        existing.floods.push(entry);
        continue;
      }
      const card = { entry, floods: [entry] };
      bySos.set(entry.sosId, card);
      cards.push(card);
    } else {
      cards.push({ entry, floods: [entry] });
    }
  }

  /** The GPS fix in the latest flood this sender put on air. */
  const sosFix = (from: string, sosId: string) => {
    const floods = nodes.find((n) => n.id === from)?.sentLog.filter((m) => m.sosId === sosId) ?? [];
    return floods.length ? floods[floods.length - 1].sosPos : undefined;
  };
  /** Nodes holding the alert right now — the reach figure that matters. */
  const sosHeard = (sosId: string) =>
    nodes.filter((n) => n.isOnline && n.inbox.some((m) => m.sosId === sosId)).length;

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
        <span style={{ color: "#4de0ff" }}>💬</span> Mesh chat
        <span style={{ fontSize: 11, color: "#9fb0c3", fontWeight: 400 }}>
          ({onlineNodes.length} online · {sentRecords.length} sent)
        </span>
      </div>

      <div style={{ padding: 12, borderBottom: "1px solid #1e2a3a", display: "flex", flexDirection: "column", gap: 8 }}>
        <div style={{ display: "flex", gap: 8 }}>
          <label style={{ flex: 1, display: "flex", flexDirection: "column", gap: 3 }}>
            <span style={{ fontSize: 10, color: "#5a6a7a", textTransform: "uppercase", letterSpacing: 0.6 }}>From</span>
            <select value={fromId} onChange={(e) => setFromId(e.target.value)} style={selectStyle}>
              {onlineNodes.map((n) => (
                <option key={n.id} value={n.id}>{n.name}</option>
              ))}
            </select>
          </label>
          <label style={{ flex: 1, display: "flex", flexDirection: "column", gap: 3 }}>
            <span style={{ fontSize: 10, color: "#5a6a7a", textTransform: "uppercase", letterSpacing: 0.6 }}>To</span>
            <select value={toId} onChange={(e) => setToId(e.target.value)} style={selectStyle}>
              <option value="BROADCAST">📡 Broadcast</option>
              {onlineNodes.filter((n) => n.id !== fromId).map((n) => (
                <option key={n.id} value={n.id}>{n.name}</option>
              ))}
            </select>
          </label>
        </div>

        <div style={{ display: "flex", gap: 4 }} role="group" aria-label="Message type">
          {(["text", "broadcast", "sos"] as const).map((t) => (
            <button
              key={t}
              aria-pressed={msgType === t}
              onClick={() => {
                setMsgType(t);
                if (t === "broadcast") setToId("BROADCAST");
              }}
              style={{
                padding: "4px 10px", borderRadius: 6, fontSize: 11, fontWeight: 600,
                cursor: "pointer", border: "1px solid #1e2a3a",
                ...(msgType === t
                  ? t === "sos"
                    ? { background: "#ff4d6d", color: "#fff" }
                    : t === "broadcast"
                    ? { background: "#ffb84d", color: "#1a1000" }
                    : { background: "#4de0ff", color: "#001019" }
                  : { background: "rgba(255,255,255,0.03)", color: "#9fb0c3" }),
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
            onKeyDown={(e) => {
              if (e.key === "Enter") handleSend();
            }}
            placeholder={msgType === "sos" ? "SOS message…" : "Type a message…"}
            aria-label="Message body"
            style={{
              flex: 1, padding: "8px 12px", borderRadius: 8, border: "1px solid #1e2a3a",
              background: "rgba(255,255,255,0.04)", color: "#eaf2ff", fontSize: 13, outline: "none",
            }}
          />
          <button
            onClick={handleSend}
            disabled={!body.trim()}
            style={{
              padding: "8px 16px", borderRadius: 8, cursor: body.trim() ? "pointer" : "default",
              border: "none", fontWeight: 700, fontSize: 13,
              background: body.trim() ? "linear-gradient(135deg, #4de0ff, #8b7dff)" : "#1e2a3a",
              color: body.trim() ? "#001019" : "#5a6a7a",
            }}
          >
            Send
          </button>
        </div>
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: 12, display: "flex", flexDirection: "column", gap: 6 }}>
        {sentRecords.length === 0 && (
          <div style={{ textAlign: "center", color: "#5a6a7a", fontSize: 13, marginTop: 20 }}>
            No messages yet. Send one to watch it route through the mesh.
          </div>
        )}
        {cards.slice(-40).map(({ entry, floods }) => {
          const isOwn = entry.from === fromId;
          const d = deliveryFor(entry.msgId);
          const isBroadcast = entry.to === "BROADCAST";
          const isSos = entry.type === "sos";
          // Every flood is a separate radio event; the alert is one.
          const receipts = floods.reduce((a, f) => a + f.recipients, 0);
          const fix = isSos && entry.sosId ? sosFix(entry.from, entry.sosId) : undefined;
          const heard = isSos && entry.sosId ? sosHeard(entry.sosId) : 0;
          const peers = nodes.filter((n) => n.isOnline && n.id !== entry.from).length;
          return (
            <div key={entry.msgId} style={{
              alignSelf: isOwn ? "flex-end" : "flex-start",
              maxWidth: "85%", padding: "8px 12px", borderRadius: 10, border: "1px solid",
              ...(entry.type === "sos"
                ? { background: "rgba(255,77,109,0.12)", borderColor: "rgba(255,77,109,0.3)" }
                : isBroadcast
                ? { background: "rgba(255,184,77,0.1)", borderColor: "rgba(255,184,77,0.2)" }
                : isOwn
                ? { background: "rgba(77,224,255,0.08)", borderColor: "rgba(77,224,255,0.2)" }
                : { background: "rgba(255,255,255,0.04)", borderColor: "#1e2a3a" }),
            }}>
              <div style={{ fontSize: 10, color: "#9fb0c3", marginBottom: 4 }}>
                {nameOf(entry.from)} → {isBroadcast ? "📡 All" : nameOf(entry.to)}
                {entry.type === "sos" && " 🆘"}
                <span style={{ marginLeft: 6, fontFamily: "monospace" }}>
                  t+{(entry.timestamp / 1000).toFixed(1)}s
                </span>
              </div>
              <div style={{ fontSize: 13, color: "#eaf2ff", wordBreak: "break-word" }}>{entry.body}</div>
              <div style={{ fontSize: 10, marginTop: 4 }}>
                {isSos ? (
                  <span style={{ color: "#ff8fa3" }}>
                    🆘 flood {floods.length}
                    {sosRepeats !== undefined ? `/${sosRepeats + 1}` : ""} ·{" "}
                    {fix ? `GPS ${fix.x.toFixed(1)}, ${fix.y.toFixed(1)}` : "no fix yet"} ·{" "}
                    <span style={{ color: heard === peers && peers > 0 ? "#b6ff4a" : "#ffb84d" }}>
                      {heard} of {peers} online nodes heard
                    </span>{" "}
                    · {receipts} radio receipts
                    {heard < peers && floods.length <= (sosRepeats ?? 0) + 1
                      ? " · re-flooding…"
                      : ""}
                  </span>
                ) : isBroadcast ? (
                  entry.recipients > 0 ? (
                    <span style={{ color: "#b6ff4a" }}>
                      ✓ reached {entry.recipients} node{entry.recipients === 1 ? "" : "s"}
                      {d ? ` · ${d.hops} hops · ${d.latencyMs.toFixed(0)}ms` : ""}
                    </span>
                  ) : (
                    <span style={{ color: "#ffb84d" }}>⏳ flooding…</span>
                  )
                ) : entry.delivered && d ? (
                  <span style={{ color: "#b6ff4a" }}>
                    ✓ {d.hops} hop{d.hops === 1 ? "" : "s"} · {d.latencyMs.toFixed(0)}ms · acked
                    {onTrace && (
                      <button
                        onClick={() => onTrace(entry.msgId)}
                        aria-label={`Trace ${entry.msgId} hop by hop`}
                        style={{
                          marginLeft: 6, padding: "1px 6px", borderRadius: 999, cursor: "pointer",
                          fontSize: 9, fontWeight: 700, verticalAlign: "middle",
                          border: `1px solid ${traceMsgId === entry.msgId ? "#ffd666" : "rgba(182,255,74,0.35)"}`,
                          background: traceMsgId === entry.msgId ? "rgba(255,214,102,0.18)" : "transparent",
                          color: traceMsgId === entry.msgId ? "#ffd666" : "#b6ff4a",
                        }}
                      >
                        trace
                      </button>
                    )}
                  </span>
                ) : (
                  <span style={{ color: "#ffb84d" }}>⏳ routing…</span>
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
  padding: "6px 10px", borderRadius: 8, border: "1px solid #1e2a3a",
  background: "rgba(255,255,255,0.04)", color: "#eaf2ff", fontSize: 12,
  outline: "none", cursor: "pointer",
};
