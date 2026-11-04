/**
 * `skills/03`'s three acceptance criteria, and `docs/07` §7's four open questions,
 * as tests.
 *
 * `docs/07` §6 maps the acceptance criteria to "not started — needs the crypto
 * library". These are the first two rows started, and the third one finished:
 *
 *   1. 2 peers: QR exchange -> Noise handshake -> E2EE DM a SUPER cannot decrypt
 *   2. Forward secrecy: compromise after = cannot decrypt prior
 *   3. Audit checklist: no plaintext PII in logs, destHint leaks only an 8 B hash
 *
 * The "SUPER cannot decrypt" test is written as a capture test in the sense
 * `skills/03` means: a relay that is a legitimate peer of the sender, holding real
 * keys from its own session with her, tries the captured bytes and fails. A relay
 * with a random key would fail too and prove nothing.
 */
import { describe, expect, it } from "vitest";
import { equalBytes, nodePrimitives as p, toHex } from "../primitives";
import { SymmetricRatchet, decodeNonce } from "../ratchet";
import {
  DumanSession,
  SESSION_TTL_MS,
  SessionCache,
  sessionPrologueFromQr,
  whoInitiates,
} from "../session";
import { addContactLink, decodeQr, encodeQr, generateIdentity, isWiped, parseAddContactLink } from "../identity";
import { SAS_CHAR_COUNT, SAS_EMOJI_COUNT, identitySas, isWellFormedSas } from "../sas";
import { HEADER_BYTES, NONCE_BYTES, openPacket, relayVisible } from "../packet";
import { wireSizeOfBody } from "../../routing";
import type { Identity } from "../identity";

interface Established {
  alice: DumanSession;
  bob: DumanSession;
  aliceId: Identity;
  bobId: Identity;
  legs: Uint8Array[];
  captured: Uint8Array[];
}

/**
 * Run the QR flow and the three legs the way the mesh would, capturing every byte
 * that goes on air into [Established.captured] so a relay can be handed exactly
 * what a relay would see.
 */
function establish(verify = true): Established {
  const aliceId = generateIdentity(p);
  const bobId = generateIdentity(p);
  const captured: Uint8Array[] = [];

  // Step 1: Bob scans Alice's QR. Everything either side needs is in it.
  const qr = decodeQr(encodeQr(aliceId));
  expect(qr).not.toBeNull();
  expect(qr!.sas).toBe(aliceId.sas);
  expect(equalBytes(qr!.publicKey, aliceId.signing.publicKey)).toBe(true);

  // Step 2: both derive the same prologue from the scan alone. If they could not,
  // the prologue would be decoration rather than a binding.
  const prologueA = sessionPrologueFromQr(p, aliceId, bobId.signing.publicKey);
  const prologueB = sessionPrologueFromQr(p, bobId, aliceId.signing.publicKey);
  expect(equalBytes(prologueA, prologueB)).toBe(true);

  const alice = new DumanSession(p, aliceId, "initiator", prologueA);
  const bob = new DumanSession(p, bobId, "responder", prologueB);

  const leg1 = alice.writeLeg();
  expect(leg1).not.toBeNull();
  captured.push(leg1!);
  expect(bob.readLeg(leg1!)).not.toBeNull();

  const leg2 = bob.writeLeg();
  expect(leg2).not.toBeNull();
  captured.push(leg2!);
  expect(alice.readLeg(leg2!)).not.toBeNull();

  const leg3 = alice.writeLeg();
  expect(leg3).not.toBeNull();
  captured.push(leg3!);
  expect(bob.readLeg(leg3!)).not.toBeNull();

  expect(alice.currentPhase).toBe("unverified");
  expect(bob.currentPhase).toBe("unverified");

  // Step 3: two humans compare eight characters, or nine emoji.
  expect(alice.sas!.chars).toBe(bob.sas!.chars);
  if (verify) {
    expect(alice.confirmSas(bob.sas!.chars)).toBe(true);
    expect(bob.confirmSas(alice.sas!.chars)).toBe(true);
    expect(alice.currentPhase).toBe("verified");
    expect(bob.currentPhase).toBe("verified");
  }
  return { alice, bob, aliceId, bobId, legs: [leg1!, leg2!, leg3!], captured };
}

function send(alice: DumanSession, bobId: Identity, msgId: string, text: string, nowMs = 1_760_000_000_000) {
  return alice.send(
    {
      msgId,
      type: "text",
      ttl: 5,
      hop: 0,
      nowMs,
      body: new TextEncoder().encode(text),
    },
    bobId.signing.publicKey
  );
}

