/**
 * The Noise_XX handshake, checked as a protocol rather than as a cipher.
 *
 * What is asserted here is the part this repository owns: that two independent
 * state machines agree, that each leg is the size `docs/07` §7.2 asks about, that
 * a tampered leg is *detected* (where, and by whom), that a mismatched prologue
 * cannot be spliced, and that the simultaneous-open tie-break is a total order.
 * The primitives underneath are OpenSSL's and are not re-tested here — that would
 * be testing Node.
 */
import { describe, expect, it } from "vitest";
import {
  assertPkcs8Prefixes,
  concat,
  equalBytes,
  nodePrimitives as p,
  toHex,
} from "../primitives";
import {
  HandshakeState,
  LEG_SIZES,
  NoiseError,
  PROTOCOL_NAME,
  encodeNonce,
  handshakeInProcess,
  noiseHkdf,
  resolveSimultaneousOpen,
} from "../noise-xx";
import { decodeNonce } from "../ratchet";
import { generateIdentity } from "../identity";
import type { X25519KeyPair } from "../primitives";

function twoKeys(): [X25519KeyPair, X25519KeyPair] {
  return [p.generateX25519(), p.generateX25519()];
}

describe("primitives seam", () => {
  it("still matches the PKCS#8 encoding Node emits, so a Node upgrade cannot silently corrupt key import", () => {
    // The prefixes are hard-coded in primitives.ts because importing a private key
    // from its 32-byte seed needs them, and deriving the public half instead would
    // mean implementing the scalar multiply — i.e. the custom crypto skills/03
    // forbids. Hard-coded DER is only safe if something re-derives it.
    expect(assertPkcs8Prefixes()).toBe(true);
  });

  it("agrees on a shared secret from both directions, which is the only property of X25519 this layer relies on", () => {
    const [a, b] = twoKeys();
    expect(equalBytes(p.dh(a.privateKey, b.publicKey), p.dh(b.privateKey, a.publicKey))).toBe(true);
  });

  it("signs and verifies, and rejects a signature over different bytes", () => {
    const id = generateIdentity(p);
    const message = new TextEncoder().encode("duman");
    const signature = p.signEd25519(id.signing.privateKey, message);
    expect(p.verifyEd25519(id.signing.publicKey, message, signature)).toBe(true);
    expect(
      p.verifyEd25519(id.signing.publicKey, new TextEncoder().encode("dumam"), signature)
    ).toBe(false);
    const other = generateIdentity(p);
    expect(p.verifyEd25519(other.signing.publicKey, message, signature)).toBe(false);
  });

  it("returns null, not an exception, for a tampered AEAD — the property the capture test depends on", () => {
    const key = p.randomBytes(32);
    const nonce = encodeNonce(0);
    const sealed = p.seal(key, nonce, new TextEncoder().encode("secret"), new Uint8Array(0));
    expect(p.open(key, nonce, sealed, new Uint8Array(0))).not.toBeNull();
    const touched = Uint8Array.from(sealed);
    touched[0] ^= 0x01;
    expect(p.open(key, nonce, touched, new Uint8Array(0))).toBeNull();
    // Wrong key is indistinguishable from tampering, which is the point: an
    // observer learns nothing from an attempt it was not meant to succeed at.
    expect(p.open(p.randomBytes(32), nonce, sealed, new Uint8Array(0))).toBeNull();
  });
});

