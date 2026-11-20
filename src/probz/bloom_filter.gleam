//// Bloom filter: set membership with false positives but no false
//// negatives. SPEC.md §5.1.
////
//// Sizing for n expected items at false-positive rate p (Broder &
//// Mitzenmacher, §2.1):
////
////     m = ceil(-n · ln p / (ln 2)²)        bits
////     k = clamp(round((m / n) · ln 2), 1, 65536)
////
//// The k bit positions come from double hashing over one XxHash64
//// (SPEC.md §2.2).
////
//// - Burton H. Bloom, "Space/Time Trade-offs in Hash Coding with Allowable
////   Errors", CACM 13(7):422–426, 1970. <https://doi.org/10.1145/362686.362692>
//// - Andrei Broder, Michael Mitzenmacher, "Network Applications of Bloom
////   Filters: A Survey", Internet Mathematics 1(4):485–509, 2004, §2.1.
////   <https://doi.org/10.1080/15427951.2004.10129096>
//// - S. Joshua Swamidass, Pierre Baldi, "Mathematical Correction for
////   Fingerprint Similarity Measures to Improve Chemical Retrieval",
////   J. Chem. Inf. Model. 47(3):952–964, 2007 (item-count estimate).
////   <https://doi.org/10.1021/ci600526a>
////
//// ```gleam
//// let assert Ok(filter) = bloom_filter.new(expected_items: 10_000, fp_rate: 0.01)
//// let filter = bloom_filter.add(filter, <<"apple">>)
//// bloom_filter.contains(filter, <<"apple">>)
//// // -> True
//// ```

import gleam/int
import gleam/list
import gleam/result
import probz/hash
import probz/internal/bits.{type Bits}
import probz/internal/bloom
import probz/internal/math
import probz/internal/wire
import probz/serde

pub opaque type BloomFilter {
  BloomFilter(bits: Bits, k: Int)
}

pub type Error {
  /// Sizing parameters out of range.
  InvalidParameters
  /// `merge` of filters with different bit or hash counts.
  IncompatibleFilters
}

/// A filter sized for `expected_items` (> 0) at `fp_rate` (in (0, 1)).
pub fn new(
  expected_items n: Int,
  fp_rate p: Float,
) -> Result(BloomFilter, Error) {
  use m <- result.try(optimal_bits(n, p))
  new_exact(bits: m, hashes: optimal_hashes(m, n))
}

/// A filter with exactly `bits` bits and `hashes` hash functions.
pub fn new_exact(bits m: Int, hashes k: Int) -> Result(BloomFilter, Error) {
  case m > 0 && k > 0 && k < 0x100000000 {
    True -> Ok(BloomFilter(bits: bits.new(m), k:))
    False -> Error(InvalidParameters)
  }
}

/// `m = ceil(-n · ln p / (ln 2)²)`.
pub fn optimal_bits(
  expected_items n: Int,
  fp_rate p: Float,
) -> Result(Int, Error) {
  bloom.optimal_bits(n, p) |> result.replace_error(InvalidParameters)
}

/// `k = clamp(round((m / n) · ln 2), 1, 65536)`.
pub fn optimal_hashes(bits m: Int, expected_items n: Int) -> Int {
  bloom.optimal_hashes(m, n)
}

pub fn add(filter: BloomFilter, item: BitArray) -> BloomFilter {
  add_hash(filter, hash.hash_bytes(item))
}

/// Insert a precomputed XxHash64 (see `probz/hash`).
pub fn add_hash(filter: BloomFilter, h: Int) -> BloomFilter {
  BloomFilter(..filter, bits: bloom.add_hash(filter.bits, filter.k, h))
}

/// Insert every item, in order: the same as folding `add`.
pub fn add_many(filter: BloomFilter, items: List(BitArray)) -> BloomFilter {
  add_hash_many(filter, list.map(items, hash.hash_bytes))
}

/// `add_many` for precomputed hashes.
pub fn add_hash_many(filter: BloomFilter, hashes: List(Int)) -> BloomFilter {
  list.fold(hashes, filter, add_hash)
}

/// True if the item may have been inserted; False means it never was.
pub fn contains(filter: BloomFilter, item: BitArray) -> Bool {
  contains_hash(filter, hash.hash_bytes(item))
}

pub fn contains_hash(filter: BloomFilter, h: Int) -> Bool {
  bloom.contains_hash(filter.bits, filter.k, h)
}

/// Estimated number of distinct items inserted (Swamidass & Baldi):
/// `n* = -(m / k) · ln(1 - X / m)` with X set bits. `Error(Nil)` when every
/// bit is set (the estimate is infinite).
pub fn estimated_items(filter: BloomFilter) -> Result(Float, Nil) {
  bloom.estimate(filter.bits.len, filter.k, bits.count_set(filter.bits))
}

/// Expected false-positive rate after `n` distinct inserts:
/// `(1 - e^(-k·n/m))^k`.
pub fn false_positive_rate(filter: BloomFilter, n: Int) -> Float {
  let m = int.to_float(filter.bits.len)
  let k = int.to_float(filter.k)
  math.pow(1.0 -. math.exp(0.0 -. k *. int.to_float(n) /. m), k)
}

/// Union. Both filters must have the same bit and hash counts.
pub fn merge(a: BloomFilter, b: BloomFilter) -> Result(BloomFilter, Error) {
  case a.bits.len == b.bits.len && a.k == b.k {
    True -> Ok(BloomFilter(..a, bits: bits.union(a.bits, b.bits)))
    False -> Error(IncompatibleFilters)
  }
}

pub fn clear(filter: BloomFilter) -> BloomFilter {
  BloomFilter(..filter, bits: bits.clear(filter.bits))
}

pub fn bit_count(filter: BloomFilter) -> Int {
  filter.bits.len
}

pub fn hash_count(filter: BloomFilter) -> Int {
  filter.k
}

/// Number of bits set to 1.
pub fn set_bits(filter: BloomFilter) -> Int {
  bits.count_set(filter.bits)
}

/// Wire body (tag 1): u32 k, then the bit array (SPEC.md §3.1).
pub fn serialize(filter: BloomFilter) -> BitArray {
  <<
    wire.header(serde.BloomFilter):bits,
    { filter.k }:little-size(32),
    bits.serialize(filter.bits):bits,
  >>
}

pub fn deserialize(bytes: BitArray) -> Result(BloomFilter, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.BloomFilter))
  use #(k, rest) <- result.try(wire.u32(rest))
  use #(b, rest) <- result.try(bits.deserialize(rest))
  use <- wire.check(k > 0 && b.len > 0)
  wire.finish(rest, BloomFilter(bits: b, k:))
}
