/**
 * The packet, serialised for real: `skills/03`'s layout, `docs/04` §4, and the
 * sizes `docs/07` §4 publishes.
 *
 *     header {msgId16, ttl, type, destHint8, hop}          = 27 B   plaintext
 *     aead   {nonce12, ciphertext, tag16}                  = 28 B + ciphertext
 *     ciphertext = from(32) + ts(6) + len(2) + body + zero-pad-to-256-blocks
 *
 * Before this file existed the layout was arithmetic on three exported constants
 * (`PACKET_OVERHEAD_BYTES` 95, `PAD_BLOCK_BYTES` 256, `BLE_MAX_BYTES` 1024) and
 * `tool/e2ee-probe.ts` checked `docs/07` §4's table against that arithmetic. That
 * is a weaker claim than it looks: a constant can be self-consistent and still not
 * describe anything you can build. Serialising the packet turns §4's table into a
 * measurement, and doing so surfaced two things the prose gets wrong.
 *
 * **1. `ts` is 6 bytes and there is a 2-byte length field.** `docs/07` §4 writes
 * `from(32) + ts(8)`, which leaves the padding unstrippable. Zero padding is
 * ambiguous for a binary body — a media chunk can legitimately end in `0x00` — so
 * the reader needs the length. Taking 2 bytes from `ts` keeps the total at 95 and
 * therefore keeps every published number: 40-bit milliseconds is valid to the
 * year 10889, and the engine's own chunk path passes an *empty* body with the
 * payload size declared separately (`docs/08` §8: *"chunks declare their payload
 * size rather than their padded size"*), so the 65 535-byte limit on `len` never
 * binds. A mandatory `0x80` pad marker instead (ISO 9797-1 method 2) would have
 * been unambiguous without a length field, but it costs a whole extra block
 * whenever `95 + body` is already a multiple of 256 — and 929 is such a body, the
 * exact size `docs/08` §5.3 uses to derive the 14.9 kbit/s PTT ceiling. So the
 * length field is what keeps that result true.
 *
 * **2. `msgId16` is a digest, not the id.** The engine's message ids are short
 * strings (`m000042`) and putting one in a plaintext header leaks the send rate
 * and the sender's counter to every relay. `skills/03` asks for 16 bytes, so the
 * header carries `SHA-256(msgId)[0:16]`: dedup compares digests, and a 128-bit
 * truncation is collision-safe for a mesh that will never see 2^64 messages.
 */
import {
  AEAD_TAG_LEN,
  concat,
  toHex,
  zeroize,
  type CryptoPrimitives,
} from "./primitives";
import { encodeNonce } from "./noise-xx";
import { NODE_ID_BYTES, timestampBytes, timestampFromBytes } from "./identity";
import { BLE_MAX_BYTES, PACKET_OVERHEAD_BYTES, PAD_BLOCK_BYTES } from "../routing";
import type { MsgType } from "../types";

export const HEADER_BYTES = 27;
export const MSG_ID_DIGEST_BYTES = 16;
export const NONCE_BYTES = 12;
export const TAG_BYTES = AEAD_TAG_LEN;
export const FROM_BYTES = NODE_ID_BYTES;
export const TS_BYTES = 6;
export const LEN_BYTES = 2;
/** `from` + `ts` + `len`, inside the ciphertext. */
export const PLAINTEXT_FIXED_BYTES = FROM_BYTES + TS_BYTES + LEN_BYTES;
/** The longest body the 2-byte length field can describe. */
export const MAX_SEALED_BODY_BYTES = 0xffff;

/**
 * The constant the engine sizes every message with, recomputed from this file's
 * field widths. [packetLayoutIsConsistent] asserts the two agree, so a width
 * change here cannot silently invalidate `wireSizeOf` — which is what sets the
 * BLE/Wi-Fi boundary and therefore every latency in `docs/06`.
 */
export const PACKET_OVERHEAD_FROM_FIELDS =
  HEADER_BYTES + NONCE_BYTES + TAG_BYTES + PLAINTEXT_FIXED_BYTES;

/** One-byte codes for `MsgType`, in the order `src/types.ts` declares them. */
const TYPE_CODES: Readonly<Record<MsgType, number>> = {
  text: 0,
  broadcast: 1,
  voice: 2,
  file: 3,
  sos: 4,
  sync: 5,
  ack: 6,
  ogm: 7,
};

