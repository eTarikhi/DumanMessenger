import { deliveredChain, type DeliveryRecord } from "../simulation";
import type { MeshNode, NodeId } from "../types";

interface Props {
  /** The delivery being explained, or null before one is picked. */
  delivery: DeliveryRecord | null;
  nodes: MeshNode[];
  onClear: () => void;
  /** Recent deliveries, so a trace can be picked without hunting in the chat. */
  recent: DeliveryRecord[];
  onPick: (msgId: string) => void;
}

const ACTION_STYLE: Record<string, { bg: string; fg: string }> = {
  delivered: { bg: "rgba(182,255,74,0.16)", fg: "#b6ff4a" },
  relayed: { bg: "rgba(77,224,255,0.14)", fg: "#4de0ff" },
  suppressed: { bg: "rgba(255,184,77,0.14)", fg: "#ffb84d" },
  queued: { bg: "rgba(255,77,109,0.14)", fg: "#ff4d6d" },
  expired: { bg: "rgba(120,130,150,0.18)", fg: "#9fb0c3" },
  received: { bg: "rgba(120,130,150,0.18)", fg: "#9fb0c3" },
};

/**
 * roadmap Phase 4: "Hop visualization: `via 2 nodes • SUPER Amir` hop trace for
 * transparency". The point is that a user can see *why* a message took the path
 * it did — which neighbour handed it on, how good that link was, and which
 * relays stayed quiet because MPR had already covered them.
 */
export function MessageTrace({ delivery, nodes, onClear, recent, onPick }: Props) {
  const nameOf = (id: NodeId) => nodes.find((n) => n.id === id)?.name ?? id;
  const roleOf = (id: NodeId) => nodes.find((n) => n.id === id)?.role ?? "NORMAL";

  const chain = delivery ? deliveredChain(delivery.hopTrace, delivery.to) : [];
  const startMs = delivery ? delivery.timestamp - delivery.latencyMs : 0;
  // Everyone but the recipient is a relay the message went *via*.
  const relays = chain.slice(0, -1);
  const supers = relays.filter((h) => roleOf(h.nodeId) === "SUPER");
  const touched = delivery?.hopTrace.length ?? 0;
  const suppressed = delivery?.hopTrace.filter((h) => h.action === "suppressed").length ?? 0;

  return (
    <div style={panelStyle}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 8 }}>
        <div style={headerStyle}>Hop trace</div>
        {delivery && (
          <button onClick={onClear} style={linkBtnStyle} aria-label="Clear hop trace">
            ✕
          </button>
        )}
      </div>

      {!delivery ? (
        <>
          <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>
            Pick a delivered message — in the chat log, or from the list below — to see every hop it
            took, the link budget of each hand-over, and which relays MPR kept quiet.
          </div>
          {recent.length > 0 && (
            <div style={{ display: "flex", flexDirection: "column", gap: 4, marginTop: 10 }}>
              <div style={sectionStyle}>Recent deliveries</div>
              {recent
                .slice(-8)
                .reverse()
                .map((d) => (
                  <button key={`${d.msgId}-${d.to}-${d.attempt}`} onClick={() => onPick(d.msgId)} style={rowBtnStyle}>
                    <span style={{ color: "#4de0ff", fontFamily: "monospace", fontSize: 11 }}>{d.msgId}</span>
                    <span style={{ color: "#cfe0f2", fontSize: 12 }}>
                      {nameOf(d.from)} → {nameOf(d.to)}
                    </span>
                    <span style={{ color: "#9fb0c3", fontSize: 11, fontFamily: "monospace" }}>
                      {d.hops}h · {d.latencyMs.toFixed(0)}ms
                      {d.dtn ? " · DTN" : ""}
                      {d.attempt > 0 ? ` · retry ${d.attempt}` : ""}
                    </span>
                  </button>
                ))}
            </div>
          )}
        </>
      ) : (
        <>
          {/* The roadmap's own phrasing, computed rather than written by hand. */}
          <div style={{ fontSize: 13, color: "#eaf2ff", marginBottom: 4 }}>
            <b style={{ color: "#ffd666" }}>
              {relays.length === 0
                ? "Direct — no relay"
                : `via ${relays.length} node${relays.length === 1 ? "" : "s"}`}
            </b>
            {relays.length > 0 && (
              <span style={{ color: "#9fb0c3" }}>
                {" "}
                •{" "}
                {supers.length > 0
                  ? `SUPER ${supers.map((h) => nameOf(h.nodeId)).join(", ")}`
                  : "no SUPER on the path"}
              </span>
            )}
          </div>
          <div style={{ fontSize: 11, color: "#5a6a7a", marginBottom: 10, fontFamily: "monospace" }}>
            {delivery.msgId} · {nameOf(delivery.from)} → {nameOf(delivery.to)} · {delivery.type} ·{" "}
            {delivery.hops} hop{delivery.hops === 1 ? "" : "s"} · {delivery.latencyMs.toFixed(0)} ms
            {delivery.attempt > 0 ? ` · retry ${delivery.attempt}` : ""}
            {delivery.dtn ? " · store-carry-forward" : ""}
          </div>

          <div style={{ display: "flex", flexDirection: "column", gap: 5 }}>
            <HopRow
              index={0}
              id={delivery.from}
              name={nameOf(delivery.from)}
              role={roleOf(delivery.from)}
              delta={0}
              at={startMs}
              note="originator"
            />
            {chain.map((h, i) => {
              const prev = i === 0 ? startMs : chain[i - 1].atMs;
              return (
                <HopRow
                  key={`${h.nodeId}-${i}`}
                  index={i + 1}
                  id={h.nodeId}
                  name={nameOf(h.nodeId)}
                  role={roleOf(h.nodeId)}
                  delta={h.atMs - prev}
                  at={h.atMs}
                  rssi={h.rssi}
                  action={h.action}
                  reason={h.reason}
                />
              );
            })}
          </div>

          <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 10, lineHeight: 1.5 }}>
            {touched} node{touched === 1 ? "" : "s"} accepted a fresh copy of this message
            {suppressed > 0
              ? `; MPR kept ${suppressed} of them quiet because a relay they heard already covered their neighbours`
              : ""}
            . The chain above is the route the delivered copy actually took — the rest is the fan-out
            a flood makes on the way.
          </div>
        </>
      )}
    </div>
  );
}

