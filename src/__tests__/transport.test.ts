/**
 * The twelve bytes of the discovery beacon — in the engine that can actually execute them.
 *
 * The layout was decided in `sim/mesh_sim/lib/src/transport.dart` and asserted in
 * `sim/mesh_sim/test/transport_test.dart`, and neither has ever run: the Dart SDK is not
 * installable where this repository is developed (`storage.googleapis.com` is unreachable —
 * `make blockers`, section A). So the wire format of roadmap item 20 existed only as source
 * nobody had executed. These tests pin the same bytes in TypeScript, using the same digest
 * `transport_test.dart:62` uses, so the two engines' claims about bytes 0..11 can be compared
 * by reading them side by side — and `check-parity.py` compares the two constants by machine.
 */
import { describe, expect, it } from "vitest";
import { fnv1a32 } from "../simulation";
import {
  BEACON_BYTES,
  DUMAN_MESH_SERVICE_UUID,
  advertise,
  beaconIdHash,
  decodeBeacon,
  encodeBeacon,
  sameDatabase,
} from "../transport";

/** The digest `sim/mesh_sim/test/transport_test.dart` advertises, so the bytes are comparable. */
const DIGEST = 0x1122334455667788n;

const hex = (b: Uint8Array): string =>
  Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

describe("discovery beacon (roadmap item 20, `AdvertPayload.beacon` in both engines)", () => {
  it("is twelve bytes, and the constant is spelled as a literal so the parity check can pair it", () => {
    const beacon = encodeBeacon({ localId: "node-0", dbHash: DIGEST });
    expect(beacon.length).toBe(12);
    expect(beacon.length).toBe(BEACON_BYTES);
    // 8 bytes of digest + 4 bytes of id hash. Written as a sum here rather than in the module,
    // because the module spells `BEACON_BYTES` as `12` on purpose: check-parity compares
    // constants textually, and `8 + 4` against Dart's `12` would read as a disagreement between
    // two engines that agree.
    expect(8 + 4).toBe(BEACON_BYTES);
  });

  it("puts the database digest in bytes 0..7, big-endian — the exact bytes the Dart test asserts", () => {
    const beacon = encodeBeacon({ localId: "node-0", dbHash: DIGEST });
    const view = new DataView(beacon.buffer);
    // transport_test.dart:74-75 expects 0x11223344 then 0x55667788, big-endian.
    expect(view.getUint32(0, false)).toBe(0x11223344);
    expect(view.getUint32(4, false)).toBe(0x55667788);
    expect(hex(beacon).slice(0, 16)).toBe("1122334455667788");
  });

  it("puts a hash of the local id in bytes 8..11, and not the id itself", () => {
    const beacon = encodeBeacon({ localId: "node-0", dbHash: DIGEST });
    const view = new DataView(beacon.buffer);
    expect(view.getUint32(8, false)).toBe(beaconIdHash("node-0"));
    // A node id is `node-<index>` — six or seven ASCII characters, which cannot fit four bytes.
    // What is on air is a pseudonym, so this asserts the length rather than the absence.
    expect(hex(beacon).slice(16)).toHaveLength(8);
  });

  it("makes two devices holding the same database agree on 0..7 and differ on 8..11", () => {
    const a = encodeBeacon({ localId: "node-0", dbHash: DIGEST });
    const b = encodeBeacon({ localId: "node-1", dbHash: DIGEST });
    // The whole use of the beacon: recognise the peer from four bytes, then compare eight to
    // learn whether it holds anything you are missing, without either side sending a list.
    expect(hex(a).slice(0, 16)).toBe(hex(b).slice(0, 16));
    expect(hex(a).slice(16)).not.toBe(hex(b).slice(16));
    expect(sameDatabase(decodeBeacon(a), decodeBeacon(b))).toBe(true);
  });

  it("refreshes: a different digest changes 0..7 and leaves the id alone", () => {
    const before = encodeBeacon({ localId: "node-0", dbHash: DIGEST });
    const after = encodeBeacon({ localId: "node-0", dbHash: 1n });
    expect(hex(before).slice(0, 16)).not.toBe(hex(after).slice(0, 16));
    expect(hex(before).slice(16)).toBe(hex(after).slice(16));
    expect(sameDatabase(decodeBeacon(before), decodeBeacon(after))).toBe(false);
  });

  it("the id hash is the FNV-1a the group-history digest already uses, pinned by value", () => {
    // Not a new hash function: docs/06 §17's anti-entropy beacons fold the same 32-bit FNV-1a,
    // and this beacon is that trick shrunk to one packet. Pinned by value so that changing the
    // algorithm — which would silently invalidate every beacon a shipped device has ever heard
    // — fails a test rather than a field test.
    expect(beaconIdHash("node-0")).toBe(fnv1a32("node-0"));
    expect(beaconIdHash("node-0")).toBe(1405366768);
    expect(beaconIdHash("node-1")).toBe(1422144387);
    expect(beaconIdHash("node-19")).toBe(719154638);
  });

  it("encodes a digest of 2^63 to the bytes Dart's signed int produces", () => {
    // Dart's `int` is 64-bit *signed*, so a digest of 2^63 or above is negative there and
    // positive here. Both write the same bytes because each masks to unsigned at the point of
    // writing — Dart with `.toUnsigned(32)`, this with `BigInt.asUintN`. If that agreement were
    // left to chance, half the digest space would advertise differently on the two platforms.
    const beacon = encodeBeacon({ localId: "node-0", dbHash: 1n << 63n });
    expect(hex(beacon).slice(0, 16)).toBe("8000000000000000");
    expect(decodeBeacon(beacon).dbHash).toBe(1n << 63n);
  });

  it("encodes -1 and 2^64-1 identically, which is the same agreement from the other side", () => {
    const negative = encodeBeacon({ localId: "node-0", dbHash: -1n });
    const unsigned = encodeBeacon({ localId: "node-0", dbHash: 0xffffffffffffffffn });
    expect(hex(negative)).toBe("ffffffffffffffff" + hex(unsigned).slice(16));
    expect(hex(negative).slice(0, 16)).toBe("ffffffffffffffff");
  });

  it("round-trips through decodeBeacon across the digest range", () => {
    for (const digest of [0n, 1n, DIGEST, 1n << 32n, (1n << 63n) | 7n, 0xffffffffffffffffn]) {
      const decoded = decodeBeacon(encodeBeacon({ localId: "node-7", dbHash: digest }));
      expect(decoded.dbHash).toBe(digest);
      expect(decoded.idHash).toBe(beaconIdHash("node-7"));
    }
  });

  it("refuses a buffer that is not a beacon, rather than returning something plausible", () => {
    // A scanner hears whatever is being advertised nearby, and most of it is not ours. Throwing
    // keeps "not a Duman beacon" distinguishable from "a Duman beacon with an empty database",
    // which a silent undefined would merge.
    expect(() => decodeBeacon(new Uint8Array(11))).toThrow(/12 bytes; got 11/);
    expect(() => decodeBeacon(new Uint8Array(13))).toThrow(/12 bytes; got 13/);
    expect(() => decodeBeacon(new Uint8Array(0))).toThrow(RangeError);
    // A subarray view has a byteOffset, which a DataView built from `.buffer` alone would read
    // from the wrong place — the kind of bug that only appears once a caller slices.
    const padded = new Uint8Array(20).fill(0);
    padded.set(encodeBeacon({ localId: "node-3", dbHash: DIGEST }), 4);
    expect(decodeBeacon(padded.subarray(4, 16)).dbHash).toBe(DIGEST);
  });

  it("advertises under the service UUID, and the UUID travels with the payload", () => {
    const adv = advertise({ localId: "node-0", dbHash: DIGEST });
    // skills/01: "12B beacon + service UUID". The UUID is what a scanner filters on, so it is
    // data rather than a constant baked into the radio code.
    expect(adv.serviceUuid).toBe(DUMAN_MESH_SERVICE_UUID);
    expect(DUMAN_MESH_SERVICE_UUID).toBe("DUMAN_MESH_SVC");
    expect(adv.beacon.length).toBe(BEACON_BYTES);
    expect(adv.localId).toBe("node-0");
    expect(adv.dbHash).toBe(DIGEST);

    const other = advertise({
      localId: "node-0",
      dbHash: DIGEST,
      serviceUuid: "TEST_SVC",
    });
    expect(other.serviceUuid).toBe("TEST_SVC");
    // The UUID is not part of the twelve bytes: changing it changes nothing on the beacon.
    expect(hex(other.beacon)).toBe(hex(adv.beacon));
  });

  it("is idempotent, which is the half of Dart's stateful contract a pure function can assert", () => {
    const payload = { localId: "node-0", dbHash: DIGEST };
    // Dart's seam replaces the current advertisement, because a radio holds one at a time. Here
    // the same payload advertises to the same bytes however often it is called; the "stop() then
    // advertise again" half belongs to whichever bridge owns the radio.
    expect(hex(advertise(payload).beacon)).toBe(hex(advertise(payload).beacon));
    expect(advertise(payload).serviceUuid).toBe(advertise(payload).serviceUuid);
  });
});
