/**
 * The per-message ratchet: `skills/03`'s "ratchet per message (Double Ratchet
 * light) for FS".
 *
 * Noise's own transport mode — one key from `Split()`, a nonce counter that
 * increments — gives confidentiality but **not** forward secrecy: hold the
 * transport key and every past message falls out of the transcript. `skills/03`
 * asks for more, and `docs/07` §6's second acceptance row is exactly that ask:
 * *"compromise after = cannot decrypt prior (ratchet verify)"*. So the session
 * layer here does not use `CipherState` for data; it seeds this ratchet from
 * `Split()`'s output and derives a **fresh key per message**, erasing the one
 * that produced it.
 *
 * It is deliberately *light*, and the two omissions are the interesting part:
 *
 * - **No DH ratchet.** A full Double Ratchet re-runs a DH each time the sending
 *   direction changes, which buys post-compromise security (the session heals
 *   after an attacker leaves). On this mesh a DH round trip is `docs/07` §2's
 *   three legs — 0.5 to 6.7 s — so healing would cost a handshake. Symmetric
 *   ratcheting is what fits the budget, and the trade is stated rather than
 *   hidden: **a compromised chain key lets the attacker read everything after
 *   the compromise, and only a fresh handshake stops it.**
 * - **No sender-key fan-out.** Group messages are sealed once per recipient by
 *   the group epoch machinery in `docs/06` §14, not by a tree.
 *
 * The one place the mesh genuinely changes the design is `docs/07` §6's note that
 * *"the ratchet must tolerate out-of-order and retransmitted messages"*. A naive
 * hash chain cannot: it can only decrypt the next message. So the receiver keeps
 * a bounded cache of keys it derived ahead of itself, and — critically — the
 * bound is a security parameter, not a convenience. [MAX_SKIP] exists because an
 * unbounded cache is a denial of service: a peer that claims message number
 * 2^40 forces the receiver to derive 2^40 keys to catch up.
 */
import { zeroize, type CryptoPrimitives } from "./primitives";
import { encodeNonce } from "./noise-xx";

/**
 * How far ahead a receiver will pre-derive message keys.
 *
 * Sized against the mesh, not picked arbitrarily: `docs/03` §7 keeps a 32-entry
 * transmit-quality window and `docs/03` §8 an OppQueue that can hold a contact's
 * messages for up to 7 days, so reordering across a whole opportunistic queue is
 * in scope. 64 covers a fully reversed 32-message burst with room to spare while
 * keeping the worst-case catch-up work at 64 HMAC pairs.
 */
export const MAX_SKIP = 64;

const MSG_KEY_TAG = new Uint8Array([0x01]);
const CHAIN_KEY_TAG = new Uint8Array([0x02]);

export type OpenFailure =
  /** The number was already consumed, or is behind the cache window. The mesh
   *  retransmits whole messages (`attempt`), so this is expected traffic, not an
   *  attack — and it is why it is a distinct reason from `auth-failed`. */
  | "replay"
  /** Too far ahead to pre-derive. Treat as a protocol error, not a gap. */
  | "gap-too-large"
  /** The tag did not verify: wrong key, tampered bytes, or not for us. */
  | "auth-failed";

export type OpenResult =
  | { ok: true; plaintext: Uint8Array; num: number }
  | { ok: false; reason: OpenFailure; num: number };

export interface SealedMessage {
  num: number;
  nonce: Uint8Array;
  /** `ciphertext || tag16`. */
  sealed: Uint8Array;
}

/** Everything an attacker who takes the device gets. Exported so the
 *  forward-secrecy test can compromise a session honestly, by reading only what
 *  is actually in memory, rather than by asking the ratchet for its keys. */
export interface CompromisedState {
  chainKey: Uint8Array;
  sendNum: number;
  nextRecvNum: number;
  skipped: ReadonlyArray<[number, Uint8Array]>;
}

export class SymmetricRatchet {
  private chainKey: Uint8Array;
  private sendNum = 0;
  private nextRecvNum = 0;
  /** Keys derived ahead of the next expected message, by message number. */
  private readonly skipped = new Map<number, Uint8Array>();

