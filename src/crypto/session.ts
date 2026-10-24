/**
 * The session: handshake legs, SAS verification, sealed messages, resumption and
 * the panic wipe. This is the object `skills/03`'s acceptance criteria are
 * written against, and where `docs/07` §7's four open questions get answers a
 * test can check.
 *
 * What it is not: a network object. Legs are byte arrays in and byte arrays out,
 * because on this mesh the transport is `docs/07` §2 — three unicast messages
 * over 0.5 to 6.7 s, any of which can vanish. Keeping sequencing outside means
 * §2.1's requirement ("retry per leg, not per handshake") is a caller loop rather
 * than a redesign, and `writeLeg` returning the same bytes for the same leg is
 * what makes that loop safe.
 */
import { concat, toHex, zeroize, type CryptoPrimitives } from "./primitives";
import { HandshakeState, NoiseError, resolveSimultaneousOpen, type HandshakeResult } from "./noise-xx";
import { SymmetricRatchet, deriveRatchetSeed, decodeNonce, type CompromisedState, type OpenFailure } from "./ratchet";
import { handshakeSas, sasMatches, type HandshakeSas } from "./sas";
import { destHintBytes, panicWipeIdentity, type Identity, type WipeResult } from "./identity";
import {
  HEADER_BYTES,
  NONCE_BYTES,
  TAG_BYTES,
  openPacket,
  sealPacket,
  type OpenFailure as PacketOpenFailure,
} from "./packet";
import type { MsgId, MsgType, NodeId } from "../types";

/** `skills/03`: "cached `sessionId` if peer met again within 7 days". The same
 *  horizon as `OPP_TTL_MS` in `src/routing.ts`, which is not a coincidence: a
 *  session that outlives the opportunistic queue holding messages for it would be
 *  a session that cannot read them. */
export const SESSION_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export const SESSION_PROLOGUE_CONTEXT = "DumanMessenger-session-v1";

export type SessionPhase =
  /** Legs still in flight. */
  | "handshaking"
  /** Keys agreed; two humans have not yet compared the SAS. Messages can flow —
   *  that is trust-on-first-use — but nothing about the peer is proven. */
  | "unverified"
  /** SAS matched. The peer is who the QR said. */
  | "verified"
  /** A leg failed authentication, or the SAS did not match. Terminal. */
  | "failed"
  /** Panic-wiped. Terminal; the object must not be used again. */
  | "wiped";

/**
 * Bind the handshake to the two identities it is between.
 *
 * Without a prologue, XX proves "a session between these two static keys", and a
 * relay holding halves of two different sessions can splice them. With the ordered
 * pair of node ids in the prologue the transcript commits to *which* pairing it
 * is, and a splice changes the hash — which both sides then see as a failed SAS
 * rather than as a working session with the wrong peer. Ordering is lexicographic
 * so both sides compute the same bytes from data they hold in opposite orders.
 */
export function sessionPrologue(nodeIdA: Uint8Array, nodeIdB: Uint8Array): Uint8Array {
  const [first, second] = orderPair(nodeIdA, nodeIdB);
  return concat(new TextEncoder().encode(SESSION_PROLOGUE_CONTEXT), first, second);
}

/**
 * The prologue for a first contact, when only the peer's QR is known.
 *
 * The QR carries the **Ed25519** public key (`skills/03`), whose SHA-256 is the
 * peer's nodeId (`docs/05`) — so the prologue can be built from the scan alone,
 * before any handshake, on both sides. That is what makes it usable at all: a
 * prologue both sides cannot compute independently is not a prologue.
 */
export function sessionPrologueFromQr(
  p: CryptoPrimitives,
  myIdentity: Identity,
  peerSigningPublicKey: Uint8Array
): Uint8Array {
  return sessionPrologue(myIdentity.nodeIdBytes, p.hash(peerSigningPublicKey));
}

function orderPair(a: Uint8Array, b: Uint8Array): [Uint8Array, Uint8Array] {
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? [a, b] : [b, a];
  }
  return a.length <= b.length ? [a, b] : [b, a];
}

