/**
 * Seeded PRNG shared by the TypeScript reference simulator and the Dart port
 * (`sim/mesh_sim`). The two implementations are bit-identical: every value is
 * kept in unsigned 32-bit space and the final double is `u32 / 2^32`.
 *
 * Determinism contract: any two runs with the same seed and the same *order* of
 * draw calls produce identical node layouts, mobility, packet-loss outcomes and
 * forwarding jitter. Golden vectors in `test-fixtures/golden-vectors.json`
 * assert this across languages.
 */

export type Rng = () => number;

const GOLDEN_GAMMA = 0x6d2b79f5;
const U32 = 4294967296;

/** mulberry32: small, fast, good enough for Monte-Carlo mesh runs. */
export function createRng(seed: number): Rng {
  let a = seed >>> 0;
  return function next(): number {
    a = (a + GOLDEN_GAMMA) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / U32;
  };
}

/** Uniform float in [min, max). */
export function randRange(rng: Rng, min: number, max: number): number {
  return min + rng() * (max - min);
}

/** Uniform integer in [minIncl, maxExcl). */
export function randInt(rng: Rng, minIncl: number, maxExcl: number): number {
  return minIncl + Math.floor(rng() * (maxExcl - minIncl));
}

/** True with probability `p`. */
export function chance(rng: Rng, p: number): boolean {
  return rng() < p;
}

/** Uniform element of a non-empty array. */
export function pick<T>(rng: Rng, items: readonly T[]): T {
  return items[Math.floor(rng() * items.length)];
}
