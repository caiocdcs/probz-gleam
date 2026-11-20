//// Blocked Bloom filter: a Bloom filter whose k bits per item all fall in
//// one 512-bit block (one 64-byte cache line). SPEC.md §5.12.
////
//// Blocks receive a Poisson-distributed number of items and overfull blocks
//// raise the false-positive rate, so the filter needs slightly more bits per
//// item than a standard one (about 3% more at p = 1%). Sizing uses the
//// blocked false-positive rate of Putze et al.:
////
////     FPR(λ, k) = Σ_j Poisson_λ(j) · (1 − (1 − 1/512)^(j·k))^k
////
//// With h = H(item), the block is ⌊(h >> 32) · blocks / 2^32⌋ (Lemire's
//// multiply-shift range reduction), and bit i in the block is the top 9 bits
//// of (h mod 2^32) · s_i mod 2^32 (Dietzfelbinger et al.). The odd salts s_i
//// come from SplitMix64 (SPEC.md §2.3).
////
//// - Felix Putze, Peter Sanders, Johannes Singler, "Cache-, Hash- and
////   Space-Efficient Bloom Filters", WEA 2007, LNCS 4525, pp. 108–121.
////   <https://doi.org/10.1007/978-3-540-72845-0_9>
//// - Martin Dietzfelbinger, Torben Hagerup, Jyrki Katajainen, Martti
////   Penttonen, "A Reliable Randomized Algorithm for the Closest-Pair
////   Problem", Journal of Algorithms 25(1):19–51, 1997.
////   <https://doi.org/10.1006/jagm.1997.0873>
//// - Daniel Lemire, "Fast Random Integer Generation in an Interval",
////   ACM TOMACS 29(1), 2019. <https://doi.org/10.1145/3230636>

import gleam/float
import gleam/int
import gleam/list
import gleam/result
import probz/hash
import probz/internal/bits.{type Bits}
import probz/internal/math
import probz/internal/u64
import probz/internal/wire
import probz/serde
import probz/splitmix64

pub const block_bits = 512

pub const max_k = 16

pub opaque type BlockedBloomFilter {
  BlockedBloomFilter(bits: Bits, blocks: Int, k: Int, salts: List(Int))
}

pub type Error {
  InvalidParameters
  IncompatibleFilters
}

/// The 16 odd multipliers: s_i = (i-th SplitMix64(0) output mod 2^32) | 1.
pub fn salts() -> List(Int) {
  let #(_, out) =
    int.range(0, max_k, #(splitmix64.new(0), []), fn(acc, _) {
      let #(g, out) = acc
      let #(x, g) = splitmix64.next(g)
      #(g, [int.bitwise_or(int.bitwise_and(x, u64.mask32), 1), ..out])
    })
  list.reverse(out)
}

/// A filter sized for `expected_items` at `fp_rate`.
pub fn new(
  expected_items n: Int,
  fp_rate p: Float,
) -> Result(BlockedBloomFilter, Error) {
  use #(blocks, k) <- result.try(optimal_params(n, p))
  new_exact(blocks:, hashes: k)
}

/// A filter with exactly `blocks` blocks (≤ 2^32) and `hashes` bits per
/// item (1–16).
pub fn new_exact(
  blocks blocks: Int,
  hashes k: Int,
) -> Result(BlockedBloomFilter, Error) {
  case blocks > 0 && blocks <= 0x100000000 && k > 0 && k <= max_k {
    True ->
      Ok(BlockedBloomFilter(
        bits: bits.new(blocks * block_bits),
        blocks:,
        k:,
        salts: list.take(salts(), k),
      ))
    False -> Error(InvalidParameters)
  }
}

/// `#(blocks, k)` for n items at rate p: for each k in [1, 16], the largest
/// load λ with FPR(λ, k) ≤ p (64 bisection steps on [0, 512]); keep the k
/// with the largest λ (smallest k on ties); blocks = max(1, ⌈n / λ⌉).
pub fn optimal_params(
  expected_items n: Int,
  fp_rate p: Float,
) -> Result(#(Int, Int), Error) {
  case n > 0 && p >. 0.0 && p <. 1.0 {
    False -> Error(InvalidParameters)
    True -> {
      let #(best_k, best_load) =
        int.range(1, max_k + 1, #(0, 0.0), fn(best, k) {
          let load = case blocked_fpr(512.0, k) <=. p {
            True -> 512.0
            False -> bisect(0.0, 512.0, k, p, 64)
          }
          case load >. best.1 {
            True -> #(k, load)
            False -> best
          }
        })
      case best_load >. 0.0 {
        False -> Error(InvalidParameters)
        True -> {
          let blocks = float.ceiling(int.to_float(n) /. best_load)
          case blocks >. 4_294_967_296.0 {
            True -> Error(InvalidParameters)
            False -> Ok(#(int.max(1, float.truncate(blocks)), best_k))
          }
        }
      }
    }
  }
}