export interface OutgoingMessage {
  msgId: MsgId;
  type: MsgType;
  ttl: number;
  hop: number;
  /** Wall-clock milliseconds on a device; simulation time in the engine. */
  nowMs: number;
  body: Uint8Array;
}

export interface IncomingMessage {
  ok: true;
  /** The ratchet message number, for the caller's dedup and reorder handling. */
  num: number;
  body: Uint8Array;
  type: MsgType;
  ttl: number;
  hop: number;
  /** The sender's Ed25519 public key. */
  from: Uint8Array;
  timestampMs: number;
  msgIdDigest: Uint8Array;
  destHint: Uint8Array;
  /** False until [DumanSession.confirmSas] matched: encrypted, but the peer is
   *  not proven. That distinction is the whole content of TOFU. */
  authenticated: boolean;
}

export type ReceiveFailure =
  | { ok: false; reason: "session"; phase: SessionPhase }
  | { ok: false; reason: "not-a-packet" }
  | { ok: false; reason: "ratchet"; detail: OpenFailure }
  | { ok: false; reason: "packet"; detail: PacketOpenFailure };

export class DumanSession {
  private readonly handshake: HandshakeState;
  private result: HandshakeResult | null = null;
  private sendRatchet: SymmetricRatchet | null = null;
  private recvRatchet: SymmetricRatchet | null = null;
  private sasValue: HandshakeSas | null = null;
  private phase: SessionPhase = "handshaking";
  /** The leg this side last wrote, kept so a lost leg can be re-sent verbatim. */
  private lastWritten: { index: number; bytes: Uint8Array } | null = null;

  constructor(
    private readonly p: CryptoPrimitives,
    readonly identity: Identity,
    readonly role: "initiator" | "responder",
    prologue: Uint8Array
  ) {
    this.handshake = new HandshakeState(p, role === "initiator", { s: identity.exchange }, prologue);
  }

  get currentPhase(): SessionPhase {
    return this.phase;
  }

  /** Which leg comes next, 0-based — the per-leg progress `docs/07` §2.1 note 3
   *  asks for, so a user watching a 6.7 s three-hop handshake does not abandon it. */
  get nextLeg(): number {
    return this.handshake.nextLeg;
  }

  get peerStatic(): Uint8Array | null {
    return this.result ? this.result.remoteStatic : null;
  }

  /** The peer's nodeId, once its static key has arrived. Note this is the hash of
   *  the peer's **X25519** key, which XX reveals — not of the Ed25519 key the QR
   *  carried. `docs/05`'s `nodeId = SHA-256(pubKey)` therefore has two readings,
   *  and a real deployment has to pick one and keep the other out of routing. */
  get peerExchangeNodeId(): NodeId | null {
    return this.result ? toHex(this.p.hash(this.result.remoteStatic)) : null;
  }

  get sas(): HandshakeSas | null {
    return this.sasValue;
  }

  get isHandshaking(): boolean {
    return this.phase === "handshaking";
  }

  /**
   * True once keys exist, verified or not. Governs both directions: an
   * unverified session can receive too, and what it receives is encrypted but
   * unproven — which is what [IncomingMessage.authenticated] reports.
   */
  get isUp(): boolean {
    return this.phase === "unverified" || this.phase === "verified";
  }

  /** True when the next leg is ours to write. */
  private legIsMine(): boolean {
    const leg = this.handshake.nextLeg;
    if (leg > 2) return false;
    const initiatorWrites = leg === 0 || leg === 2;
    return initiatorWrites === (this.role === "initiator");
  }

  /**
   * Produce the next leg, or `null` when it is the peer's turn.
   *
   * This **advances** the state machine, so it is not a retransmission primitive:
   * calling it twice produces leg 2, then nothing. Retrying a lost leg is
   * [retryLeg], which re-sends the bytes already written. The distinction matters
   * because `docs/07` §2.1 note 2 requires retry *per leg* — restarting the
   * handshake turns a 5 % per-leg loss rate into ~14 % failure over three legs,
   * and the state machine must not make restarting the easy option.
   */
  writeLeg(payload: Uint8Array = new Uint8Array(0)): Uint8Array | null {
    if (this.phase !== "handshaking" || !this.legIsMine()) return null;
    try {
      const index = this.handshake.nextLeg;
      const leg = this.handshake.writeMessage(payload);
      this.lastWritten = { index, bytes: Uint8Array.from(leg) };
      this.finishIfComplete();
      return leg;
    } catch (error) {
      this.fail(error);
    }
  }

