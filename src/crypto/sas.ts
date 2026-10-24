/**
 * Short Authentication Strings: the human channel this network has to fall back
 * on, because there is no CA to phone home to (`docs/04` §2: *"Why not TLS/PKI:
 * no internet to reach CA"*).
 *
 * There are **two** SAS values in this design and the documents blur them, so
 * both are implemented and named separately:
 *
 * 1. [identitySas] — the `sas8` that rides in the QR code (`docs/04` §2: *"QR
 *    contains `pubKey + shortAuthString (8 chars)`"*, `skills/03`: *"QR =
 *    `base64(pubKey || sas8)`"*). It is a function of the long-term key alone, so
 *    it can be computed **before any handshake** and is what a scanned QR is
 *    checked against. It answers "did the QR get swapped", not "is this session
 *    mine".
 * 2. [handshakeSas] — derived from the Noise transcript hash after XX completes.
 *    Both sides compute the same 8 characters and the same 3×3 emoji
 *    (`skills/03`: *"display SAS 3×3 emoji or 8-char string for verbal verify"*),
 *    and agreement is the only evidence either device has that no relay sat in
 *    the middle. This is the one that authenticates a session.
 *
 * Neither is a substitute for the other, and a UI that shows only the first would
 * let a man-in-the-middle through: the QR proves which key was scanned, the
 * handshake SAS proves which key is on the other end of *this* session.
 *
 * **Strength.** 8 characters from a 32-symbol alphabet is 40 bits. That is far
 * below the 256 bits of the keys it vouches for, and it is enough: the limit is
 * the human channel, not the derivation. A user who compares nine emoji will not
 * compare forty. What the bound does mean is that a SAS must never be the only
 * authentication on a high-value action, and that an attacker who can make a
 * victim accept a *chosen* SAS gets 2^-40 per attempt — which is why the session
 * starts unauthenticated and is upgraded by [DumanSession.confirmSas], not
 * created by it.
 */
import { compareBytes, concat, type CryptoPrimitives } from "./primitives";

/** Crockford's 32: no `I`, `L`, `O` or `U`, so a read-aloud character cannot be
 *  mistaken for a digit or for another letter. */
export const SAS_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
export const SAS_CHAR_COUNT = 8;
/** `skills/03`: "3×3 emoji". */
export const SAS_EMOJI_COUNT = 9;

/**
 * The emoji half of the SAS.
 *
 * Chosen so no two are the same *shape* at the size a phone renders them: a user
 * scanning a 3×3 grid is matching silhouettes, not reading names, and 🍑/🍒 or
 * 🐬/🐳 would be a comparison the human loses. 32 entries so one byte of MAC maps
 * to one emoji with the same 5-bit masking as the characters.
 */
export const SAS_EMOJI: readonly string[] = [
  "🍎", "🚗", "🌵", "🎩", "🐘", "🌙", "🔥", "🍇",
  "🐬", "🌻", "🍄", "⚽", "🎸", "🐝", "🌈", "🍋",
  "🐢", "🎈", "🌊", "🍒", "🐧", "⛄", "🎺", "🌴",
  "🍑", "🐳", "🎲", "🦉", "🍀", "🐈", "🎻", "🌰",
];

const IDENTITY_CONTEXT = "DumanSAS-identity-v1";
const HANDSHAKE_CONTEXT = "DumanSAS-handshake-v1";
const EMOJI_CONTEXT = "DumanSAS-emoji-v1";

export interface HandshakeSas {
  /** 8 characters from [SAS_ALPHABET]. */
  chars: string;
  /** 9 emoji from [SAS_EMOJI], row-major. */
  emoji: readonly string[];
  /** The derivation output, for tests that need to check the binding. */
  mac: Uint8Array;
}

function toSymbols(p: CryptoPrimitives, key: Uint8Array, context: string, count: number): Uint8Array {
  const mac = p.hmac(key, new TextEncoder().encode(context));
  const out = new Uint8Array(count);
  for (let i = 0; i < count; i++) out[i] = mac[i] & 0x1f;
  return out;
}

/**
 * The QR's `sas8`: a fingerprint of one long-term public key.
 *
 * Keyed with HMAC rather than a bare hash so that the 8 characters cannot be
 * produced by anyone who has not chosen the context string — which does not make
 * them secret (the public key is public) but does stop a precomputation table of
 * `pubKey -> plausible sas8` being built to forge a QR that looks right.
 */
export function identitySas(p: CryptoPrimitives, publicKey: Uint8Array): string {
  const key = p.hash(concat(new TextEncoder().encode(IDENTITY_CONTEXT), publicKey));
  const symbols = toSymbols(p, key, IDENTITY_CONTEXT, SAS_CHAR_COUNT);
  let out = "";
  for (const symbol of symbols) out += SAS_ALPHABET[symbol];
  return out;
}

/**
 * The session SAS: the transcript hash bound to both static keys.
 *
 * The two keys are ordered lexicographically before being fed in, because each
 * side knows them in a different order (mine, theirs) and an unordered feed would
 * give the two devices different strings — which would look like a
 * man-in-the-middle and train users to ignore a real one.
 */
export function handshakeSas(
  p: CryptoPrimitives,
  handshakeHash: Uint8Array,
  staticA: Uint8Array,
  staticB: Uint8Array
): HandshakeSas {
  const order = compareBytes(staticA, staticB);
  const [first, second] = order <= 0 ? [staticA, staticB] : [staticB, staticA];
  const bound = p.hash(concat(handshakeHash, first, second));
  const charSymbols = toSymbols(p, bound, HANDSHAKE_CONTEXT, SAS_CHAR_COUNT);
  const emojiSymbols = toSymbols(p, bound, EMOJI_CONTEXT, SAS_EMOJI_COUNT);
  let chars = "";
  for (const symbol of charSymbols) chars += SAS_ALPHABET[symbol];
  const emoji = [...emojiSymbols].map((symbol) => SAS_EMOJI[symbol]);
  return { chars, emoji, mac: bound };
}

/**
 * Compare two SAS strings.
 *
 * Written as an explicit comparison rather than `===` so the intent is visible
 * at the call site: a mismatch is a security event, not a typo. It is *not*
 * constant-time in any meaningful sense — the comparison is between two strings
 * a human is about to read aloud — and pretending otherwise would be worse than
 * saying so.
 */
export function sasMatches(mine: string, theirs: string): boolean {
  if (mine.length !== theirs.length) return false;
  let diff = 0;
  for (let i = 0; i < mine.length; i++) diff |= mine.charCodeAt(i) ^ theirs.charCodeAt(i);
  return diff === 0;
}

/** True when every character is one a user could read aloud unambiguously. */
export function isWellFormedSas(text: string): boolean {
  return text.length === SAS_CHAR_COUNT && [...text].every((c) => SAS_ALPHABET.includes(c));
}