describe("skills/03 acceptance 1 — QR exchange, handshake, and a DM a SUPER cannot decrypt", () => {
  it("completes the whole flow and delivers a message", () => {
    const { alice, bob, bobId, aliceId } = establish();
    const packet = send(alice, bobId, "m000001", "meet at the atrium at 14:00");
    expect(packet).not.toBeNull();
    const received = bob.receive(packet!);
    expect(received.ok).toBe(true);
    if (!received.ok) return;
    expect(new TextDecoder().decode(received.body)).toBe("meet at the atrium at 14:00");
    expect(received.authenticated).toBe(true);
    expect(received.type).toBe("text");
    expect(received.ttl).toBe(5);
    expect(received.num).toBe(0);
    expect(equalBytes(received.from, aliceId.signing.publicKey)).toBe(true);
    expect(received.timestampMs).toBe(1_760_000_000_000);
  });

  it("is not readable by a SUPER relay that is itself a legitimate peer of the sender", () => {
    const { alice, bob, bobId, captured } = establish();
    const body = "the atrium, 14:00, and bring the battery pack";
    const packet = send(alice, bobId, "m000002", body)!;

    // A SUPER node that Alice also has a session with. It holds real keys — the
    // chain key from its own live session with her — which is the strongest
    // position a relay can be in short of having Bob's private key.
    const relayId = generateIdentity(p);
    const relaySession = new DumanSession(
      p,
      relayId,
      "responder",
      sessionPrologueFromQr(p, relayId, alice.identity.signing.publicKey)
    );
    const relayAsInitiator = new DumanSession(
      p,
      alice.identity,
      "initiator",
      sessionPrologueFromQr(p, alice.identity, relayId.signing.publicKey)
    );
    relaySession.readLeg(relayAsInitiator.writeLeg()!);
    relayAsInitiator.readLeg(relaySession.writeLeg()!);
    relaySession.readLeg(relayAsInitiator.writeLeg()!);
    expect(relaySession.currentPhase).toBe("unverified");

    // The relay's receive chain *is* the chain Alice seals to it on, so this is the
    // real message key Alice would use for message 0 to this relay — the strongest
    // position a relay can be in short of holding Bob's private key.
    const stolen = relaySession.compromise()!;
    const attacker = SymmetricRatchet.restore(p, stolen.recv);
    const num = decodeNonce(packet.subarray(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES))!;
    const derived = attacker.keyFor(num);
    expect(derived.ok).toBe(true); // a legitimate key, legitimately derived

    // Everything the relay can see is the header, and the header has no destination
    // in it (docs/04 §4's list has no `to`; the engine's MeshMessage does, because
    // a routing simulator has to route).
    const visible = relayVisible(packet);
    expect(visible).not.toBeNull();
    expect(visible!.bodyReadable).toBe(false);
    expect(visible!.ttl).toBe(5);

    // And the key does not open the packet: same sender, same message number,
    // different recipient, so a different session and a different chain.
    if (!derived.ok) return;
    const attempt = openPacket(p, derived.key, packet);
    expect(attempt.ok).toBe(false);
    if (!attempt.ok) expect(attempt.reason).toBe("auth-failed");

    // The body, the sender's key and the recipient's key are nowhere in the bytes
    // that went on air — including the three handshake legs, which is the part
    // often forgotten: leg 1 is a bare ephemeral and legs 2 and 3 carry the static
    // keys encrypted, so a passive sniffer that recorded all of it still learns
    // only two ephemeral public keys and a tag.
    const onAir = Buffer.concat([packet, ...captured.map((leg) => Buffer.from(leg))]).toString("latin1");
    expect(onAir).not.toContain("atrium");
    expect(onAir).not.toContain("battery pack");
    expect(onAir).not.toContain("m000002");
    expect(onAir).not.toContain(Buffer.from(bob.identity.signing.publicKey).toString("latin1"));
    // Bob, who holds the private key, reads it fine.
    expect(bob.receive(packet).ok).toBe(true);
  });

  it("lets messages flow before the SAS is compared, but marks them unproven — that is what TOFU means", () => {
    const { alice, bob, bobId } = establish(false);
    expect(alice.currentPhase).toBe("unverified");
    const packet = send(alice, bobId, "m000003", "hi before we verify")!;
    const received = bob.receive(packet);
    expect(received.ok).toBe(true);
    if (!received.ok) return;
    expect(received.authenticated).toBe(false);
    expect(new TextDecoder().decode(received.body)).toBe("hi before we verify");
    // Verifying upgrades the session, and the next message says so.
    expect(bob.confirmSas(alice.sas!.chars)).toBe(true);
    const second = send(alice, bobId, "m000004", "hi after", 1_760_000_000_001);
    const receivedSecond = bob.receive(second!);
    expect(receivedSecond.ok).toBe(true);
    if (receivedSecond.ok) expect(receivedSecond.authenticated).toBe(true);
  });

  it("produces the three legs docs/07 §2.1 measures, at sizes §7.2 asks about", () => {
    const { legs } = establish();
    expect(legs.map((leg) => leg.length)).toEqual([32, 96, 64]);
    // §7.2: does a leg fit a negotiated GATT MTU? All three do, unfragmented.
    for (const leg of legs) expect(leg.length).toBeLessThanOrEqual(247);
  });

  it("re-sends a lost leg byte for byte, which is what §2.1 note 2 requires", () => {
    // "Retry per leg, not per handshake": restarting turns a 5 % per-leg loss rate
    // into ~14 % failure over three legs. Retrying leg 3 has to be possible without
    // touching the transcript, and it is, because leg 3 carries no new randomness.
    const aliceId = generateIdentity(p);
    const bobId = generateIdentity(p);
    const prologue = sessionPrologueFromQr(p, aliceId, bobId.signing.publicKey);
    const alice = new DumanSession(p, aliceId, "initiator", prologue);
    const bob = new DumanSession(p, bobId, "responder", sessionPrologueFromQr(p, bobId, aliceId.signing.publicKey));

    const leg1 = alice.writeLeg()!;
    expect(alice.retryLeg()).toEqual(leg1); // leg 1 lost, re-sent
    bob.readLeg(leg1);
    const leg2 = bob.writeLeg()!;
    expect(bob.retryLeg()).toEqual(leg2); // leg 2 lost, re-sent
    alice.readLeg(leg2);
    const leg3 = alice.writeLeg()!;
    expect(alice.retryLeg()).toEqual(leg3); // leg 3 lost, re-sent
    bob.readLeg(leg3);
    expect(bob.currentPhase).toBe("unverified");
    expect(alice.currentPhase).toBe("unverified");
    // Once complete there is no *next* leg to write — but the last one is still
    // retryable, and that is precisely the case docs/07 §2.1 note 2 describes: the
    // initiator finishes the instant it writes leg 3, so if leg 3 is lost it is
    // `unverified` while the responder is still waiting, and the only correct
    // recovery is a retransmission of a leg whose transcript is already fixed.
    expect(alice.writeLeg()).toBeNull();
    expect(alice.retryLeg()).toEqual(leg3);
    expect(leg3).toHaveLength(64);
    // A wipe is what finally makes it unavailable.
    alice.panicWipe();
    expect(alice.retryLeg()).toBeNull();
  });

  it("fails when the two sides bind different prologues, so a spliced session cannot come up", () => {
    const aliceId = generateIdentity(p);
    const bobId = generateIdentity(p);
    const malloryId = generateIdentity(p);
    const alice = new DumanSession(p, aliceId, "initiator", sessionPrologueFromQr(p, aliceId, bobId.signing.publicKey));
    // A relay that thinks it is talking to Mallory on Bob's side.
    const bob = new DumanSession(p, bobId, "responder", sessionPrologueFromQr(p, bobId, malloryId.signing.publicKey));
    const leg1 = alice.writeLeg()!;
    expect(bob.readLeg(leg1)).not.toBeNull(); // leg 1 is unencrypted, so it reads
    const leg2 = bob.writeLeg()!;
    expect(() => alice.readLeg(leg2)).toThrow();
    expect(alice.currentPhase).toBe("failed");
    expect(alice.isUp).toBe(false);
  });
});