  /**
   * Re-send the leg this side last wrote, byte for byte.
   *
   * Safe for every leg, including the two that carry ephemeral keys: an ephemeral
   * is generated once, on the first `writeLeg`, and held by the state machine, so
   * the retransmission is the same frame with the same key in it. Leg 3 is the case
   * `docs/07` §2.1 calls out — by then XX's transcript is fixed, so a lost leg 3
   * costs one retransmission rather than a 0.5-6.7 s restart.
   */
  retryLeg(): Uint8Array | null {
    if (this.phase !== "handshaking" || !this.lastWritten) return null;
    return Uint8Array.from(this.lastWritten.bytes);
  }

  readLeg(leg: Uint8Array, expectPayload = 0): Uint8Array | null {
    if (this.phase !== "handshaking" || this.legIsMine()) return null;
    try {
      const payload = this.handshake.readMessage(leg, expectPayload);
      this.finishIfComplete();
      return payload;
    } catch (error) {
      this.fail(error);
    }
  }

  private fail(error: unknown): never {
    this.phase = "failed";
    this.wipeKeyMaterial();
    throw error;
  }

  private finishIfComplete(): void {
    if (!this.handshake.isComplete || this.result) return;
    this.result = this.handshake.result();
    const mine = this.role === "initiator" ? this.result.c1 : this.result.c2;
    const theirs = this.role === "initiator" ? this.result.c2 : this.result.c1;
    if (!mine.key || !theirs.key) throw new NoiseError("out-of-order", "Split() produced no keys");
    // Noise's transport key becomes a ratchet *seed*, domain-separated per
    // direction so the two chains cannot be substituted for one another, and then
    // erased: nothing holds the Noise transport key once the session is up.
    this.sendRatchet = new SymmetricRatchet(this.p, deriveRatchetSeed(this.p, mine.key, "send"));
    this.recvRatchet = new SymmetricRatchet(this.p, deriveRatchetSeed(this.p, theirs.key, "recv"));
    zeroize(mine.key, theirs.key);
    this.sasValue = handshakeSas(
      this.p,
      this.result.handshakeHash,
      this.identity.exchange.publicKey,
      this.result.remoteStatic
    );
    this.phase = "unverified";
  }

  /**
   * Compare the SAS a human read off the other device.
   *
   * This is the moment the session becomes authenticated, and it is *after* the
   * keys exist: TOFU means messages may already have flowed. A mismatch is
   * terminal and must not be retried — the transcript has just been shown to
   * involve a third party, and re-handshaking with that third party produces the
   * same mismatch.
   */
  confirmSas(theirs: string): boolean {
    if (!this.sasValue || this.phase === "wiped" || this.phase === "failed") return false;
    if (!sasMatches(this.sasValue.chars, theirs)) {
      this.phase = "failed";
      this.wipeKeyMaterial();
      return false;
    }
    this.phase = "verified";
    return true;
  }

  destHintFor(destSigningPublicKey: Uint8Array): Uint8Array {
    return destHintBytes(this.p, destSigningPublicKey);
  }

  /**
   * Seal a message. Returns `null` if the session is not up.
   *
   * The message key lives for exactly one call: it is derived, used, and zeroed
   * here, and the chain key that produced it is already gone. That is the whole
   * forward-secrecy mechanism, and it is why [compromise] can be honest about
   * what an attacker gets.
   */
  send(message: OutgoingMessage, destSigningPublicKey: Uint8Array): Uint8Array | null {
    if (!this.isUp || !this.sendRatchet) return null;
    const { num, key } = this.sendRatchet.nextKey();
    try {
      const packet = sealPacket(this.p, key, {
        msgId: message.msgId,
        ttl: message.ttl,
        type: message.type,
        destHint: destHintBytes(this.p, destSigningPublicKey),
        hop: message.hop,
        from: this.identity.signing.publicKey,
        timestampMs: message.nowMs,
        body: message.body,
        nonce: num,
      });
      return packet.bytes;
    } finally {
      zeroize(key);
    }
  }