const TYPE_NAMES = Object.entries(TYPE_CODES) as Array<[MsgType, number]>;

export function msgTypeCode(type: MsgType): number {
  return TYPE_CODES[type];
}

export function msgTypeFromCode(code: number): MsgType | null {
  for (const [name, value] of TYPE_NAMES) if (value === code) return name;
  return null;
}

/**
 * `docs/04` §3: the broadcast/pager channel is *not* private by design, and `ogm`
 * and `ack` are control plane — a relay has to read them. Everything else is
 * sealed. This mirrors the engine's `encrypted: type !== "broadcast"`, widened to
 * the two control types the engine also never encrypts in practice.
 */
export function isSealedType(type: MsgType): boolean {
  return type !== "broadcast" && type !== "ogm" && type !== "ack";
}

export interface PacketHeader {
  /** `SHA-256(msgId)[0:16]`. */
  msgIdDigest: Uint8Array;
  ttl: number;
  type: MsgType;
  destHint: Uint8Array;
  hop: number;
}

/** What came out of [openPacket]: the header plus the decrypted interior. */
export interface PacketFields extends PacketHeader {
  /** The sender's Ed25519 public key — `docs/04` §4's `fromPubKey`, inside the
   *  ciphertext, which is what makes a relay unable to name the sender. */
  from: Uint8Array;
  timestampMs: number;
  body: Uint8Array;
}

/**
 * What goes into [sealPacket].
 *
 * Not `PacketFields`: the caller supplies the *message id* and the header carries
 * its digest, so the two shapes differ by exactly the field that must not go on
 * air. Keeping them separate is what stops a future refactor from "simplifying"
 * by putting the id in the header.
 */
export interface SealRequest {
  msgId: string;
  ttl: number;
  type: MsgType;
  destHint: Uint8Array;
  hop: number;
  /** The sender's Ed25519 public key, 32 bytes. */
  from: Uint8Array;
  timestampMs: number;
  body: Uint8Array;
  /** The ratchet message number; encoded into the 12-byte nonce field. */
  nonce: number;
}

export interface SealedPacket {
  /** The exact bytes that go on air. `bytes.length === wireSizeOfBody(body)`. */
  bytes: Uint8Array;
  header: PacketHeader;
  nonce: Uint8Array;
}

export type OpenFailure = "short" | "bad-type" | "auth-failed" | "bad-length";

export type OpenPacketResult =
  | { ok: true; packet: PacketFields; headerBytes: number }
  | { ok: false; reason: OpenFailure };

export function msgIdDigest(p: CryptoPrimitives, msgId: string): Uint8Array {
  return p.hash(new TextEncoder().encode(msgId)).subarray(0, MSG_ID_DIGEST_BYTES);
}

/**
 * Pad a plaintext so the whole packet is a multiple of [PAD_BLOCK_BYTES].
 *
 * The padding rounds the **packet**, not the ciphertext — that is the reading of
 * `skills/03`'s "pad to 256B blocks" that reproduces `docs/07` §4's table exactly
 * (body 0 → 256 B, body 930 → 1280 B). Padding the ciphertext alone would give
 * `55 + ceil((40 + body) / 256) × 256`, which disagrees with the published table
 * from body 0 upwards.
 */
export function padPlaintext(plaintext: Uint8Array, bodyBytes: number): Uint8Array {
  const total = wireSizeOfBodyBytes(bodyBytes);
  const fixed = PACKET_OVERHEAD_FROM_FIELDS - PLAINTEXT_FIXED_BYTES;
  const pad = total - fixed - plaintext.length;
  if (pad < 0) throw new RangeError(`plaintext of ${plaintext.length} B cannot fit a ${total} B packet`);
  if (pad === 0) return plaintext;
  return concat(plaintext, new Uint8Array(pad));
}

/** `wireSizeOf` in terms of *bytes* rather than characters. The engine's version
 *  takes a character count; see `src/routing.ts` for why that matters. */
export function wireSizeOfBodyBytes(bodyBytes: number): number {
  const raw = PACKET_OVERHEAD_FROM_FIELDS + Math.max(0, bodyBytes);
  return Math.ceil(raw / PAD_BLOCK_BYTES) * PAD_BLOCK_BYTES;
}

