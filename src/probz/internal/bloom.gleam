//// Bloom filter core shared by `bloom_filter` and `scalable_bloom_filter`.

import gleam/float
import gleam/int
import probz/hash
import probz/internal/bits.{type Bits}
import probz/internal/math

pub fn optimal_bits(n: Int, p: Float) -> Result(Int, Nil) {
  case n > 0 && p >. 0.0 && p <. 1.0 {
    False -> Error(Nil)
    True -> {
      let m =
        float.ceiling(
          0.0 -. int.to_float(n) *. math.ln(p) /. { math.ln2 *. math.ln2 },
        )
      case m >=. 9.223372036854775807e18 {
        True -> Error(Nil)
        False -> Ok(float.truncate(m))
      }
    }
  }
}

pub fn optimal_hashes(m: Int, n: Int) -> Int {
  let k = float.round(int.to_float(m) /. int.to_float(n) *. math.ln2)
  int.clamp(k, 1, 65_536)
}

pub fn add_hash(b: Bits, k: Int, h: Int) -> Bits {
  let p = hash.pair(h)
  let m = b.len
  int.range(0, k, b, fn(b, i) { bits.set(b, hash.index(p, i, m)) })
}

pub fn contains_hash(b: Bits, k: Int, h: Int) -> Bool {
  all_set(b, hash.pair(h), 0, k)
}

fn all_set(b: Bits, p: hash.HashPair, i: Int, k: Int) -> Bool {
  case i >= k {
    True -> True
    False -> bits.is_set(b, hash.index(p, i, b.len)) && all_set(b, p, i + 1, k)
  }
}

/// `n* = -(m / k) · ln(1 - X / m)` for X non-zero cells out of m.
pub fn estimate(m: Int, k: Int, x: Int) -> Result(Float, Nil) {
  let m = int.to_float(m)
  let x = int.to_float(x)
  case x >=. m {
    True -> Error(Nil)
    False -> Ok(0.0 -. { m /. int.to_float(k) } *. math.ln(1.0 -. x /. m))
  }
}