  constructor(private readonly p: CryptoPrimitives, seedKey: Uint8Array) {
    if (seedKey.length === 0) throw new RangeError("ratchet needs a non-empty seed key");
    this.chainKey = Uint8Array.from(seedKey);
  }

  /** The next message number this side will seal with. */
  get nextSendNum(): number {
    return this.sendNum;
  }

  /** The next message number this side expects to open. */
  get nextExpectedNum(): number {
    return this.nextRecvNum;
  }

  /** How many keys are sitting in the out-of-order cache. */
  get cachedSkips(): number {
    return this.skipped.size;
  }

  /**
   * The next sending key, and the number it belongs to.
   *
   * Exposed separately from [SymmetricRatchet.seal] because the session layer
   * needs the key *and* the number before it has built a packet: the number goes
   * into the packet's nonce field, and the packet's header is the AEAD's
   * associated data, so the packet has to exist before the AEAD runs. The caller
   * owns zeroizing the key.
   */
  nextKey(): { num: number; nonce: Uint8Array; key: Uint8Array } {
    const num = this.sendNum;
    return { num, nonce: encodeNonce(num), key: this.stepSend() };
  }

  /**
   * The receiving key for message `num`, or the reason there is not one.
   *
   * `"replay"` covers both a number already consumed and one behind the
   * [MAX_SKIP] window — the two are indistinguishable without keeping every
   * number ever seen, and keeping them is exactly the unbounded state the window
   * exists to avoid. Callers that need to tell a mesh retransmission from an
   * attack have to dedup above this layer, on the message id, which is what the
   * engine already does (`isSeen` keys on `id#attempt`).
   */
  keyFor(num: number): { ok: true; key: Uint8Array } | { ok: false; reason: OpenFailure } {
    if (!Number.isSafeInteger(num) || num < 0) return { ok: false, reason: "replay" };

    if (num < this.nextRecvNum) {
      const cached = this.skipped.get(num);
      if (!cached) return { ok: false, reason: "replay" };
      this.skipped.delete(num);
      return { ok: true, key: cached };
    }

    const gap = num - this.nextRecvNum;
    if (gap > MAX_SKIP) return { ok: false, reason: "gap-too-large" };

    // Catch up, storing every key we step over. Each stored key is the reason an
    // out-of-order arrival can still be decrypted; the bound on how many we store
    // is the reason a malicious number cannot exhaust us.
    for (let i = 0; i < gap; i++) {
      const skippedNum = this.nextRecvNum;
      this.skipped.set(skippedNum, this.stepRecv());
    }
    const key = this.stepRecv();
    return { ok: true, key };
  }

  /** Seal with the next key. A convenience over [nextKey] for callers that do
   *  not need to put the number anywhere. */
  seal(plaintext: Uint8Array): SealedMessage {
    const { num, nonce, key } = this.nextKey();
    const sealed = this.p.seal(key, nonce, plaintext, new Uint8Array(0));
    zeroize(key);
    return { num, nonce, sealed };
  }

  open(num: number, sealed: Uint8Array): OpenResult {
    const derived = this.keyFor(num);
    if (!derived.ok) return { ok: false, reason: derived.reason, num };
    const plaintext = this.p.open(derived.key, encodeNonce(num), sealed, new Uint8Array(0));
    zeroize(derived.key);
    if (plaintext === null) return { ok: false, reason: "auth-failed", num };
    if (num >= this.nextRecvNum) this.nextRecvNum = num + 1;
    return { ok: true, plaintext, num };
  }

  /** `chainKey -> (msgKey, chainKey')`. One-way in both outputs, so neither the
   *  previous chain key nor a previous message key is recoverable. */
  private step(chainKey: Uint8Array): [Uint8Array, Uint8Array] {
    const msgKey = this.p.hmac(chainKey, MSG_KEY_TAG);
    const next = this.p.hmac(chainKey, CHAIN_KEY_TAG);
    zeroize(chainKey);
    return [msgKey, next];
  }

