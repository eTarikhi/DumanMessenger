import type { Group, MeshNode } from "../types";
import type { RfParams } from "../rf";
import { peersInRange, rssiModel, normRssi } from "../rf";
import { TQ_USABLE } from "../election";

interface Props {
  node: MeshNode | null;
  allNodes: MeshNode[];
  rf: RfParams;
  /** Whether the duty cycle is running — otherwise "asleep" is meaningless. */
  dutyCycleEnabled: boolean;
  /** Is this node inside its scan window right now (SUPER nodes always are). */
  awake: boolean;
  onToggleOnline: (id: string) => void;
  onToggleCharging: (id: string) => void;
  onToggleSuperOptOut: (id: string) => void;
  onToggleBatterySaver: (id: string) => void;
  onClose: () => void;
  /** Group channels this node may belong to (roadmap Phase 1 / Phase 4 Group UX). */
  groups?: Group[];
  onCreateGroup?: (nodeId: string) => void;
  onInviteNearest?: (groupId: string, nodeId: string) => void;
  onLeaveGroup?: (groupId: string, nodeId: string) => void;
  onRotateKey?: (groupId: string, nodeId: string) => void;
}

export function NodeInspector({
  node,
  allNodes,
  rf,
  dutyCycleEnabled,
  awake,
  onToggleOnline,
  onToggleCharging,
  onToggleSuperOptOut,
  onToggleBatterySaver,
  groups,
  onCreateGroup,
  onInviteNearest,
  onLeaveGroup,
  onRotateKey,
  onClose,
}: Props) {
  if (!node) return null;

  const peers = peersInRange(node, allNodes, rf);
  const routeEntries = Object.entries(node.nextHopTable);
  const usableRoutes = routeEntries.filter(([, e]) => e.tq >= TQ_USABLE);

  const myGroups = (groups ?? []).filter((g) => g.members.has(node.id));
  const byDistance = (ids: string[]) =>
    ids
      .map((id) => allNodes.find((n) => n.id === id))
      .filter((n): n is MeshNode => !!n && n.isOnline)
      .sort(
        (a, b) =>
          (a.pos.x - node.pos.x) ** 2 +
          (a.pos.y - node.pos.y) ** 2 -
          ((b.pos.x - node.pos.x) ** 2 + (b.pos.y - node.pos.y) ** 2)
      );
  const nearestOutsider = (g: Group) =>
    byDistance(allNodes.filter((n) => !g.members.has(n.id)).map((n) => n.id))[0];
  const groupButton: React.CSSProperties = {
    flex: 1, padding: "5px 8px", borderRadius: 7, cursor: "pointer",
    border: "1px solid #1e2a3a", fontSize: 10.5, fontWeight: 600,
    background: "rgba(38,208,168,0.10)", color: "#26d0a8",
  };
  const disabledButton: React.CSSProperties = { ...groupButton, opacity: 0.35, cursor: "not-allowed" };

  return (
    <div style={panelStyle}>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 800, color: "#eaf2ff" }}>{node.name}</div>
          <div style={{ fontSize: 11, color: "#9fb0c3", fontFamily: "monospace" }}>{node.id}</div>
        </div>
        <button onClick={onClose} aria-label="Close inspector" style={{
          background: "none", border: "none", color: "#9fb0c3", cursor: "pointer", fontSize: 18, padding: 4,
        }}>✕</button>
      </div>

      <div style={{
        display: "inline-block", padding: "4px 10px", borderRadius: 999,
        fontSize: 11, fontWeight: 700, marginBottom: 12,
        ...(node.role === "SUPER"
          ? { background: "#b6ff4a", color: "#0b1a00" }
          : { background: "rgba(255,184,77,0.15)", color: "#ffb84d", border: "1px solid rgba(255,184,77,0.3)" }),
      }}>
        {node.role === "SUPER" ? "SUPER NODE" : "NORMAL"}
        {!node.isOnline && " • OFFLINE"}
        {node.isOnline && dutyCycleEnabled && (awake ? " • AWAKE" : " • ASLEEP")}
        {node.superOptOut && " • ROUTER DECLINED"}
      </div>

      <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 14, lineHeight: 1.5 }}>
        {node.reasonTrace}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginBottom: 14 }}>
        <Metric label="Battery" value={`${(node.battery * 100).toFixed(0)}%`}
          color={node.battery > 0.4 ? "#b6ff4a" : node.battery > 0.25 ? "#ffb84d" : "#ff4d6d"} />
        <Metric label="Coverage score" value={node.score.toFixed(3)} color="#8b7dff" />
        <Metric label="Peers" value={`${peers.length}`} color="#4de0ff" />
        <Metric label="Avg RSSI" value={`${node.avgRssi.toFixed(0)} dBm`} color="#4de0ff" />
        <Metric label="Uptime" value={`${node.uptimeMin.toFixed(1)} min`} color="#eaf2ff" />
        <Metric label="PDR (last 20)" value={`${(node.pdr * 100).toFixed(0)}%`} color="#eaf2ff" />
        <Metric label="Mobility" value={node.mobility.toFixed(2)} color="#eaf2ff" />
        <Metric label="Charging" value={node.charging ? "Yes" : "No"} color={node.charging ? "#b6ff4a" : "#9fb0c3"} />
        <Metric
          label="Router role"
          value={node.superOptOut ? "Opted out" : node.batterySaver ? "Saver" : "Available"}
          color={node.superOptOut || node.batterySaver ? "#ffb84d" : "#b6ff4a"}
        />
        <Metric
          label={dutyCycleEnabled ? "Duty state" : "Duty cycle"}
          value={
            dutyCycleEnabled
              ? node.role === "SUPER"
                ? "Continuous"
                : awake
                  ? "Scanning"
                  : "Asleep"
              : "Off"
          }
          color={dutyCycleEnabled && !awake && node.role !== "SUPER" ? "#8b7dff" : "#4de0ff"}
        />
        <Metric label="Tx packets" value={`${node.txCount}`} color="#4de0ff" />
        <Metric label="MPR suppressed" value={`${node.mprSuppressed}`} color="#b6ff4a" />
        <Metric label="Role changes" value={`${node.roleTransitions}`} color="#ffb84d" />
        <Metric label="Position" value={`${node.pos.x.toFixed(0)}, ${node.pos.y.toFixed(0)} m`} color="#eaf2ff" />
      </div>

      <Section title={`Peers in range (${peers.length})`}>
        {peers.length === 0 && <Empty>No peers in range</Empty>}
        {peers.map((p) => {
          const rssi = rssiModel(node, p, rf);
          const q = normRssi(rssi);
          return (
            <div key={p.id} style={rowStyle}>
              <span style={{ color: p.role === "SUPER" ? "#b6ff4a" : "#cfe0f2", minWidth: 96 }}>
                {p.name} {p.role === "SUPER" && "★"}
              </span>
              <span style={{ color: "#9fb0c3", fontFamily: "monospace", minWidth: 62, textAlign: "right" }}>
                {rssi.toFixed(0)} dBm
              </span>
              <div style={{ width: 40, height: 4, borderRadius: 2, background: "#1e2a3a", overflow: "hidden" }}>
                <div style={{
                  width: `${q * 100}%`, height: "100%",
                  background: q > 0.6 ? "#b6ff4a" : q > 0.3 ? "#ffb84d" : "#ff4d6d",
                }} />
              </div>
            </div>
          );
        })}
      </Section>

      <Section title={`Routing table (${usableRoutes.length}/${routeEntries.length} usable)`}>
        {routeEntries.length === 0 && <Empty>No routes known</Empty>}
        {routeEntries
          .sort((a, b) => a[1].hopCount - b[1].hopCount || (a[0] < b[0] ? -1 : 1))
          .slice(0, 12)
          .map(([dest, entry]) => (
            <div key={dest} style={{ ...rowStyle, fontFamily: "monospace", fontSize: 11 }}>
              <span style={{ minWidth: 62 }}>{dest}</span>
              <span style={{ color: "#9fb0c3", minWidth: 76 }}>via {entry.bestNeighbor}</span>
              <span style={{ color: "#9fb0c3", minWidth: 40 }}>{entry.hopCount}h</span>
              <span style={{ color: entry.tq >= TQ_USABLE ? "#b6ff4a" : "#ffb84d" }}>
                tq={entry.tq.toFixed(2)}
              </span>
            </div>
          ))}
      </Section>

      <Section title={`DTN queue (${node.oppQueue.length})`}>
        {node.oppQueue.length === 0 ? (
          <Empty>Queue empty</Empty>
        ) : (
          node.oppQueue.slice(0, 6).map((q) => (
            <div key={q.msg.id} style={{
              fontSize: 11, color: "#ff4d6d", fontFamily: "monospace",
              padding: "3px 6px", background: "rgba(255,77,109,0.08)", borderRadius: 4,
            }}>
              {q.msg.id} → {q.msg.to} (spray {q.copyCount}/3)
            </div>
          ))
        )}
      </Section>

      <Section title={`Inbox (${node.inbox.length})`}>
        {node.inbox.length === 0 ? (
          <Empty>No messages</Empty>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 3, maxHeight: 132, overflowY: "auto" }}>
            {node.inbox.slice(-8).map((m) => (
              <div key={m.id} style={{
                fontSize: 11, color: "#cfe0f2", padding: "4px 8px",
                background: "rgba(77,224,255,0.06)", borderRadius: 6,
              }}>
                <span style={{ color: "#4de0ff" }}>{m.from}</span>: {m.body.slice(0, 40)}
                <span style={{ color: "#5a6a7a", marginLeft: 4 }}>({m.hopCount}h · {m.type})</span>
              </div>
            ))}
          </div>
        )}
      </Section>

      <div style={{ display: "flex", gap: 8, marginTop: 16 }}>
        <button onClick={() => onToggleOnline(node.id)} style={{
          flex: 1, padding: "8px 12px", borderRadius: 8, cursor: "pointer",
          border: "1px solid #1e2a3a", fontSize: 12, fontWeight: 600,
          background: node.isOnline ? "rgba(255,77,109,0.1)" : "rgba(182,255,74,0.1)",
          color: node.isOnline ? "#ff4d6d" : "#b6ff4a",
        }}>
          {node.isOnline ? "Take offline" : "Bring online"}
        </button>
        <button onClick={() => onToggleCharging(node.id)} style={{
          flex: 1, padding: "8px 12px", borderRadius: 8, cursor: "pointer",
          border: "1px solid #1e2a3a", fontSize: 12, fontWeight: 600,
          background: node.charging ? "rgba(255,184,77,0.1)" : "rgba(255,255,255,0.04)",
          color: node.charging ? "#ffb84d" : "#eaf2ff",
        }}>
          {node.charging ? "Unplug" : "Plug in ⚡"}
        </button>
      </div>

      {/* skills/02 acceptance: "SUPER opt-out respected; NORMAL never
          auto-promoted if battery saver on". Both are user-visible switches on
          a real device, so they are user-visible here too. */}
      <div style={{ display: "flex", gap: 8, marginTop: 8 }}>
        <button onClick={() => onToggleSuperOptOut(node.id)} aria-pressed={node.superOptOut} style={{
          flex: 1, padding: "8px 12px", borderRadius: 8, cursor: "pointer",
          border: "1px solid #1e2a3a", fontSize: 12, fontWeight: 600,
          background: node.superOptOut ? "rgba(255,184,77,0.15)" : "rgba(255,255,255,0.04)",
          color: node.superOptOut ? "#ffb84d" : "#eaf2ff",
        }}>
          {node.superOptOut ? "Accept router role" : "Decline router role"}
        </button>
        <button onClick={() => onToggleBatterySaver(node.id)} aria-pressed={node.batterySaver} style={{
          flex: 1, padding: "8px 12px", borderRadius: 8, cursor: "pointer",
          border: "1px solid #1e2a3a", fontSize: 12, fontWeight: 600,
          background: node.batterySaver ? "rgba(255,77,109,0.15)" : "rgba(255,255,255,0.04)",
          color: node.batterySaver ? "#ff4d6d" : "#eaf2ff",
        }}>
          {node.batterySaver ? "Battery saver on" : "Battery saver off"}
        </button>
      </div>
      <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
        Declining takes effect at once — no two-cycle hysteresis — and is advertised in this node's
        OGM so neighbours stop counting it as a top-20% candidate.
      </div>

      {/* roadmap Phase 1 "group (3-10 members)" and Phase 4 "Group UX: admin rotate
          key, leave/rejoin sync". Membership is per-node state, so it lives here
          rather than in the config panel. */}
      <div style={{ marginTop: 14, borderTop: "1px solid #1e2a3a", paddingTop: 10 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: "#26d0a8", letterSpacing: 0.4 }}>
          👥 Groups
        </div>
        {myGroups.length === 0 && (
          <div style={{ fontSize: 11, color: "#5a6a7a", marginTop: 4 }}>Not a member of any group.</div>
        )}
        {myGroups.map((g) => {
          const outsider = nearestOutsider(g);
          return (
            <div
              key={g.id}
              style={{ marginTop: 8, border: "1px solid #1e2a3a", borderRadius: 8, padding: 8 }}
            >
              <div style={{ fontSize: 12, color: "#eaf2ff", fontWeight: 600 }}>
                {g.name}
                <span style={{ color: "#5a6a7a", fontWeight: 400, marginLeft: 6 }}>
                  {g.members.size}/10 · epoch {g.keyEpoch}
                  {g.adminId === node.id ? " · you are admin" : ""}
                </span>
              </div>
              <div style={{ fontSize: 10, color: "#9fb0c3", marginTop: 3, fontFamily: "monospace" }}>
                {byDistance([...g.members])
                  .map((n) => (n.id === node.id ? `${n.name} (you)` : n.name))
                  .join(", ")}
              </div>
              <div style={{ display: "flex", gap: 6, marginTop: 6 }}>
                <button
                  onClick={() => onRotateKey?.(g.id, node.id)}
                  disabled={g.adminId !== node.id}
                  style={g.adminId === node.id ? groupButton : disabledButton}
                  title="Only the admin may rotate the group key"
                >
                  Rotate key
                </button>
                <button
                  onClick={() => outsider && onInviteNearest?.(g.id, node.id)}
                  disabled={g.members.size >= 10 || !outsider}
                  style={g.members.size < 10 && outsider ? groupButton : disabledButton}
                  title={outsider ? `Invite ${outsider.name}, the nearest non-member` : "Group is full"}
                >
                  Invite nearest
                </button>
                <button
                  onClick={() => onLeaveGroup?.(g.id, node.id)}
                  disabled={g.members.size <= 3}
                  style={g.members.size > 3 ? groupButton : disabledButton}
                  title="A group cannot drop below three members"
                >
                  Leave
                </button>
              </div>
            </div>
          );
        })}
        <button
          onClick={() => onCreateGroup?.(node.id)}
          disabled={peers.length < 2}
          style={{ ...groupButton, flex: "none", width: "100%", marginTop: 8, padding: "7px 10px" }}
          title="Group with this node and its four nearest online peers"
        >
          New group with 4 nearest peers
        </button>
        <div style={{ fontSize: 10, color: "#5a6a7a", marginTop: 6, lineHeight: 1.5 }}>
          Every membership change rotates the group key (docs/04 §4), so a node that leaves keeps
          relaying group traffic but can no longer read it, and a node that joins cannot read the
          history it missed. Below three members a group is a 1:1 chat, so leaving is refused.
        </div>
      </div>
    </div>
  );
}

