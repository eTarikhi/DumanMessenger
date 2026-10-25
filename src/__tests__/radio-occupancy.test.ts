/**
 * `docs/06` §24.5's question, answered: what a radio is *busy* for is not the same quantity
 * as how long a packet takes to arrive, and the engine had been charging one for the other.
 *
 * The shipped model charges every packet a calibrated hop latency (120 ms on BLE, which
 * `serializationMs`'s own comment says already includes one full-sized GATT write) and only
 * the excess over 1 024 B on top. That is right at 1 024 B and wrong below it, so a short
 * text pays what a media chunk pays. `"airtime"` charges `bytes × 8 / kbps` instead, from
 * rate constants the engine already had, and beacons — which had no size at all — get one
 * derived from the fields an OGM actually carries.
 */
import { describe, expect, it } from "vitest";
import { MeshSimulation, type SimConfig } from "../simulation";
import { campusQuad, festivalCrowd } from "../scenarios";
import {
  BLE_MAX_BYTES,
  OGM_BATTERY_BYTES,
  OGM_FIXED_BYTES,
  OGM_FLAG_BYTES,
  OGM_HOP_ENTRY_BYTES,
  OGM_ID_BYTES,
  OGM_MAX_WIRE_BYTES,
  OGM_SCORE_BYTES,
  OGM_SEQ_BYTES,
  ogmWireBytes,
} from "../routing";
import {
  BEST_HOP_ADVERTISE_LIMIT,
  MPR_NEIGHBOR_ADVERTISE_LIMIT,
} from "../election";

function run(over: Partial<SimConfig>, scenario = campusQuad) {
  const sim = new MeshSimulation({ ...scenario(42), ...over });
  sim.runFor(90_000);
  sim.refresh();
  sim.clearRecords();
  sim.injectTraffic(30, 40_000);
  sim.runFor(60_000);
  sim.refresh();
  return sim;
}

describe("OGM wire size, derived rather than guessed", () => {
  it("is the sum of the fields docs/03 §4 says a beacon carries", () => {
    // nodeId 32, seq 4, score 4, isSuper/declinedRouter/hopCount 1 each, peerCount 2,
    // batteryBucket 1 — the same derivation style as PACKET_OVERHEAD_BYTES, whose 32-byte
    // `from` field is the same X25519 public key.
    expect(OGM_ID_BYTES).toBe(32);
    expect(OGM_HOP_ENTRY_BYTES).toBe(33);
    expect(OGM_FIXED_BYTES).toBe(46);
    expect(ogmWireBytes(0, 0)).toBe(OGM_FIXED_BYTES);
    expect(ogmWireBytes(10, 8)).toBe(46 + 10 * 32 + 8 * 33);
    expect(ogmWireBytes(10, 8)).toBe(630);
  });

  it("bounds a beacon by the advertise limits the engine actually enforces", () => {
    expect(MPR_NEIGHBOR_ADVERTISE_LIMIT).toBe(30);
    expect(BEST_HOP_ADVERTISE_LIMIT).toBe(8);
    expect(OGM_MAX_WIRE_BYTES).toBe(ogmWireBytes(30, 8));
    expect(OGM_MAX_WIRE_BYTES).toBe(1270);
  });

  it("ties the literal widths to the named ones, which is what makes the literals safe", () => {
    // `check-parity.py` compares the two engines' non-scalar initialisers as *text*, and
    // identifier case is the one thing TypeScript and Dart cannot agree on, so these
    // constants are spelled `32 + 4 + 4 + (1 + 1 + 1 + 2) + 1` on both sides exactly as
    // `PACKET_OVERHEAD_BYTES` spells its 95 B. These assertions are what stop a width change
    // from silently invalidating the literal: they fail, and name the constant to update.
    expect(OGM_HOP_ENTRY_BYTES).toBe(OGM_ID_BYTES + 1);
    expect(OGM_FIXED_BYTES).toBe(
      OGM_ID_BYTES +
        OGM_SEQ_BYTES +
        OGM_SCORE_BYTES +
        OGM_FLAG_BYTES +
        OGM_BATTERY_BYTES
    );
    expect(OGM_MAX_WIRE_BYTES).toBe(
      ogmWireBytes(MPR_NEIGHBOR_ADVERTISE_LIMIT, BEST_HOP_ADVERTISE_LIMIT)
    );
  });

  it("puts a fully loaded beacon over the BLE ceiling, which is a finding not a defect", () => {
    // A node with 30 advertised neighbours and 8 route entries sends 1 270 B, and
    // `selectTransport` flips to Wi-Fi Direct above 1 024. The engine never sized beacons
    // before, so nothing noticed; docs/06 §24.6 records it. Clamping the MPR set or the
    // route table is a spec decision, not a simulator one.
    expect(OGM_MAX_WIRE_BYTES).toBeGreaterThan(BLE_MAX_BYTES);
    expect(ogmWireBytes(10, 8)).toBeLessThan(BLE_MAX_BYTES);
  });

  it("never goes negative on an empty or clamped field", () => {
    expect(ogmWireBytes(-5, -5)).toBe(OGM_FIXED_BYTES);
  });
});

