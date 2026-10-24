/**
 * `docs/04` §6's abuse limits: "Max 5 broadcasts / minute per node; SUPERs drop
 * excess" and "Cap relay to 30 msgs/min per source; ignore floods".
 *
 * Neither engine implemented either until now, and the second number turns out not
 * to be usable as written — `docs/03` §1 beacons an OGM every 2 s, which is exactly
 * 30 per minute per source, so a relay cap that counted control-plane traffic would
 * leave the routing protocol zero headroom and drop the first data message any node
 * sent. That is tested explicitly below, because it is the kind of thing that reads
 * like a rounding error in a spec and behaves like a total outage.
 */
import { describe, expect, it } from "vitest";
import {
  BROADCAST_PER_MINUTE_CAP,
  RATE_WINDOW_MS,
  RELAY_PER_SOURCE_PER_MINUTE_CAP,
  admitByRate,
  countsAgainstRelayCap,
  type RateBucket,
} from "../routing";
import { MeshSimulation } from "../simulation";
import { campusQuad } from "../scenarios";
import type { MeshMessage, MsgType } from "../types";

function bucket(): Map<string, RateBucket> {
  return new Map();
}

function msg(type: MsgType): MeshMessage {
  return { type } as MeshMessage;
}

describe("the caps are the numbers docs/04 §6 states", () => {
  it("is 5 broadcasts and 30 relays per minute", () => {
    expect(BROADCAST_PER_MINUTE_CAP).toBe(5);
    expect(RELAY_PER_SOURCE_PER_MINUTE_CAP).toBe(30);
    expect(RATE_WINDOW_MS).toBe(60_000);
  });
});

describe("admitByRate", () => {
  it("admits exactly `cap` messages, then refuses", () => {
    const buckets = bucket();
    for (let i = 0; i < BROADCAST_PER_MINUTE_CAP; i++) {
      expect(admitByRate(buckets, "a|src", BROADCAST_PER_MINUTE_CAP, 0).ok, `message ${i}`).toBe(true);
    }
    const refused = admitByRate(buckets, "a|src", BROADCAST_PER_MINUTE_CAP, 0);
    expect(refused.ok).toBe(false);
    expect(refused.reason).toContain("rate limit");
    expect(refused.reason).toContain("5 per minute");
    expect(refused.retryInMs).toBeGreaterThan(0);
  });

  it("refills continuously, so a rate is enforced rather than a per-minute tally", () => {
    // A tumbling counter would admit 5 at t=59 999 and 5 more at t=60 001: ten
    // broadcasts in two milliseconds while never breaking a per-minute count. A
    // bucket refills at cap per window, so the tenth arrives only after the first
    // has aged out.
    const buckets = bucket();
    for (let i = 0; i < 5; i++) admitByRate(buckets, "k", 5, 0);
    expect(admitByRate(buckets, "k", 5, 1_000).ok).toBe(false);
    // One token per RATE_WINDOW_MS / cap = 12 s at cap 5.
    expect(admitByRate(buckets, "k", 5, 11_999).ok).toBe(false);
    expect(admitByRate(buckets, "k", 5, 12_001).ok).toBe(true);
    expect(admitByRate(buckets, "k", 5, 12_002).ok).toBe(false);
  });

  it("never refills above the cap, so a quiet source does not bank an unlimited burst", () => {
    const buckets = bucket();
    admitByRate(buckets, "k", 5, 0);
    // Ten minutes of silence is worth 50 tokens at 5/min, but the bucket holds 5.
    const after = admitByRate(buckets, "k", 5, 600_000);
    expect(after.ok).toBe(true);
    expect(after.tokensLeft).toBeLessThanOrEqual(5);
    let admitted = 1;
    while (admitByRate(buckets, "k", 5, 600_000).ok) admitted++;
    expect(admitted).toBe(5);
  });

  it("keeps sources and enforcers apart", () => {
    const buckets = bucket();
    for (let i = 0; i < 5; i++) admitByRate(buckets, "a|src1", 5, 0);
    expect(admitByRate(buckets, "a|src1", 5, 0).ok).toBe(false);
    // A different source through the same enforcer is unaffected, and the same
    // source through a different enforcer is a different bucket — which is what
    // makes the cap per-hop rather than network-wide.
    expect(admitByRate(buckets, "a|src2", 5, 0).ok).toBe(true);
    expect(admitByRate(buckets, "b|src1", 5, 0).ok).toBe(true);
  });

  it("treats a non-positive cap as no cap", () => {
    const buckets = bucket();
    for (let i = 0; i < 500; i++) expect(admitByRate(buckets, "k", 0, i).ok).toBe(true);
    expect(buckets.size).toBe(0);
    expect(admitByRate(buckets, "k", -1, 0).ok).toBe(true);
  });

  it("grants no refill when the clock goes backwards", () => {
    // A metrics reset, or a map reused across runs. Subtracting tokens would be
    // worse than doing nothing: it would punish a source for the engine's rewind.
    const buckets = bucket();
    for (let i = 0; i < 5; i++) admitByRate(buckets, "k", 5, 10_000);
    expect(admitByRate(buckets, "k", 5, 0).ok).toBe(false);
    expect(buckets.get("k")!.atMs).toBe(0);
  });

  it("reports how long until the next token, which is what a UI has to show", () => {
    const buckets = bucket();
    for (let i = 0; i < 30; i++) admitByRate(buckets, "k", 30, 0);
    const refused = admitByRate(buckets, "k", 30, 0);
    expect(refused.ok).toBe(false);
    // 30 per minute is one token every 2 s.
    expect(Math.round(refused.retryInMs)).toBe(2000);
    expect(refused.reason).toContain("2.0 s");
  });
});

