/**
 * Identity, the QR add-contact flow, and `destHint` — `skills/03`'s "Identity"
 * block and `docs/04` §2.
 *
 * `skills/03`: *"Keygen on first launch: `Ed25519 (sign) + X25519 (exchange) +
 * 32B nodeId = hash(pubKey)`"*, and *"Add-contact: QR = `base64(pubKey || sas8)`"*.
 * `docs/05` fixes the hash: *"32-byte nodeId = SHA-256(pubKey)"*. All three are
 * implemented here, and implementing them surfaced something the prose does not
 * say — see [destHintBytes].
 *
 * Storage is out of scope and deliberately so: `skills/03` puts these keys in
 * Android StrongBox/Keystore and the iOS Secure Enclave, and a JS
 * `Uint8Array` is not that. [Identity] is the shape a keystore-backed
 * implementation has to satisfy; the app should hold the private halves inside
 * the keystore and expose only the operations.
 */
import { concat, toHex, zeroize, type CryptoPrimitives, type Ed25519KeyPair, type X25519KeyPair } from "./primitives";
import { identitySas, isWellFormedSas, SAS_CHAR_COUNT } from "./sas";
import type { NodeId } from "../types";

/** `docs/05`: "32-byte nodeId = SHA-256(pubKey)". */
export const NODE_ID_BYTES = 32;
/** `docs/04` §2 / `skills/03`: the hint is 8 bytes. */
export const DEST_HINT_BYTES = 8;
/** The QR is `base64(pubKey || sas8)` — 32 key bytes plus 8 ASCII characters. */
export const QR_PAYLOAD_BYTES = NODE_ID_BYTES + SAS_CHAR_COUNT;

export const ADD_CONTACT_SCHEME = "duman";
export const ADD_CONTACT_HOST = "add";

export interface Identity {
  /** Ed25519 signing key. Its public half *is* the identity. */
  signing: Ed25519KeyPair;
  /** X25519 exchange key, the `s` in the Noise handshake. */
  exchange: X25519KeyPair;
  /** SHA-256 of the signing public key, 32 raw bytes. */
  nodeIdBytes: Uint8Array;
  /** The same value as the engine's `NodeId` (hex), so a real node can be
   *  dropped into a simulation without a translation table. */
  nodeId: NodeId;
  /** The QR's `sas8`: a fingerprint of the signing key, computable offline. */
  sas: string;
}

export function generateIdentity(p: CryptoPrimitives): Identity {
  const signing = p.generateEd25519();
  const exchange = p.generateX25519();
  const nodeIdBytes = p.hash(signing.publicKey);
  return {
    signing,
    exchange,
    nodeIdBytes,
    nodeId: toHex(nodeIdBytes),
    sas: identitySas(p, signing.publicKey),
  };
}

/**
 * The 8-byte destination hint, and why it hides less than `docs/04` §4 claims.
 *
 * `docs/04` §4: *"`destHint` = truncated hash of dest pubKey (8 bytes) so relays
 * can route without learning full identity."* Implemented literally against
 * `docs/05`'s `nodeId = SHA-256(pubKey)`, the hint is
 *
 *     SHA-256(pubKey)[0..8]  ==  nodeId[0..8]
 *
 * — a prefix of the **nodeId**, which `docs/02` §2 puts in an OGM the destination
 * itself broadcasts every 2 seconds, and which `docs/03` §2 floods through the
 * routing table of every node in range. So a relay that can route the packet at
 * all has already heard the destination's nodeId, and can match the hint against
 * it directly.
 *
 * What the hint therefore buys is **not** identity hiding. It is a shorter label:
 * 8 bytes in every header instead of 32, which on a 256-byte padded block is 9 %
 * of the packet, and a passive sniffer that has *not* collected OGMs cannot read
 * the destination without building the prefix table itself. That is a real but
 * modest win, and the honest version of `docs/04` §4's sentence is the one above.
 * (Corrected in `docs/04` and `docs/07` §6 alongside this file.)
 *
 * Collisions: a 64-bit prefix over the 10-200 node worlds `skills/08` sizes for
 * has a birthday probability near 1e-15 — but see the note in the engine below,
 * because the *simulator* does not compute this value.
 */