function HopRow({
  index,
  name,
  role,
  delta,
  at,
  rssi,
  action,
  reason,
  note,
}: {
  index: number;
  id: NodeId;
  name: string;
  role: string;
  delta: number;
  at: number;
  rssi?: number;
  action?: string;
  reason?: string;
  note?: string;
}) {
  const style = action ? ACTION_STYLE[action] ?? ACTION_STYLE.received : undefined;
  const q = rssi === undefined ? 0 : Math.max(0, Math.min(1, (rssi + 95) / 40));
  return (
    <div style={hopRowStyle}>
      <span style={{ color: "#5a6a7a", fontFamily: "monospace", fontSize: 10, width: 14 }}>{index}</span>
      <span style={{ color: role === "SUPER" ? "#b6ff4a" : "#cfe0f2", fontSize: 12, minWidth: 74 }}>
        {name}
        {role === "SUPER" && " ★"}
      </span>
      {rssi !== undefined && (
        <span style={{ display: "flex", alignItems: "center", gap: 4, minWidth: 78 }}>
          <span style={{ width: 34, height: 4, borderRadius: 2, background: "#1e2a3a", overflow: "hidden", display: "block" }}>
            <span
              style={{
                display: "block",
                width: `${q * 100}%`,
                height: "100%",
                background: q > 0.6 ? "#b6ff4a" : q > 0.3 ? "#ffb84d" : "#ff4d6d",
              }}
            />
          </span>
          <span style={{ fontFamily: "monospace", fontSize: 10, color: "#9fb0c3" }}>
            {rssi.toFixed(0)} dBm
          </span>
        </span>
      )}
      <span style={{ fontFamily: "monospace", fontSize: 10, color: "#9fb0c3", minWidth: 62, textAlign: "right" }}>
        {note ?? `+${delta.toFixed(0)}ms`}
      </span>
      {style && (
        <span
          title={reason}
          style={{
            fontSize: 10,
            fontWeight: 700,
            padding: "2px 6px",
            borderRadius: 999,
            background: style.bg,
            color: style.fg,
            whiteSpace: "nowrap",
          }}
        >
          {action}
        </span>
      )}
      {reason && (
        <span style={{ fontSize: 10, color: "#5a6a7a", flex: 1, textAlign: "right" }} title={`t+${at.toFixed(0)}ms`}>
          {reason}
        </span>
      )}
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

const sectionStyle: React.CSSProperties = {
  fontSize: 11,
  color: "#9fb0c3",
  textTransform: "uppercase",
  letterSpacing: 1,
};

const hopRowStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 6,
  padding: "5px 8px",
  borderRadius: 6,
  background: "rgba(255,255,255,0.03)",
};

const rowBtnStyle: React.CSSProperties = {
  display: "flex",
  justifyContent: "space-between",
  alignItems: "center",
  gap: 8,
  padding: "6px 8px",
  borderRadius: 6,
  background: "rgba(255,255,255,0.03)",
  border: "1px solid #1e2a3a",
  cursor: "pointer",
  textAlign: "left",
  color: "#cfe0f2",
};

const linkBtnStyle: React.CSSProperties = {
  background: "none",
  border: "none",
  color: "#9fb0c3",
  cursor: "pointer",
  fontSize: 14,
  padding: 2,
};