describe("skills/03 acceptance 2 — forward secrecy, verified by ratchet", () => {
  it("a compromise after three delivered messages cannot decrypt any of them", () => {
    const { alice, bob, bobId } = establish();
    const bodies = ["first", "second", "third", "fourth"];
    const packets = bodies.map((body, i) => send(alice, bobId, `m${i}`, body, 1_760_000_000_000 + i)!);

    for (let i = 0; i < 3; i++) {
      const received = bob.receive(packets[i]);
      expect(received.ok, `message ${i}`).toBe(true);
    }

    const stolen = bob.compromise();
    expect(stolen).not.toBeNull();
    expect(stolen!.phase).toBe("verified");
    expect(stolen!.recv.skipped).toHaveLength(0);

    // The attacker rebuilds a receiving ratchet from nothing but the stolen state
    // and tries every message that was already read.
    const attacker = SymmetricRatchet.restore(p, stolen!.recv);
    for (let i = 0; i < 3; i++) {
      const num = decodeNonce(packets[i].subarray(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES))!;
      const derived = attacker.keyFor(num);
      expect(derived.ok, `message ${i} must not yield a key`).toBe(false);
      if (!derived.ok) expect(derived.reason).toBe("replay");
    }

    // The fourth message had not arrived when the device was taken, so it is
    // readable — the compromise is real, and its reach begins at the moment it
    // happened. That asymmetry is the whole content of forward secrecy.
    const num = decodeNonce(packets[3].subarray(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES))!;
    const derived = attacker.keyFor(num);
    expect(derived.ok).toBe(true);
    if (!derived.ok) return;
    const opened = openPacket(p, derived.key, packets[3]);
    expect(opened.ok).toBe(true);
    if (opened.ok) expect(new TextDecoder().decode(opened.packet.body)).toBe("fourth");
  });

  it("keeps the two directions independent, so a stolen receive chain does not let an attacker send", () => {
    const { alice, bob, bobId } = establish();
    bob.receive(send(alice, bobId, "m0", "one")!);
    const stolen = bob.compromise()!;
    expect(equalBytes(stolen.send.chainKey, stolen.recv.chainKey)).toBe(false);
    expect(stolen.send.sendNum).toBe(0); // Bob has not sent anything
    expect(stolen.recv.nextRecvNum).toBe(1);
  });
});

