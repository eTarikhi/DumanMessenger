/**
 * The packet, sealed and opened for real.
 *
 * `tool/e2ee-probe.ts` checks `docs/07` §4's size table against three exported
 * constants, which is arithmetic agreeing with itself. These tests check it
 * against bytes that exist: serialise a message, measure it, and require the
 * measurement to equal the model the transport selector uses. That is the
 * difference between a documented packet and a buildable one.
 */
import { describe, expect, it } from "vitest";
import { equalBytes, nodePrimitives as p, toHex, zeroize } from "../primitives";
import {
  HEADER_BYTES,
  MAX_SEALED_BODY_BYTES,
  MSG_ID_DIGEST_BYTES,
  NONCE_BYTES,
  PACKET_OVERHEAD_FROM_FIELDS,
  PLAINTEXT_FIXED_BYTES,
  TAG_BYTES,
  decodeHeader,
  encodeHeader,
  isSealedType,
  msgIdDigest,
  msgTypeCode,
  msgTypeFromCode,
  openPacket,
  packetLayoutIsConsistent,
  padPlaintext,
  relayVisible,
  sealPacket,
  wireSizeOfBodyBytes,
  type SealRequest,
} from "../packet";
import { destHintBytes, destHintBytesOpaque, generateIdentity, timestampBytes, timestampFromBytes } from "../identity";
import { BLE_MAX_BYTES, PACKET_OVERHEAD_BYTES, PAD_BLOCK_BYTES, selectTransport, utf8ByteLength, wireSizeOf } from "../../routing";
import type { MsgType } from "../../types";

const TYPES: readonly MsgType[] = ["text", "broadcast", "voice", "file", "sos", "sync", "ack", "ogm"];

function seal(bodyText: string, over: Partial<SealRequest> = {}) {
  const alice = generateIdentity(p);
  const bob = generateIdentity(p);
  const key = p.randomBytes(32);
  const packet = sealPacket(p, key, {
    msgId: "m000001",
    ttl: 5,
    type: "text",
    destHint: destHintBytes(p, bob.signing.publicKey),
    hop: 2,
    from: alice.signing.publicKey,
    timestampMs: 1_760_000_000_000,
    body: new TextEncoder().encode(bodyText),
    nonce: 7,
    ...over,
  });
  return { alice, bob, key, packet };
}

