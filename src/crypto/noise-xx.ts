/**
 * Noise_XX, as a mesh handshake (`docs/07` §1, `skills/03`).
 *
 * Protocol: `Noise_XX_25519_ChaChaPoly_SHA256`, the pattern `skills/03` fixes:
 *
 *     <- s
 *     ...
 *     -> e
 *     <- e, ee, s, es
 *     -> s, se
 *
 * This is a faithful implementation of the Noise Protocol Framework's
 * `HandshakeState` for that one pattern — `CipherState`, `SymmetricState`,
 * `MixHash`, `MixKey`, `EncryptAndHash`, `DecryptAndHash`, `Split` and the
 * Noise-flavoured HKDF are all here with the spec's names, because the value of
 * the code is that it can be read against the spec and against libsodium's
 * output. The primitives themselves come from [CryptoPrimitives]; nothing here
 * implements a cipher.
 *
 * What the mesh adds is not in the Noise spec and is the reason this file exists
 * at all:
 *
 * - **A leg can be lost** (`docs/07` §2.2 measured one lost at four hops in a
 *   60-node crowd). Noise is a lock-step protocol with no retransmission, so the
 *   retry has to live outside it. [HandshakeLeg] is therefore a plain byte array
 *   the caller may re-send, and the state machine is resumable: nothing about
 *   `writeMessage` consumes the message pattern until the caller takes it.
 * - **Simultaneous open** (`docs/07` §7.1). XX supports both sides initiating,
 *   which on a mesh with no RTT asymmetry means two devices can each send leg 1
 *   at the same moment. [resolveSimultaneousOpen] is the tie-break, and it
 *   discards rather than reuses the loser's ephemeral key.
 */
import {
  AEAD_TAG_LEN,
  DHLEN,
  HASHLEN,
  NONCE_LEN,
  concat,
  equalBytes,
  zeroize,
  type CryptoPrimitives,
  type X25519KeyPair,
} from "./primitives";

export const PROTOCOL_NAME = "Noise_XX_25519_ChaChaPoly_SHA256";

const MESSAGE_PATTERNS: ReadonlyArray<{ dir: "<" | ">"; tokens: readonly string[] }> = [
  { dir: ">", tokens: ["e"] },
  { dir: "<", tokens: ["e", "ee", "s", "es"] },
  { dir: ">", tokens: ["s", "se"] },
];

/** Which side sends which leg. `>` is the initiator. */
export const LEG_DIRECTIONS = MESSAGE_PATTERNS.map((pattern) => pattern.dir) as ReadonlyArray<
  "<" | ">"
>;

/**
 * The encoded size of each leg, in bytes, for an empty payload and before any
 * framing the transport adds: **32, 96, 64**.
 *
 * This is `docs/07` §7.2's open question answered with arithmetic instead of
 * prose, and the arithmetic has one wrinkle worth stating: a leg's trailing
 * payload is `EncryptAndHash`, so once a key exists an *empty* payload still costs
 * a 16-byte tag. Leg 1 is the only one with no key yet, which is why it is a bare
 * 32-byte ephemeral and the other two carry a tag they do not obviously need.
 *
 * None of the three is near the 247 B GATT MTU §7.2 worries about — the
 * fragmentation problem belongs to the *data* plane, whose packets are padded to
 * 256 B blocks, not to the handshake. A handshake fits one unfragmented GATT
 * write per leg with 151 B to spare on the largest.
 */
export const LEG_SIZES: readonly number[] = [
  DHLEN,
  DHLEN + (DHLEN + AEAD_TAG_LEN) + AEAD_TAG_LEN,
  DHLEN + AEAD_TAG_LEN + AEAD_TAG_LEN,
];

export interface NoiseCipherState {
  /** Null until `MixKey` runs — Noise models "no key yet" explicitly, because
   *  that is what makes leg 1's ephemeral travel in the clear. */
  key: Uint8Array | null;
  n: number;
}

/**
 * Noise's 96-bit little-endian nonce. For every `n` this protocol can reach the
 * high 4 bytes stay zero, so the encoding is 4 zero bytes then `n` as a 64-bit
 * little-endian integer — the same bytes, written so the reader can see both
 * descriptions agree.
 */