export function sealPacket(
  p: CryptoPrimitives,
  key: Uint8Array,
  fields: SealRequest
): SealedPacket {
  if (fields.body.length > MAX_SEALED_BODY_BYTES) {
    throw new RangeError(
      `body of ${fields.body.length} B exceeds the ${MAX_SEALED_BODY_BYTES} B length field; ` +
        "media chunks declare their payload size separately (docs/08 §8) and pass an empty body"
    );
  }
  if (fields.from.length !== FROM_BYTES) throw new RangeError("from must be a 32-byte public key");
  if (!Number.isInteger(fields.ttl) || fields.ttl < 0 || fields.ttl > 0xff) throw new RangeError(`ttl ${fields.ttl} does not fit a byte`);
  if (!Number.isInteger(fields.hop) || fields.hop < 0 || fields.hop > 0xff) throw new RangeError(`hop ${fields.hop} does not fit a byte`);

  const digest = msgIdDigest(p, fields.msgId);
  const plaintext = padPlaintext(
    concat(
      fields.from,
      timestampBytes(fields.timestampMs),
      new Uint8Array([(fields.body.length >> 8) & 0xff, fields.body.length & 0xff]),
      fields.body
    ),
    fields.body.length
  );

  const nonce = encodeNonce(fields.nonce);
  // The header is the AEAD's associated data: authenticated but not encrypted, so
  // a relay can read ttl/hop and still cannot alter them without the tag failing.
  const headerBytes = encodeHeader({
    msgIdDigest: digest,
    ttl: fields.ttl,
    type: fields.type,
    destHint: fields.destHint,
    hop: fields.hop,
  });
  const sealed = p.seal(key, nonce, plaintext, headerBytes);

  return {
    bytes: concat(headerBytes, nonce, sealed),
    header: {
      msgIdDigest: digest,
      ttl: fields.ttl,
      type: fields.type,
      destHint: Uint8Array.from(fields.destHint),
      hop: fields.hop,
    },
    nonce,
  };
}

export function encodeHeader(header: PacketHeader): Uint8Array {
  if (header.msgIdDigest.length !== MSG_ID_DIGEST_BYTES || header.destHint.length !== 8)
    throw new RangeError("header requires an exact 16-byte digest and 8-byte destination hint");
  if (![header.ttl, header.hop].every(n => Number.isInteger(n) && n >= 0 && n <= 255))
    throw new RangeError("header ttl/hop must be integer bytes");
  if (!Number.isInteger(msgTypeCode(header.type))) throw new RangeError("unknown packet type");
  const out = new Uint8Array(HEADER_BYTES);
  out.set(header.msgIdDigest.subarray(0, MSG_ID_DIGEST_BYTES), 0);
  let offset = MSG_ID_DIGEST_BYTES;
  out[offset++] = header.ttl & 0xff;
  out[offset++] = msgTypeCode(header.type) & 0xff;
  out.set(header.destHint.subarray(0, 8), offset);
  offset += 8;
  out[offset] = header.hop & 0xff;
  return out;
}

export function decodeHeader(bytes: Uint8Array): PacketHeader | null {
  if (bytes.length < HEADER_BYTES) return null;
  const type = msgTypeFromCode(bytes[17]);
  if (type === null) return null;
  return {
    msgIdDigest: Uint8Array.from(bytes.subarray(0, MSG_ID_DIGEST_BYTES)),
    ttl: bytes[16],
    type,
    destHint: Uint8Array.from(bytes.subarray(18, 26)),
    hop: bytes[26],
  };
}

/**
 * Open a packet.
 *
 * Returns `reason: "auth-failed"` for a tag mismatch, which is the only thing a
 * relay-tampered or wrong-key packet can produce — and the reason
 * `docs/07` §6's "SUPER cannot decrypt" capture test is decidable at all: the
 * AEAD does not fail loudly, it fails *identically* whether the key is wrong or
 * the bytes were touched, so an observer learns nothing from the attempt.
 */