  private stepSend(): Uint8Array {
    const [msgKey, next] = this.step(this.chainKey);
    this.chainKey = next;
    this.sendNum += 1;
    return msgKey;
  }

  private stepRecv(): Uint8Array {
    const [msgKey, next] = this.step(this.chainKey);
    this.chainKey = next;
    this.nextRecvNum += 1;
    return msgKey;
  }

  /**
   * What a device compromise exposes.
   *
   * Note what is *absent*: no message keys for messages already opened, and no
   * chain key from any earlier step. That absence is the forward-secrecy claim,
   * and [SymmetricRatchet.restore] exists only so a test can pick the state back
   * up as the "attacker" — production code has no reason to call it.
   */
  compromise(): CompromisedState {
    return {
      chainKey: Uint8Array.from(this.chainKey),
      sendNum: this.sendNum,
      nextRecvNum: this.nextRecvNum,
      skipped: [...this.skipped.entries()].map(([num, key]) => [num, Uint8Array.from(key)] as [number, Uint8Array]),
    };
  }

  static restore(p: CryptoPrimitives, state: CompromisedState): SymmetricRatchet {
    const ratchet = new SymmetricRatchet(p, state.chainKey);
    ratchet.sendNum = state.sendNum;
    ratchet.nextRecvNum = state.nextRecvNum;
    for (const [num, key] of state.skipped) ratchet.skipped.set(num, key);
    return ratchet;
  }

  wipe(): void {
    zeroize(this.chainKey);
    this.chainKey = new Uint8Array(32);
    for (const key of this.skipped.values()) zeroize(key);
    this.skipped.clear();
    this.sendNum = 0;
    this.nextRecvNum = 0;
  }
}

/**
 * Seed material for the two directions from Noise's `Split()`, for the side that
 * sends on `c1`. The peer calls it with the arguments swapped.
 *
 * Each chain gets its own ratchet, so compromising the receiving chain does not
 * expose the sending one — the property that makes "compromise after ≠ can decrypt
 * prior" hold per direction rather than only per session.
 */
export function ratchetPair(
  p: CryptoPrimitives,
  c1Key: Uint8Array,
  c2Key: Uint8Array
): { send: SymmetricRatchet; recv: SymmetricRatchet } {
  return { send: new SymmetricRatchet(p, c1Key), recv: new SymmetricRatchet(p, c2Key) };
}

/**
 * Read a message number back out of a wire nonce.
 *
 * The session layer needs this before it can ask for a key, because the number
 * travels in the packet's plaintext nonce field — and that is a deliberate
 * consequence of ratcheting per message: the receiver cannot derive the key
 * without being told which one, so the counter is public. It leaks the message
 * rate and nothing else, which `docs/04` §5 already concedes to timing analysis.
 */
export function decodeNonce(nonce: Uint8Array): number | null {
  if (nonce.length !== 12) return null;
  const view = new DataView(nonce.buffer, nonce.byteOffset, nonce.byteLength);
  for (let i = 0; i < 4; i++) if (nonce[i] !== 0) return null;
  const value = view.getBigUint64(4, true);
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) return null;
  return Number(value);
}

/**
 * Domain-separate a ratchet seed from the raw Noise transport key, so the same 32
 * bytes are never used as both a Noise `CipherState` key and a ratchet seed.
 *
 * The label names the **chain**, not the local direction. Labelling it `"send"`
 * and `"recv"` looks natural and is wrong: `Split()` gives the initiator `c1` to
 * send on and the responder `c1` to receive on, so a per-direction label makes the
 * two sides derive different seeds from the same key and no message ever decrypts.
 * Naming the chain is symmetric by construction — `c1` is `c1` for both — and still
 * keeps the two chains independent, which is the property that stops a stolen
 * receive chain from being used to send.
 */
export function deriveRatchetSeed(
  p: CryptoPrimitives,
  transportKey: Uint8Array,
  chain: "c1" | "c2"
): Uint8Array {
  return p.hmac(transportKey, new TextEncoder().encode(`DumanRatchet-v1:${chain}`));
}