describe("skills/03 acceptance 3 — the audit checklist", () => {
  it("leaks only an 8-byte destHint, and no plaintext identifier", () => {
    const { alice, bob, bobId, aliceId } = establish();
    const packet = send(alice, bobId, "m000042", "handle: Kemal, at the east gate")!;
    const visible = relayVisible(packet)!;
    expect(visible.destHint).toHaveLength(16); // 8 bytes, hex
    expect(visible.msgIdDigest).toHaveLength(32); // 16 bytes, hex
    // The hint is the destination's, not the sender's, and is a prefix of the
    // nodeId that docs/02 §2 broadcasts anyway — so it is a short routing label,
    // not the identity hiding docs/04 §4 claims. That is the finding, not a bug
    // here: the field does exactly what a 64-bit prefix of a public value can do.
    expect(visible.destHint).toBe(toHex(bobId.nodeIdBytes).slice(0, 16));
    expect(visible.destHint).not.toBe(toHex(aliceId.nodeIdBytes).slice(0, 16));

    const latin1 = Buffer.from(packet).toString("latin1");
    for (const leak of ["Kemal", "east gate", "m000042", "handle"]) {
      expect(latin1, `${leak} must not appear in a sealed packet`).not.toContain(leak);
    }
    // The sender's identity is inside the ciphertext, so a relay cannot name it.
    expect(Object.keys(visible).sort()).toEqual([
      "bodyReadable",
      "destHint",
      "hop",
      "msgIdDigest",
      "ttl",
      "type",
    ]);
    // The hint is enough to deliver: Bob, whose key produced it, reads the message.
    expect(bob.receive(packet).ok).toBe(true);
  });

  it("lets the receiver dedup on a digest, so an id never has to go on air to be recognised", () => {
    const { alice, bob, bobId } = establish();
    // Two *distinct* packets carrying the same logical message id: the ratchet
    // number differs, so both decrypt, and dedup has to happen on the digest above
    // this layer — which is what src/routing.ts `seenKey` already does on `id#attempt`.
    const first = send(alice, bobId, "m000042", "same id")!;
    const second = send(alice, bobId, "m000042", "same id", 1_760_000_000_001)!;
    const a = bob.receive(first);
    const b = bob.receive(second);
    expect(a.ok).toBe(true);
    expect(b.ok).toBe(true);
    if (!a.ok || !b.ok) return;
    expect(equalBytes(a.msgIdDigest, b.msgIdDigest)).toBe(true);
    expect(a.num).toBe(0);
    expect(b.num).toBe(1);
    // A different id gives a different digest, so the receiver can tell them apart
    // without ever seeing either id.
    const third = bob.receive(send(alice, bobId, "m000043", "same id")!);
    expect(third.ok).toBe(true);
    if (third.ok) expect(equalBytes(third.msgIdDigest, a.msgIdDigest)).toBe(false);
  });
});

