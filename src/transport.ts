/**
 * The discovery beacon: twelve bytes on air, and the byte order both engines agree on.
 *
 * Roadmap Phase 0 item 20 asks for a "BLE GATT hello: Android GATT server + scanner +
 * 12-byte beacon (DB hash + id)". The radio half of that needs a handset, and no development
 * machine has one (`make blockers`, section D). The *format* half does not, and it is the half
 * that has to be fixed before either platform bridge exists: a beacon that reads differently on
 * Android and on iOS matches nobody, so the byte order is a decision, not an implementation
 * detail.
 *
 * This is not the transport *choice*: which radio a payload rides is `selectTransport` in
 * `src/routing.ts`, measured at the 1 KB boundary where a body stops fitting a BLE packet.
 * This file is the discovery half — what a device says so that it can be found at all.
 *
 * That decision was already made and written down — in `sim/mesh_sim/lib/src/transport.dart`,
 * as `AdvertPayload.beacon`, with `sim/mesh_sim/test/transport_test.dart` asserting the layout.
 * What was missing is that it existed in **one** engine, in Dart, in a repository whose Dart
 * cannot be compiled where it is written: `storage.googleapis.com` is unreachable, so the SDK
 * is not installable and the format had never been executed anywhere. This file is the other
 * half of the same decision, in the engine that does run, so the twelve bytes are asserted by
 * a test that has actually passed.
 *
 * Two rules keep the halves from drifting:
 *
 *  - `BEACON_BYTES` and `DUMAN_MESH_SERVICE_UUID` are paired with Dart's `beaconBytes` and
 *    `dumanMeshServiceUuid` by `tool/ci/check-parity.py`, which converts the naming convention
 *    and compares the values. A size changed on one side only is a failing check, not a
 *    surprise on a phone.
 *  - The id hash is not a new function. It is `fnv1a32`, the same 32-bit FNV-1a the
 *    group-history digest already uses (`docs/06` §17), which is the trick this beacon shrinks
 *    to one packet: recognise the peer from 4 bytes, then compare 8 to learn whether it holds
 *    anything you are missing, without either side sending a list.
 *
 * Not a security boundary, and deliberately so: the id hash is a pseudonym in clear text on a
 * public channel. `docs/04` §2 is explicit that discovery carries no secret, and §4.2 of
 * `PRIVACY.md` says what a radio-range observer learns from it.
 */

import { fnv1a32 } from "./simulation";

/** The service UUID a scanner filters on (`skills/01`: `DUMAN_MESH_SVC`). */
export const DUMAN_MESH_SERVICE_UUID = "DUMAN_MESH_SVC";

/**
 * The beacon's size on air, which roadmap item 20 fixes at 12 bytes.
 *
 * Spelled as a literal on both engines rather than derived from the two field widths, because
 * `check-parity.py` compares constants textually: `8 + 4` on one side and `12` on the other
 * would be reported as a disagreement between two engines that agree.
 */
export const BEACON_BYTES = 12;

/** What a device advertises, and what a scanner receives. */
export interface AdvertPayload {
  /** This device's node id — `node-<index>` in both engines. */
  localId: string;
  /**
   * Digest of the local database, occupying beacon bytes 0..7.
   *
   * A `bigint` because the field is 64 bits wide and a JavaScript `number` is not: `>> 32` on a
   * number would silently produce zero, and a beacon whose high word is always zero is a beacon
   * that recognises every peer as holding the same database. Dart's side is a plain `int`,
   * which is 64-bit signed — so a digest of 2^63 or above is negative there and positive here,
   * and both write the same bytes because each masks to unsigned at the point of writing.
   * `encodeBeacon`'s test for `1n << 63n` is that agreement, pinned.
   *
   * How the digest is computed is the application's business and is not specified here: an app
   * refreshes it as its store changes, which is why it is a parameter rather than a constant.
   */
  dbHash: bigint;
  /**
   * The UUID to advertise under. Optional, and travels with the payload rather than being baked
   * into the implementation, because it is what a scanner filters on — a test that advertises
   * under a second UUID is testing the seam, not the radio.
   */
  serviceUuid?: string;
}

