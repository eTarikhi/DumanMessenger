/**
 * A packet carries bytes; `String.length` counts UTF-16 code units.
 *
 * `wireSizeOf` was being called with `body.length` everywhere, which is correct
 * for ASCII and optimistic for everything else — and optimistic is the direction
 * `docs/07` §4 already identified as the dangerous one, because the number chooses
 * the transport and the transport sets the per-hop latency the whole findings
 * document reports.
 */
import { describe, expect, it } from "vitest";
import {
  BLE_MAX_BYTES,
  PAD_BLOCK_BYTES,
  createMessage,
  selectTransport,
  utf8ByteLength,
  wireSizeOf,
  wireSizeOfBody,
} from "../routing";

const CASES: ReadonlyArray<[string, string]> = [
  ["empty", ""],
  ["ascii", "hey Kemal"],
  ["latin-1 supplement (Turkish)", "Duman: ışık çığ Şişli Güneş"],
  ["latin extended (Romanian names in NAMES)", "Marcu Țepeș"],
  ["greek", "Δουμάνι"],
  ["cyrillic", "Думан"],
  ["arabic", "دخان"],
  ["hebrew", "עשן"],
  ["devanagari", "धुआँ"],
  ["thai", "ควัน"],
  ["georgian", "კვამლი"],
  ["cjk", "煙"],
  ["hangul", "연기"],
  ["hiragana (the locale this repo is read in)", "けむり"],
  ["emoji, astral plane", "🆘👥📦"],
  ["mixed", "hey 👥 ควัน Думан"],
  ["a lone high surrogate, which is not a character", "\ud83d"],
  ["a lone low surrogate", "\ude00"],
  ["a valid surrogate pair", "\ud83d\ude00"],
];

describe("utf8ByteLength", () => {
  it("agrees with TextEncoder on every script the app is likely to meet first", () => {
    const encoder = new TextEncoder();
    for (const [label, text] of CASES) {
      // TextEncoder replaces an unpaired surrogate with U+FFFD, three bytes.
      // utf8ByteLength implements that rule explicitly rather than inheriting it,
      // because the Dart port has to match and two standard libraries agreeing by
      // accident is not a contract.
      expect(utf8ByteLength(text), label).toBe(encoder.encode(text).length);
    }
  });

  it("agrees with TextEncoder on long random text, including astral characters", () => {
    const encoder = new TextEncoder();
    const pool = "aZ0 ışık Δ Д ד ध ควัน 煙 연기 けむり 🆘👥📦😀\ud83d";
    for (let trial = 0; trial < 200; trial++) {
      let text = "";
      const length = 1 + (trial % 97);
      for (let i = 0; i < length; i++) {
        text += pool[(trial * 31 + i * 17) % pool.length];
      }
      expect(utf8ByteLength(text), JSON.stringify(text)).toBe(encoder.encode(text).length);
    }
  });

  it("is String.length for ASCII, which is why nothing already measured changes", () => {
    for (const [, text] of CASES) {
      if (/^[\x00-\x7f]*$/.test(text)) expect(utf8ByteLength(text)).toBe(text.length);
    }
    expect(utf8ByteLength("x".repeat(930))).toBe(930);
  });

  it("counts 2, 3 and 4 bytes where UTF-8 says so", () => {
    expect(utf8ByteLength("é")).toBe(2); // U+00E9
    expect(utf8ByteLength("ș")).toBe(2); // U+0219, in NAMES-adjacent Romanian
    expect(utf8ByteLength("Δ")).toBe(2);
    expect(utf8ByteLength("Д")).toBe(2);
    expect(utf8ByteLength("ध")).toBe(3);
    expect(utf8ByteLength("ควัน"[0])).toBe(3);
    expect(utf8ByteLength("煙")).toBe(3);
    expect(utf8ByteLength("😀")).toBe(4); // one character, two code units
    expect("😀".length).toBe(2);
  });
});

