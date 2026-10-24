/**
 * Cryptographic primitives, and the seam that keeps them out of this repository.
 *
 * `skills/03-crypto.skill.md`: *"DO use libsodium via FFI; never custom crypto."*
 * `docs/07-e2ee-noise-xx.md` repeats it as the reason nothing cryptographic is
 * implemented here. That rule is about **primitives** — nobody should hand-roll
 * X25519, ChaCha20-Poly1305 or SHA-256 — and it is respected below: every
 * primitive delegates to OpenSSL through `node:crypto`. What this directory does
 * implement is the *protocol layer* on top of them (the Noise_XX state machine,
 * the ratchet, the SAS, the packet), which is what `skills/03`'s acceptance
 * criteria and `docs/07` §7's open questions are actually about, and which no
 * library supplies.
 *
 * The indirection through [CryptoPrimitives] is deliberate and load-bearing:
 *
 * - The app (`skills/03`) will run this protocol on libsodium via FFI and on
 *   Dart's `cryptography` package. Those are different primitive implementations
 *   behind the same interface, so the protocol code beside this file ports
 *   without being rewritten.
 * - Tests can inject a deterministic or deliberately broken primitive set, which
 *   is how the tamper and forward-secrecy tests get to be exact rather than
 *   probabilistic.
 *
 * **This is a reference implementation, not a production one.** It has no
 * constant-time guarantees of its own, it keeps key material in ordinary JS
 * `Uint8Array`s that the collector may have copied, and `zeroize()` below is
 * best-effort for exactly that reason. Ship the libsodium/`cryptography` build;
 * `docs/07` §7.4 explains why a wipe in JS cannot be a guarantee.
 */
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  randomBytes as nodeRandomBytes,
  sign as edSign,
  verify as edVerify,
  type KeyObject,
} from "node:crypto";

export interface X25519KeyPair {
  /** 32 bytes, raw. */
  publicKey: Uint8Array;
  /** 32 bytes, raw. */
  privateKey: Uint8Array;
}

export type Ed25519KeyPair = X25519KeyPair;

export interface CryptoPrimitives {
  /** X25519 key agreement (RFC 7748 §5). Returns the 32-byte shared secret. */
  dh(privateKey: Uint8Array, publicKey: Uint8Array): Uint8Array;
  generateX25519(): X25519KeyPair;
  generateEd25519(): Ed25519KeyPair;
  signEd25519(privateKey: Uint8Array, message: Uint8Array): Uint8Array;
  verifyEd25519(publicKey: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean;
  /**
   * ChaCha20-Poly1305 (RFC 8439). Returns `ciphertext || tag16`.
   * Noise always supplies a 32-byte `ad` (the handshake hash); the ratchet layer
   * passes none, so empty AD has to work.
   */
  seal(key: Uint8Array, nonce: Uint8Array, plaintext: Uint8Array, ad: Uint8Array): Uint8Array;
  /** Returns `null` rather than throwing when the tag does not verify. */
  open(key: Uint8Array, nonce: Uint8Array, sealed: Uint8Array, ad: Uint8Array): Uint8Array | null;
  /** SHA-256, 32 bytes — Noise's `HASHLEN`. */
  hash(data: Uint8Array): Uint8Array;
  hmac(key: Uint8Array, data: Uint8Array): Uint8Array;
  randomBytes(n: number): Uint8Array;
}

export const HASHLEN = 32;
export const DHLEN = 32;
export const AEAD_TAG_LEN = 16;
/** ChaCha20-Poly1305 in Noise, and in Node, both fix the nonce at 12 bytes. */
export const NONCE_LEN = 12;

function toBytes(value: Uint8Array | Buffer): Uint8Array {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
}

function b64url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}

function fromB64url(text: string): Uint8Array {
  return new Uint8Array(Buffer.from(text, "base64url"));
}

/**
 * Raw 32-byte keys out of an OKP `KeyObject`. Node has no `raw` export for OKP,
 * so the JWK is the route that does not depend on DER prefix lengths.
 */
function rawPart(key: KeyObject, part: "x" | "d"): Uint8Array {
  const jwk = key.export({ format: "jwk" });
  const value = part === "x" ? jwk.x : jwk.d;
  if (!value) throw new Error(`OKP key has no "${part}" component`);
  return fromB64url(value);
}

function x25519Public(pub: Uint8Array): KeyObject {
  return createPublicKey({ key: { kty: "OKP", crv: "X25519", x: b64url(pub) }, format: "jwk" });
}

function ed25519Public(pub: Uint8Array): KeyObject {
  return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: b64url(pub) }, format: "jwk" });
}

/**
 * PKCS#8 prefixes for the two curves. A private key can be imported from its
 * 32-byte seed alone through PKCS#8, whereas the JWK route wants both halves —
 * and deriving the public half would mean implementing the scalar multiply, i.e.
 * custom crypto. The prefixes are hard-coded, which is only safe because
 * [assertPkcs8Prefixes] re-derives them from Node on every test run.
 */
const ED25519_PKCS8_PREFIX = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
]);
const X25519_PKCS8_PREFIX = new Uint8Array([
  0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x04, 0x22, 0x04, 0x20,
]);

function pkcs8Private(prefix: Uint8Array, seed: Uint8Array): KeyObject {
  return createPrivateKey({
    key: Buffer.concat([Buffer.from(prefix), Buffer.from(seed)]),
    format: "der",
    type: "pkcs8",
  });
}

