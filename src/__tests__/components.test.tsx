import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { MeshSimulation, deliveredChain, type SimConfig } from "../simulation";
import { campusQuad } from "../scenarios";
import { MessageTrace } from "../components/MessageTrace";
import { MeshLogPanel } from "../components/MeshLogPanel";
import { MetricsPanel } from "../components/MetricsPanel";
import { ChatPanel } from "../components/ChatPanel";

/**
 * Render smoke tests. The components have no unit coverage otherwise, and a
 * crash in one of them is invisible to the engine suites — these render against
 * real simulation state, so a field rename or an undefined dereference in the
 * panels fails here rather than in the browser.
 */

function world(over: Partial<SimConfig> = {}): MeshSimulation {
  const sim = new MeshSimulation({ ...campusQuad(42), ...over });
  sim.runFor(90000);
  const online = sim.nodes.filter((n) => n.isOnline);
  for (let i = 0; i < 16; i++) {
    const from = online[i % online.length];
    let to = online[(i * 7 + 3) % online.length];
    if (to.id === from.id) to = online[(i + 1) % online.length];
    sim.sendMessage(from.id, to.id, `probe-${i}`, "text");
    sim.runFor(1500);
  }
  sim.refresh();
  return sim;
}

/** A world with one live SOS in it: 90 s to settle, then the emergency. */
function sosWorld(over: Partial<SimConfig> = {}): MeshSimulation {
  const sim = new MeshSimulation({ ...campusQuad(42), ...over });
  sim.runFor(90000);
  sim.clearRecords();
  sim.sendMessage("node-0", "BROADCAST", "injured, need help", "sos");
  sim.runFor(20000); // floods at 0, 5, 10 and 15 s
  sim.refresh();
  return sim;
}

describe("SOS in the UI", () => {
  it("shows one alert card for four floods, with the fix and the reach", () => {
    const sim = sosWorld();
    expect(sim.stats.sosFloods).toBe(4);
    const html = renderToStaticMarkup(
      <ChatPanel
        nodes={sim.nodes}
        selectedNodeId={null}
        onSendMessage={() => null}
        sentRecords={sim.sentRecords}
        deliveries={sim.deliveries}
        sosRepeats={sim.config.sosRepeats}
      />
    );
    // Four floods, one card: the collapse a receiver's inbox does, in the log too.
    expect((html.match(/flood 4\/4/g) ?? []).length).toBe(1);
    expect(html).toContain("🆘");
    expect(html).toContain("GPS");
    expect(html).toContain("injured, need help");
    // 19 peers online besides the sender, and every one of them holds the alert.
    expect(html).toContain("19 of 19 online nodes heard");
    // Radio receipts outnumber notifications, which is the point of collapsing.
    const receipts = Number((html.match(/(\d+) radio receipts/) ?? [])[1]);
    expect(receipts).toBeGreaterThan(19);
  });

  it("counts live alerts and the newest fix on the dashboard", () => {
    const sim = sosWorld();
    const html = renderToStaticMarkup(
      <MetricsPanel stats={sim.stats} dutyCycleEnabled={false} nodes={sim.nodes} />
    );
    expect(html).toContain("SOS — repeated flood");
    expect(html).toContain("Alerts live");
    expect(html).toContain("Nodes alerted");
    // One emergency, four floods, one alert.
    expect(html).toContain("Newest fix (flood 4)");
  });

  it("keeps the SOS row off the dashboard until there is an SOS", () => {
    const sim = world();
    expect(sim.stats.sosFloods).toBe(0);
    expect(
      renderToStaticMarkup(
        <MetricsPanel stats={sim.stats} dutyCycleEnabled={false} nodes={sim.nodes} />
      )
    ).not.toContain("SOS — repeated flood");
  });
});