describe("the SAS", () => {
  it("is eight readable characters and nine emoji, and both sides compute the same ones", () => {
    const { alice, bob } = establish(false);
    expect(alice.sas!.chars).toHaveLength(SAS_CHAR_COUNT);
    expect(isWellFormedSas(alice.sas!.chars)).toBe(true);
    expect(alice.sas!.emoji).toHaveLength(SAS_EMOJI_COUNT);
    expect(alice.sas!.emoji).toEqual([...bob.sas!.emoji]);
    expect(alice.sas!.chars).toBe(bob.sas!.chars);
  });

  it("is terminal when it does not match: a mismatch deletes the session rather than retrying it", () => {
    const { alice, bob } = establish(false);
    const wrong = bob.sas!.chars === "00000000" ? "00000001" : "00000000";
    expect(bob.confirmSas(wrong)).toBe(false);
    expect(bob.currentPhase).toBe("failed");
    expect(bob.isUp).toBe(false);
    // Re-handshaking with the same third party produces the same mismatch, so a
    // failed session must not be retryable — which is why this is `false` too.
    expect(bob.confirmSas(alice.sas!.chars)).toBe(false);
  });

  it("gives two different sessions two different SAS values", () => {
    const first = establish(false);
    const second = establish(false);
    expect(first.alice.sas!.chars).not.toBe(second.alice.sas!.chars);
  });

  it("fingerprints the long-term key for the QR, separately from the handshake SAS", () => {
    // docs/04 §2 puts a `sas8` in the QR, which has to be computable *before* any
    // handshake. It therefore cannot be the transcript SAS, and conflating the two
    // would let a man-in-the-middle through: the QR proves which key was scanned,
    // the handshake SAS proves which key is on the other end of this session.
    const identity = generateIdentity(p);
    const qr = decodeQr(encodeQr(identity))!;
    expect(qr.sas).toBe(identity.sas);
    expect(isWellFormedSas(qr.sas)).toBe(true);
    // And the two values are not the same value: a UI that showed only the QR
    // fingerprint would prove which key was scanned and nothing about the session.
    const { alice } = establish(false);
    expect(alice.sas!.chars).not.toBe(identity.sas);
  });
});

describe("docs/07 §7.1 — simultaneous open", () => {
  it("picks exactly one initiator from keys both devices already hold", () => {
    const a = generateIdentity(p);
    const b = generateIdentity(p);
    const fromA = whoInitiates(a.exchange.publicKey, b.exchange.publicKey);
    const fromB = whoInitiates(b.exchange.publicKey, a.exchange.publicKey);
    expect([fromA, fromB].sort()).toEqual(["accept", "initiate"]);
    expect(whoInitiates(a.exchange.publicKey, Uint8Array.from(a.exchange.publicKey))).toBe("identical");
  });

  it("lets the loser abandon its half-session, destroying the ephemeral it already put on air", () => {
    const a = generateIdentity(p);
    const b = generateIdentity(p);
    const prologueA = sessionPrologueFromQr(p, a, b.signing.publicKey);
    const prologueB = sessionPrologueFromQr(p, b, a.signing.publicKey);
    const fromA = new DumanSession(p, a, "initiator", prologueA);
    const fromB = new DumanSession(p, b, "initiator", prologueB);

    // Both tap "add". Both write leg 0, and what each receives is the other's
    // leg 0 — a bare ephemeral, not the leg 1 it is waiting for.
    const legFromA = fromA.writeLeg()!;
    const legFromB = fromB.writeLeg()!;
    expect(legFromA).toHaveLength(32);
    expect(legFromA).not.toEqual(legFromB);
    expect(fromA.readLeg(legFromB)).toBeNull();
    expect(fromB.readLeg(legFromA)).toBeNull();
    // Detected as a collision rather than consumed as a truncated leg 1, which is
    // the difference between a recoverable tie and two dead sessions.
    expect(fromA.simultaneousOpen).toBe(true);
    expect(fromB.simultaneousOpen).toBe(true);
    expect(fromA.currentPhase).toBe("handshaking");
    expect(fromB.currentPhase).toBe("handshaking");

    // The tie-break, computed identically on both devices from keys they hold.
    const loser = whoInitiates(a.exchange.publicKey, b.exchange.publicKey) === "accept" ? fromA : fromB;
    const winner = loser === fromA ? fromB : fromA;
    const loserId = loser === fromA ? a : b;
    const winnerId = winner === fromA ? a : b;
    expect(loser.abandon()).toBe(true); // an ephemeral existed, and is now destroyed
    expect(loser.currentPhase).toBe("failed");
    expect(loser.isUp).toBe(false);
    // Abandoning twice reports nothing left to destroy.
    expect(loser.abandon()).toBe(false);

    // Only the loser pays. The winner keeps its session and re-sends the leg 0 it
    // already put on air — same ephemeral, same bytes — and the loser rejoins as
    // the responder it should have been, with a *fresh* ephemeral, because reusing
    // one across two transcripts would end its forward secrecy.
    const resumed = new DumanSession(
      p,
      loserId,
      "responder",
      sessionPrologueFromQr(p, loserId, winnerId.signing.publicKey)
    );
    const leg0 = winner.retryLeg()!;
    expect(leg0).toEqual(loser === fromA ? legFromB : legFromA);
    resumed.readLeg(leg0);
    winner.readLeg(resumed.writeLeg()!);
    resumed.readLeg(winner.writeLeg()!);
    expect(winner.currentPhase).toBe("unverified");
    expect(resumed.currentPhase).toBe("unverified");
    expect(winner.sas!.chars).toBe(resumed.sas!.chars);
    expect(winner.confirmSas(resumed.sas!.chars)).toBe(true);
  });
});

