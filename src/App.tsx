import { useState, useEffect, useRef, useCallback } from "react";
import { MeshSimulation, DEFAULT_CONFIG, type SimConfig } from "./simulation";
import { MeshCanvas } from "./components/MeshCanvas";
import { StatsBar } from "./components/StatsBar";
import { NodeInspector } from "./components/NodeInspector";
import { ChatPanel } from "./components/ChatPanel";
import { ConfigPanel } from "./components/ConfigPanel";
import { LatencyChart } from "./components/LatencyChart";

export function App() {
  const simRef = useRef<MeshSimulation>(new MeshSimulation(DEFAULT_CONFIG));
  const [, forceUpdate] = useState({});
  const [isRunning, setIsRunning] = useState(false);
  const [speed, setSpeed] = useState(1000);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showLinks, setShowLinks] = useState(true);
  const [showRanges, setShowRanges] = useState(false);
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const rerender = useCallback(() => forceUpdate({}), []);

  useEffect(() => {
    const sim = simRef.current;
    const unsub = sim.subscribe(rerender);
    return unsub;
  }, [rerender]);

  useEffect(() => {
    if (isRunning) {
      intervalRef.current = setInterval(() => {
        simRef.current.step();
      }, speed);
      return () => {
        if (intervalRef.current) clearInterval(intervalRef.current);
      };
    }
  }, [isRunning, speed]);

  const sim = simRef.current;
  const selectedNode = selectedId ? sim.nodes.find((n) => n.id === selectedId) ?? null : null;

  const handleConfigChange = (config: Partial<SimConfig>) => {
    sim.reset(config);
    setIsRunning(false);
  };

  const handleSend = (
    from: string,
    to: string | "BROADCAST",
    body: string,
    type: "text" | "broadcast" | "sos"
  ) => {
    sim.sendMessage(from, to, body, type);
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
        maxWidth: 1400, margin: "0 auto", padding: "20px 24px 8px",
        display: "flex", alignItems: "center", gap: 14, justifyContent: "space-between",
        flexWrap: "wrap",
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
            <h1 style={{ margin: 0, fontSize: 20, fontWeight: 800 }}>
              Duman Mesh Simulator
            </h1>
            <div style={{ fontSize: 12, color: "#9fb0c3", marginTop: 2 }}>
              BATMAN-lite routing · Super-Node election · DTN store-carry-forward · CRDT sync
            </div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          <span style={badgeStyle}>Flutter + Native (reference impl)</span>
          <span style={{ ...badgeStyle, borderColor: "rgba(182,255,74,0.4)" }}>Live Simulation</span>
        </div>
      </header>

      <div style={{
        maxWidth: 1400, margin: "0 auto", padding: "12px 24px 40px",
        display: "grid",
        gridTemplateColumns: "1fr 320px",
        gap: 16,
      }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <StatsBar
            stats={sim.stats}
            isRunning={isRunning}
            onToggleRun={() => setIsRunning(!isRunning)}
            onStep={() => sim.step()}
            onReset={() => { sim.reset(); setIsRunning(false); setSelectedId(null); }}
            speed={speed}
            onSpeedChange={setSpeed}
          />

          <div style={{
            borderRadius: 14, border: "1px solid #1e2a3a", overflow: "hidden",
            background: "rgba(17, 24, 35, 0.5)",
            display: "flex", justifyContent: "center", padding: 8,
          }}>
            <MeshCanvas
              nodes={sim.nodes}
              config={sim.config}
              selectedId={selectedId}
              onSelect={setSelectedId}
              showLinks={showLinks}
              showRanges={showRanges}
            />
          </div>

          <div style={{
            display: "grid", gridTemplateColumns: "1fr 1fr", gap: 16,
          }}>
            <div style={{ height: 360 }}>
              <ChatPanel
                nodes={sim.nodes}
                selectedNodeId={selectedId}
                onSendMessage={handleSend}
                deliveries={sim.deliveries}
              />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
              <LatencyChart deliveries={sim.deliveries} maxPoints={40} />
              <div style={{
                padding: 14, borderRadius: 14, border: "1px solid #1e2a3a",
                background: "rgba(17, 24, 35, 0.95)",
              }}>
                <div style={{ fontSize: 11, color: "#9fb0c3", textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>
                  Legend
                </div>
                <div style={{ display: "flex", flexDirection: "column", gap: 6, fontSize: 12, color: "#cfe0f2" }}>
                  <LegendItem color="#b6ff4a" label="SUPER node (continuous scan, relay-all, WiFi GO)" />
                  <LegendItem color="#4de0ff" label="NORMAL node (duty-cycled, MPR lazy relay)" />
                  <LegendItem color="#3a4a5a" label="Offline / battery dead" />
                  <LegendItem color="rgba(182,255,74,0.35)" label="SUPER relay link" />
                  <LegendItem color="rgba(77,224,255,0.18)" label="Normal peer link" />
                </div>
              </div>
            </div>
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
          />
          <NodeInspector
            node={selectedNode}
            allNodes={sim.nodes}
            onToggleOnline={(id) => sim.toggleNodeOnline(id)}
            onToggleCharging={(id) => sim.setNodeCharging(id, !sim.nodes.find((n) => n.id === id)?.charging)}
            onClose={() => setSelectedId(null)}
          />
        </div>
      </div>

      <footer style={{
        textAlign: "center", padding: "16px 24px 32px", fontSize: 12, color: "#5a6a7a",
      }}>
        Duman Messenger — Serverless Offline Mesh · This simulator implements the Duman Adaptive Routing
        algorithm from docs/03-smart-router-algorithm.md · Click any node to inspect its state
      </footer>
    </div>
  );
}

const badgeStyle: React.CSSProperties = {
  fontSize: 11,
  border: "1px solid #1e2a3a",
  background: "rgba(255,255,255,0.04)",
  padding: "6px 10px",
  borderRadius: 999,
  color: "#9fb0c3",
};

function LegendItem({ color, label }: { color: string; label: string }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
      <div style={{ width: 10, height: 10, borderRadius: "50%", background: color, flexShrink: 0 }} />
      <span>{label}</span>
    </div>
  );
}