describe("Noise_XX", () => {
  it("is the protocol skills/03 names, and its name is exactly HASHLEN bytes", () => {
    expect(PROTOCOL_NAME).toBe("Noise_XX_25519_ChaChaPoly_SHA256");
    // 32 characters is why `initialize` takes the padding branch rather than the
    // hashing one. Both branches exist because a longer hash would take the other,
    // and a missing branch would truncate instead of hashing.
    expect(new TextEncoder().encode(PROTOCOL_NAME).length).toBe(32);
  });

  it("derives identical transport keys and an identical transcript hash on both sides", () => {
    const [a, b] = twoKeys();
    const { alice, bob } = handshakeInProcess(p, a, b);
    expect(equalBytes(alice.c1.key!, bob.c1.key!)).toBe(true);
    expect(equalBytes(alice.c2.key!, bob.c2.key!)).toBe(true);
    expect(equalBytes(alice.handshakeHash, bob.handshakeHash)).toBe(true);
    expect(equalBytes(alice.c1.key!, alice.c2.key!)).toBe(false);
    expect(equalBytes(alice.remoteStatic, b.publicKey)).toBe(true);
    expect(equalBytes(bob.remoteStatic, a.publicKey)).toBe(true);
    expect(alice.c1.n).toBe(0);
  });

  it("carries a payload on each leg, which is how a first message rides along with the handshake", () => {
    const [a, b] = twoKeys();
    const payloads = [
      new TextEncoder().encode("leg1"),
      new TextEncoder().encode("leg2"),
      new TextEncoder().encode("leg3"),
    ];
    const initiator = new HandshakeState(p, true, { s: a });
    const responder = new HandshakeState(p, false, { s: b });
    expect(new TextDecoder().decode(responder.readMessage(initiator.writeMessage(payloads[0]), 4))).toBe("leg1");
    expect(new TextDecoder().decode(initiator.readMessage(responder.writeMessage(payloads[1]), 4))).toBe("leg2");
    expect(new TextDecoder().decode(responder.readMessage(initiator.writeMessage(payloads[2]), 4))).toBe("leg3");
    expect(initiator.isComplete).toBe(true);
    expect(responder.isComplete).toBe(true);
  });

  it("produces legs of the size docs/07 §7.2 asks about — none of them near a 247-byte GATT MTU", () => {
    const [a, b] = twoKeys();
    const { legs } = handshakeInProcess(p, a, b);
    expect(legs.map((leg) => leg.length)).toEqual([...LEG_SIZES]);
    // §7.2 worried that "the 256 B padded block fits a negotiated 247 B MTU only
    // by luck". That is a data-plane worry: the handshake legs are 32, 80 and 48
    // bytes, so a handshake needs no MTU negotiation and no fragmentation at all.
    const GATT_MTU = 247;
    for (const size of LEG_SIZES) expect(size).toBeLessThanOrEqual(GATT_MTU);
    expect(Math.max(...LEG_SIZES)).toBe(96);
    // The largest leg leaves 151 B of a negotiated 247 B MTU unused.
    expect(GATT_MTU - Math.max(...LEG_SIZES)).toBe(151);
  });

  it("refuses to let either side write or read the other's leg", () => {
    const [a, b] = twoKeys();
    const initiator = new HandshakeState(p, true, { s: a });
    const responder = new HandshakeState(p, false, { s: b });
    expect(() => responder.writeMessage()).toThrow(NoiseError);
    expect(() => initiator.readMessage(new Uint8Array(32))).toThrow(NoiseError);
    initiator.writeMessage();
    expect(() => initiator.writeMessage()).toThrow(NoiseError);
  });

  it("detects a tampered leg 1 — at leg 2, by the initiator, because leg 1 is not encrypted", () => {
    // A bare ephemeral key has no tag on it, so nothing can fail on arrival. What
    // fails is the *next* leg: the responder mixed the tampered key into its
    // transcript, so its encrypted static no longer authenticates for the initiator.
    const [a, b] = twoKeys();
    const initiator = new HandshakeState(p, true, { s: a });
    const responder = new HandshakeState(p, false, { s: b });
    const leg1 = initiator.writeMessage();
    const touched = Uint8Array.from(leg1);
    touched[10] ^= 0x40;
    responder.readMessage(touched); // accepted: there is nothing to check yet
    const leg2 = responder.writeMessage();
    expect(() => initiator.readMessage(leg2)).toThrow(NoiseError);
  });

  it("detects a tampered leg 2 immediately, and a tampered leg 3 immediately", () => {
    const [a, b] = twoKeys();
    const initiator = new HandshakeState(p, true, { s: a });
    const responder = new HandshakeState(p, false, { s: b });
    responder.readMessage(initiator.writeMessage());
    const leg2 = Uint8Array.from(responder.writeMessage());
    leg2[leg2.length - 1] ^= 0x01; // the last byte is inside the AEAD tag
    expect(() => initiator.readMessage(leg2)).toThrow(/aead|decryption/i);

    const [c, d] = twoKeys();
    const i2 = new HandshakeState(p, true, { s: c });
    const r2 = new HandshakeState(p, false, { s: d });
    r2.readMessage(i2.writeMessage());
    i2.readMessage(r2.writeMessage());
    const leg3 = Uint8Array.from(i2.writeMessage());
    leg3[5] ^= 0x02;
    expect(() => r2.readMessage(leg3)).toThrow(NoiseError);
  });

  it("rejects a truncated leg rather than reading past the end", () => {
    const [a, b] = twoKeys();
    const initiator = new HandshakeState(p, true, { s: a });
    const responder = new HandshakeState(p, false, { s: b });
    responder.readMessage(initiator.writeMessage());
    const leg2 = responder.writeMessage();
    // Cut inside the responder's ephemeral, so the reader runs out of bytes before
    // it reaches anything with a tag on it. Chopping the *last* byte instead would
    // be reported as an AEAD failure, which is also correct but tests less.
    expect(leg2).toHaveLength(96);
    expect(() => initiator.readMessage(leg2.subarray(0, 20))).toThrow(/truncated|need/i);
  });

  it("cannot be spliced: a prologue the two sides disagree on fails the handshake", () => {
    // docs/04 §1's "active relay attacker". Without a prologue binding the two
    // identities, XX proves only that *a* session exists between two static keys;
    // with one, a relay that stitches together halves of two sessions gets a
    // transcript hash nobody can produce.
    const [a, b] = twoKeys();
    const prologueA = new TextEncoder().encode("alice-and-bob");
    const prologueB = new TextEncoder().encode("alice-and-mallory");
    const initiator = new HandshakeState(p, true, { s: a }, prologueA);
    const responder = new HandshakeState(p, false, { s: b }, prologueB);
    responder.readMessage(initiator.writeMessage());
    expect(() => initiator.readMessage(responder.writeMessage())).toThrow(NoiseError);
  });

  it("refuses another leg once the handshake is complete", () => {
    const [a, b] = twoKeys();
    const initiator = new HandshakeState(p, true, { s: a });
    const responder = new HandshakeState(p, false, { s: b });
    responder.readMessage(initiator.writeMessage());
    initiator.readMessage(responder.writeMessage());
    responder.readMessage(initiator.writeMessage());
    expect(() => initiator.writeMessage()).toThrow(/complete/i);
    expect(() => initiator.result()).not.toThrow();
  });

  it("zeroizes an ephemeral key that a simultaneous open has to abandon (docs/07 §7.1)", () => {
    // §7.1 asks whether the loser discards or reuses its ephemeral key. It must
    // discard it: an ephemeral reused across two transcripts is not ephemeral, and
    // the aborted half-session's forward secrecy rests on that key being dead.
    const [a, b] = twoKeys();
    const loser = new HandshakeState(p, true, { s: a });
    const leg1 = loser.writeMessage();
    // The reference, not a copy: zeroization has to be observed on the buffer the
    // state machine actually held, or the test proves nothing.
    const held = loser.ephemeralPublic!;
    const snapshot = Uint8Array.from(held);
    expect(snapshot.some((byte) => byte !== 0)).toBe(true);
    expect(leg1.subarray(0, 32)).toEqual(snapshot);
    loser.discardEphemeral();
    expect(held.every((byte) => byte === 0)).toBe(true);
    expect(loser.ephemeralPublic).toBeNull();
  });
});