describe("the layout is the one docs/07 §4 publishes", () => {
  it("adds up to the engine's PACKET_OVERHEAD_BYTES, from field widths rather than from the constant", () => {
    // 27 header + 12 nonce + 16 tag + 32 from + 6 ts + 2 len = 95. docs/07 §4
    // writes this as `from(32) + ts(8)`; the 8 is really 6 + 2, because a length
    // field is what makes zero padding strippable for a binary body.
    expect(HEADER_BYTES).toBe(27);
    expect(MSG_ID_DIGEST_BYTES).toBe(16);
    expect(NONCE_BYTES).toBe(12);
    expect(TAG_BYTES).toBe(16);
    expect(PLAINTEXT_FIXED_BYTES).toBe(40);
    expect(PACKET_OVERHEAD_FROM_FIELDS).toBe(PACKET_OVERHEAD_BYTES);
    const consistent = packetLayoutIsConsistent();
    expect(consistent).toEqual({ overhead: true, emptyBody: true, bleCeiling: true });
  });

  it("reproduces §4's table exactly, at every body size the table names", () => {
    const table: ReadonlyArray<[number, number, string]> = [
      [0, 256, "ble"],
      [241, 512, "ble"],
      [700, 1024, "ble"],
      [900, 1024, "ble"],
      [929, 1024, "ble"],
      [930, 1280, "wifiDirect"],
    ];
    for (const [bodyBytes, expected, transport] of table) {
      const size = wireSizeOfBodyBytes(bodyBytes);
      expect(size, `body ${bodyBytes}`).toBe(expected);
      expect(size).toBe(wireSizeOf(bodyBytes));
      expect(selectTransport(size), `body ${bodyBytes}`).toBe(transport);
      // And the serialiser agrees with the model, which is the part the constants
      // alone cannot prove.
      const { packet } = seal("x".repeat(bodyBytes));
      expect(packet.bytes.length, `sealed body ${bodyBytes}`).toBe(expected);
    }
  });

  it("keeps the docs/08 §5.3 boundary: 929 bytes is the largest payload on BLE", () => {
    expect(wireSizeOfBodyBytes(929)).toBe(BLE_MAX_BYTES);
    expect(wireSizeOfBodyBytes(930)).toBe(BLE_MAX_BYTES + 256);
    // A 929-byte body pads to exactly one BLE frame with zero pad bytes, which is
    // why a mandatory 0x80 pad marker would have cost a whole extra block here and
    // invalidated the PTT ceiling docs/08 derives from it.
    expect(padPlaintext(new Uint8Array(PLAINTEXT_FIXED_BYTES + 929), 929)).toHaveLength(
      PLAINTEXT_FIXED_BYTES + 929
    );
    expect(padPlaintext(new Uint8Array(PLAINTEXT_FIXED_BYTES), 0)).toHaveLength(
      PLAINTEXT_FIXED_BYTES + 161
    );
  });

  it("pads with zeros, and only with zeros", () => {
    for (const bodyBytes of [0, 1, 100, 160, 161, 162, 300, 929, 930]) {
      const plaintext = new Uint8Array(PLAINTEXT_FIXED_BYTES + bodyBytes);
      plaintext.fill(0xab);
      const padded = padPlaintext(plaintext, bodyBytes);
      // The whole packet, not just the plaintext, is what lands on a block
      // boundary — that reading of skills/03's "pad to 256B blocks" is the one that
      // reproduces docs/07 §4's table.
      expect((HEADER_BYTES + NONCE_BYTES + TAG_BYTES + padded.length) % PAD_BLOCK_BYTES).toBe(0);
      for (let i = plaintext.length; i < padded.length; i++) {
        expect(padded[i], `pad byte ${i} for body ${bodyBytes}`).toBe(0);
      }
      expect(padded.subarray(0, plaintext.length)).toEqual(plaintext);
    }
  });

  it("sizes a message by its UTF-8 bytes, agreeing with src/routing.ts", () => {
    for (const text of ["", "hey Kemal", "Duman ışık çığ", "けむり", "🆘👥📦", "Думан धुआँ ควัน"]) {
      const { packet } = seal(text);
      expect(packet.bytes.length, text).toBe(wireSizeOf(utf8ByteLength(text)));
      expect(packet.bytes.length).toBe(wireSizeOfBodyBytes(utf8ByteLength(text)));
    }
  });

  it("refuses a body the 2-byte length field cannot describe", () => {
    expect(MAX_SEALED_BODY_BYTES).toBe(65535);
    expect(() => seal("x", { body: new Uint8Array(MAX_SEALED_BODY_BYTES + 1) })).toThrow(RangeError);
    // A media chunk is not affected: the engine passes an empty body and declares
    // the payload size separately (docs/08 §8), so this limit never binds there.
    expect(() => seal("", { body: new Uint8Array(MAX_SEALED_BODY_BYTES) })).not.toThrow();
  });
});

describe("the header is plaintext, authenticated and readable by a relay", () => {
  it("round-trips every field, and nothing else", () => {
    const { packet, alice, bob } = seal("meet at the atrium");
    const header = decodeHeader(packet.bytes);
    expect(header).not.toBeNull();
    expect(header!.ttl).toBe(5);
    expect(header!.type).toBe("text");
    expect(header!.hop).toBe(2);
    expect(header!.destHint).toHaveLength(8);
    expect(header!.msgIdDigest).toHaveLength(MSG_ID_DIGEST_BYTES);
    expect(equalBytes(header!.destHint, destHintBytes(p, bob.signing.publicKey))).toBe(true);
    // The header encodes back to the same bytes, so what a relay reads is what the
    // AEAD authenticated.
    expect(encodeHeader(header!)).toEqual(packet.bytes.subarray(0, HEADER_BYTES));
    void alice;
  });

  it("carries a digest of the message id, not the id — so the counter stays off air", () => {
    const digest = msgIdDigest(p, "m000001");
    expect(digest).toHaveLength(16);
    expect(msgIdDigest(p, "m000001")).toEqual(digest);
    expect(msgIdDigest(p, "m000002")).not.toEqual(digest);
    const { packet } = seal("hello");
    const latin1 = Buffer.from(packet.bytes).toString("latin1");
    // The engine's ids are short and sequential; leaking one leaks the send rate.
    expect(latin1).not.toContain("m000001");
    expect(latin1).not.toContain("m0000");
  });

  it("gives every MsgType a distinct one-byte code, and rejects an unknown one", () => {
    const codes = TYPES.map((type) => msgTypeCode(type));
    expect(new Set(codes).size).toBe(TYPES.length);
    for (const type of TYPES) expect(msgTypeFromCode(msgTypeCode(type))).toBe(type);
    expect(msgTypeFromCode(8)).toBeNull();
    expect(msgTypeFromCode(255)).toBeNull();
    // A zeroed header is well-formed and says "text": code 0 is a real type, so an
    // all-zero packet is not rejected on its type byte. It is rejected by its tag.
    expect(decodeHeader(new Uint8Array(HEADER_BYTES))!.type).toBe("text");
    const bad = new Uint8Array(HEADER_BYTES);
    bad[17] = 99;
    expect(decodeHeader(bad)).toBeNull();
    expect(decodeHeader(new Uint8Array(HEADER_BYTES - 1))).toBeNull();
  });

  it("seals everything except the three types a relay has to read", () => {
    // docs/04 §3: the broadcast/pager channel is not private by design. `ogm` and
    // `ack` are control plane: a relay that cannot read them cannot route.
    expect(isSealedType("broadcast")).toBe(false);
    expect(isSealedType("ogm")).toBe(false);
    expect(isSealedType("ack")).toBe(false);
    for (const type of ["text", "voice", "file", "sos", "sync"] as MsgType[]) {
      expect(isSealedType(type), type).toBe(true);
    }
  });

  it("rejects a ttl or hop that does not fit a byte, instead of truncating it silently", () => {
    expect(() => seal("x", { ttl: 256 })).toThrow(RangeError);
    expect(() => seal("x", { ttl: -1 })).toThrow(RangeError);
    expect(() => seal("x", { hop: 256 })).toThrow(RangeError);
    expect(() => seal("x", { from: new Uint8Array(31) })).toThrow(RangeError);
  });
});

