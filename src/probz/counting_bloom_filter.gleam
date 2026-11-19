//// Counting Bloom filter: a Bloom filter whose cells are small counters, so
//// items can be removed. SPEC.md §5.2.
////
//// Sizing and index derivation are those of `bloom_filter` (m cells, k
//// positions by double hashing). `add` increments the k counters and
//// `remove` decrements them. Counters are w bits wide (2–32, default 4).
////
//// Overflow: Fan et al. let a counter that would exceed its maximum stay at
//// the maximum. This implementation saturates the same way and never
//// decrements a saturated counter, so false negatives cannot occur; the cost
//// is that saturated cells stay set permanently.
////
//// `remove` must only be called for items that were added: removing a
//// false positive decrements counters that belong to other items.
////
//// On the wire counters are bit-packed, floor(64 / w) per u64 word, never
//// straddling a word.
////
//// - Li Fan, Pei Cao, Jussara Almeida, Andrei Z. Broder, "Summary Cache: A
////   Scalable Wide-Area Web Cache Sharing Protocol", IEEE/ACM Transactions
////   on Networking 8(3):281–293, 2000. <https://doi.org/10.1109/90.851975>

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import iv
import probz/hash
import probz/internal/bloom
import probz/internal/wire
import probz/serde

pub opaque type CountingBloomFilter {
  CountingBloomFilter(cells: iv.Array(Int), m: Int, k: Int, width: Int)
}

pub type Error {
  InvalidParameters
  IncompatibleFilters
}

pub const default_counter_bits = 4

/// A filter sized like a Bloom filter for `expected_items` at `fp_rate`,
/// with `counter_bits`-bit counters (2–32).
pub fn new(
  expected_items n: Int,
  fp_rate p: Float,
  counter_bits w: Int,
) -> Result(CountingBloomFilter, Error) {
  case bloom.optimal_bits(n, p) {
    Ok(m) ->
      new_exact(cells: m, hashes: bloom.optimal_hashes(m, n), counter_bits: w)
    Error(_) -> Error(InvalidParameters)
  }
}

/// A filter with exactly `cells` counters and `hashes` hash functions.
pub fn new_exact(
  cells m: Int,
  hashes k: Int,
  counter_bits w: Int,
) -> Result(CountingBloomFilter, Error) {
  case m > 0 && k > 0 && k < 0x100000000 && w >= 2 && w <= 32 {
    True -> Ok(CountingBloomFilter(cells: iv.repeat(0, m), m:, k:, width: w))
    False -> Error(InvalidParameters)
  }
}

fn max(filter: CountingBloomFilter) -> Int {
  int.bitwise_shift_left(1, filter.width) - 1
}

fn indexes(filter: CountingBloomFilter, h: Int) -> List(Int) {
  let p = hash.pair(h)
  int.range(filter.k - 1, -1, [], fn(acc, i) {
    [hash.index(p, i, filter.m), ..acc]
  })
}

/// Apply `f` to each of the k counters in turn. Indexes may repeat, and
/// every step sees the previous one's update, as in the reference.
fn update(
  filter: CountingBloomFilter,
  h: Int,
  f: fn(Int) -> Int,
) -> CountingBloomFilter {
  let cells =
    list.fold(indexes(filter, h), filter.cells, fn(cells, i) {
      iv.try_update(cells, i, f)
    })
  CountingBloomFilter(..filter, cells:)
}

pub fn add(filter: CountingBloomFilter, item: BitArray) -> CountingBloomFilter {
  add_hash(filter, hash.hash_bytes(item))
}

pub fn add_hash(filter: CountingBloomFilter, h: Int) -> CountingBloomFilter {
  let max = max(filter)
  update(filter, h, fn(c) {
    case c == max {
      True -> c
      False -> c + 1
    }
  })
}

pub fn contains(filter: CountingBloomFilter, item: BitArray) -> Bool {
  contains_hash(filter, hash.hash_bytes(item))
}

pub fn contains_hash(filter: CountingBloomFilter, h: Int) -> Bool {
  count_hash(filter, h) > 0
}

/// Upper bound on the multiplicity of `item`: the minimum of its k counters.
pub fn count(filter: CountingBloomFilter, item: BitArray) -> Int {
  count_hash(filter, hash.hash_bytes(item))
}

pub fn count_hash(filter: CountingBloomFilter, h: Int) -> Int {
  list.fold(indexes(filter, h), max(filter), fn(m, i) {
    int.min(m, iv.get_or_default(filter.cells, i, 0))
  })
}