describe("docs/07 §7.3 — the 7-day session cache", () => {
  it("is keyed on the peer's static key and evicts on time, not on radio contact", () => {
    expect(SESSION_TTL_MS).toBe(7 * 24 * 60 * 60 * 1000);
    const cache = new SessionCache();
    const { alice } = establish();
    // A session is keyed on its own peer: Alice's session is filed under Bob's
    // static key, which is `alice.peerStatic`, not `bob.peerStatic`.
    const peer = alice.peerStatic!;
    cache.put(alice, peer, 0);
    expect(cache.size).toBe(1);
    // §3 measures 54 % of campus pairs meeting within ten minutes, so a
    // contact-keyed eviction would throw a working session away several times a
    // day. Six days of silence must not.
    expect(cache.get(peer, 6 * 24 * 60 * 60 * 1000)).toBe(alice);
    expect(cache.expiredAt(6 * 24 * 60 * 60 * 1000)).toBe(0);
    expect(cache.get(peer, SESSION_TTL_MS + 1)).toBeNull();
    // Eviction wipes rather than merely forgetting: the entry holds live chain keys,
    // and dropping a reference leaves them in memory until the collector runs.
    expect(alice.currentPhase).toBe("wiped");
    expect(isWiped(alice.identity)).toBe(true);
    expect(cache.size).toBe(0);
  });

  it("keeps peers apart and evicts only the ones that expired", () => {
    const cache = new SessionCache();
    const first = establish();
    const second = establish();
    cache.put(first.alice, first.alice.peerStatic!, 0);
    cache.put(second.alice, second.alice.peerStatic!, 5 * 24 * 60 * 60 * 1000);
    expect(cache.size).toBe(2);
    expect(cache.get(first.alice.peerStatic!, 6 * 24 * 60 * 60 * 1000)).toBe(first.alice);
    expect(cache.expiredAt(8 * 24 * 60 * 60 * 1000)).toBe(1);
    expect(cache.evictExpired(8 * 24 * 60 * 60 * 1000)).toBe(1);
    expect(cache.size).toBe(1);
    expect(first.alice.currentPhase).toBe("wiped");
    expect(second.alice.currentPhase).toBe("verified");
  });

  it("resumes without putting anything on air, which is the answer to §7.3's linkability worry", () => {
    // §7.3 fears a cached sessionId is a linkable identifier. None is transmitted:
    // resumption is both sides continuing chains they already hold, so an observer
    // sees traffic resume with *no* key agreement in front of it. Against §3's
    // ~140 new peers per node per hour in a crowd, that absence is the point.
    const cache = new SessionCache();
    const { alice, bob, bobId } = establish();
    cache.put(bob, bob.peerStatic!, 0);
    const resumed = cache.get(bob.peerStatic!, 60_000);
    expect(resumed).toBe(bob);
    const packet = send(alice, bobId, "m000099", "still the same session", 1_760_000_060_000)!;
    const received = resumed!.receive(packet);
    expect(received.ok).toBe(true);
    if (received.ok) {
      expect(new TextDecoder().decode(received.body)).toBe("still the same session");
      expect(received.authenticated).toBe(true);
    }
    // Nothing was exchanged to get there: the cache is local, and no resumption
    // packet exists.
    expect(resumed!.nextLeg).toBe(3);
  });
});