describe("radioOccupancy", () => {
  it("ships on the model every published number was measured under", () => {
    expect(campusQuad(42).radioOccupancy).toBe("hop-latency");
    expect(festivalCrowd(42).radioOccupancy).toBe("hop-latency");
  });

  it("charges airtime from the rate constants the engine already had", () => {
    const sim = new MeshSimulation(campusQuad(42));
    // 1 024 B at 80 kbit/s is 102.4 ms — which is why a 120 ms hop latency can claim to
    // include one full-sized GATT write, and why the two models agree near the ceiling.
    expect(sim.airtimeMs(1024, "ble")).toBeCloseTo(102.4, 6);
    expect(sim.airtimeMs(256, "ble")).toBeCloseTo(25.6, 6);
    expect(sim.airtimeMs(0, "ble")).toBe(0);
    expect(sim.airtimeMs(1024, "wifiDirect")).toBeCloseTo(0.4096, 6);
    // A typical beacon: 630 B, 63 ms — about half the flat 120 ms it was charged before.
    expect(sim.airtimeMs(630, "ble")).toBeCloseTo(63, 6);
  });

  it("changes telemetry and nothing else under the shipped radio baseline", () => {
    // Under `free`/`none` no code path reads occupancy except the wake-lock accounting, so
    // the two models must produce bit-identical worlds and different telemetry. This is the
    // property that makes the knob safe to add: it cannot move a published delivery, latency
    // or overhead figure unless a contention model is switched on at the same time.
    const flat = run({ radioOccupancy: "hop-latency" });
    const sized = run({ radioOccupancy: "airtime" });
    expect(flat.config.channelAccess).toBe("free");
    expect(flat.config.channelCapture).toBe("none");
    for (const key of [
      "totalDelivered",
      "totalForwarded",
      "deliveryRatio",
      "broadcastReach",
      "overheadRatio",
      "mprSuppressed",
      "controlOverhead",
      "sentUnicast",
      "sentBroadcast",
    ] as const) {
      expect(sized.stats[key], key).toBe(flat.stats[key]);
    }
    expect(sized.stats.wakeLockMs).not.toBe(flat.stats.wakeLockMs);
    expect(sized.stats.wakeLockMs).toBeLessThan(flat.stats.wakeLockMs);
    // Acquisitions are the same events either way; only their duration changes.
    expect(sized.stats.wakeLocks).toBe(flat.stats.wakeLocks);
  });

  it("halves the demanded radio time without making it physically possible", () => {
    // The over-subscription §24.3 measured is only partly the flat occupancy. Sizing packets
    // properly takes campus_quad from 3.9x to about 1.7x and festival_crowd from 8.4x to
    // about 5.8x — still above 1, because the volume of beacon receptions and their gossip
    // is the dominant term, not the per-packet charge. docs/06 §24.6.
    const flat = run({ radioOccupancy: "hop-latency" });
    const sized = run({ radioOccupancy: "airtime" });
    expect(sized.stats.radioDemandRatio).toBeLessThan(flat.stats.radioDemandRatio);
    expect(sized.stats.radioDemandRatio).toBeGreaterThan(1);
    expect(flat.stats.radioDemandRatio).toBeGreaterThan(3);
    expect(sized.stats.radioDemandRatio).toBeLessThan(2.5);
  });

  it("costs a dense crowd fewer deferrals and buys it delivery, once contention is modelled", () => {
    // This is where the two models stop being equivalent: under `csma` a radio that is busy
    // for 120 ms defers traffic that a radio busy for 26 ms would have taken. §12's
    // published contention numbers were measured under the flat charge, so they are
    // pessimistic in the dense arm — by about 6 points of delivery here.
    const flat = run({ channelAccess: "csma", radioOccupancy: "hop-latency" }, festivalCrowd);
    const sized = run({ channelAccess: "csma", radioOccupancy: "airtime" }, festivalCrowd);
    expect(sized.stats.channelDeferrals).toBeLessThan(flat.stats.channelDeferrals);
    expect(sized.stats.channelDrops).toBeLessThan(flat.stats.channelDrops);
    expect(sized.stats.deliveryRatio).toBeGreaterThan(flat.stats.deliveryRatio);
  });

  it("leaves a sparse mesh's delivery alone under contention, which bounds the finding", () => {
    // campus_quad delivers everything in every arm under both models, so the correction is
    // about density and not about the contention model in general.
    const flat = run({ channelAccess: "csma", radioOccupancy: "hop-latency" });
    const sized = run({ channelAccess: "csma", radioOccupancy: "airtime" });
    expect(flat.stats.deliveryRatio).toBe(1);
    expect(sized.stats.deliveryRatio).toBe(1);
    expect(sized.stats.channelDeferrals).toBeLessThan(flat.stats.channelDeferrals);
  });
});