export function encodeNonce(n: number): Uint8Array {
  if (!Number.isSafeInteger(n) || n < 0) throw new RangeError(`nonce counter out of range: ${n}`);
  const out = new Uint8Array(NONCE_LEN);
  const view = new DataView(out.buffer);
  view.setBigUint64(4, BigInt(n), true);
  return out;
}

/**
 * Noise's HKDF: `HKDF(ck, ikm, n)` = extract with `salt = ck`, then expand to
 * `n` 32-byte outputs where each output feeds the next. Written with HMAC
 * directly rather than through a generic HKDF, because the chaining is the part
 * that is easy to get subtly wrong and easy to read this way.
 */
export function noiseHkdf(
  p: CryptoPrimitives,
  ck: Uint8Array,
  ikm: Uint8Array,
  outputs: 2 | 3
): Uint8Array[] {
  const salt = p.hmac(ck, ikm);
  const result: Uint8Array[] = [];
  // Annotated rather than inferred: `new Uint8Array(0)` infers
  // `Uint8Array<ArrayBuffer>` under @types/node 26, and HMAC returns
  // `Uint8Array<ArrayBufferLike>`, which will not assign back into it.
  let previous: Uint8Array = new Uint8Array(0);
  for (let i = 1; i <= outputs; i++) {
    previous = p.hmac(salt, concat(previous, new Uint8Array([i])));
    result.push(previous);
  }
  return result;
}

class CipherState {
  key: Uint8Array | null = null;
  n = 0;

  constructor(private readonly p: CryptoPrimitives) {}

  initializeKey(key: Uint8Array | null, n = 0): void {
    zeroize(this.key);
    this.key = key === null ? null : Uint8Array.from(key);
    this.n = n;
  }

  hasKey(): boolean {
    return this.key !== null;
  }

  encryptWithAd(ad: Uint8Array, plaintext: Uint8Array): Uint8Array {
    if (!this.key) return Uint8Array.from(plaintext);
    const sealed = this.p.seal(this.key, encodeNonce(this.n), plaintext, ad);
    this.n += 1;
    return sealed;
  }

  decryptWithAd(ad: Uint8Array, sealed: Uint8Array): Uint8Array {
    if (!this.key) return Uint8Array.from(sealed);
    const plaintext = this.p.open(this.key, encodeNonce(this.n), sealed, ad);
    if (plaintext === null) throw new NoiseError("aead-failed", "decryption failed: tag mismatch");
    this.n += 1;
    return plaintext;
  }

  wipe(): void {
    zeroize(this.key);
    this.key = null;
    this.n = 0;
  }
}

export type NoiseFailure = "aead-failed" | "truncated" | "out-of-order" | "already-complete";

/** Thrown rather than returned, because a handshake that fails mid-leg has no
 *  useful partial state and the caller's only correct action is to discard it. */
export class NoiseError extends Error {
  constructor(readonly reason: NoiseFailure, message: string) {
    super(message);
    this.name = "NoiseError";
  }
}

export interface HandshakeKeys {
  /** Our long-term X25519 key. Required for XX. */
  s: X25519KeyPair;
  /**
   * An ephemeral key the caller supplies instead of one being generated. Used by
   * [HandshakeState.forkWithFreshEphemeral] and by the tests, which need to know
   * the ephemeral in advance to tamper with it.
   */
  e?: X25519KeyPair;
}

export interface HandshakeResult {
  /** Initiator → responder transport cipher. */
  c1: NoiseCipherState;
  /** Responder → initiator transport cipher. */
  c2: NoiseCipherState;
  /** The transcript hash. Equal on both sides, and the input to the SAS. */
  handshakeHash: Uint8Array;
  /** The peer's static public key, learned during the handshake. */
  remoteStatic: Uint8Array;
}

/**
 * One side of a Noise_XX handshake.
 *
 * Deliberately *not* a network object: it knows nothing about legs arriving, and
 * `readMessage`/`writeMessage` are the caller's to sequence. That is what makes
 * the `docs/07` §2.1 requirement — retry per leg, not per handshake — expressible:
 * a lost leg 3 is re-produced from the same state with the same bytes, because
 * XX's transcript is already fixed by then.
 */
