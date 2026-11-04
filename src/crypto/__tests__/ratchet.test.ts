/**
 * The per-message ratchet: `skills/03`'s "ratchet per message (Double Ratchet
 * light) for FS", and `docs/07` §6's note that it "must tolerate out-of-order and
 * retransmitted messages".
 *
 * The forward-secrecy test below is written the only way that is honest: it names
 * the state an attacker actually gets ([SymmetricRatchet.compromise]), rebuilds a
 * ratchet from nothing but that, and checks what it can and cannot decrypt. It
 * does not ask the ratchet for its old keys, because a ratchet that could answer
 * that would have failed the property being tested.
 */
import { describe, expect, it } from "vitest";
import { equalBytes, nodePrimitives as p } from "../primitives";
import { MAX_SKIP, SymmetricRatchet, decodeNonce, deriveRatchetSeed, ratchetPair } from "../ratchet";

const SEED = new TextEncoder().encode("a-32-byte-seed-for-the-ratchet!!");

function pair(): { send: SymmetricRatchet; recv: SymmetricRatchet } {
  return { send: new SymmetricRatchet(p, SEED), recv: new SymmetricRatchet(p, SEED) };
}

function body(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function text(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

describe("the ratchet advances", () => {
  it("seals and opens in order", () => {
    const { send, recv } = pair();
    for (const message of ["first", "second", "third"]) {
      const sealed = send.seal(body(message));
      const opened = recv.open(sealed.num, sealed.sealed);
      expect(opened.ok).toBe(true);
      if (opened.ok) expect(text(opened.plaintext)).toBe(message);
    }
    expect(send.nextSendNum).toBe(3);
    expect(recv.nextExpectedNum).toBe(3);
  });

  it("uses a different key per message, so the same body does not produce the same bytes", () => {
    const { send, recv } = pair();
    const a = send.seal(body("yes"));
    const b = send.seal(body("yes"));
    expect(equalBytes(a.sealed, b.sealed)).toBe(false);
    expect(a.num).toBe(0);
    expect(b.num).toBe(1);
    expect(equalBytes(a.nonce, b.nonce)).toBe(false);
    // Both still open, in order.
    expect(recv.open(a.num, a.sealed).ok).toBe(true);
    expect(recv.open(b.num, b.sealed).ok).toBe(true);
  });

  it("puts the message number in the nonce, so a receiver can ask for the right key", () => {
    const { send } = pair();
    const sealed = send.seal(body("x"));
    expect(decodeNonce(sealed.nonce)).toBe(sealed.num);
  });

  it("domain-separates the two chains, so one cannot stand in for the other", () => {
    const key = p.randomBytes(32);
    const c1Seed = deriveRatchetSeed(p, key, "c1");
    const c2Seed = deriveRatchetSeed(p, key, "c2");
    expect(equalBytes(c1Seed, c2Seed)).toBe(false);
    expect(c1Seed).toHaveLength(32);
    // The label names the chain, not the local direction: `Split()` gives the
    // initiator c1 to send on and the responder c1 to receive on, so both sides
    // derive the same seed for the same chain and different seeds for different
    // ones. Naming it "send"/"recv" instead silently breaks every session.
    expect(deriveRatchetSeed(p, key, "c1")).toEqual(c1Seed);
    // A message sealed on one chain does not open on a ratchet seeded from the same
    // transport key with the other label.
    const send = new SymmetricRatchet(p, c1Seed);
    const wrong = new SymmetricRatchet(p, c2Seed);
    const sealed = send.seal(body("hello"));
    const opened = wrong.open(sealed.num, sealed.sealed);
    expect(opened.ok).toBe(false);
    if (!opened.ok) expect(opened.reason).toBe("auth-failed");
  });

  it("builds an independent send and receive ratchet from a Noise Split()", () => {
    const c1 = p.randomBytes(32);
    const c2 = p.randomBytes(32);
    const alice = ratchetPair(p, c1, c2);
    const bob = ratchetPair(p, c2, c1);
    const sealed = alice.send.seal(body("ping"));
    const opened = bob.recv.open(sealed.num, sealed.sealed);
    expect(opened.ok).toBe(true);
    // Crossing the wires must fail: alice's send chain is bob's receive chain and
    // nobody else's.
    expect(alice.recv.open(sealed.num, sealed.sealed).ok).toBe(false);
  });
});

describe("out of order, which docs/07 §6 says the mesh will produce", () => {
  it("opens messages that arrive in any order inside the skip window", () => {
    const { send, recv } = pair();
    const sealed = ["zero", "one", "two", "three", "four", "five"].map((message) =>
      send.seal(body(message))
    );
    // A mesh reorder: 3, 1, 5, 0, 2, 4.
    for (const index of [3, 1, 5, 0, 2, 4]) {
      const opened = recv.open(sealed[index].num, sealed[index].sealed);
      expect(opened.ok, `message ${index}`).toBe(true);
      if (opened.ok) expect(text(opened.plaintext)).toBe(["zero", "one", "two", "three", "four", "five"][index]);
    }
    expect(recv.cachedSkips).toBe(0);
  });

  it("caches exactly the keys it stepped over, and no more", () => {
    const { send, recv } = pair();
    const sealed = Array.from({ length: 5 }, (_, i) => send.seal(body(`m${i}`)));
    expect(recv.cachedSkips).toBe(0);
    expect(recv.open(4, sealed[4].sealed).ok).toBe(true);
    // Jumping to 4 derived and stored keys 0-3.
    expect(recv.cachedSkips).toBe(4);
    expect(recv.nextExpectedNum).toBe(5);
    for (const index of [0, 1, 2, 3]) {
      expect(recv.open(index, sealed[index].sealed).ok, `message ${index}`).toBe(true);
    }
    expect(recv.cachedSkips).toBe(0);
  });

  it("rejects a retransmission as a replay rather than as an authentication failure", () => {
    // The mesh retransmits whole messages (`attempt` in src/types.ts) and the
    // engine dedups on `id#attempt` above this layer, so a replay reaching the
    // ratchet is normal traffic. Calling it "auth-failed" would make a healthy
    // network look like an attacked one.
    const { send, recv } = pair();
    const sealed = send.seal(body("once"));
    expect(recv.open(sealed.num, sealed.sealed).ok).toBe(true);
    const again = recv.open(sealed.num, sealed.sealed);
    expect(again.ok).toBe(false);
    if (!again.ok) expect(again.reason).toBe("replay");
  });

  it("refuses to pre-derive beyond the window, because an unbounded cache is a denial of service", () => {
    const { send, recv } = pair();
    expect(MAX_SKIP).toBe(64);
    const far = recv.keyFor(recv.nextExpectedNum + MAX_SKIP + 1);
    expect(far.ok).toBe(false);
    if (!far.ok) expect(far.reason).toBe("gap-too-large");
    // Nothing was consumed getting there: a hostile number must not move the
    // receiver's state, or one packet would desynchronise a session.
    expect(recv.nextExpectedNum).toBe(0);
    expect(recv.cachedSkips).toBe(0);
    const sealed = send.seal(body("still fine"));
    expect(recv.open(sealed.num, sealed.sealed).ok).toBe(true);
    // The window edge itself is allowed, and costs exactly MAX_SKIP stored keys.
    const { send: s2, recv: r2 } = pair();
    const burst = Array.from({ length: MAX_SKIP + 1 }, (_, i) => s2.seal(body(`m${i}`)));
    const furthest = burst[MAX_SKIP];
    expect(furthest.num).toBe(MAX_SKIP);
    expect(r2.open(furthest.num, furthest.sealed).ok).toBe(true);
    // Getting to 64 derived and stored keys 0..63. That is the whole cost an
    // attacker can impose with one packet, and it is the reason the window exists.
    expect(r2.cachedSkips).toBe(MAX_SKIP);
    expect(r2.open(0, burst[0].sealed).ok).toBe(true);
    expect(r2.cachedSkips).toBe(MAX_SKIP - 1);
  });

  it("rejects a negative or impossible message number", () => {
    const { recv } = pair();
    expect(recv.keyFor(-1).ok).toBe(false);
    expect(recv.keyFor(Number.NaN).ok).toBe(false);
    expect(recv.keyFor(Number.MAX_SAFE_INTEGER).ok).toBe(false);
  });

  it("reports a tampered ciphertext as auth-failed, distinctly from a replay", () => {
    const { send, recv } = pair();
    const sealed = send.seal(body("hello"));
    const touched = Uint8Array.from(sealed.sealed);
    touched[0] ^= 0x80;
    const opened = recv.open(sealed.num, touched);
    expect(opened.ok).toBe(false);
    if (!opened.ok) expect(opened.reason).toBe("auth-failed");
  });
});

describe("forward secrecy — skills/03 acceptance line 2", () => {
  it("a compromise after four messages cannot decrypt any of them, and can decrypt the fifth", () => {
    const { send, recv } = pair();
    const sealed = ["one", "two", "three", "four", "five"].map((message) => send.seal(body(message)));

    // The receiver opens the first four. Each message key is derived, used and
    // zeroed; nothing accumulates.
    for (const index of [0, 1, 2, 3]) {
      const opened = recv.open(sealed[index].num, sealed[index].sealed);
      expect(opened.ok, `message ${index}`).toBe(true);
    }

    // What an attacker who takes the device now holds.
    const stolen = recv.compromise();
    expect(stolen.nextRecvNum).toBe(4);
    expect(stolen.skipped).toHaveLength(0);
    expect(stolen.chainKey).toHaveLength(32);

    // The attacker rebuilds a ratchet from nothing but that.
    const attacker = SymmetricRatchet.restore(p, stolen);
    expect(attacker.nextExpectedNum).toBe(4);

    // Every earlier message is beyond reach: the numbers are behind the receiver's
    // counter and no key for them survived.
    for (const index of [0, 1, 2, 3]) {
      const attempt = attacker.open(sealed[index].num, sealed[index].sealed);
      expect(attempt.ok, `message ${index} must not open`).toBe(false);
      if (!attempt.ok) expect(attempt.reason).toBe("replay");
    }

    // The fifth message, which had not arrived yet, does open — the compromise is
    // real, and its reach starts at the moment it happened.
    const fifth = attacker.open(sealed[4].num, sealed[4].sealed);
    expect(fifth.ok).toBe(true);
    if (fifth.ok) expect(text(fifth.plaintext)).toBe("five");
  });

  it("exposes no chain key from an earlier step, which is the actual one-way property", () => {
    const ratchet = new SymmetricRatchet(p, SEED);
    const chainKeys: Uint8Array[] = [];
    for (let i = 0; i < 5; i++) {
      // Copied before each step, because `step()` zeroes the buffer it is
      // replacing — reading it afterwards would show zeros and prove nothing.
      chainKeys.push(Uint8Array.from(ratchet.compromise().chainKey));
      ratchet.seal(body(`m${i}`));
    }
    // Five consecutive chain keys, all distinct: the chain does not cycle and no
    // step repeats a key it has already used. Distinctness is the observable half
    // of one-wayness; the other half is that nothing here can walk backwards, and
    // the test above is what checks that.
    for (let i = 0; i < chainKeys.length; i++) {
      for (let j = i + 1; j < chainKeys.length; j++) {
        expect(equalBytes(chainKeys[i], chainKeys[j]), `chain keys ${i} and ${j}`).toBe(false);
      }
    }
    // Step 0's chain key is the seed itself, so the seed is not reused as a
    // message key and the first step is a real derivation.
    expect(chainKeys[0]).toEqual(SEED);
    expect(chainKeys.every((key) => key.every((byte) => byte !== 0) || key === chainKeys[0])).toBe(true);
  });

  it("keeps the sending and receiving chains independent, so one compromise is not both", () => {
    const send = new SymmetricRatchet(p, deriveRatchetSeed(p, SEED, "c1"));
    const recv = new SymmetricRatchet(p, deriveRatchetSeed(p, SEED, "c2"));
    send.seal(body("a"));
    send.seal(body("b"));
    const sendState = send.compromise();
    const recvState = recv.compromise();
    expect(equalBytes(sendState.chainKey, recvState.chainKey)).toBe(false);
    expect(sendState.sendNum).toBe(2);
    expect(recvState.nextRecvNum).toBe(0);
  });

  it("leaves nothing usable after a wipe", () => {
    const ratchet = new SymmetricRatchet(p, SEED);
    ratchet.seal(body("x"));
    ratchet.wipe();
    expect(ratchet.nextSendNum).toBe(0);
    expect(ratchet.cachedSkips).toBe(0);
    // A terminal wipe must not produce ciphertext under a publicly known zero seed.
    expect(() => ratchet.seal(body("x"))).toThrow("wiped");
    expect(ratchet.keyFor(0)).toEqual({ ok: false, reason: "wiped" });
  });
});