/** The default primitive set: OpenSSL, via `node:crypto`. */
export const nodePrimitives: CryptoPrimitives = {
  dh(privateKey, publicKey) {
    return toBytes(
      diffieHellman({
        privateKey: pkcs8Private(X25519_PKCS8_PREFIX, privateKey),
        publicKey: x25519Public(publicKey),
      })
    );
  },
  generateX25519() {
    const { publicKey, privateKey } = generateKeyPairSync("x25519");
    return { publicKey: rawPart(publicKey, "x"), privateKey: rawPart(privateKey, "d") };
  },
  generateEd25519() {
    const { publicKey, privateKey } = generateKeyPairSync("ed25519");
    return { publicKey: rawPart(publicKey, "x"), privateKey: rawPart(privateKey, "d") };
  },
  signEd25519(privateKey, message) {
    return toBytes(edSign(null, Buffer.from(message), pkcs8Private(ED25519_PKCS8_PREFIX, privateKey)));
  },
  verifyEd25519(publicKey, message, signature) {
    return edVerify(null, Buffer.from(message), ed25519Public(publicKey), Buffer.from(signature));
  },
  seal(key, nonce, plaintext, ad) {
    const cipher = createCipheriv("chacha20-poly1305", Buffer.from(key), Buffer.from(nonce), {
      authTagLength: AEAD_TAG_LEN,
    });
    if (ad.length > 0) cipher.setAAD(Buffer.from(ad));
    const ct = Buffer.concat([cipher.update(Buffer.from(plaintext)), cipher.final()]);
    return toBytes(Buffer.concat([ct, cipher.getAuthTag()]));
  },
  open(key, nonce, sealed, ad) {
    if (sealed.length < AEAD_TAG_LEN) return null;
    const ct = sealed.subarray(0, sealed.length - AEAD_TAG_LEN);
    const tag = sealed.subarray(sealed.length - AEAD_TAG_LEN);
    try {
      const decipher = createDecipheriv("chacha20-poly1305", Buffer.from(key), Buffer.from(nonce), {
        authTagLength: AEAD_TAG_LEN,
      });
      if (ad.length > 0) decipher.setAAD(Buffer.from(ad));
      decipher.setAuthTag(Buffer.from(tag));
      const pt = Buffer.concat([decipher.update(Buffer.from(ct)), decipher.final()]);
      return toBytes(pt);
    } catch {
      // An AEAD that fails its tag is not an error to report, it is a fact: the
      // caller learns "not for me" and nothing else.
      return null;
    }
  },
  hash(data) {
    return toBytes(createHash("sha256").update(Buffer.from(data)).digest());
  },
  hmac(key, data) {
    return toBytes(createHmac("sha256", Buffer.from(key)).update(Buffer.from(data)).digest());
  },
  randomBytes(n) {
    return toBytes(nodeRandomBytes(n));
  },
};

/**
 * Confirm the hard-coded PKCS#8 prefixes still describe what Node emits, so a
 * Node upgrade that changes the encoding fails a test instead of silently
 * corrupting every private key import.
 */
export function assertPkcs8Prefixes(): boolean {
  // Written out per curve rather than looped over a union: `generateKeyPairSync`
  // has one overload per algorithm, and a `"ed25519" | "x25519"` argument selects
  // none of them.
  const cases: Array<[Uint8Array, Uint8Array]> = [
    [
      ED25519_PKCS8_PREFIX,
      new Uint8Array(generateKeyPairSync("ed25519").privateKey.export({ format: "der", type: "pkcs8" })),
    ],
    [
      X25519_PKCS8_PREFIX,
      new Uint8Array(generateKeyPairSync("x25519").privateKey.export({ format: "der", type: "pkcs8" })),
    ],
  ];
  for (const [prefix, der] of cases) {
    if (der.length !== prefix.length + DHLEN) return false;
    for (let i = 0; i < prefix.length; i++) if (der[i] !== prefix[i]) return false;
  }
  return true;
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const byte of bytes) out += byte.toString(16).padStart(2, "0");
  return out;
}

export function fromHex(text: string): Uint8Array {
  if (text.length % 2 !== 0) throw new RangeError("hex string has an odd length");
  const out = new Uint8Array(text.length / 2);
  for (let i = 0; i < out.length; i++) {
    const byte = Number.parseInt(text.slice(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(byte)) throw new RangeError(`not hex at offset ${i * 2}`);
    out[i] = byte;
  }
  return out;
}

/**
 * Lexicographic byte order. Used wherever two devices must agree on "who is
 * first" from data they both hold — the SAS key ordering and `docs/07` §7.1's
 * simultaneous-open tie-break — so it has to be a total order, and `-1 | 0 | 1`
 * is what makes that checkable.
 */
export function compareBytes(a: Uint8Array, b: Uint8Array): -1 | 0 | 1 {
  const shared = Math.min(a.length, b.length);
  for (let i = 0; i < shared; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  if (a.length === b.length) return 0;
  return a.length < b.length ? -1 : 1;
}

/** Constant-time-ish comparison. Not a guarantee (see the file header), but the
 *  branching is at least not on the first differing byte. */
export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/**
 * Best-effort zeroization. JS gives no way to pin a `Uint8Array` in memory or to
 * stop the collector from having copied it, so `docs/07` §7.4's panic wipe can
 * only ever mean "overwrite what we still hold a reference to". That limitation
 * is why `skills/03` puts keys in StrongBox/Secure Enclave: the platform keystore
 * is the only place a wipe is actually guaranteed.
 */
export function zeroize(...buffers: Array<Uint8Array | null | undefined>): void {
  for (const buffer of buffers) if (buffer) buffer.fill(0);
}