  receive(bytes: Uint8Array): IncomingMessage | ReceiveFailure {
    if (!this.isUp || !this.recvRatchet) {
      return { ok: false, reason: "session", phase: this.phase };
    }
    if (bytes.length < HEADER_BYTES + NONCE_BYTES + TAG_BYTES) {
      return { ok: false, reason: "not-a-packet" };
    }
    const num = decodeNonce(bytes.subarray(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES));
    if (num === null) return { ok: false, reason: "not-a-packet" };

    const derived = this.recvRatchet.keyFor(num);
    if (!derived.ok) return { ok: false, reason: "ratchet", detail: derived.reason };
    try {
      const opened = openPacket(this.p, derived.key, bytes);
      if (!opened.ok) return { ok: false, reason: "packet", detail: opened.reason };
      const { packet } = opened;
      return {
        ok: true,
        num,
        body: packet.body,
        type: packet.type,
        ttl: packet.ttl,
        hop: packet.hop,
        from: packet.from,
        timestampMs: packet.timestampMs,
        msgIdDigest: packet.msgIdDigest,
        destHint: packet.destHint,
        authenticated: this.phase === "verified",
      };
    } finally {
      zeroize(derived.key);
    }
  }

  /**
   * Everything a device compromise exposes — `skills/03`'s "compromise after =
   * cannot decrypt prior", made checkable by naming the state.
   *
   * Both chain keys, both counters, and the out-of-order cache are here, because
   * an attacker with the device has all of them. What is absent is any message key
   * for a message already opened, and any chain key from an earlier step: those
   * were zeroed when they were used, and their absence is the property under test.
   */
  compromise(): { phase: SessionPhase; send: CompromisedState; recv: CompromisedState } | null {
    if (!this.sendRatchet || !this.recvRatchet) return null;
    return { phase: this.phase, send: this.sendRatchet.compromise(), recv: this.recvRatchet.compromise() };
  }

  /**
   * `docs/07` §7.4's panic wipe, in the order it has to happen.
   *
   * Ratchets die before the handshake, and the handshake before the identity,
   * because each is derived from the one after it: wiping the identity first would
   * leave a live chain key that can still decrypt. The order is returned rather
   * than assumed, so a caller — and a test — can see what was reached. A wipe that
   * throws halfway is worse than one that reports where it stopped.
   *
   * What it cannot do is reach the N−1 group members `docs/06` §14's rotation
   * would have to notify. That is not an ordering problem but a physics one: the
   * rotation needs pairwise channels whose keys are the thing being destroyed. So
   * **a wipe cannot revoke**, and detection has to move to the receiver, which
   * notices an epoch it cannot decrypt instead of being told. `docs/07` §7.4 asks
   * the question; this is the answer.
   */
  panicWipe(): { order: string[]; identity: WipeResult } {
    const order: string[] = [];
    this.recvRatchet?.wipe();
    this.recvRatchet = null;
    order.push("recvRatchet");
    this.sendRatchet?.wipe();
    this.sendRatchet = null;
    order.push("sendRatchet");
    this.handshake.wipe();
    order.push("handshake");
    if (this.lastWritten) zeroize(this.lastWritten.bytes);
    this.lastWritten = null;
    order.push("lastLeg");
    if (this.result) {
      zeroize(this.result.c1.key, this.result.c2.key, this.result.handshakeHash);
      this.result = null;
    }
    order.push("transportKeys");
    if (this.sasValue) zeroize(this.sasValue.mac);
    this.sasValue = null;
    order.push("sas");
    this.phase = "wiped";
    order.push("identity");
    return { order, identity: panicWipeIdentity(this.identity) };
  }

  private wipeKeyMaterial(): void {
    this.handshake.wipe();
    if (this.lastWritten) zeroize(this.lastWritten.bytes);
    this.lastWritten = null;
    this.sendRatchet?.wipe();
    this.recvRatchet?.wipe();
    this.sendRatchet = null;
    this.recvRatchet = null;
    if (this.result) {
      zeroize(this.result.c1.key, this.result.c2.key, this.result.handshakeHash);
      this.result = null;
    }
    if (this.sasValue) zeroize(this.sasValue.mac);
    this.sasValue = null;
  }
}