describe("countsAgainstRelayCap — the 2 s OGM problem", () => {
  it("exempts control-plane traffic and counts everything a user sends", () => {
    expect(countsAgainstRelayCap(msg("ogm"))).toBe(false);
    expect(countsAgainstRelayCap(msg("ack"))).toBe(false);
    expect(countsAgainstRelayCap(msg("sync"))).toBe(false);
    for (const type of ["text", "broadcast", "voice", "file", "sos"] as MsgType[]) {
      expect(countsAgainstRelayCap(msg(type)), type).toBe(true);
    }
  });

  it("would otherwise cost a node 90 % of its sustained data rate, at the documented numbers", () => {
    // docs/03 §1: an OGM every 2 s. docs/04 §6: cap relay at 30 msgs/min per source.
    // 60 000 / 2 000 = 30 — a source's own beacons arrive at exactly the cap rate.
    const ogmIntervalMs = 2000;
    expect(RATE_WINDOW_MS / ogmIntervalMs).toBe(RELAY_PER_SOURCE_PER_MINUTE_CAP);

    // Ten minutes of a source that beacons every 2 s and wants to send one data
    // message in every slot, with the relay cap applied to whichever traffic the
    // policy says counts.
    const sustained = (countOgms: boolean): number => {
      const buckets = bucket();
      let admitted = 0;
      for (let t = 0; t < 10 * RATE_WINDOW_MS; t += ogmIntervalMs) {
        if (countOgms || countsAgainstRelayCap(msg("ogm"))) {
          admitByRate(buckets, "relay|src", RELAY_PER_SOURCE_PER_MINUTE_CAP, t);
        }
        if (admitByRate(buckets, "relay|src", RELAY_PER_SOURCE_PER_MINUTE_CAP, t).ok) admitted++;
      }
      return admitted;
    };

    // Counting beacons: the bucket refills one token per slot and the beacon spends
    // it, so data runs off the initial burst alone and then starves.
    expect(sustained(true)).toBe(29);
    // Exempting them: the full 30/min is available to user traffic, one per slot.
    expect(sustained(false)).toBe(300);
    expect(sustained(false)).toBe((10 * RATE_WINDOW_MS) / ogmIntervalMs);
    // And the exemption does not disable the cap: a source that floods is still
    // refused, because 30/min is one message per 2 s and a flood exceeds that.
    const flooding = bucket();
    let refused = 0;
    for (let i = 0; i < 100; i++) {
      if (!admitByRate(flooding, "relay|src", RELAY_PER_SOURCE_PER_MINUTE_CAP, 0).ok) refused++;
    }
    expect(refused).toBe(100 - RELAY_PER_SOURCE_PER_MINUTE_CAP);
  });
});