describe("docs/07 §7.4 — panic wipe", () => {
  it("zeroes in the order the derivations require, and reports what it reached", () => {
    const { alice } = establish();
    const result = alice.panicWipe();
    // Ratchets before the handshake before the transport keys before the identity:
    // each is derived from the next, so wiping the identity first would leave a
    // live chain key that can still decrypt.
    expect(result.order).toEqual([
      "recvRatchet",
      "sendRatchet",
      "handshake",
      "lastLeg",
      "transportKeys",
      "sas",
      "identity",
    ]);
    expect(result.identity.zeroed).toEqual([
      "signing.privateKey",
      "signing.publicKey",
      "exchange.privateKey",
      "exchange.publicKey",
      "nodeIdBytes",
    ]);
    expect(isWiped(alice.identity)).toBe(true);
    expect(alice.currentPhase).toBe("wiped");
    expect(alice.isUp).toBe(false);
    expect(alice.sas).toBeNull();
    expect(alice.peerStatic).toBeNull();
  });

  it("stops a wiped session sending or receiving, and cannot be undone", () => {
    const { alice, bob, bobId } = establish();
    alice.panicWipe();
    expect(send(alice, bobId, "m1", "after the wipe")).toBeNull();
    const fromBob = send(bob, alice.identity, "m2", "to a wiped peer")!;
    const received = alice.receive(fromBob);
    expect(received.ok).toBe(false);
    if (!received.ok) expect(received.reason).toBe("session");
  });

  it("cannot revoke: the peer learns by failing to decrypt, not by being told", () => {
    // §7.4 asks how a wipe reaches N-1 group members who need a rotation. It
    // cannot — the rotation needs the pairwise channels whose keys are the thing
    // being destroyed. So detection has to live on the receiving side, and this is
    // what that looks like: Bob is not notified, he just stops being able to read.
    const { alice, bob, bobId } = establish();
    const inFlight = send(alice, bobId, "m1", "sent before the wipe")!;
    alice.panicWipe();
    // The message was sealed with a key Bob still holds a chain for, so it opens —
    // a wipe does not retroactively protect anything already on air, which is the
    // second half of §7.4's answer and the reason at-rest encryption matters.
    expect(bob.receive(inFlight).ok).toBe(true);
    // What Bob cannot do any more is be *told*. There is no revocation packet, and
    // no field in the header that could carry one without leaking the wipe.
    expect(relayVisible(inFlight)!.bodyReadable).toBe(false);
    expect(bob.currentPhase).toBe("verified");
  });

  it("wipes every session in the cache in one tap, as docs/04 §3 asks", () => {
    const cache = new SessionCache();
    const first = establish();
    const second = establish();
    cache.put(first.bob, first.bob.peerStatic!, 0);
    cache.put(second.bob, second.bob.peerStatic!, 0);
    const result = cache.panicWipe();
    expect(result.wiped).toBe(2);
    expect(result.order).toHaveLength(2);
    expect(cache.size).toBe(0);
    expect(isWiped(first.bob.identity)).toBe(true);
    expect(isWiped(second.bob.identity)).toBe(true);
    // The peers' identities were not in this cache, so they survive — which is the
    // gap a real one-tap wipe has to close by reaching every store, not just this
    // one. skills/03 says "zero keys + overwrite DB + toast" for that reason.
    expect(isWiped(first.alice.identity)).toBe(false);
  });
});