describe("opening a packet", () => {
  it("returns the body, the sender, the timestamp and every header field", () => {
    const { packet, key, alice, bob } = seal("meet at the atrium at 14:00");
    const opened = openPacket(p, key, packet.bytes);
    expect(opened.ok).toBe(true);
    if (!opened.ok) return;
    expect(new TextDecoder().decode(opened.packet.body)).toBe("meet at the atrium at 14:00");
    expect(opened.packet.type).toBe("text");
    expect(opened.packet.ttl).toBe(5);
    expect(opened.packet.hop).toBe(2);
    expect(opened.packet.timestampMs).toBe(1_760_000_000_000);
    expect(equalBytes(opened.packet.from, alice.signing.publicKey)).toBe(true);
    expect(equalBytes(opened.packet.destHint, destHintBytes(p, bob.signing.publicKey))).toBe(true);
    expect(opened.headerBytes).toBe(HEADER_BYTES);
  });

  it("round-trips a body that ends in zero bytes, which is why the length field exists", () => {
    // Zero padding is ambiguous for binary payloads: a media chunk can legitimately
    // end in 0x00, and without `len` the reader cannot tell body from padding.
    const { key } = seal("");
    const bob = generateIdentity(p);
    const alice = generateIdentity(p);
    const body = new Uint8Array([1, 2, 3, 0, 0, 0]);
    const packet = sealPacket(p, key, {
      msgId: "chunk-0",
      ttl: 3,
      type: "file",
      destHint: destHintBytes(p, bob.signing.publicKey),
      hop: 1,
      from: alice.signing.publicKey,
      timestampMs: 5,
      body,
      nonce: 0,
    });
    const opened = openPacket(p, key, packet.bytes);
    expect(opened.ok).toBe(true);
    if (!opened.ok) return;
    expect(opened.packet.body).toEqual(body);
    expect(opened.packet.body).toHaveLength(6);
  });

  it("round-trips an empty body, which is what a media chunk carries", () => {
    const { packet, key } = seal("");
    expect(packet.bytes).toHaveLength(PAD_BLOCK_BYTES);
    const opened = openPacket(p, key, packet.bytes);
    expect(opened.ok).toBe(true);
    if (opened.ok) expect(opened.packet.body).toHaveLength(0);
  });

  it("fails closed on a wrong key, a touched byte and a short packet", () => {
    const { packet, key } = seal("secret");
    expect(openPacket(p, p.randomBytes(32), packet.bytes).ok).toBe(false);

    const touched = Uint8Array.from(packet.bytes);
    touched[HEADER_BYTES + NONCE_BYTES + 3] ^= 0x01;
    const result = openPacket(p, key, touched);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toBe("auth-failed");

    // Touching the *header* must fail too: it is the AEAD's associated data, so a
    // relay can read ttl and hop but cannot lower a ttl or advance a hop count.
    const rettl = Uint8Array.from(packet.bytes);
    rettl[16] = 9;
    const headerTamper = openPacket(p, key, rettl);
    expect(headerTamper.ok).toBe(false);
    if (!headerTamper.ok) expect(headerTamper.reason).toBe("auth-failed");

    expect(openPacket(p, key, packet.bytes.subarray(0, HEADER_BYTES)).ok).toBe(false);
    const short = openPacket(p, key, new Uint8Array(94));
    expect(short.ok).toBe(false);
    if (!short.ok) expect(short.reason).toBe("short");
    zeroize(key);
  });

  it("survives a 48-bit timestamp, including one past the 32-bit range", () => {
    expect(timestampFromBytes(timestampBytes(0))).toBe(0);
    expect(timestampFromBytes(timestampBytes(1_760_000_000_000))).toBe(1_760_000_000_000);
    // 2^32 ms is 1970 + 49 days; 2^48 ms is the year 10889. Six bytes is enough
    // and eight was costing the length field its room.
    expect(timestampFromBytes(timestampBytes(2 ** 32))).toBe(2 ** 32);
    expect(timestampFromBytes(timestampBytes(2 ** 48 - 1))).toBe(2 ** 48 - 1);
    expect(() => timestampBytes(-1)).toThrow(RangeError);
    expect(() => timestampBytes(2 ** 48)).toThrow(RangeError);
  });
});