export class HandshakeState {
  private readonly p: CryptoPrimitives;
  private readonly symmetric: SymmetricState;
  private readonly s: X25519KeyPair;
  private e: X25519KeyPair | null;
  private rs: Uint8Array | null = null;
  private re: Uint8Array | null = null;
  private patternIndex = 0;
  private done = false;

  constructor(
    p: CryptoPrimitives,
    readonly initiator: boolean,
    keys: HandshakeKeys,
    prologue: Uint8Array = new Uint8Array(0)
  ) {
    this.p = p;
    this.s = keys.s;
    // `keys.e` is how a caller fixes the ephemeral in advance — either to resume
    // a handshake with a key it already generated, or, in tests, to know which
    // bytes to tamper with.
    this.e = keys.e ? { publicKey: keys.e.publicKey, privateKey: keys.e.privateKey } : null;
    this.symmetric = new SymmetricState(p);
    this.symmetric.initialize(PROTOCOL_NAME, prologue);
    // XX's pre-message `<- s` contributes nothing to the transcript: neither
    // side starts holding the other's static key, which is the whole reason the
    // QR exchange exists. Nothing to mix, so nothing is mixed.
  }

  get isComplete(): boolean {
    return this.done;
  }

  /** The ephemeral public key this side is using, or `null` before leg 1. */
  get ephemeralPublic(): Uint8Array | null {
    return this.e ? this.e.publicKey : null;
  }

  /** Which leg comes next (0-based), for progress UIs — `docs/07` §2.1 note 3. */
  get nextLeg(): number {
    return this.patternIndex;
  }

  writeMessage(payload: Uint8Array = new Uint8Array(0)): Uint8Array {
    this.assertNotDone("write");
    const pattern = MESSAGE_PATTERNS[this.patternIndex];
    const mine = pattern.dir === ">" ? this.initiator : !this.initiator;
    if (!mine) {
      throw new NoiseError(
        "out-of-order",
        `leg ${this.patternIndex} belongs to the ${this.initiator ? "responder" : "initiator"}`
      );
    }
    const out: Uint8Array[] = [];
    for (const token of pattern.tokens) out.push(this.writeToken(token));
    out.push(this.symmetric.encryptAndHash(payload));
    this.advance();
    return concat(...out);
  }

  readMessage(message: Uint8Array, expectPayload = 0): Uint8Array {
    this.assertNotDone("read");
    const pattern = MESSAGE_PATTERNS[this.patternIndex];
    const mine = pattern.dir === ">" ? this.initiator : !this.initiator;
    if (mine) {
      throw new NoiseError(
        "out-of-order",
        `leg ${this.patternIndex} is ours to write, not to read`
      );
    }
    let offset = 0;
    const take = (n: number): Uint8Array => {
      if (offset + n > message.length) {
        throw new NoiseError("truncated", `leg ${this.patternIndex} is ${message.length} B, need ${offset + n}`);
      }
      const part = message.subarray(offset, offset + n);
      offset += n;
      return part;
    };
    for (const token of pattern.tokens) {
      if (token === "s") {
        const length = this.symmetric.hasKey() ? DHLEN + AEAD_TAG_LEN : DHLEN;
        this.rs = this.symmetric.decryptAndHash(take(length));
      } else if (token === "e") {
        this.re = Uint8Array.from(take(DHLEN));
        this.symmetric.mixHash(this.re);
      } else {
        this.mixKeyFor(token);
      }
    }
    const remaining = message.length - offset;
    if (remaining < expectPayload) {
      throw new NoiseError("truncated", `leg ${this.patternIndex} carries ${remaining} B of payload`);
    }
    const payload = this.symmetric.decryptAndHash(message.subarray(offset));
    this.advance();
    return payload;
  }

  private assertNotDone(what: string): void {
    if (this.done) {
      throw new NoiseError("already-complete", `handshake is complete; cannot ${what} another leg`);
    }
    if (this.patternIndex >= MESSAGE_PATTERNS.length) {
      throw new NoiseError("already-complete", "no legs left in the pattern");
    }
  }

  private writeToken(token: string): Uint8Array {
    switch (token) {
      case "e": {
        if (!this.e) this.e = this.p.generateX25519();
        this.symmetric.mixHash(this.e.publicKey);
        return Uint8Array.from(this.e.publicKey);
      }
      case "s":
        return this.symmetric.encryptAndHash(this.s.publicKey);
      case "ee":
      case "es":
      case "se":
      case "ss":
        this.mixKeyFor(token);
        return new Uint8Array(0);
      default:
        throw new Error(`unknown Noise token "${token}"`);
    }
  }