const panelStyle: React.CSSProperties = {
  padding: 16, borderRadius: 14, border: "1px solid #1e2a3a",
  background: "rgba(17, 24, 35, 0.95)", backdropFilter: "blur(8px)",
  maxHeight: "100%", overflowY: "auto",
};

const rowStyle: React.CSSProperties = {
  display: "flex", justifyContent: "space-between", alignItems: "center", gap: 6,
  padding: "6px 8px", borderRadius: 6, background: "rgba(255,255,255,0.03)", fontSize: 12,
};

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={{ marginBottom: 14 }}>
      <div style={{ fontSize: 11, color: "#9fb0c3", marginBottom: 6, textTransform: "uppercase", letterSpacing: 1 }}>
        {title}
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>{children}</div>
    </div>
  );
}

function Empty({ children }: { children: React.ReactNode }) {
  return <div style={{ fontSize: 12, color: "#5a6a7a", fontStyle: "italic" }}>{children}</div>;
}

function Metric({ label, value, color }: { label: string; value: string; color: string }) {
  return (
    <div style={{ padding: "8px 10px", borderRadius: 8, background: "rgba(255,255,255,0.03)", border: "1px solid #1e2a3a" }}>
      <div style={{ fontSize: 14, fontWeight: 700, color }}>{value}</div>
      <div style={{ fontSize: 10, color: "#9fb0c3", marginTop: 2 }}>{label}</div>
    </div>
  );
}