describe("what a relay is allowed to see — docs/04 §5 and skills/03 acceptance line 3", () => {
  it("sees the header and nothing else, and the packet says so structurally", () => {
    const bodyText = "the atrium, 14:00, bring the battery pack";
    const { packet, alice, bob } = seal(bodyText);
    const visible = relayVisible(packet.bytes);
    expect(visible).not.toBeNull();
    expect(visible!.bodyReadable).toBe(false);
    expect(visible!.ttl).toBe(5);
    expect(visible!.hop).toBe(2);
    expect(visible!.type).toBe("text");
    expect(visible!.destHint).toHaveLength(16); // 8 bytes as hex
    expect(visible!.msgIdDigest).toHaveLength(32); // 16 bytes as hex

    const latin1 = Buffer.from(packet.bytes).toString("latin1");
    // The body, the sender's public key and the sender's nodeId are all inside the
    // ciphertext. This is the assertion docs/04 §5 makes in prose.
    expect(latin1).not.toContain("atrium");
    expect(latin1).not.toContain(bodyText);
    expect(visible!.destHint).not.toBe(toHex(alice.nodeIdBytes));
    expect(latin1).not.toContain(Buffer.from(alice.signing.publicKey).toString("latin1"));
    expect(latin1).not.toContain(Buffer.from(bob.signing.publicKey).toString("latin1"));
  });

  it("gives the same destHint to every relay, deterministically, from the destination key alone", () => {
    const bob = generateIdentity(p);
    const first = destHintBytes(p, bob.signing.publicKey);
    expect(first).toHaveLength(8);
    expect(destHintBytes(p, bob.signing.publicKey)).toEqual(first);
    expect(destHintBytes(p, generateIdentity(p).signing.publicKey)).not.toEqual(first);
    // The hint is a prefix of the nodeId (docs/05: nodeId = SHA-256(pubKey)), which
    // is the finding worth recording: it is a shorter routing label, not identity
    // hiding, because docs/02 §2 broadcasts the nodeId itself every 2 seconds.
    expect(toHex(bob.nodeIdBytes).startsWith(toHex(first))).toBe(true);
    // The domain-separated variant is not a prefix of anything, for a deployment
    // that would rather pay a lookup than publish the relationship.
    const opaque = destHintBytesOpaque(p, bob.signing.publicKey);
    expect(opaque).toHaveLength(8);
    expect(toHex(bob.nodeIdBytes).startsWith(toHex(opaque))).toBe(false);
    expect(destHintBytesOpaque(p, bob.signing.publicKey)).toEqual(opaque);
  });

  it("leaves the destination out of the header entirely, which src/types.ts does not", () => {
    // docs/04 §4 lists the header as {msgId, ttl, hopCount, destHint, type,
    // priority}: no `to`. The engine's MeshMessage carries a cleartext `to` because
    // a routing simulator has to route. relayVisible is the documented header, and
    // this asserts it has no destination field to leak.
    const { packet } = seal("hello");
    const visible = relayVisible(packet.bytes) as Record<string, unknown>;
    expect(Object.keys(visible).sort()).toEqual([
      "bodyReadable",
      "destHint",
      "hop",
      "msgIdDigest",
      "ttl",
      "type",
    ]);
    expect("to" in visible).toBe(false);
    expect("from" in visible).toBe(false);
  });
});
