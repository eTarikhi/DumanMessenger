import { describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { MeshSimulation, deliveredChain, type SimConfig } from "../simulation";
import { campusQuad } from "../scenarios";
import { MessageTrace } from "../components/MessageTrace";
import { MeshLogPanel } from "../components/MeshLogPanel";
import { MetricsPanel } from "../components/MetricsPanel";
import { ChatPanel } from "../components/ChatPanel";
import { NodeInspector } from "../components/NodeInspector";

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

/** A settled world with one five-member group that has already exchanged traffic. */
function groupWorld(over: Partial<SimConfig> = {}): MeshSimulation {
  const sim = new MeshSimulation({ ...campusQuad(42), ...over });
  sim.runFor(90000);
  sim.clearRecords();
  const online = sim.nodes.filter((n) => n.isOnline);
  const anchor = online[0];
  const nearest = online
    .filter((n) => n.id !== anchor.id)
    .sort(
      (a, b) =>
        (a.pos.x - anchor.pos.x) ** 2 +
        (a.pos.y - anchor.pos.y) ** 2 -
        ((b.pos.x - anchor.pos.x) ** 2 + (b.pos.y - anchor.pos.y) ** 2)
    )
    .slice(0, 4)
    .map((n) => n.id);
  const group = sim.createGroup("field team", [anchor.id, ...nearest], anchor.id)!;
  for (let i = 0; i < 3; i++) {
    sim.sendMessage(anchor.id, group.id, `status ${i}`, "text");
    sim.runFor(4000);
  }
  sim.refresh();
  return sim;
}

function inspector(sim: MeshSimulation, nodeId: string) {
  return renderToStaticMarkup(
    <NodeInspector
      node={sim.nodes.find((n) => n.id === nodeId) ?? null}
      allNodes={sim.nodes}
      rf={sim.rf}
      dutyCycleEnabled={false}
      awake
      onToggleOnline={() => {}}
      onToggleCharging={() => {}}
      onToggleSuperOptOut={() => {}}
      onToggleBatterySaver={() => {}}
      onClose={() => {}}
      groups={[...sim.groups.values()]}
      onCreateGroup={() => {}}
      onInviteNearest={() => {}}
      onLeaveGroup={() => {}}
      onRotateKey={() => {}}
    />
  );
}

describe("groups in the UI", () => {
  it("offers the group as a destination and reports member reach", () => {
    const sim = groupWorld();
    const group = [...sim.groups.values()][0];
    const sender = [...group.members][0];
    const html = renderToStaticMarkup(
      <ChatPanel
        nodes={sim.nodes}
        selectedNodeId={sender}
        onSendMessage={() => null}
        sentRecords={sim.sentRecords}
        deliveries={sim.deliveries}
        groups={[...sim.groups.values()]}
        groupMode={sim.config.groupMode}
      />
    );
    expect(html).toContain("👥 field team (5)");       // the destination picker
    expect(html).toContain("epoch 0");
    expect(html).toContain("4 of 4 members received");  // everyone but the sender
    expect(html).toContain("one scoped flood");
    expect(sim.stats.groupDeliveryRatio).toBe(1);
  });

  it("collapses per-member unicasts into the one send the user made", () => {
    const sim = groupWorld({ groupMode: "per-member-unicast" });
    const group = [...sim.groups.values()][0];
    const sender = [...group.members][0];
    // three sends, four members each: twelve radio messages, three cards
    expect(sim.stats.sentGroup).toBe(12);
    const html = renderToStaticMarkup(
      <ChatPanel
        nodes={sim.nodes}
        selectedNodeId={sender}
        onSendMessage={() => null}
        sentRecords={sim.sentRecords}
        deliveries={sim.deliveries}
        groups={[...sim.groups.values()]}
        groupMode={sim.config.groupMode}
        onToggleGroupMode={() => {}}
      />
    );
    expect((html.match(/one send/g) ?? []).length).toBe(3);
    expect(html).toContain("4 routed unicasts");
    expect(html).toContain("per-member unicast"); // the live mode toggle
  });

  it("shows membership, the admin badge and the rules that bind the buttons", () => {
    const sim = groupWorld();
    const group = [...sim.groups.values()][0];
    const admin = [...group.members][0];
    const member = [...group.members][1];
    const outsider = sim.nodes.find((n) => !group.members.has(n.id))!;

    const asAdmin = inspector(sim, admin);
    expect(asAdmin).toContain("field team");
    expect(asAdmin).toContain("5/10 · epoch 0");
    expect(asAdmin).toContain("you are admin");
    expect(asAdmin).toContain("(you)");

    // A non-admin sees the same group without the badge, and a non-member sees none.
    expect(inspector(sim, member)).not.toContain("you are admin");
    expect(inspector(sim, outsider.id)).toContain("Not a member of any group");
  });

  it("disables leaving a three-member group and rotating without admin", () => {
    const sim = groupWorld();
    const group = [...sim.groups.values()][0];
    const member = [...group.members][1];
    sim.removeFromGroup(group.id, [...group.members][4]);
    sim.removeFromGroup(group.id, [...group.members][3]);
    expect(group.members.size).toBe(3);
    const html = inspector(sim, member);
    // The rule is in the DOM, not just in the engine: leaving would drop below three.
    expect(html).toContain("A group cannot drop below three members");
    expect(html).toContain("Only the admin may rotate the group key");
  });

  it("counts group traffic on the dashboard, and only when there is any", () => {
    const sim = groupWorld();
    const html = renderToStaticMarkup(
      <MetricsPanel stats={sim.stats} dutyCycleEnabled={false} nodes={sim.nodes} />
    );
    expect(html).toContain("Group channels");
    expect(html).toContain("12/12"); // three sends × four members
    expect(html).toContain("100%");
    expect(
      renderToStaticMarkup(<MetricsPanel stats={world().stats} dutyCycleEnabled={false} />)
    ).not.toContain("Group channels");
  });
});

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

/** A settled campus world with one file transfer and one voice note in it. */
function mediaWorld(over: Partial<SimConfig> = {}): MeshSimulation {
  const sim = new MeshSimulation({ ...campusQuad(42), ...over });
  sim.runFor(90000);
  sim.clearRecords();
  const online = sim.nodes.filter((n) => n.isOnline);
  sim.sendFile(online[0].id, online[1].id, 1024 * 1024);
  sim.sendVoice(online[2].id, online[3].id, 1);
  sim.runFor(60000);
  sim.refresh();
  return sim;
}

describe("group history anti-entropy in the UI", () => {
  it("reports the repair traffic, and only once a group has beaconed", () => {
    const sim = groupWorld();
    sim.runFor(30000); // three beacon intervals
    sim.refresh();
    expect(sim.stats.historyBeacons).toBeGreaterThan(0);
    const html = renderToStaticMarkup(
      <MetricsPanel stats={sim.stats} dutyCycleEnabled={false} config={sim.config} />
    );
    expect(html).toContain("Group history anti-entropy");
    expect(html).toContain("Digest beacons");
    expect(html).toContain("Messages recovered");
    expect(html).toContain("Unreadable after rotation");
    // The footnote states the two properties the protocol rests on.
    expect(html).toContain("grow-only CRDT");
    expect(html).toContain("BLE packet");

    const quiet = world();
    expect(
      renderToStaticMarkup(<MetricsPanel stats={quiet.stats} dutyCycleEnabled={false} />)
    ).not.toContain("Group history anti-entropy");
  });

  it("keeps digest beacons out of the chat log", () => {
    const sim = groupWorld();
    sim.runFor(30000);
    sim.refresh();
    expect(sim.sentRecords.some((r) => r.type === "sync")).toBe(true);
    const group = [...sim.groups.values()][0];
    const html = renderToStaticMarkup(
      <ChatPanel
        nodes={sim.nodes}
        selectedNodeId={[...group.members][0]}
        onSendMessage={() => null}
        sentRecords={sim.sentRecords}
        deliveries={sim.deliveries}
        groups={[...sim.groups.values()]}
      />
    );
    expect(html).not.toContain("HB|");
    expect(html).toContain("sent"); // the header still counts real messages
  });
});

describe("media transport in the UI", () => {
  it("offers the file and push-to-talk controls, and explains why they are greyed out", () => {
    const sim = mediaWorld();
    const html = renderToStaticMarkup(
      <ChatPanel
        nodes={sim.nodes}
        selectedNodeId={sim.nodes[0].id}
        onSendMessage={() => null}
        sentRecords={sim.sentRecords}
        deliveries={sim.deliveries}
        onSendFile={() => {}}
        onSendVoice={() => {}}
        transfers={[...sim.transfers.values()]}
      />
    );
    expect(html).toContain("Send file");
    expect(html).toContain("PTT · stream");
    expect(html).toContain("PTT · blob");
    expect(html).toContain("File size in megabytes");
    expect(html).toContain("Voice note length in seconds");
    // The composer starts on "everybody", and media is 1:1.
    expect(html).toContain("a file transfer is 1:1");
    expect(html).toContain("disabled");
  });

  it("shows one progress row per transfer, with the radio it is riding", () => {
    const sim = mediaWorld();
    const transfers = [...sim.transfers.values()];
    expect(transfers.length).toBe(2);
    const html = renderToStaticMarkup(
      <ChatPanel
        nodes={sim.nodes}
        selectedNodeId={transfers[0].from}
        onSendMessage={() => null}
        sentRecords={sim.sentRecords}
        deliveries={sim.deliveries}
        transfers={transfers}
      />
    );
    expect(html).toContain(`data-testid="transfer-${transfers[0].id}"`);
    expect(html).toContain(`data-testid="transfer-${transfers[1].id}"`);
    expect(html).toContain("1.0 MB");   // the file
    expect(html).toContain("1 KB");     // two 500 ms Opus frames at 12 kbps
    expect(html).toContain("wifiDirect");
    expect(html).toContain("over ble"); // a voice frame stays inside one BLE packet
    expect(html).toContain("/16");      // 1 MB in 64 KB chunks
    // The chunks are counted as media, not rendered as chat bubbles.
    expect(html).toContain("media chunks");
    expect((html.match(/Amir-0 → Bianca-1/g) ?? []).length).toBe(0);
  });

  it("counts media on the dashboard, and only once there is any", () => {
    const busy = mediaWorld();
    const html = renderToStaticMarkup(
      <MetricsPanel stats={busy.stats} dutyCycleEnabled={false} config={busy.config} />
    );
    expect(html).toContain("Media transport");
    expect(html).toContain("Chunks on air");
    expect(html).toContain("Window stalls");
    expect(html).toContain("Payload delivered");
    // The footnote quotes the sizing the engine is actually running with.
    expect(html).toContain("64 KB chunks");
    expect(html).toContain("250×");

    const quiet = world();
    expect(
      renderToStaticMarkup(<MetricsPanel stats={quiet.stats} dutyCycleEnabled={false} />)
    ).not.toContain("Media transport");
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