export function destHintBytes(p: CryptoPrimitives, destSigningPublicKey: Uint8Array): Uint8Array {
  return p.hash(destSigningPublicKey).subarray(0, DEST_HINT_BYTES);
}

/** Domain-separated variant, for a hint that must not be a bare prefix of the
 *  nodeId — see the "shorter label, not identity hiding" note above. */
export function destHintBytesOpaque(
  p: CryptoPrimitives,
  destSigningPublicKey: Uint8Array
): Uint8Array {
  return p
    .hash(concat(new TextEncoder().encode("DumanDestHint-v1"), destSigningPublicKey))
    .subarray(0, DEST_HINT_BYTES);
}

// --- QR add-contact ----------------------------------------------------------

export interface QrPayload {
  /** The Ed25519 public key that was scanned. */
  publicKey: Uint8Array;
  /** Its 8-character fingerprint, for the user to read back. */
  sas: string;
}

/** `skills/03`: `QR = base64(pubKey || sas8)`. Base64**url**, unpadded, because
 *  a QR in the wild gets copied into URLs and chat messages. */
export function encodeQr(identity: Identity): string {
  const ascii = new TextEncoder().encode(identity.sas);
  if (ascii.length !== SAS_CHAR_COUNT) {
    throw new RangeError(`sas must be ${SAS_CHAR_COUNT} ASCII characters, got ${ascii.length}`);
  }
  return Buffer.from(concat(identity.signing.publicKey, ascii)).toString("base64url");
}

export function decodeQr(text: string): QrPayload | null {
  const raw = Buffer.from(text.trim(), "base64url");
  if (raw.length !== QR_PAYLOAD_BYTES) return null;
  const publicKey = new Uint8Array(raw.subarray(0, NODE_ID_BYTES));
  const sas = new TextDecoder().decode(raw.subarray(NODE_ID_BYTES));
  // The fingerprint is checked against its own alphabet before it is shown to a
  // user, because "read these eight characters back to me" is the whole protocol
  // and a payload that cannot be read aloud is not a contact.
  if (!isWellFormedSas(sas)) return null;
  return { publicKey, sas };
}

/** `docs/04` §2's side channel: *"share `duman://add?pub=...&sas=...` over any
 *  side channel (then verify SAS verbally)"*. */
export function addContactLink(payload: QrPayload): string {
  const pub = Buffer.from(payload.publicKey).toString("base64url");
  return `${ADD_CONTACT_SCHEME}://${ADD_CONTACT_HOST}?pub=${pub}&sas=${payload.sas}`;
}