  /**
   * The DH tokens, with Noise's initiator/responder asymmetry written out rather
   * than abbreviated — `es` and `se` mean different things on each side and
   * swapping them produces a handshake that fails only at leg 3.
   */
  private mixKeyFor(token: string): void {
    if (!this.e) throw new NoiseError("out-of-order", `"${token}" before our ephemeral exists`);
    if (!this.re) throw new NoiseError("out-of-order", `"${token}" before the peer's ephemeral exists`);
    switch (token) {
      case "ee":
        this.symmetric.mixKey(this.p.dh(this.e.privateKey, this.re));
        return;
      case "es":
        if (this.initiator) {
          this.symmetric.mixKey(this.p.dh(this.e.privateKey, this.requireRemoteStatic()));
        } else {
          this.symmetric.mixKey(this.p.dh(this.s.privateKey, this.re));
        }
        return;
      case "se":
        if (this.initiator) {
          this.symmetric.mixKey(this.p.dh(this.s.privateKey, this.re));
        } else {
          this.symmetric.mixKey(this.p.dh(this.e.privateKey, this.requireRemoteStatic()));
        }
        return;
      case "ss":
        this.symmetric.mixKey(this.p.dh(this.s.privateKey, this.requireRemoteStatic()));
        return;
      default:
        throw new Error(`"${token}" is not a DH token`);
    }
  }

  private requireRemoteStatic(): Uint8Array {
    if (!this.rs) throw new NoiseError("out-of-order", "DH token needs the peer's static key");
    return this.rs;
  }

  private advance(): void {
    this.patternIndex += 1;
    if (this.patternIndex === MESSAGE_PATTERNS.length) {
      this.done = true;
      this.symmetric.split();
    }
  }

  /** The transport ciphers. Only valid once [isComplete]. */
  result(): HandshakeResult {
    if (!this.done) throw new NoiseError("out-of-order", "handshake has not completed");
    if (!this.rs) throw new NoiseError("out-of-order", "peer static key never arrived");
    return {
      c1: this.symmetric.c1State(),
      c2: this.symmetric.c2State(),
      handshakeHash: Uint8Array.from(this.symmetric.h),
      remoteStatic: Uint8Array.from(this.rs),
    };
  }

  /**
   * Discard this handshake's ephemeral key.
   *
   * `docs/07` §7.1 asks whether the loser of a simultaneous open discards or
   * reuses its ephemeral key. It has to discard it: an ephemeral reused across
   * two handshakes is no longer ephemeral, and the aborted half-session's
   * forward secrecy depends on that key never having been in another transcript.
   */
  discardEphemeral(): void {
    if (this.e) zeroize(this.e.privateKey, this.e.publicKey);
    this.e = null;
  }

  wipe(): void {
    this.discardEphemeral();
    this.symmetric.wipe();
    zeroize(this.rs, this.re);
    this.rs = null;
    this.re = null;
  }
}

class SymmetricState {
  private readonly cipher: CipherState;
  ck: Uint8Array;
  h: Uint8Array;

  private c1: CipherState | null = null;
  private c2: CipherState | null = null;

  constructor(private readonly p: CryptoPrimitives) {
    this.ck = new Uint8Array(HASHLEN);
    this.h = new Uint8Array(HASHLEN);
    this.cipher = new CipherState(p);
  }

  initialize(protocolName: string, prologue: Uint8Array): void {
    const name = new TextEncoder().encode(protocolName);
    if (name.length <= HASHLEN) {
      // Spec: pad with zeros to HASHLEN. The name is exactly 32 bytes, so this
      // branch is the one that runs — but the other branch has to exist, because
      // a longer hash function would take it and a missing branch would silently
      // truncate.
      this.h = new Uint8Array(HASHLEN);
      this.h.set(name);
    } else {
      this.h = this.p.hash(name);
    }
    this.ck = Uint8Array.from(this.h);
    this.mixHash(prologue);
  }

  mixHash(data: Uint8Array): void {
    this.h = this.p.hash(concat(this.h, data));
  }

