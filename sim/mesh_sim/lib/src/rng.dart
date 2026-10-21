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

/// JavaScript's `Math.imul`: multiply two values and keep the low 32 bits.
///
/// Dart integers are 64-bit, so the product has to be masked back down. Masking
/// the operands first is what reproduces `imul`'s ToUint32 coercion of a
/// negative int32.
int _imul(int x, int y) => ((x & _mask) * (y & _mask)) & _mask;

/// mulberry32: small, fast, good enough for Monte-Carlo mesh runs.
Rng createRng(int seed) {
  var a = seed & _mask;
  return () {
    a = (a + _goldenGamma) & _mask;
    var t = a;
    // Both operands of each multiply are read from the *same* t, so the
    // right-hand operand must be taken before t is overwritten by the product.
    // Getting this wrong still yields a plausible stream — it just is not
    // mulberry32, and every golden vector diverges from the first draw.
    t = _imul(t ^ (t >> 15), t | 1);
    t = (t ^ ((t + _imul(t ^ (t >> 7), t | 61)) & _mask)) & _mask;
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