export function parseAddContactLink(url: string): QrPayload | null {
  const match = /^duman:\/\/add\?([^#]*)$/.exec(url.trim());
  if (!match) return null;
  const params = new URLSearchParams(match[1]);
  const pub = params.get("pub");
  const sas = params.get("sas");
  if (!pub || !sas) return null;
  const publicKey = new Uint8Array(Buffer.from(pub, "base64url"));
  if (publicKey.length !== NODE_ID_BYTES || !isWellFormedSas(sas)) return null;
  return { publicKey, sas };
}

// --- panic wipe --------------------------------------------------------------

/**
 * `docs/04` §3: *"panic wipe = overwrite key"*, `skills/03`: *"zero keys +
 * overwrite DB + toast"*.
 *
 * What this can do is overwrite every buffer this object still holds. What it
 * cannot do is guarantee the bytes are gone: the JS collector may have copied
 * them, a debugger may have them, and the `Identity` was constructed from
 * `generateKeyPairSync` whose own `KeyObject`s lived in OpenSSL memory first.
 * That is `docs/07` §7.4's open question, and the answer is not a better JS
 * function — it is that the private halves should never have been in JS, which is
 * what StrongBox and the Secure Enclave are for. The return value is the list of
 * buffers that were *not* held here, so a caller can see the shape of the gap.
 */
export interface WipeResult {
  /** Buffers overwritten, by field. */
  zeroed: string[];
}

export function panicWipeIdentity(identity: Identity): WipeResult {
  const zeroed: string[] = [];
  const fields: Array<[string, Uint8Array]> = [
    ["signing.privateKey", identity.signing.privateKey],
    ["signing.publicKey", identity.signing.publicKey],
    ["exchange.privateKey", identity.exchange.privateKey],
    ["exchange.publicKey", identity.exchange.publicKey],
    ["nodeIdBytes", identity.nodeIdBytes],
  ];
  for (const [name, buffer] of fields) {
    zeroize(buffer);
    zeroed.push(name);
  }
  return { zeroed };
}

/** True once a wiped identity's buffers are all zero — the property the panic
 *  wipe test actually asserts, rather than trusting the function that does it. */
export function isWiped(identity: Identity): boolean {
  return [
    identity.signing.privateKey,
    identity.signing.publicKey,
    identity.exchange.privateKey,
    identity.exchange.publicKey,
    identity.nodeIdBytes,
  ].every((buffer) => buffer.every((byte) => byte === 0));
}

/** Sign a handle-to-key binding, so a contact list can prove *this* key was
 *  claimed under *that* name at *that* time. `docs/04` §2: uniqueness is
 *  per-contact, so the binding is the only thing a name ever means. */
export function signHandleClaim(
  p: CryptoPrimitives,
  identity: Identity,
  handle: string,
  nowMs: number
): { handle: string; nodeId: NodeId; claimedAt: number; signature: Uint8Array } {
  const message = concat(
    new TextEncoder().encode(handle),
    identity.nodeIdBytes,
    timestampBytes(nowMs)
  );
  return {
    handle,
    nodeId: identity.nodeId,
    claimedAt: nowMs,
    signature: p.signEd25519(identity.signing.privateKey, message),
  };
}

export function verifyHandleClaim(
  p: CryptoPrimitives,
  publicKey: Uint8Array,
  claim: { handle: string; claimedAt: number; signature: Uint8Array }
): boolean {
  const nodeIdBytes = p.hash(publicKey);
  return p.verifyEd25519(
    publicKey,
    concat(new TextEncoder().encode(claim.handle), nodeIdBytes, timestampBytes(claim.claimedAt)),
    claim.signature
  );
}

/** 48-bit big-endian milliseconds — the width the packet's `ts` field uses, so
 *  the two encodings cannot drift apart. Valid to year 10889. */
export const TIMESTAMP_MAX_MS = 2 ** 48 - 1;

export function timestampBytes(nowMs: number): Uint8Array {
  // The ceiling is enforced rather than left to `setUint16`, which would mask a
  // value past 2^48 to its low 16 bits and silently put the packet in 1970.
  if (!Number.isSafeInteger(nowMs) || nowMs < 0 || nowMs > TIMESTAMP_MAX_MS) {
    throw new RangeError(`timestamp ${nowMs} is outside 0..${TIMESTAMP_MAX_MS}`);
  }
  const out = new Uint8Array(6);
  const view = new DataView(out.buffer);
  // 48-bit BE = the low 16 bits first, then the high 32.
  view.setUint16(0, Math.floor(nowMs / 2 ** 32) & 0xffff, false);
  view.setUint32(2, nowMs >>> 0, false);
  return out;
}

export function timestampFromBytes(bytes: Uint8Array): number {
  if (bytes.length < 6) throw new RangeError("timestamp needs 6 bytes");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return view.getUint16(0, false) * 2 ** 32 + view.getUint32(2, false);
}
