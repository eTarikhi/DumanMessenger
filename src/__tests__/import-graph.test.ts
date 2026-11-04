/**
 * The browser bundle's import graph must never reach `src/crypto`.
 *
 * `src/crypto/primitives.ts` is built on `node:crypto` — X25519, ChaCha20-Poly1305, SHA-256 —
 * which is what `skills/03`'s *"never custom crypto"* asks for: vetted primitives rather than
 * hand-rolled ones. It is also a Node builtin with no browser equivalent, so anything that
 * pulls it into `App.tsx`'s graph puts it in the Vite bundle, where it either fails to build or
 * resolves to a stub that throws at runtime. Both outcomes are worse than the boundary being
 * checked.
 *
 * The boundary has been a standing constraint on every change to the visualiser, and until this
 * file existed it was enforced by a person remembering to run a script — which is not
 * enforcement. `README.md` claims a test fails if the boundary moves; this is that test.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { describe, expect, it } from "vitest";

const SRC = resolve(process.cwd(), "src");

/** Resolve one extensionless relative specifier the way the bundler would. */
function resolveSpecifier(fromFile: string, spec: string): string | null {
  const base = resolve(dirname(fromFile), spec);
  for (const candidate of [
    `${base}.ts`,
    `${base}.tsx`,
    resolve(base, "index.ts"),
    resolve(base, "index.tsx"),
  ]) {
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

/** Every file reachable from `entry` by relative imports, transitively. */
function importGraph(entry: string): Set<string> {
  const seen = new Set<string>();
  const stack = [entry];
  while (stack.length > 0) {
    const file = stack.pop()!;
    if (seen.has(file) || !existsSync(file)) continue;
    seen.add(file);
    const text = readFileSync(file, "utf8");
    // `from "..."`, `import "..."` and `export ... from "..."` — the three shapes that pull a
    // module into the graph. Bare specifiers (react, node:fs) are not followed: they resolve
    // outside src/ and the boundary is about src/crypto.
    for (const match of text.matchAll(/(?:from|import)\s+["'](\.[^"']+)["']/g)) {
      const next = resolveSpecifier(file, match[1]);
      if (next) stack.push(next);
    }
  }
  return seen;
}

const CRYPTO_DIR = resolve(SRC, "crypto");

describe("the browser bundle's import graph", () => {
  it("never reaches src/crypto, which needs node:crypto", () => {
    const reached = [...importGraph(resolve(SRC, "App.tsx"))];
    const crypto = reached.filter((f) => f.startsWith(CRYPTO_DIR));
    // Named in the failure rather than counted, so a violation says which file crossed.
    expect(crypto.map((f) => f.slice(SRC.length + 1))).toEqual([]);
  });

  it("does reach the components it renders, so the walk above is not vacuous", () => {
    // A graph walk that finds nothing also finds no crypto, and passes. This is the case that
    // distinguishes "the boundary holds" from "the walker is broken" — the same reason every
    // checker in tool/ci has a self-test.
    const reached = [...importGraph(resolve(SRC, "App.tsx"))];
    expect(reached.length).toBeGreaterThan(10);
    for (const component of [
      "components/MeshCanvas.tsx",
      "components/StatsBar.tsx",
      "components/NodeInspector.tsx",
      "components/ConfigPanel.tsx",
    ]) {
      expect(reached, component).toContain(resolve(SRC, component));
    }
    // And the engine itself, which is the graph the visualiser actually runs.
    expect(reached).toContain(resolve(SRC, "simulation.ts"));
  });

  it("reaches src/crypto from a file that is allowed to, so the walker follows real edges", () => {
    // The negative control: src/crypto/index.ts is the barrel the probes and the crypto tests
    // import, and it must reach the modules behind it. If this fails, the walker does not
    // follow edges and the first test means nothing.
    const reached = [...importGraph(resolve(CRYPTO_DIR, "index.ts"))];
    expect(reached).toContain(resolve(CRYPTO_DIR, "primitives.ts"));
    expect(reached).toContain(resolve(CRYPTO_DIR, "noise-xx.ts"));
  });

  it("is node:crypto that makes the boundary necessary, and it is still there", () => {
    const primitives = readFileSync(resolve(CRYPTO_DIR, "primitives.ts"), "utf8");
    expect(primitives).toContain("node:crypto");
    // If this ever stops being true — a WebCrypto port, say — the boundary can be relaxed, and
    // this test failing is the prompt to reconsider the three above rather than a regression.
  });
});
