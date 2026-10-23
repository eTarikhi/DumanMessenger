import type React from "react";
import { useEffect, useRef, useState } from "react";
import type { Group, MeshNode, MeshMessage } from "../types";
import type { DeliveryRecord, SentRecord, Transfer } from "../simulation";

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
  /** Live group channels, so the destination picker can offer them. */
  groups?: Group[];
  groupMode?: "scoped-flood" | "per-member-unicast";
  /** Flips the group delivery mode without rebuilding the world. */
  onToggleGroupMode?: () => void;
  /** Media transport (roadmap Phase 3): a chunked file, or a push-to-talk note.
   *  Both are 1:1, so the buttons are disabled while a group or everybody is the
   *  destination. */
  onSendFile?: (from: string, to: string, megabytes: number) => void;
  onSendVoice?: (from: string, to: string, seconds: number, stream: boolean) => void;
  /** Live and finished transfers, rendered as progress bars. */
  transfers?: Transfer[];
}

/** The media buttons' look: enabled is a soft blue, disabled explains itself. */
function mediaBtnStyle(enabled: boolean): React.CSSProperties {
  return {
    padding: "5px 10px",
    borderRadius: 6,
    fontSize: 11,
    fontWeight: 600,
    cursor: enabled ? "pointer" : "default",
    border: "1px solid #1e2a3a",
    background: enabled ? "rgba(127,179,255,0.14)" : "rgba(255,255,255,0.03)",
    color: enabled ? "#7fb3ff" : "#5a6a7a",
  };
}