describe("simultaneous open (docs/07 §7.1)", () => {
  it("is a total order both devices compute the same way from keys they already hold", () => {
    const [a, b] = twoKeys();
    const fromA = resolveSimultaneousOpen(a.publicKey, b.publicKey);
    const fromB = resolveSimultaneousOpen(b.publicKey, a.publicKey);
    expect(fromA).not.toBe("identical");
    // Antisymmetry is the property that makes exactly one side win.
    expect([fromA, fromB].sort()).toEqual(["accept", "initiate"]);
    expect(resolveSimultaneousOpen(a.publicKey, Uint8Array.from(a.publicKey))).toBe("identical");
  });

  it("agrees with itself over many key pairs, i.e. there is no input where both sides initiate", () => {
    for (let i = 0; i < 40; i++) {
      const [a, b] = twoKeys();
      const x = resolveSimultaneousOpen(a.publicKey, b.publicKey);
      const y = resolveSimultaneousOpen(b.publicKey, a.publicKey);
      expect(x === "initiate" ? y : x).toBe("accept");
    }
  });
});

describe("Noise HKDF and the nonce encoding", () => {
  it("chains its outputs the way the spec says, so the 3-output case extends the 2-output one", () => {
    const ck = p.randomBytes(32);
    const ikm = p.randomBytes(32);
    const two = noiseHkdf(p, ck, ikm, 2);
    const three = noiseHkdf(p, ck, ikm, 3);
    expect(two).toHaveLength(2);
    expect(three).toHaveLength(3);
    for (const output of three) expect(output).toHaveLength(32);
    expect(equalBytes(two[0], three[0])).toBe(true);
    expect(equalBytes(two[1], three[1])).toBe(true);
    expect(equalBytes(two[0], two[1])).toBe(false);
    // Different input key material gives a different chain: MixKey must not be a
    // no-op when the DH output changes.
    const other = noiseHkdf(p, ck, p.randomBytes(32), 2);
    expect(equalBytes(two[0], other[0])).toBe(false);
  });

  it("encodes the counter as a 96-bit little-endian nonce with the high bytes zero", () => {
    const zero = encodeNonce(0);
    expect(zero).toHaveLength(12);
    expect(zero.every((byte) => byte === 0)).toBe(true);
    const one = encodeNonce(1);
    expect(Array.from(one)).toEqual([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]);
    const wide = encodeNonce(0x0102);
    expect(Array.from(wide.subarray(4, 6))).toEqual([0x02, 0x01]);
    expect(() => encodeNonce(-1)).toThrow(RangeError);
  });

  it("reads a message number back off a wire nonce, and rejects one that is not a Duman nonce", () => {
    for (const n of [0, 1, 7, 63, 64, 65535, 1_000_000]) {
      expect(decodeNonce(encodeNonce(n))).toBe(n);
    }
    // The high four bytes must be zero. A peer that sends a nonce this layer would
    // never produce is not a gap in the ratchet, it is a malformed packet, and
    // treating it as a huge message number would let it drive the skip cache.
    const high = encodeNonce(1);
    high[0] = 1;
    expect(decodeNonce(high)).toBeNull();
    expect(decodeNonce(new Uint8Array(11))).toBeNull();
  });
});