/**
 * FNV-1a/32 over the node id, for beacon bytes 8..11.
 *
 * Four lines, no dependency, and identical on both platforms — the reason it is FNV and not
 * something stronger is that a beacon has to be cheap to produce every two seconds and its
 * contents are public anyway. It is not a security primitive and must not be used as one.
 */
export function beaconIdHash(localId: string): number {
  return fnv1a32(localId);
}

/**
 * The twelve bytes that go on air: the digest big-endian in 0..7, the id hash in 8..11.
 *
 * Big-endian is the whole point of fixing this before either bridge exists — BLE advertising
 * data is a byte string with no native word order, so the two platforms would each pick their
 * own and neither beacon would match anybody's.
 */
export function encodeBeacon(payload: AdvertPayload): Uint8Array {
  const bytes = new Uint8Array(BEACON_BYTES);
  const view = new DataView(bytes.buffer);
  // BigInt.asUintN rather than a mask-and-convert: it is the two's-complement reading of the
  // low 32 bits, which is what Dart's `.toUnsigned(32)` produces for a negative `int`, and a
  // digest above 2^63 is negative in Dart and positive here.
  view.setUint32(0, Number(BigInt.asUintN(32, payload.dbHash >> 32n)), false);
  view.setUint32(4, Number(BigInt.asUintN(32, payload.dbHash)), false);
  view.setUint32(8, beaconIdHash(payload.localId), false);
  return bytes;
}

/** What the beacon says, read back out of the bytes a scanner was handed. */
export interface DecodedBeacon {
  /** The advertiser's database digest, unsigned across the full 64 bits. */
  dbHash: bigint;
  /** The advertiser's id hash — a pseudonym, not an identity. */
  idHash: number;
}

/**
 * Parse twelve bytes heard on air.
 *
 * Throws rather than returning `undefined` on a short or long buffer, because a scanner hears
 * whatever is being advertised nearby and most of it is not ours: the caller has to distinguish
 * "not a Duman beacon" from "a Duman beacon with an empty database", and a silent `undefined`
 * merges the two.
 */
export function decodeBeacon(bytes: Uint8Array): DecodedBeacon {
  if (bytes.length !== BEACON_BYTES) {
    throw new RangeError(
      `a Duman beacon is ${BEACON_BYTES} bytes; got ${bytes.length}`
    );
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const hi = BigInt(view.getUint32(0, false));
  const lo = BigInt(view.getUint32(4, false));
  return { dbHash: (hi << 32n) | lo, idHash: view.getUint32(8, false) };
}

/** What a device is advertising, as a scanner would see it: the UUID to filter on plus the bytes. */
export interface Advertisement {
  serviceUuid: string;
  beacon: Uint8Array;
  /** Carried alongside the bytes so a caller can refresh the digest without re-encoding. */
  localId: string;
  dbHash: bigint;
}

/**
 * Put a payload on air.
 *
 * The UUID travels with the advertisement rather than being baked in here, because it is what a
 * scanner filters on and a test needs to advertise under a second one without this file caring.
 * Dart's seam is stateful — `startAdvertising` replaces the current advertisement, and `stop()`
 * clears it, because a radio holds one advertisement at a time. This function is pure, so the
 * interesting half of that contract (idempotence: a device advertises, it does not accumulate
 * advertisements) is asserted by calling it twice and comparing bytes; the stateful half belongs
 * to whichever bridge owns the radio.
 */
export function advertise(payload: AdvertPayload): Advertisement {
  return {
    serviceUuid: payload.serviceUuid ?? DUMAN_MESH_SERVICE_UUID,
    beacon: encodeBeacon(payload),
    localId: payload.localId,
    dbHash: payload.dbHash,
  };
}

/**
 * Whether two devices holding these beacons have the same database.
 *
 * The comparison the beacon exists to make cheap: 8 bytes, no list, no round trip. Callers that
 * also want to know *who* is on the other end compare `idHash`, and should treat a match as a
 * pseudonym rather than an identity — 32 bits over a small id space is a collision an adversary
 * can manufacture, which is fine for "same database?" and would not be fine for "is this Amir?".
 */
export function sameDatabase(a: DecodedBeacon, b: DecodedBeacon): boolean {
  return a.dbHash === b.dbHash;
}