export function ChatPanel({ nodes, selectedNodeId, onSendMessage, sentRecords, deliveries, onTrace, traceMsgId, sosRepeats, groups, groupMode, onToggleGroupMode, onSendFile, onSendVoice, transfers }: Props) {
  const onlineNodes = nodes.filter((n) => n.isOnline);
  // Seeded from the node list rather than left to an effect: the composer should
  // have a valid sender on the very first render (and a server-side render, where
  // effects never run, should still show the sender's groups).
  const [fromId, setFromId] = useState<string>(() => nodes.find((n) => n.isOnline)?.id ?? "");
  const [toId, setToId] = useState<string>("BROADCAST");
  const [body, setBody] = useState("");
  const [msgType, setMsgType] = useState<"text" | "broadcast" | "sos">("text");
  const [mediaMb, setMediaMb] = useState(10);
  const [voiceSec, setVoiceSec] = useState(3);
  // Media is 1:1: a scoped flood cannot carry 160 chunks, and a group has no single
  // receiver to slide a window against.
  const mediaTarget =
    !!fromId && toId !== "BROADCAST" && !(groups ?? []).some((g) => g.id === toId);
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

  // A group destination belongs to whoever created it: if the sender changes and is
  // not a member, fall back to the broadcast channel rather than sending into a
  // group the engine will refuse.
  useEffect(() => {
    if (toId.startsWith("grp-") && !(groups ?? []).some((g) => g.id === toId && g.members.has(fromId))) {
      setToId("BROADCAST");
    }
  }, [fromId, toId, groups]);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ block: "nearest" });
  }, [sentRecords.length, deliveries.length]);

  const handleSend = () => {
    if (!body.trim() || !fromId) return;
    onSendMessage(fromId, toId, body.trim(), msgType);
    setBody("");
  };

  const myGroups = (groups ?? []).filter((g) => g.members.has(fromId));
  const groupById = (id?: string) => (id ? (groups ?? []).find((g) => g.id === id) : undefined);
  const nameOf = (id: string) => nodes.find((n) => n.id === id)?.name ?? id;
  const deliveryFor = (msgId: string) => deliveries.find((d) => d.msgId === msgId);

  // One emergency, one card. The originator re-floods an SOS every sosRepeatMs and
  // a receiver's inbox collapses those floods onto a single alert (docs/04 keeps
  // the channel opt-in precisely so an emergency cannot spam it), so the log shows
  // the same collapse — with the flood count and the freshest GPS fix — instead of
  // four near-identical bubbles.
  const cards: { entry: SentRecord; floods: SentRecord[] }[] = [];
  const bySos = new Map<string, { entry: SentRecord; floods: SentRecord[] }>();
  // A chunk is not a message: 160 of them are one file, and the transfer rows below
  // already show its progress. Rendering them as bubbles would bury the chat. Nor is a
  // history digest, which is control traffic between members (docs/06 §17).
  const chatRecords = sentRecords.filter((r) => !r.transferId && r.type !== "sync");
  for (const entry of chatRecords) {
    // In `per-member-unicast` mode one user action is N radio messages, all created
    // at the same instant for the same group: one card, like the SOS collapse.
    if (entry.groupId && groupMode === "per-member-unicast") {
      const key = `${entry.groupId}|${entry.timestamp}|${entry.body}`;
      const existing = bySos.get(key);
      if (existing) {
        existing.floods.push(entry);
        continue;
      }
      const card = { entry, floods: [entry] };
      bySos.set(key, card);
      cards.push(card);
      continue;
    }
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
          ({onlineNodes.length} online · {chatRecords.length} sent
          {sentRecords.length > chatRecords.length
            ? ` · ${sentRecords.length - chatRecords.length} media chunks`
            : ""})
        </span>
        {onToggleGroupMode && groupMode && (
          <button
            onClick={onToggleGroupMode}
            title="How a group message travels: one flood only members accept, or one routed unicast per member"
            style={{
              marginLeft: "auto", padding: "2px 9px", borderRadius: 999, cursor: "pointer",
              fontSize: 10, fontWeight: 700, border: "1px solid rgba(38,208,168,0.4)",
              background: "rgba(38,208,168,0.12)", color: "#26d0a8",
            }}
          >
            👥 {groupMode === "scoped-flood" ? "scoped flood" : "per-member unicast"}
          </button>
        )}
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
              {myGroups.length > 0 && (
                <optgroup label="Groups">
                  {myGroups.map((g) => (
                    <option key={g.id} value={g.id}>
                      👥 {g.name} ({g.members.size})
                    </option>
                  ))}
                </optgroup>
              )}
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

        {(onSendFile || onSendVoice) && (
          <div
            style={{
              display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap",
              paddingTop: 8, borderTop: "1px solid #141d29",
            }}
          >
            <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, color: "#9fb0c3" }}>
              📎 {mediaMb} MB
              <input
                type="range" min={1} max={20} step={1} value={mediaMb}
                aria-label="File size in megabytes"
                onChange={(e) => setMediaMb(Number(e.target.value))}
              />
            </label>
            <button
              onClick={() => onSendFile?.(fromId, toId, mediaMb)}
              disabled={!mediaTarget}
              title={mediaTarget ? "Slice into 64 KB chunks and slide them across the mesh" : "Pick one person — a file transfer is 1:1"}
              style={mediaBtnStyle(mediaTarget)}
            >
              Send file
            </button>
            <label style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, color: "#9fb0c3" }}>
              🎙 {voiceSec} s
              <input
                type="range" min={1} max={30} step={1} value={voiceSec}
                aria-label="Voice note length in seconds"
                onChange={(e) => setVoiceSec(Number(e.target.value))}
              />
            </label>
            <button
              onClick={() => onSendVoice?.(fromId, toId, voiceSec, true)}
              disabled={!mediaTarget}
              title={mediaTarget ? "Stream 500 ms Opus frames while the button is held" : "Pick one person — push-to-talk is 1:1"}
              style={mediaBtnStyle(mediaTarget)}
            >
              PTT · stream
            </button>
            <button
              onClick={() => onSendVoice?.(fromId, toId, voiceSec, false)}
              disabled={!mediaTarget}
              title={mediaTarget ? "Send the whole note as one blob at release — the design streaming is measured against" : "Pick one person — push-to-talk is 1:1"}
              style={mediaBtnStyle(mediaTarget)}
            >
              PTT · blob
            </button>
          </div>
        )}

        {(transfers ?? []).length > 0 && (
          <div style={{ display: "flex", flexDirection: "column", gap: 4, paddingTop: 6 }}>
            {(transfers ?? []).slice(-4).map((t) => {
              const pct = t.chunks > 0 ? (t.received / t.chunks) * 100 : 0;
              const peer = nodes.find((n) => n.id === (t.from === fromId ? t.to : t.from));
              return (
                <div key={t.id} style={{ fontSize: 11, color: "#9fb0c3" }} data-testid={`transfer-${t.id}`}>
                  <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
                    <span>{t.kind === "voice" ? "🎙" : "📦"}</span>
                    <span>
                      {t.from === fromId ? "→" : "←"} {peer?.name ?? (t.from === fromId ? t.to : t.from)} ·{" "}
                      {t.totalBytes >= 1048576
                        ? `${(t.totalBytes / 1048576).toFixed(1)} MB`
                        : `${(t.totalBytes / 1024).toFixed(0)} KB`}{" "}
                      over {t.transport} · {t.received}/{t.chunks}
                      {t.completedAt !== null
                        ? ` · done in ${((t.completedAt - t.startedAt) / 1000).toFixed(1)} s`
                        : t.stalls > 0
                        ? ` · ${t.stalls} stall${t.stalls === 1 ? "" : "s"}`
                        : ""}
                    </span>
                  </div>
                  <div style={{ height: 4, background: "#141d29", borderRadius: 2, overflow: "hidden" }}>
                    <div
                      style={{
                        width: `${pct}%`, height: "100%",
                        background: t.completedAt !== null ? "#b6ff4a" : "#7fb3ff",
                      }}
                    />
                  </div>
                </div>
              );
            })}
          </div>
        )}
      </div>

      <div style={{ flex: 1, overflowY: "auto", padding: 12, display: "flex", flexDirection: "column", gap: 6 }}>
        {chatRecords.length === 0 && (
          <div style={{ textAlign: "center", color: "#5a6a7a", fontSize: 13, marginTop: 20 }}>
            No messages yet. Send one to watch it route through the mesh.
          </div>
        )}
        {cards.slice(-40).map(({ entry, floods }) => {
          const isOwn = entry.from === fromId;
          const d = deliveryFor(entry.msgId);
          const isBroadcast = entry.to === "BROADCAST";
          const isSos = entry.type === "sos";
          const cardGroup = groupById(entry.groupId);
          const groupGot = cardGroup
            ? new Set(
                deliveries
                  .filter((d) => floods.some((f) => f.msgId === d.msgId) && d.type !== "ack")
                  .map((d) => d.to)
              ).size
            : 0;
          const groupWant = cardGroup ? cardGroup.members.size - 1 : 0;
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
                {nameOf(entry.from)} →{" "}
                {cardGroup
                  ? `👥 ${cardGroup.name} (${cardGroup.members.size} · epoch ${cardGroup.keyEpoch})`
                  : isBroadcast
                  ? "📡 All"
                  : nameOf(entry.to)}
                {entry.type === "sos" && " 🆘"}
                <span style={{ marginLeft: 6, fontFamily: "monospace" }}>
                  t+{(entry.timestamp / 1000).toFixed(1)}s
                </span>
              </div>
              <div style={{ fontSize: 13, color: "#eaf2ff", wordBreak: "break-word" }}>{entry.body}</div>
              <div style={{ fontSize: 10, marginTop: 4 }}>
                {cardGroup ? (
                  <span style={{ color: groupGot === groupWant ? "#b6ff4a" : "#ffb84d" }}>
                    👥 {groupGot} of {groupWant} member{groupWant === 1 ? "" : "s"} received
                    {groupMode ? ` · ${groupMode === "scoped-flood" ? "one scoped flood" : `${floods.length} routed unicasts`}` : ""}
                    {floods.length > 1 && groupMode === "per-member-unicast"
                      ? " (one send)"
                      : ""}
                  </span>
                ) : isSos ? (
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