describe("the mesh's effect on the data plane, which docs/07 §6 row 2 asks about", () => {
  it("tolerates packets that arrive out of order", () => {
    const { alice, bob, bobId } = establish();
    const bodies = ["zero", "one", "two", "three", "four"];
    const packets = bodies.map((body, i) => send(alice, bobId, `m${i}`, body, 1_760_000_000_000 + i)!);
    for (const index of [3, 0, 4, 2, 1]) {
      const received = bob.receive(packets[index]);
      expect(received.ok, `message ${index}`).toBe(true);
      if (received.ok) {
        expect(new TextDecoder().decode(received.body)).toBe(bodies[index]);
        expect(received.num).toBe(index);
      }
    }
  });

  it("reports a retransmitted packet as a replay, distinctly from a forged one", () => {
    const { alice, bob, bobId } = establish();
    const packet = send(alice, bobId, "m0", "once")!;
    expect(bob.receive(packet).ok).toBe(true);
    const again = bob.receive(packet);
    expect(again.ok).toBe(false);
    if (!again.ok) expect(again.reason).toBe("ratchet");

    // A *forged* packet has to arrive under a number the receiver has not consumed,
    // or the replay check fires first and the AEAD is never exercised. So forge the
    // next message, not the one just replayed.
    const next = Uint8Array.from(send(alice, bobId, "m1", "twice")!);
    next[next.length - 1] ^= 0x01;
    const tampered = bob.receive(next);
    expect(tampered.ok).toBe(false);
    // The ratchet handed over a key and the packet's own tag rejected the bytes, so
    // the reason is "packet" and not "ratchet" — the two failure modes stay
    // distinguishable, which is what lets a caller tell a reorder from an attack.
    if (!tampered.ok) expect(tampered.reason).toBe("packet");
  });

  it("rejects a packet whose nonce this layer would never have produced", () => {
    const { alice, bob, bobId } = establish();
    const packet = Uint8Array.from(send(alice, bobId, "m0", "hello")!);
    // The high four bytes of a Noise nonce are always zero. A packet that sets one
    // is not a huge message number to be cached — it is malformed — and treating it
    // as a number would let one packet drive the receiver's skip cache.
    packet[HEADER_BYTES] = 0x01;
    const received = bob.receive(packet);
    expect(received.ok).toBe(false);
    if (!received.ok) expect(received.reason).toBe("not-a-packet");
    expect(bob.receive(new Uint8Array(20)).ok).toBe(false);
  });

  it("sizes a sealed message exactly as the engine's transport selector would", () => {
    const { alice, bobId } = establish();
    for (const body of ["", "hey Kemal", "x".repeat(929), "x".repeat(930), "😀".repeat(300)]) {
      const packet = send(alice, bobId, "m0", body)!;
      expect(packet.length, JSON.stringify(body.slice(0, 12))).toBe(wireSizeOfBody(body));
    }
    // The two boundaries the docs publish, measured off a real sealed packet.
    expect(send(alice, bobId, "m1", "x".repeat(929))!.length).toBe(1024);
    expect(send(alice, bobId, "m2", "x".repeat(930))!.length).toBe(1280);
  });
});

describe("the QR add-contact flow, docs/04 §2", () => {
  it("round-trips a key and its fingerprint through base64url", () => {
    const identity = generateIdentity(p);
    const encoded = encodeQr(identity);
    // 32 key bytes + 8 ASCII characters = 40 bytes -> 54 base64url characters,
    // unpadded (40 mod 3 is 1, so the two padding characters are dropped).
    expect(encoded).toHaveLength(54);
    expect(encoded).not.toContain("=");
    expect(encoded).not.toContain("+");
    const decoded = decodeQr(encoded)!;
    expect(equalBytes(decoded.publicKey, identity.signing.publicKey)).toBe(true);
    expect(decoded.sas).toBe(identity.sas);
  });

  it("rejects a QR whose fingerprint is not readable aloud", () => {
    const identity = generateIdentity(p);
    const raw = Buffer.from(encodeQr(identity), "base64url");
    const touched = Buffer.from(raw);
    touched[32] = "O".charCodeAt(0); // not in Crockford's 32: 0, O, 1, I, L, U are out
    expect(decodeQr(touched.toString("base64url"))).toBeNull();
    expect(decodeQr(Buffer.from(new Uint8Array(39)).toString("base64url"))).toBeNull();
    expect(decodeQr("")).toBeNull();
  });

  it("round-trips the duman:// side channel too, and rejects anything else", () => {
    const identity = generateIdentity(p);
    const qr = decodeQr(encodeQr(identity))!;
    const link = addContactLink(qr);
    expect(link.startsWith("duman://add?pub=")).toBe(true);
    const parsed = parseAddContactLink(link)!;
    expect(equalBytes(parsed.publicKey, qr.publicKey)).toBe(true);
    expect(parsed.sas).toBe(qr.sas);
    expect(parseAddContactLink("https://add?pub=x&sas=y")).toBeNull();
    expect(parseAddContactLink("duman://add?pub=x")).toBeNull();
    expect(parseAddContactLink(link.replace("duman://add", "duman://remove"))).toBeNull();
  });

  it("derives a nodeId that is a NodeId the engine could route on", () => {
    const identity = generateIdentity(p);
    expect(identity.nodeId).toHaveLength(64);
    expect(identity.nodeId).toMatch(/^[0-9a-f]{64}$/);
    expect(identity.nodeId).toBe(toHex(identity.nodeIdBytes));
    // docs/05: nodeId = SHA-256(pubKey). Which pubKey is the ambiguity — the QR
    // carries the Ed25519 key, XX reveals the X25519 one, and they hash differently.
    // This implementation uses the Ed25519 key, so destHint and the QR agree; a
    // deployment that used the X25519 key would have two nodeIds per device.
    expect(identity.nodeId).not.toBe(toHex(p.hash(identity.exchange.publicKey)));
    expect(identitySas(p, identity.signing.publicKey)).toBe(identity.sas);
  });
});