  mixKey(inputKeyMaterial: Uint8Array): void {
    const [ck, tempK] = noiseHkdf(this.p, this.ck, inputKeyMaterial, 2);
    this.ck = ck;
    this.cipher.initializeKey(tempK);
  }

  hasKey(): boolean {
    return this.cipher.hasKey();
  }

  encryptAndHash(plaintext: Uint8Array): Uint8Array {
    const sealed = this.cipher.encryptWithAd(this.h, plaintext);
    this.mixHash(sealed);
    return sealed;
  }

  decryptAndHash(sealed: Uint8Array): Uint8Array {
    const plaintext = this.cipher.decryptWithAd(this.h, sealed);
    this.mixHash(sealed);
    return plaintext;
  }

  split(): void {
    const [k1, k2] = noiseHkdf(this.p, this.ck, new Uint8Array(0), 2);
    this.c1 = new CipherState(this.p);
    this.c2 = new CipherState(this.p);
    this.c1.initializeKey(k1);
    this.c2.initializeKey(k2);
  }

  c1State(): NoiseCipherState {
    return this.exportState(this.c1);
  }

  c2State(): NoiseCipherState {
    return this.exportState(this.c2);
  }

  private exportState(cipher: CipherState | null): NoiseCipherState {
    if (!cipher || !cipher.key) throw new NoiseError("out-of-order", "Split() has not run");
    return { key: Uint8Array.from(cipher.key), n: cipher.n };
  }

  wipe(): void {
    this.cipher.wipe();
    this.c1?.wipe();
    this.c2?.wipe();
    this.c1 = null;
    this.c2 = null;
    zeroize(this.ck, this.h);
    this.ck = new Uint8Array(HASHLEN);
    this.h = new Uint8Array(HASHLEN);
  }
}

/**
 * Run a whole handshake in one process, initiator and responder both.
 *
 * Not how the mesh does it — there the three legs are three radio messages over
 * `docs/07` §2's latency — but it is the cheapest way to prove the two sides
 * agree, and the tests use it as the base case before the mesh-level ones.
 */
export function handshakeInProcess(
  p: CryptoPrimitives,
  alice: X25519KeyPair,
  bob: X25519KeyPair,
  prologue: Uint8Array = new Uint8Array(0),
  payloadPerLeg: ReadonlyArray<Uint8Array> = [new Uint8Array(0), new Uint8Array(0), new Uint8Array(0)]
): { alice: HandshakeResult; bob: HandshakeResult; legs: Uint8Array[] } {
  const initiator = new HandshakeState(p, true, { s: alice }, prologue);
  const responder = new HandshakeState(p, false, { s: bob }, prologue);
  const legs: Uint8Array[] = [];

  legs.push(initiator.writeMessage(payloadPerLeg[0]));
  responder.readMessage(legs[0], payloadPerLeg[0].length);

  legs.push(responder.writeMessage(payloadPerLeg[1]));
  initiator.readMessage(legs[1], payloadPerLeg[1].length);

  legs.push(initiator.writeMessage(payloadPerLeg[2]));
  responder.readMessage(legs[2], payloadPerLeg[2].length);

  return { alice: initiator.result(), bob: responder.result(), legs };
}

/**
 * `docs/07` §7.1, answered: who initiates when both sides tap "add" at once.
 *
 * The rule has to be computable by both devices from data they already hold —
 * the two static public keys, exchanged out of band by the QR flow (`docs/04`
 * §2) — and it has to be a total order, so exactly one side wins. Lexicographic
 * comparison of the public keys is both.
 *
 * Returns `"initiate"` if this device should send leg 1, `"accept"` if it should
 * wait. A device that has already sent leg 1 and then learns it lost calls
 * [HandshakeState.discardEphemeral] and restarts as the responder.
 */
export function resolveSimultaneousOpen(
  myStatic: Uint8Array,
  theirStatic: Uint8Array
): "initiate" | "accept" | "identical" {
  if (equalBytes(myStatic, theirStatic)) return "identical";
  for (let i = 0; i < Math.min(myStatic.length, theirStatic.length); i++) {
    if (myStatic[i] !== theirStatic[i]) return myStatic[i] < theirStatic[i] ? "initiate" : "accept";
  }
  return myStatic.length < theirStatic.length ? "initiate" : "accept";
}