describe("in the engine", () => {
  it("is off by default, so nothing a shipped run does changes", () => {
    const config = campusQuad(42);
    expect(config.rateLimits).toBe(false);
    expect(config.broadcastPerMinuteCap).toBe(BROADCAST_PER_MINUTE_CAP);
    expect(config.relayPerSourcePerMinuteCap).toBe(RELAY_PER_SOURCE_PER_MINUTE_CAP);
  });

  it("suppresses a broadcast flood at the SUPERs when it is on, and not when it is off", () => {
    const run = (rateLimits: boolean) => {
      const sim = new MeshSimulation({ ...campusQuad(42), rateLimits });
      sim.runFor(60_000); // settle elections so there are SUPERs to enforce
      sim.refresh();
      const supers = sim.nodes.filter((n) => n.role === "SUPER").length;
      expect(supers, "the world must have elected SUPERs for this to mean anything").toBeGreaterThan(0);
      const source = sim.nodes[0];
      // 24 broadcasts inside a few seconds: 5/min is the documented cap, so most of
      // these are excess wherever a SUPER hears them.
      for (let i = 0; i < 24; i++) {
        sim.sendMessage(source.id, "BROADCAST", `flood ${i}`, "broadcast");
        sim.runFor(200);
      }
      sim.runFor(20_000);
      sim.refresh();
      return sim.stats;
    };

    const off = run(false);
    const on = run(true);
    expect(off.rateBroadcastDrops).toBe(0);
    expect(off.rateRelayDrops).toBe(0);
    expect(on.rateBroadcastDrops).toBeGreaterThan(0);
  });

  it("leaves an honest sender alone, which is the property that makes the cap shippable", () => {
    const sim = new MeshSimulation({ ...campusQuad(42), rateLimits: true });
    sim.runFor(60_000);
    sim.refresh();
    const source = sim.nodes[0];
    // One broadcast every 20 s is 3/min, under the cap of 5. Over two minutes that
    // is six broadcasts, and none of them may be suppressed.
    for (let i = 0; i < 6; i++) {
      sim.sendMessage(source.id, "BROADCAST", `honest ${i}`, "broadcast");
      sim.runFor(20_000);
    }
    sim.refresh();
    expect(sim.stats.rateBroadcastDrops).toBe(0);
  });

  it("does not rate-limit an SOS, which docs/04 §6 gives its own mechanism instead", () => {
    // §6 says SOS abuse is handled by making the channel opt-in, and §11's
    // collapsing means a repeated flood is one emergency, not N notifications.
    // Capping an emergency channel at 5/min would be a worse failure than the abuse
    // it prevents, so the broadcast gate keys on the `broadcast` type and SOS — which
    // also travels to BROADCAST — is not caught by it.
    const sim = new MeshSimulation({ ...campusQuad(42), rateLimits: true });
    sim.runFor(60_000);
    sim.refresh();
    const source = sim.nodes[0];
    for (let i = 0; i < 12; i++) {
      sim.sendMessage(source.id, "BROADCAST", `sos ${i}`, "sos");
      sim.runFor(100);
    }
    sim.runFor(10_000);
    sim.refresh();
    expect(sim.stats.rateBroadcastDrops).toBe(0);
  });
});