describe("the handshake transcript is bound to the keys, not to the run", () => {
  it("gives two different key pairs two different transcript hashes", () => {
    const [a, b] = twoKeys();
    const [c, d] = twoKeys();
    const first = handshakeInProcess(p, a, b);
    const second = handshakeInProcess(p, c, d);
    expect(equalBytes(first.alice.handshakeHash, second.alice.handshakeHash)).toBe(false);
    expect(toHex(first.alice.handshakeHash)).toHaveLength(64);
  });

  it("changes when a 64-byte prologue changes, which is what makes sessionPrologue worth having", () => {
    const alice = generateIdentity(p);
    const bob = generateIdentity(p);
    const forward = concat(alice.nodeIdBytes, bob.nodeIdBytes);
    const backward = concat(bob.nodeIdBytes, alice.nodeIdBytes);
    // sessionPrologue orders the pair so both sides compute one value; the point
    // here is that the unordered inputs genuinely differ, so the ordering is doing
    // work rather than being decoration.
    expect(equalBytes(forward, backward)).toBe(false);
    const first = handshakeInProcess(p, alice.exchange, bob.exchange, forward);
    const second = handshakeInProcess(p, alice.exchange, bob.exchange, backward);
    expect(equalBytes(first.alice.handshakeHash, first.bob.handshakeHash)).toBe(true);
    expect(equalBytes(first.alice.handshakeHash, second.alice.handshakeHash)).toBe(false);
    // A 64-byte prologue is longer than HASHLEN, so it goes through MixHash and
    // not through the name-padding branch — worth knowing both paths run.
    expect(forward).toHaveLength(64);
  });
});