describe("metrics dashboard", () => {
  it("renders the battery, radio and hop-budget figures", () => {
    const sim = world();
    const html = renderToStaticMarkup(
      <MetricsPanel stats={sim.stats} dutyCycleEnabled={false} />
    );
    expect(html).toContain("Metrics dashboard");
    expect(html).toContain("%/h");
    expect(html).toContain("Scans/s");
    // Latency by hop, the roadmap Phase 2 line this panel exists for.
    expect(html).toContain("Latency by hop");
    for (const bucket of sim.stats.latencyByHop) {
      expect(html).toContain(`>${bucket.count}<`);
    }
  });

  it("shows the awake ratio only when the duty cycle is running", () => {
    const sim = world({ dutyCycleEnabled: true });
    expect(renderToStaticMarkup(<MetricsPanel stats={sim.stats} dutyCycleEnabled />)).toContain(
      "Awake"
    );
    expect(
      renderToStaticMarkup(<MetricsPanel stats={sim.stats} dutyCycleEnabled={false} />)
    ).not.toContain("Awake");
  });
});

describe("hop trace panel", () => {
  it("names the relays a delivered message went via", () => {
    const sim = world();
    const multi = sim.deliveries.find((d) => d.hops >= 2 && !d.dtn);
    expect(multi).toBeDefined();
    const chain = deliveredChain(multi!.hopTrace, multi!.to);
    const html = renderToStaticMarkup(
      <MessageTrace
        delivery={multi!}
        nodes={sim.nodes}
        recent={sim.deliveries}
        onPick={() => {}}
        onClear={() => {}}
      />
    );
    expect(html).toContain(`via ${chain.length - 1} node`);
    expect(html).toContain(multi!.msgId);
    // Every node on the route is named, and the originator leads the chain.
    for (const hop of chain) {
      const name = sim.nodes.find((n) => n.id === hop.nodeId)?.name ?? "";
      expect(html).toContain(name);
    }
    expect(html).toContain("originator");
    expect(html).toContain("delivered");
  });

  it("says so plainly when nothing relayed the message", () => {
    const sim = world();
    const direct = sim.deliveries.find((d) => d.hops === 1);
    expect(direct).toBeDefined();
    const html = renderToStaticMarkup(
      <MessageTrace
        delivery={direct!}
        nodes={sim.nodes}
        recent={sim.deliveries}
        onPick={() => {}}
        onClear={() => {}}
      />
    );
    expect(html).toContain("Direct — no relay");
  });

  it("offers a picker before anything is traced", () => {
    const sim = world();
    const html = renderToStaticMarkup(
      <MessageTrace
        delivery={null}
        nodes={sim.nodes}
        recent={sim.deliveries}
        onPick={() => {}}
        onClear={() => {}}
      />
    );
    expect(html).toContain("Recent deliveries");
    expect(html).toContain("Pick a delivered message");
  });
});

describe("mesh log panel", () => {
  it("explains itself while capture is off", () => {
    const sim = world();
    const html = renderToStaticMarkup(
      <MeshLogPanel
        entries={sim.log}
        captureLog={false}
        captureOgm={false}
        onToggleCapture={() => {}}
        onToggleOgm={() => {}}
        nodes={sim.nodes}
        focusMsgId={null}
      />
    );
    expect(html).toContain("capture off");
    expect(html).toContain("Capture is off");
  });

  it("renders captured events with their kinds and reasons", () => {
    const sim = world({ captureLog: true });
    expect(sim.log.length).toBeGreaterThan(0);
    const html = renderToStaticMarkup(
      <MeshLogPanel
        entries={sim.log}
        captureLog
        captureOgm={false}
        onToggleCapture={() => {}}
        onToggleOgm={() => {}}
        nodes={sim.nodes}
        focusMsgId={null}
      />
    );
    expect(html).toContain(`${sim.log.length} events`);
    for (const kind of ["tx", "decision", "deliver"]) {
      expect(html).toContain(kind);
    }
    // The engine's own words make it into the panel.
    expect(sim.log.some((e) => /MPR/.test(e.detail))).toBe(true);
  });

  it("filters to the message being traced", () => {
    const sim = world({ captureLog: true });
    const target = sim.deliveries.find((d) => d.hops >= 2);
    expect(target).toBeDefined();
    const html = renderToStaticMarkup(
      <MeshLogPanel
        entries={sim.log.filter((e) => e.msgId === target!.msgId)}
        captureLog
        captureOgm={false}
        onToggleCapture={() => {}}
        onToggleOgm={() => {}}
        nodes={sim.nodes}
        focusMsgId={target!.msgId}
      />
    );
    expect(html).toContain(`only ${target!.msgId}`);
  });
});
