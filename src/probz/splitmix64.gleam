//// SplitMix64: the portable PRNG used wherever a structure makes random
//// choices (cuckoo evictions, MinHash coefficients). SPEC.md §2.3.
////
//// Guy L. Steele, Doug Lea, Christine H. Flood, "Fast Splittable
//// Pseudorandom Number Generators", OOPSLA 2014.
//// <https://doi.org/10.1145/2714064.2660195>. Constants as in Vigna's
//// reference code, <https://prng.di.unimi.it/splitmix64.c>.

import probz/internal/u64

pub type SplitMix64 {
  SplitMix64(state: Int)
}

pub fn new(seed: Int) -> SplitMix64 {
  SplitMix64(state: u64.wrap(seed))
}

/// The next 64-bit output and the advanced generator.
pub fn next(g: SplitMix64) -> #(Int, SplitMix64) {
  let state = u64.add(g.state, 0x9e3779b97f4a7c15)
  let z = u64.mul(u64.xor(state, u64.shr(state, 30)), 0xbf58476d1ce4e5b9)
  let z = u64.mul(u64.xor(z, u64.shr(z, 27)), 0x94d049bb133111eb)
  #(u64.xor(z, u64.shr(z, 31)), SplitMix64(state:))
}

/// A value in `[0, n)` as `next() mod n`. `n` must be positive.
pub fn below(g: SplitMix64, n: Int) -> #(Int, SplitMix64) {
  let #(x, g) = next(g)
  #(x % n, g)
}
