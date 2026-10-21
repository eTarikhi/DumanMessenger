/// Seeded PRNG, bit-identical to the TypeScript reference (`src/rng.ts`).
///
/// mulberry32 kept entirely in unsigned 32-bit space. Dart integers are 64-bit,
/// so every intermediate result is masked with 0xFFFFFFFF; that reproduces
/// JavaScript's signed-32 bitwise semantics bit-for-bit (the final value only
/// depends on the low 32 bits), and `Math.imul` becomes a masked multiply.
///
/// Determinism contract: two runs with the same seed and the same *order* of
/// draw calls produce identical node layouts, mobility, packet-loss outcomes and
/// forwarding jitter. `test-fixtures/golden-vectors.json` asserts this across
/// both languages.
library;

/// A draw function returning a double in [0, 1).
typedef Rng = double Function();

const int _goldenGamma = 0x6d2b79f5;
const int _u32 = 4294967296;
const int _mask = 0xFFFFFFFF;

/// mulberry32: small, fast, good enough for Monte-Carlo mesh runs.
Rng createRng(int seed) {
  var a = seed & _mask;
  return () {
    a = (a + _goldenGamma) & _mask;
    var t = a;
    t = (t ^ (t >> 15)) & _mask;
    t = (t * ((t | 1) & _mask)) & _mask;
    final inner = (t ^ (t >> 7)) & _mask;
    final product = (inner * ((inner | 61) & _mask)) & _mask;
    t = (t ^ ((t + product) & _mask)) & _mask;
    t = (t ^ (t >> 14)) & _mask;
    return t / _u32;
  };
}

/// Uniform float in [min, max).
double randRange(Rng rng, double min, double max) => min + rng() * (max - min);

/// Uniform integer in [minIncl, maxExcl).
int randInt(Rng rng, int minIncl, int maxExcl) =>
    minIncl + (rng() * (maxExcl - minIncl)).floor();

/// True with probability [p].
bool chance(Rng rng, double p) => rng() < p;

/// Uniform element of a non-empty list.
T pick<T>(Rng rng, List<T> items) => items[(rng() * items.length).floor()];
