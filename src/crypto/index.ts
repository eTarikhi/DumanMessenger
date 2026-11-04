/**
 * `src/crypto` — the protocol layer of `skills/03`, `docs/04` §2-§4 and
 * `docs/07`, implemented over OpenSSL primitives.
 *
 * **Read the caveat in [primitives.ts] before using any of this in a product.**
 * It is a reference implementation: correct protocol logic, no constant-time
 * guarantees, key material in garbage-collected buffers. `skills/03` is explicit
 * that the shipped build uses libsodium via FFI (and Dart's `cryptography`), and
 * nothing here argues with that. What here does is make the protocol layer
 * *runnable*, so that `skills/03`'s three acceptance criteria, `docs/07` §6's
 * mapping and §7's four open questions have code and measurements behind them
 * instead of prose.
 *
 * Layering, bottom up:
 *
 *   primitives.ts  OpenSSL behind one interface — nothing custom, per skills/03
 *   noise-xx.ts    the Noise_XX state machine, leg sizes, simultaneous-open rule
 *   ratchet.ts     per-message keys, forward secrecy, bounded out-of-order cache
 *   sas.ts         the two SAS values: the QR fingerprint and the handshake SAS
 *   identity.ts    keygen, nodeId, destHint, QR encode/decode, panic wipe
 *   packet.ts      the skills/03 packet, serialised and opened for real
 *   session.ts     legs, SAS confirmation, sealed messages, 7-day cache, wipe
 *
 * Nothing in `src/App.tsx` or `src/components/` imports this directory, and
 * nothing here should be imported by them: it pulls in `node:crypto`, which has
 * no browser build. The visualiser models the mesh; this models the crypto that
 * runs on each node of it.
 */
export {
  AEAD_TAG_LEN,
  DHLEN,
  HASHLEN,
  NONCE_LEN,
  assertPkcs8Prefixes,
  compareBytes,
  concat,
  equalBytes,
  fromHex,
  nodePrimitives,
  toHex,
  zeroize,
  type CryptoPrimitives,
  type Ed25519KeyPair,
  type X25519KeyPair,
} from "./primitives";

export {
  LEG_SIZES,
  NoiseError,
  PROTOCOL_NAME,
  HandshakeState,
  encodeNonce,
  handshakeInProcess,
  noiseHkdf,
  resolveSimultaneousOpen,
  type HandshakeKeys,
  type HandshakeResult,
  type NoiseCipherState,
  type NoiseFailure,
} from "./noise-xx";

export {
  MAX_SKIP,
  SymmetricRatchet,
  decodeNonce,
  deriveRatchetSeed,
  ratchetPair,
  type CompromisedState,
  type OpenFailure,
  type OpenResult,
  type SealedMessage,
} from "./ratchet";

export {
  SAS_ALPHABET,
  SAS_CHAR_COUNT,
  SAS_EMOJI,
  SAS_EMOJI_COUNT,
  handshakeSas,
  identitySas,
  isWellFormedSas,
  sasMatches,
  type HandshakeSas,
} from "./sas";

export {
  ADD_CONTACT_HOST,
  ADD_CONTACT_SCHEME,
  DEST_HINT_BYTES,
  NODE_ID_BYTES,
  QR_PAYLOAD_BYTES,
  addContactLink,
  decodeQr,
  destHintBytes,
  destHintBytesOpaque,
  encodeQr,
  generateIdentity,
  isWiped,
  panicWipeIdentity,
  parseAddContactLink,
  signHandleClaim,
  timestampBytes,
  timestampFromBytes,
  verifyHandleClaim,
  type Identity,
  type QrPayload,
  type WipeResult,
} from "./identity";

export {
  FROM_BYTES,
  HEADER_BYTES,
  LEN_BYTES,
  MAX_SEALED_BODY_BYTES,
  MSG_ID_DIGEST_BYTES,
  NONCE_BYTES,
  PACKET_OVERHEAD_FROM_FIELDS,
  PLAINTEXT_FIXED_BYTES,
  TAG_BYTES,
  TS_BYTES,
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
  type OpenFailure as PacketOpenFailure,
  type OpenPacketResult,
  type PacketFields,
  type PacketHeader,
  type SealRequest,
  type SealedPacket,
} from "./packet";

export {
  SESSION_PROLOGUE_CONTEXT,
  SESSION_TTL_MS,
  DumanSession,
  SessionCache,
  sessionPrologue,
  sessionPrologueFromQr,
  whoInitiates,
  type IncomingMessage,
  type OutgoingMessage,
  type ReceiveFailure,
  type SessionPhase,
} from "./session";