/**
 * `docs/07` §7.1, at the session level: who initiates when both tap "add".
 *
 * The comparison is over the **X25519** keys, because those are what XX binds;
 * comparing the Ed25519 keys the QR carries would be a different order and two
 * devices could disagree. `"identical"` cannot happen for two distinct devices and
 * is returned rather than thrown so a caller sees the impossible case instead of
 * silently picking a side.
 */
export function whoInitiates(
  myExchangePublic: Uint8Array,
  theirExchangePublic: Uint8Array
): "initiate" | "accept" | "identical" {
  return resolveSimultaneousOpen(myExchangePublic, theirExchangePublic);
}

// --- resumption --------------------------------------------------------------

interface CacheEntry {
  session: DumanSession;
  storedAtMs: number;
  lastUsedMs: number;
}

/**
 * The 7-day session cache (`skills/03`), and `docs/07` §7.3's answer.
 *
 * §7.3 worries that *"a cached `sessionId` is a linkable identifier"*. It would
 * be, if an id went on air — and none does. The cache is keyed **locally** on the
 * peer's static key, which the device already holds; resumption transmits nothing
 * at all, because the two sides simply keep using chains they already share. So
 * the privacy cost of resumption is not an identifier, it is the absence of a
 * handshake: an observer sees traffic resume with no key agreement in front of it.
 * Against §3's ~140 new peers per node per hour in a crowd, that absence is the
 * point — and it is strictly less observable than re-handshaking.
 *
 * What the cache must do is evict on **time and on wipe**, never on radio contact:
 * §3 measures 54 % of all campus pairs meeting within ten minutes, so a
 * contact-keyed eviction would throw away a working session several times a day.
 */
export class SessionCache {
  private readonly entries = new Map<string, CacheEntry>();

  constructor(private readonly ttlMs: number = SESSION_TTL_MS) {}

  get size(): number {
    return this.entries.size;
  }

  private static keyFor(peerStatic: Uint8Array): string {
    return toHex(peerStatic);
  }

  put(session: DumanSession, peerStatic: Uint8Array, nowMs: number): void {
    this.entries.set(SessionCache.keyFor(peerStatic), {
      session,
      storedAtMs: nowMs,
      lastUsedMs: nowMs,
    });
  }

  get(peerStatic: Uint8Array, nowMs: number): DumanSession | null {
    const key = SessionCache.keyFor(peerStatic);
    const entry = this.entries.get(key);
    if (!entry) return null;
    if (nowMs - entry.storedAtMs > this.ttlMs) {
      // Expired: wipe it rather than dropping the reference, because the entry
      // holds live chain keys and an eviction that merely forgets them leaves them
      // in memory until the collector happens to run.
      entry.session.panicWipe();
      this.entries.delete(key);
      return null;
    }
    entry.lastUsedMs = nowMs;
    return entry.session;
  }

  /** How many entries have outlived the horizon, without touching them. */
  expiredAt(nowMs: number): number {
    let count = 0;
    for (const entry of this.entries.values()) if (nowMs - entry.storedAtMs > this.ttlMs) count++;
    return count;
  }

  evictExpired(nowMs: number): number {
    let evicted = 0;
    for (const [key, entry] of [...this.entries.entries()]) {
      if (nowMs - entry.storedAtMs > this.ttlMs) {
        entry.session.panicWipe();
        this.entries.delete(key);
        evicted++;
      }
    }
    return evicted;
  }

  /**
   * `skills/03`: *"zero keys + overwrite DB + toast"*.
   *
   * Returns the count wiped, because a panic wipe whose completeness cannot be
   * reported cannot be tested — and `docs/04` §3 asks for one tap, which means the
   * caller gets exactly one chance to find out it missed something.
   */
  panicWipe(): { wiped: number; order: string[][] } {
    const order: string[][] = [];
    let wiped = 0;
    for (const entry of this.entries.values()) {
      order.push(entry.session.panicWipe().order);
      wiped++;
    }
    this.entries.clear();
    return { wiped, order };
  }
}
