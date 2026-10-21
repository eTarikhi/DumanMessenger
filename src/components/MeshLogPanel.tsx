import { useMemo, useState } from "react";
import type { MeshLogEntry, MeshLogKind, MeshNode, NodeId } from "../types";

interface Props {
  entries: MeshLogEntry[];
  captureLog: boolean;
  captureOgm: boolean;
  onToggleCapture: () => void;
  onToggleOgm: () => void;
  nodes: MeshNode[];
  /** Filter to the message currently being traced, if any. */
  focusMsgId: string | null;
}

const KIND_COLOR: Record<MeshLogKind, string> = {
  tx: "#4de0ff",
  loss: "#ff4d6d",
  duplicate: "#5a6a7a",
  deliver: "#b6ff4a",
  decision: "#8b7dff",
  queue: "#ff9f4d",
  election: "#ffd666",
  ack: "#9fb0c3",
  ogm: "#3f5568",
};

const KINDS: MeshLogKind[] = [
  "tx",
  "decision",
  "deliver",
  "duplicate",
  "loss",
  "queue",
  "ack",
  "election",
  "ogm",
];

/** Only this many rows are rendered, whatever the buffer holds. */
const RENDER_LIMIT = 250;

/**
 * A pcap-like view of the mesh: every radio transmission, loss, duplicate,
 * forwarding decision, delivery, ACK, DTN hand-off and role change, in
 * simulation-time order, with the reason the engine gave. Capture is off by
 * default and costs the run nothing (`docs/06-simulator-findings.md` §10 is the
 * equivalent for power telemetry); beacons sit behind their own switch because
 * in a 60-node crowd they outnumber everything else.
 */
export function MeshLogPanel({
  entries,
  captureLog,
  captureOgm,
  onToggleCapture,
  onToggleOgm,
  nodes,
  focusMsgId,
}: Props) {
  const [kinds, setKinds] = useState<Set<MeshLogKind>>(new Set(KINDS));
  const [onlyFocus, setOnlyFocus] = useState(false);

  const nameOf = (id: NodeId) => nodes.find((n) => n.id === id)?.name ?? id;

  const rows = useMemo(() => {
    const filtered = entries.filter(
      (e) =>
        kinds.has(e.kind) &&
        (!onlyFocus || !focusMsgId || e.msgId === focusMsgId)
    );
    return filtered.slice(-RENDER_LIMIT).reverse();
  }, [entries, kinds, onlyFocus, focusMsgId]);

  const toggleKind = (k: MeshLogKind) =>
    setKinds((prev) => {
      const next = new Set(prev);
      if (next.has(k)) next.delete(k);
      else next.add(k);
      return next;
    });

  return (
    <div style={{ ...panelStyle, display: "flex", flexDirection: "column", gap: 10 }}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
        <div style={headerStyle}>Mesh log</div>
        <div style={{ fontSize: 11, color: "#5a6a7a", fontFamily: "monospace" }}>
          {captureLog ? `${entries.length} events` : "capture off"}
        </div>
      </div>

      <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
        <button onClick={onToggleCapture} aria-pressed={captureLog} style={pillStyle(captureLog, "#ff4d6d")}>
          {captureLog ? "⏺ Capturing" : "○ Capture"}
        </button>
        <button
          onClick={onToggleOgm}
          aria-pressed={captureOgm}
          disabled={!captureLog}
          style={{ ...pillStyle(captureOgm, "#8b7dff"), opacity: captureLog ? 1 : 0.4 }}
        >
          + beacons
        </button>
        <button
          onClick={() => setOnlyFocus(!onlyFocus)}
          aria-pressed={onlyFocus}
          disabled={!focusMsgId}
          style={{ ...pillStyle(onlyFocus, "#ffd666"), opacity: focusMsgId ? 1 : 0.4 }}
        >
          {focusMsgId ? `only ${focusMsgId}` : "only traced msg"}
        </button>
      </div>

      <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
        {KINDS.map((k) => (
          <button
            key={k}
            onClick={() => toggleKind(k)}
            aria-pressed={kinds.has(k)}
            style={{
              fontSize: 10,
              padding: "2px 7px",
              borderRadius: 999,
              cursor: "pointer",
              border: `1px solid ${kinds.has(k) ? KIND_COLOR[k] : "#1e2a3a"}`,
              background: kinds.has(k) ? "rgba(255,255,255,0.05)" : "transparent",
              color: kinds.has(k) ? KIND_COLOR[k] : "#3f5568",
              fontWeight: 600,
            }}
          >
            {k}
          </button>
        ))}
      </div>

      <div
        style={{
          fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
          fontSize: 10.5,
          lineHeight: 1.55,
          maxHeight: 320,
          overflowY: "auto",
          border: "1px solid #1e2a3a",
          borderRadius: 8,
          background: "rgba(8, 12, 18, 0.7)",
          padding: 6,
        }}
      >
        {!captureLog ? (
          <div style={{ color: "#5a6a7a", fontStyle: "italic", fontFamily: "Inter, sans-serif", fontSize: 12 }}>
            Capture is off, so the run pays nothing for this panel. Turn it on to record every
            transmission, decision and hand-off from here onwards — the buffer is a ring of the last{" "}
            <code>maxLogEntries</code> events and is cleared when metrics are re-baselined.
          </div>
        ) : rows.length === 0 ? (
          <div style={{ color: "#5a6a7a", fontStyle: "italic", fontFamily: "Inter, sans-serif", fontSize: 12 }}>
            No events match the filters yet.
          </div>
        ) : (
          rows.map((e, i) => (
            <div key={`${e.atMs}-${i}`} style={{ display: "flex", gap: 6, whiteSpace: "nowrap" }}>
              <span style={{ color: "#5a6a7a", minWidth: 62, textAlign: "right" }}>
                {(e.atMs / 1000).toFixed(2)}s
              </span>
              <span style={{ color: KIND_COLOR[e.kind], minWidth: 58, fontWeight: 700 }}>{e.kind}</span>
              <span style={{ color: "#9fb0c3", minWidth: 92 }}>
                {nameOf(e.nodeId)}
                {e.peerId ? ` → ${nameOf(e.peerId)}` : ""}
              </span>
              <span style={{ color: e.kind === "loss" ? "#ff4d6d" : "#cfe0f2", overflow: "hidden", textOverflow: "ellipsis" }}>
                {e.detail}
              </span>
            </div>
          ))
        )}
      </div>

      <div style={{ fontSize: 10, color: "#5a6a7a", lineHeight: 1.5 }}>
        Newest first. Every line is what the engine decided, in its own words — the forwarding reason
        from <code>decideForward</code>, the MPR verdict, the link budget that lost a packet.
      </div>
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  padding: 14,
  borderRadius: 14,
  border: "1px solid #1e2a3a",
  background: "rgba(17, 24, 35, 0.95)",
};

const headerStyle: React.CSSProperties = {
  fontSize: 13,
  fontWeight: 700,
  color: "#eaf2ff",
  letterSpacing: 0.5,
};

function pillStyle(active: boolean, color: string): React.CSSProperties {
  return {
    fontSize: 11,
    fontWeight: 700,
    padding: "5px 10px",
    borderRadius: 8,
    cursor: "pointer",
    border: `1px solid ${active ? color : "#1e2a3a"}`,
    background: active ? "rgba(255,255,255,0.06)" : "rgba(255,255,255,0.02)",
    color: active ? color : "#9fb0c3",
  };
}
