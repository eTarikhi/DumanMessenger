import { useCallback, useEffect, useRef, useState } from "react";
import { DEFAULT_CONFIG, MeshSimulation, type SimConfig } from "./simulation";
import type { MeshMessage } from "./types";
import { MeshCanvas } from "./components/MeshCanvas";
import { StatsBar } from "./components/StatsBar";
import { NodeInspector } from "./components/NodeInspector";
import { ChatPanel } from "./components/ChatPanel";
import { ConfigPanel } from "./components/ConfigPanel";
import { LatencyChart } from "./components/LatencyChart";
import { MetricsPanel } from "./components/MetricsPanel";
import { MessageTrace } from "./components/MessageTrace";
import { MeshLogPanel } from "./components/MeshLogPanel";
import { deliveredChain } from "./simulation";

export function App() {
  const simRef = useRef<MeshSimulation | null>(null);
  if (simRef.current === null) simRef.current = new MeshSimulation(DEFAULT_CONFIG);
  const sim = simRef.current;

  const [frame, setFrame] = useState(0);
  const [isRunning, setIsRunning] = useState(false);
  const [speed, setSpeed] = useState(500);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showLinks, setShowLinks] = useState(true);
  const [showRanges, setShowRanges] = useState(false);
  const [autoTraffic, setAutoTraffic] = useState(false);
  /** The message whose hop-by-hop route is drawn on the canvas and explained in
   *  the trace panel (roadmap Phase 4). */
  const [traceMsgId, setTraceMsgId] = useState<string | null>(null);
  // Capture is a config flag, not a world parameter: flipping it must not throw
  // the run away, so it mutates the live config instead of calling reset().
  const [captureLog, setCaptureLog] = useState(false);
  const [captureOgm, setCaptureOgm] = useState(false);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const rerender = useCallback(() => setFrame((f) => f + 1), []);

  useEffect(() => sim.subscribe(rerender), [sim, rerender]);

  useEffect(() => {
    if (!isRunning) return;
    intervalRef.current = setInterval(() => sim.step(), speed);
    return () => {
      if (intervalRef.current) clearInterval(intervalRef.current);
    };
  }, [sim, isRunning, speed]);

  useEffect(() => {
    sim.reset({ trafficIntervalMs: autoTraffic ? 1500 : 0 });
    setIsRunning(false);
  }, [sim, autoTraffic]);

  const selectedNode = selectedId ? sim.nodes.find((n) => n.id === selectedId) ?? null : null;

  // A broadcast has one delivery record per recipient; trace the first, since
  // its route is a tree rather than a chain either way.
  const tracedDelivery = traceMsgId
    ? sim.deliveries.find((d) => d.msgId === traceMsgId) ?? null
    : null;
  const traceIds = tracedDelivery
    ? [
        tracedDelivery.from,
        ...deliveredChain(tracedDelivery.hopTrace, tracedDelivery.to).map((h) => h.nodeId),
      ]
    : undefined;

  const handleConfigChange = (config: Partial<SimConfig>) => {
    sim.reset(config);
    setSelectedId(null);
    setTraceMsgId(null);
    setIsRunning(false);
  };

  const handleNewSeed = () => {
    sim.reset({ seed: Math.floor(Math.random() * 9999) + 1 });
    setSelectedId(null);
    setTraceMsgId(null);
    setIsRunning(false);
  };

  const handleToggleCapture = () => {
    const next = !captureLog;
    sim.config.captureLog = next;
    setCaptureLog(next);
    if (!next) sim.config.captureOgm = false;
    setCaptureOgm(next ? captureOgm : false);
    if (!next) sim.log = [];
    rerender();
  };

  // --- group channels (roadmap Phase 1 "group (3-10 members)", Phase 4 Group UX)
  /** Online nodes nearest to `nodeId`, optionally skipping a set (e.g. members). */
  const nearestIds = (nodeId: string, count: number, exclude?: Set<string>): string[] => {
    const node = sim.nodes.find((n) => n.id === nodeId);
    if (!node) return [];
    return sim.nodes
      .filter((n) => n.isOnline && n.id !== nodeId && !(exclude && exclude.has(n.id)))
      .sort(
        (a, b) =>
          (a.pos.x - node.pos.x) ** 2 +
          (a.pos.y - node.pos.y) ** 2 -
          ((b.pos.x - node.pos.x) ** 2 + (b.pos.y - node.pos.y) ** 2)
      )
      .slice(0, count)
      .map((n) => n.id);
  };

  const handleCreateGroup = (nodeId: string) => {
    const node = sim.nodes.find((n) => n.id === nodeId);
    sim.createGroup(`${node?.name ?? nodeId}'s team`, [nodeId, ...nearestIds(nodeId, 4)], nodeId);
    rerender();
  };

  const handleInviteNearest = (groupId: string, nodeId: string) => {
    const group = sim.groups.get(groupId);
    if (!group) return;
    const [next] = nearestIds(nodeId, 1, group.members);
    if (next) sim.inviteToGroup(groupId, next);
    rerender();
  };

  const handleLeaveGroup = (groupId: string, nodeId: string) => {
    sim.removeFromGroup(groupId, nodeId);
    rerender();
  };

  const handleRotateKey = (groupId: string, nodeId: string) => {
    sim.rotateGroupKey(groupId, nodeId);
    rerender();
  };

  /** Live protocol switch, like capture: flipping it must not throw the world away,
   *  or every group the user built would vanish with it. */
  const handleToggleGroupMode = () => {
    sim.config.groupMode =
      sim.config.groupMode === "scoped-flood" ? "per-member-unicast" : "scoped-flood";
    rerender();
  };

  /** A file goes out as 64 KB chunks behind a sliding window; a voice note as 500 ms
   *  Opus frames while the button is held (roadmap Phase 3, docs/08). */
  const handleSendFile = (from: string, to: string, megabytes: number) => {
    sim.sendFile(from, to, Math.round(megabytes * 1048576));
    rerender();
  };

  const handleSendVoice = (from: string, to: string, seconds: number, stream: boolean) => {
    sim.sendVoice(from, to, seconds, { stream });
    rerender();
  };

  const handleToggleOgm = () => {
    const next = !captureOgm;
    sim.config.captureOgm = next;
    setCaptureOgm(next);
    rerender();
  };

  const handleSend = (
    from: string,
    to: string | "BROADCAST",
    body: string,
    type: "text" | "broadcast" | "sos"
  ): MeshMessage | null => {
    const msg = sim.sendMessage(from, to, body, type);
    sim.refresh();
    rerender();
    return msg;
  };

  const handleRandomBroadcast = () => {
    const online = sim.nodes.filter((n) => n.isOnline);
    if (online.length === 0) return;
    const sender = online[Math.floor(Math.random() * online.length)];
    const bodies = ["Hello mesh!", "Anyone there?", "Test broadcast", "Mesh check", "Ping all"];
    sim.sendMessage(sender.id, "BROADCAST", bodies[Math.floor(Math.random() * bodies.length)], "broadcast");
    sim.refresh();
    rerender();
  };

  const handleRandomDM = () => {
    sim.injectRandomMessage();
    sim.refresh();
    rerender();
  };

  return (
    <div style={{
      minHeight: "100vh",
      background: "radial-gradient(1200px 600px at 70% -10%, #1b2a41 0%, #0b0f14 55%) fixed",
      color: "#eaf2ff",
      fontFamily: "Inter, ui-sans-serif, system-ui, -apple-system, sans-serif",
    }}>
      <header style={{
        maxWidth: 1440, margin: "0 auto", padding: "20px 24px 8px",
        display: "flex", alignItems: "center", gap: 14, justifyContent: "space-between", flexWrap: "wrap",
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
          <div style={{
            width: 44, height: 44, borderRadius: 12,
            background: "linear-gradient(135deg, #4de0ff, #8b7dff)",
            display: "grid", placeItems: "center",
            fontWeight: 900, fontSize: 18, color: "#001019",
            boxShadow: "0 8px 28px rgba(77,224,255,0.35)",
          }}>DM</div>
          <div>
            <h1 style={{ margin: 0, fontSize: 20, fontWeight: 800 }}>Duman Mesh Simulator</h1>
            <p role="note" style={{ margin: "4px 0", color: "#ffd28a", fontSize: 12 }}>
              Simulation only — synthetic data. No real radios, encryption or saved messages. Do not enter secrets.
            </p>
            <div style={{ fontSize: 12, color: "#9fb0c3", marginTop: 2 }}>
              BATMAN-lite routing · coverage-score super-node election · MPR flood suppression ·
              DTN store-carry-forward
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <span style={badgeStyle}>Discrete-event · seeded · virtual clock</span>
          <span style={{ ...badgeStyle, borderColor: "rgba(182,255,74,0.4)" }}>
            seed {sim.config.seed}
          </span>
        </div>
      </header>

      <div className="duman-main-grid" style={{
        maxWidth: 1440, margin: "0 auto", padding: "12px 24px 40px",
        display: "grid", gridTemplateColumns: "1fr 330px", gap: 16,
      }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <StatsBar
            stats={sim.stats}
            isRunning={isRunning}
            onToggleRun={() => setIsRunning(!isRunning)}
            onStep={() => sim.step()}
            onReset={() => {
              sim.reset();
              setIsRunning(false);
              setSelectedId(null);
              setTraceMsgId(null);
            }}
            onNewSeed={handleNewSeed}
            speed={speed}
            onSpeedChange={setSpeed}
          />

          <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            <button onClick={handleRandomBroadcast} style={quickBtnStyle}>📡 Random broadcast</button>
            <button onClick={handleRandomDM} style={quickBtnStyle}>💬 Random DM</button>
            <span style={{ fontSize: 11, color: "#5a6a7a", alignSelf: "center" }}>
              Relay policy: <b style={{ color: "#9fb0c3" }}>{sim.config.relayPolicy}</b>
            </span>
          </div>

          <div className="duman-canvas-wrap" style={{
            borderRadius: 14, border: "1px solid #1e2a3a", overflow: "hidden",
            background: "rgba(17, 24, 35, 0.5)", display: "flex", justifyContent: "center", padding: 8,
          }}>
            <MeshCanvas
              nodes={sim.nodes}
              config={sim.config}
              rf={sim.rf}
              selectedId={selectedId}
              onSelect={setSelectedId}
              showLinks={showLinks}
              showRanges={showRanges}
              traceIds={traceIds}
              frame={frame}
            />
          </div>

          <MetricsPanel
              stats={sim.stats}
              dutyCycleEnabled={sim.config.dutyCycleEnabled}
              nodes={sim.nodes}
              config={sim.config}
            />

          <div className="duman-chat-grid" style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
            <div style={{ height: 380 }}>
              <ChatPanel
                nodes={sim.nodes}
                selectedNodeId={selectedId}
                onSendMessage={handleSend}
                sentRecords={sim.sentRecords}
                deliveries={sim.deliveries}
                onTrace={(msgId) => {
                  setTraceMsgId(msgId);
                  rerender();
                }}
                traceMsgId={traceMsgId}
                sosRepeats={sim.config.sosRepeats}
                groups={[...sim.groups.values()]}
                groupMode={sim.config.groupMode}
                onToggleGroupMode={handleToggleGroupMode}
                onSendFile={handleSendFile}
                onSendVoice={handleSendVoice}
                transfers={[...sim.transfers.values()]}
              />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <LatencyChart deliveries={sim.deliveries} maxPoints={40} />
              <div style={{
                padding: 14, borderRadius: 14, border: "1px solid #1e2a3a",
                background: "rgba(17, 24, 35, 0.95)",
              }}>
                <div style={legendHeaderStyle}>Legend</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 12, color: "#cfe0f2" }}>
                  <LegendItem color="#b6ff4a" label="SUPER — continuous scan, relay-all, Wi-Fi GO" />
                  <LegendItem color="#4de0ff" label="NORMAL — duty-cycled, MPR lazy relay" />
                  <LegendItem color="#3a4a5a" label="Offline / battery dead" />
                  <LegendItem color="rgba(120,130,150,0.5)" label="Building (−12 dB per wall crossed)" />
                  <LegendItem color="rgba(182,255,74,0.35)" label="Link touching a SUPER" />
                  <LegendItem color="rgba(77,224,255,0.18)" label="Normal peer link" />
                  <LegendItem color="#ffd666" label="Traced route — the hops one delivered message took" />
                </div>
              </div>
            </div>
          </div>
          <div className="duman-chat-grid" style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16 }}>
            <MessageTrace
              delivery={tracedDelivery}
              nodes={sim.nodes}
              recent={sim.deliveries}
              onPick={(msgId) => {
                setTraceMsgId(msgId);
                rerender();
              }}
              onClear={() => {
                setTraceMsgId(null);
                rerender();
              }}
            />
            <MeshLogPanel
              entries={sim.log}
              captureLog={captureLog}
              captureOgm={captureOgm}
              onToggleCapture={handleToggleCapture}
              onToggleOgm={handleToggleOgm}
              nodes={sim.nodes}
              focusMsgId={traceMsgId}
            />
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <ConfigPanel
            config={sim.config}
            onChange={handleConfigChange}
            showLinks={showLinks}
            showRanges={showRanges}
            onToggleLinks={() => setShowLinks(!showLinks)}
            onToggleRanges={() => setShowRanges(!showRanges)}
            autoTraffic={autoTraffic}
            onToggleAutoTraffic={() => setAutoTraffic(!autoTraffic)}
          />
          <NodeInspector
            node={selectedNode}
            allNodes={sim.nodes}
            rf={sim.rf}
            dutyCycleEnabled={sim.config.dutyCycleEnabled}
            awake={selectedNode ? sim.isAwake(selectedNode) : true}
            onToggleOnline={(id) => sim.toggleNodeOnline(id)}
            onToggleCharging={(id) => {
              const n = sim.nodes.find((x) => x.id === id);
              if (n) sim.setNodeCharging(id, !n.charging);
            }}
            onToggleSuperOptOut={(id) => {
              const n = sim.nodes.find((x) => x.id === id);
              if (n) sim.setSuperOptOut(id, !n.superOptOut);
            }}
            onToggleBatterySaver={(id) => {
              const n = sim.nodes.find((x) => x.id === id);
              if (n) sim.setBatterySaver(id, !n.batterySaver);
            }}
            blockedPeers={selectedNode ? sim.blockedPeers(selectedNode.id) : []}
            onToggleBlock={(peerId) => {
              // docs/04 §6's local block, from the inspector. One-way and local: this node
              // stops accepting that peer's messages and nothing else changes — the peer
              // keeps hearing this one, and SOS, beacons and ACKs still get through, because
              // blocking those would make the blocked peer retransmit forever (docs/06 §22).
              if (!selectedNode) return;
              if (sim.isBlocked(selectedNode.id, peerId)) {
                sim.unblockPeer(selectedNode.id, peerId);
              } else {
                sim.blockPeer(selectedNode.id, peerId);
              }
            }}
            groups={[...sim.groups.values()]}
            onCreateGroup={handleCreateGroup}
            onInviteNearest={handleInviteNearest}
            onLeaveGroup={handleLeaveGroup}
            onRotateKey={handleRotateKey}
            onClose={() => setSelectedId(null)}
          />
        </div>
      </div>

      <footer style={{ textAlign: "center", padding: "16px 24px 32px", fontSize: 12, color: "#5a6a7a" }}>
        Duman Messenger — serverless offline mesh. This simulator implements the Duman Adaptive
        Routing algorithm from <code>docs/03-smart-router-algorithm.md</code>; the authoritative
        headless engine lives in <code>sim/mesh_sim</code> (Dart). Click any node to inspect its state.
      </footer>
    </div>
  );
}

const quickBtnStyle: React.CSSProperties = {
  padding: "8px 14px", borderRadius: 8, border: "1px solid #1e2a3a",
  background: "rgba(255,255,255,0.04)", color: "#cfe0f2", fontWeight: 600, fontSize: 12, cursor: "pointer",
};

const badgeStyle: React.CSSProperties = {
  fontSize: 11, border: "1px solid #1e2a3a", background: "rgba(255,255,255,0.04)",
  padding: "6px 10px", borderRadius: 999, color: "#9fb0c3",
};

const legendHeaderStyle: React.CSSProperties = {
  fontSize: 11, color: "#9fb0c3", textTransform: "uppercase", letterSpacing: 1, marginBottom: 8,
};

function LegendItem({ color, label }: { color: string; label: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <div style={{ width: 10, height: 10, borderRadius: "50%", background: color, flexShrink: 0 }} />
      <span>{label}</span>
    </div>
  );
}