export function openPacket(p: CryptoPrimitives, key: Uint8Array, bytes: Uint8Array): OpenPacketResult {
  const minimum = HEADER_BYTES + NONCE_BYTES + TAG_BYTES + PLAINTEXT_FIXED_BYTES;
  if (bytes.length < minimum) return { ok: false, reason: "short" };
  const header = decodeHeader(bytes);
  if (!header) return { ok: false, reason: "bad-type" };

  const nonce = bytes.subarray(HEADER_BYTES, HEADER_BYTES + NONCE_BYTES);
  const sealed = bytes.subarray(HEADER_BYTES + NONCE_BYTES);
  const plaintext = p.open(key, nonce, sealed, bytes.subarray(0, HEADER_BYTES));
  if (plaintext === null) return { ok: false, reason: "auth-failed" };
  if (plaintext.length < PLAINTEXT_FIXED_BYTES) return { ok: false, reason: "bad-length" };

  const bodyLen = (plaintext[FROM_BYTES + TS_BYTES] << 8) | plaintext[FROM_BYTES + TS_BYTES + 1];
  const bodyStart = PLAINTEXT_FIXED_BYTES;
  if (bodyStart + bodyLen > plaintext.length) return { ok: false, reason: "bad-length" };
  // Everything after the body must be zero: the padding is part of what the tag
  // covers, so a non-zero tail means the sender and receiver disagree about the
  // layout — the one failure a length field cannot paper over.
  for (let i = bodyStart + bodyLen; i < plaintext.length; i++) {
    if (plaintext[i] !== 0) return { ok: false, reason: "bad-length" };
  }

  const result: OpenPacketResult = {
    ok: true,
    headerBytes: HEADER_BYTES,
    packet: {
      msgIdDigest: header.msgIdDigest,
      ttl: header.ttl,
      type: header.type,
      destHint: header.destHint,
      hop: header.hop,
      from: Uint8Array.from(plaintext.subarray(0, FROM_BYTES)),
      timestampMs: timestampFromBytes(plaintext.subarray(FROM_BYTES, FROM_BYTES + TS_BYTES)),
      body: Uint8Array.from(plaintext.subarray(bodyStart, bodyStart + bodyLen)),
    },
  };
  zeroize(plaintext);
  return result;
}

/**
 * What a relay is allowed to see.
 *
 * `docs/04` §5: *"SUPER nodes cannot read E2EE DMs — they see only header"*, and
 * §4 lists the header fields as `{msgId, ttl, hopCount, destHint (hashed), type,
 * priority}`. Note what is **not** in that list: the destination. `src/types.ts`'s
 * `MeshMessage` carries a cleartext `to`, because a routing simulator has to route;
 * the documented packet does not, and this function is the difference made
 * explicit so the capture test can assert it rather than assume it.
 */
export function relayVisible(bytes: Uint8Array): {
  msgIdDigest: string;
  ttl: number;
  type: MsgType;
  destHint: string;
  hop: number;
  /** Always `false`: nothing outside the header is readable without the key. */
  bodyReadable: boolean;
} | null {
  const header = decodeHeader(bytes);
  if (!header) return null;
  return {
    msgIdDigest: toHex(header.msgIdDigest),
    ttl: header.ttl,
    type: header.type,
    destHint: toHex(header.destHint),
    hop: header.hop,
    bodyReadable: false,
  };
}

/** True when this file's field widths still add up to the engine's constant, and
 *  to the two other numbers `docs/07` §4 and `docs/08` §5.3 depend on. */
export function packetLayoutIsConsistent(): {
  overhead: boolean;
  emptyBody: boolean;
  bleCeiling: boolean;
} {
  return {
    overhead: PACKET_OVERHEAD_FROM_FIELDS === PACKET_OVERHEAD_BYTES,
    // docs/07 §4's table: an empty body is still one padded block.
    emptyBody: wireSizeOfBodyBytes(0) === PAD_BLOCK_BYTES,
    // docs/08 §5.3: a 929-byte body is the largest that still fits one BLE
    // packet (95 + 929 = 1024 exactly); 930 costs a whole extra block and
    // crosses to Wi-Fi Direct. That boundary is what sets the 14.9 kbit/s PTT
    // ceiling, so it is asserted here rather than left in prose.
    bleCeiling:
      wireSizeOfBodyBytes(929) === BLE_MAX_BYTES && wireSizeOfBodyBytes(930) === 1280,
  };
}