describe("wireSizeOfBody", () => {
  it("leaves every ASCII result exactly where wireSizeOf put it", () => {
    for (const chars of [0, 1, 160, 161, 162, 241, 700, 900, 929, 930, 1200]) {
      const body = "x".repeat(chars);
      expect(wireSizeOfBody(body)).toBe(wireSizeOf(chars));
    }
    // The two numbers the golden vectors and docs/07 §4's table are built on.
    expect(wireSizeOfBody("")).toBe(PAD_BLOCK_BYTES);
    expect(wireSizeOfBody("x".repeat(929))).toBe(BLE_MAX_BYTES);
    expect(wireSizeOfBody("x".repeat(930))).toBe(1280);
  });

  it("moves a non-ASCII body to the transport that can actually carry it", () => {
    // 300 emoji: 600 code units, 1200 UTF-8 bytes. By code units the packet is
    // 95 + 600 = 695 -> 768 B and rides BLE; by bytes it is 95 + 1200 = 1295 ->
    // 1536 B and needs Wi-Fi Direct. The old code reported the BLE latency for a
    // payload that does not fit in a BLE frame.
    const emoji = "😀".repeat(300);
    expect(emoji.length).toBe(600);
    expect(utf8ByteLength(emoji)).toBe(1200);
    expect(wireSizeOf(emoji.length)).toBe(768);
    expect(selectTransport(wireSizeOf(emoji.length))).toBe("ble");
    expect(wireSizeOfBody(emoji)).toBe(1536);
    expect(selectTransport(wireSizeOfBody(emoji))).toBe("wifiDirect");
  });

  it("moves a Turkish body across the boundary too, at a size ASCII would not", () => {
    // "ışık " is 5 code units and 8 bytes. Forty of them is a 200-character
    // Turkish body that is 320 bytes on air — enough to cross the 929-byte BLE
    // boundary once the filler is added by *bytes* rather than by characters.
    const turkish = "ışık ".repeat(40); // 200 code units, 320 bytes
    expect(turkish.length).toBe(200);
    expect(utf8ByteLength(turkish)).toBe(320);
    const filler = 930 - 320; // bytes, to land exactly on the boundary
    const body = turkish + "x".repeat(filler);
    expect(utf8ByteLength(body)).toBe(930);
    expect(body.length).toBe(200 + filler);
    // By code units this is 810 characters -> 905 raw -> 1024 B -> BLE. By bytes
    // it is 930 -> 1280 B -> Wi-Fi Direct. Same message, two transports, and only
    // one of them is a packet a radio can send.
    expect(body.length).toBe(810);
    expect(wireSizeOf(body.length)).toBe(1024);
    expect(selectTransport(wireSizeOf(body.length))).toBe("ble");
    expect(selectTransport(wireSizeOfBody(body))).toBe("wifiDirect");
  });
});

describe("createMessage sizes from bytes", () => {
  it("selects the transport from the UTF-8 length of the body", () => {
    const ascii = createMessage("m1", 0, "a", "b", "x".repeat(930));
    expect(ascii.sizeBytes).toBe(1280);
    expect(ascii.transport).toBe("wifiDirect");

    const emoji = createMessage("m2", 0, "a", "b", "😀".repeat(300));
    expect(emoji.sizeBytes).toBe(1536);
    expect(emoji.transport).toBe("wifiDirect");

    const short = createMessage("m3", 0, "a", "b", "merhaba ışık");
    // "merhaba ışık" is 12 code units and 15 bytes; both fit the first block.
    expect(short.sizeBytes).toBe(256);
    expect(short.transport).toBe("ble");
  });

  it("still produces identical sizes for the ASCII bodies every fixture uses", () => {
    // test-fixtures/golden-vectors.json contains no non-ASCII character at all, so
    // this change is byte-identical for every golden vector. That is the reason it
    // could be made at all: a change that moved the goldens would have needed the
    // Dart port to land in the same commit.
    expect(createMessage("m4", 0, "a", "b", "hey Kemal").sizeBytes).toBe(256);
    expect(createMessage("m5", 0, "a", "b", "ping all").sizeBytes).toBe(256);
    expect(createMessage("m6", 0, "a", "b", "").sizeBytes).toBe(256);
  });
});