fn bisect(lo: Float, hi: Float, k: Int, p: Float, steps: Int) -> Float {
  case steps {
    0 -> lo
    _ -> {
      let mid = { lo +. hi } /. 2.0
      case blocked_fpr(mid, k) <=. p {
        True -> bisect(mid, hi, k, p, steps - 1)
        False -> bisect(lo, mid, k, p, steps - 1)
      }
    }
  }
}

/// FPR(λ, k) summed for j up to λ + 12·√λ + 20.
fn blocked_fpr(load: Float, k: Int) -> Float {
  case load <=. 0.0 {
    True -> 0.0
    False -> {
      let j_max = float.truncate(load +. 12.0 *. math.sqrt(load) +. 20.0)
      let kf = int.to_float(k)
      let q = math.pow(1.0 -. 1.0 /. 512.0, kf)
      let #(_, _, rate) =
        int.range(1, j_max + 1, #(math.exp(0.0 -. load), 1.0, 0.0), fn(acc, j) {
          let #(pmf, qj, rate) = acc
          let pmf = pmf *. { load /. int.to_float(j) }
          let qj = qj *. q
          #(pmf, qj, rate +. pmf *. math.pow(1.0 -. qj, kf))
        })
      rate
    }
  }
}

fn positions(filter: BlockedBloomFilter, h: Int) -> List(Int) {
  let base = u64.shr(u64.shr(h, 32) * filter.blocks, 32) * block_bits
  let x = int.bitwise_and(h, u64.mask32)
  list.map(filter.salts, fn(s) {
    base + int.bitwise_shift_right(int.bitwise_and(x * s, u64.mask32), 23)
  })
}

pub fn add(filter: BlockedBloomFilter, item: BitArray) -> BlockedBloomFilter {
  add_hash(filter, hash.hash_bytes(item))
}

pub fn add_hash(filter: BlockedBloomFilter, h: Int) -> BlockedBloomFilter {
  let b = list.fold(positions(filter, h), filter.bits, bits.set)
  BlockedBloomFilter(..filter, bits: b)
}

/// Insert every item, in order: the same as folding `add`.
pub fn add_many(
  filter: BlockedBloomFilter,
  items: List(BitArray),
) -> BlockedBloomFilter {
  add_hash_many(filter, list.map(items, hash.hash_bytes))
}

/// `add_many` for precomputed hashes.
pub fn add_hash_many(
  filter: BlockedBloomFilter,
  hashes: List(Int),
) -> BlockedBloomFilter {
  list.fold(hashes, filter, add_hash)
}

/// True if the item may have been inserted; False means it never was.
pub fn contains(filter: BlockedBloomFilter, item: BitArray) -> Bool {
  contains_hash(filter, hash.hash_bytes(item))
}

pub fn contains_hash(filter: BlockedBloomFilter, h: Int) -> Bool {
  list.all(positions(filter, h), bits.is_set(filter.bits, _))
}

/// Expected false-positive rate after `n` distinct inserts.
pub fn false_positive_rate(filter: BlockedBloomFilter, n: Int) -> Float {
  blocked_fpr(int.to_float(n) /. int.to_float(filter.blocks), filter.k)
}

/// Union. Both filters must have the same block count and k.
pub fn merge(
  a: BlockedBloomFilter,
  b: BlockedBloomFilter,
) -> Result(BlockedBloomFilter, Error) {
  case a.blocks == b.blocks && a.k == b.k {
    True -> Ok(BlockedBloomFilter(..a, bits: bits.union(a.bits, b.bits)))
    False -> Error(IncompatibleFilters)
  }
}

pub fn clear(filter: BlockedBloomFilter) -> BlockedBloomFilter {
  BlockedBloomFilter(..filter, bits: bits.clear(filter.bits))
}

pub fn block_count(filter: BlockedBloomFilter) -> Int {
  filter.blocks
}

pub fn hash_count(filter: BlockedBloomFilter) -> Int {
  filter.k
}

/// Wire body (tag 12): u32 k, then a bit array of 512 · blocks bits.
pub fn serialize(filter: BlockedBloomFilter) -> BitArray {
  <<
    wire.header(serde.BlockedBloomFilter):bits,
    { filter.k }:little-size(32),
    bits.serialize(filter.bits):bits,
  >>
}

pub fn deserialize(
  bytes: BitArray,
) -> Result(BlockedBloomFilter, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.BlockedBloomFilter))
  use #(k, rest) <- result.try(wire.u32(rest))
  use #(b, rest) <- result.try(bits.deserialize(rest))
  use <- wire.check(b.len > 0 && b.len % block_bits == 0)
  case new_exact(blocks: b.len / block_bits, hashes: k) {
    Ok(f) -> wire.finish(rest, BlockedBloomFilter(..f, bits: b))
    Error(_) -> Error(serde.InvalidData)
  }
}