/// Decrement the item's counters. `Error(Nil)` if the item is not present.
pub fn remove(
  filter: CountingBloomFilter,
  item: BitArray,
) -> Result(CountingBloomFilter, Nil) {
  remove_hash(filter, hash.hash_bytes(item))
}

pub fn remove_hash(
  filter: CountingBloomFilter,
  h: Int,
) -> Result(CountingBloomFilter, Nil) {
  case contains_hash(filter, h) {
    False -> Error(Nil)
    True -> {
      let max = max(filter)
      Ok(
        update(filter, h, fn(c) {
          case c == max || c == 0 {
            True -> c
            False -> c - 1
          }
        }),
      )
    }
  }
}

/// Estimated number of distinct items, from the non-zero cells (see
/// `bloom_filter.estimated_items`).
pub fn estimated_items(filter: CountingBloomFilter) -> Result(Float, Nil) {
  bloom.estimate(filter.m, filter.k, non_zero_count(filter))
}

pub fn non_zero_count(filter: CountingBloomFilter) -> Int {
  iv.fold(filter.cells, 0, fn(n, c) {
    case c {
      0 -> n
      _ -> n + 1
    }
  })
}

/// Cell-wise saturating sum. Both filters must have the same parameters.
pub fn merge(
  a: CountingBloomFilter,
  b: CountingBloomFilter,
) -> Result(CountingBloomFilter, Error) {
  case a.m == b.m && a.k == b.k && a.width == b.width {
    False -> Error(IncompatibleFilters)
    True -> {
      let max = max(a)
      let cells = iv.map2(a.cells, b.cells, fn(x, y) { int.min(x + y, max) })
      Ok(CountingBloomFilter(..a, cells:))
    }
  }
}

pub fn clear(filter: CountingBloomFilter) -> CountingBloomFilter {
  CountingBloomFilter(..filter, cells: iv.repeat(0, filter.m))
}

pub fn cell_count(filter: CountingBloomFilter) -> Int {
  filter.m
}

pub fn hash_count(filter: CountingBloomFilter) -> Int {
  filter.k
}

pub fn counter_bits(filter: CountingBloomFilter) -> Int {
  filter.width
}

/// Wire body (tag 2): u8 w, u32 k, u64 m, then ceil(m / floor(64 / w)) u64
/// words of packed counters, counter i at bit (i mod per_word)·w of word
/// floor(i / per_word).
pub fn serialize(filter: CountingBloomFilter) -> BitArray {
  let per_word = 64 / filter.width
  let words =
    filter.cells
    |> iv.to_list
    |> list.sized_chunk(per_word)
    |> list.map(fn(chunk) {
      let #(word, _) =
        list.fold(chunk, #(0, 0), fn(acc, c) {
          #(
            int.bitwise_or(acc.0, int.bitwise_shift_left(c, acc.1)),
            acc.1 + filter.width,
          )
        })
      <<word:little-size(64)>>
    })
  bit_array.concat([
    wire.header(serde.CountingBloomFilter),
    <<
      { filter.width },
      { filter.k }:little-size(32),
      { filter.m }:little-size(64),
    >>,
    ..words
  ])
}

pub fn deserialize(
  bytes: BitArray,
) -> Result(CountingBloomFilter, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.CountingBloomFilter))
  use #(w, rest) <- result.try(wire.u8(rest))
  use #(k, rest) <- result.try(wire.u32(rest))
  use #(m, rest) <- result.try(wire.u64(rest))
  use filter <- result.try(
    new_exact(cells: m, hashes: k, counter_bits: w)
    |> result.replace_error(serde.InvalidData),
  )
  let per_word = 64 / w
  let n_words = { m + per_word - 1 } / per_word
  use <- wire.check(bit_array.byte_size(rest) >= n_words * 8)
  use #(words, rest) <- result.try(wire.many(rest, n_words, wire.u64))
  let mask = int.bitwise_shift_left(1, w) - 1
  let unpacked =
    list.index_map(words, fn(word, wi) {
      let used = int.min(per_word, m - wi * per_word)
      let cells =
        int.range(used - 1, -1, [], fn(acc, j) {
          [int.bitwise_and(int.bitwise_shift_right(word, j * w), mask), ..acc]
        })
      let tail_ok =
        used * w >= 64 || int.bitwise_shift_right(word, used * w) == 0
      #(cells, tail_ok)
    })
  use <- wire.check(list.all(unpacked, fn(u) { u.1 }))
  let cells = iv.from_list(list.flat_map(unpacked, fn(u) { u.0 }))
  wire.finish(rest, CountingBloomFilter(..filter, cells:))
}
