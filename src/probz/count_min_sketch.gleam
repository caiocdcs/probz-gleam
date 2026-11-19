//// Count-Min sketch: frequency estimates that never undercount, and
//// overcount by at most ε·N with probability 1 − δ. SPEC.md §5.7.
////
//// d rows of w counters. Row j of an item uses column j of a SplitMix64
//// sequence seeded with the item's hash. The standard update adds to the d
//// counters; the conservative update (Estan & Varghese §3.3.2) raises each
//// only to max(counter, estimate + c), which never undercounts and
//// overestimates less.
////
//// Counters are `counter_bits` wide (8–64, default 32). An add that would
//// overflow a counter or the total fails without changing anything.
////
//// Deviation: the analysis assumes d pairwise-independent hash functions;
//// here every row depends only on the 64-bit item hash.
////
//// - Graham Cormode, S. Muthukrishnan, "An Improved Data Stream Summary: The
////   Count-Min Sketch and its Applications", Journal of Algorithms
////   55(1):58–75, 2005. <https://doi.org/10.1016/j.jalgor.2003.12.001>
//// - Cristian Estan, George Varghese, "New Directions in Traffic Measurement
////   and Accounting", SIGCOMM 2002, §3.3.2.
////   <https://doi.org/10.1145/633025.633056>

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import iv
import probz/hash
import probz/internal/math
import probz/internal/u64
import probz/internal/wire
import probz/serde
import probz/splitmix64

pub type Update {
  /// Add c to each of the item's d counters (Cormode & Muthukrishnan).
  Standard
  /// Raise each counter to at least estimate + c (Estan & Varghese).
  Conservative
}

pub opaque type CountMinSketch {
  CountMinSketch(
    width: Int,
    depth: Int,
    bits: Int,
    /// Row-major, depth · width counters.
    counters: iv.Array(Int),
    total: Int,
    update: Update,
  )
}

pub type Error {
  InvalidParameters
  /// A counter or the total would overflow.
  Overflow
  IncompatibleSketches
}

const e = 2.718281828459045

/// A sketch of `depth` rows of `width` counters, each `counter_bits` wide
/// (8–64).
pub fn new(
  width w: Int,
  depth d: Int,
  counter_bits bits: Int,
  update update: Update,
) -> Result(CountMinSketch, Error) {
  case
    w > 0
    && w <= u64.mask
    && d > 0
    && d < 0x100000000
    && bits >= 8
    && bits <= 64
  {
    False -> Error(InvalidParameters)
    True ->
      Ok(CountMinSketch(
        width: w,
        depth: d,
        bits:,
        counters: iv.repeat(0, w * d),
        total: 0,
        update:,
      ))
  }
}

/// `#(width, depth)` for additive error ε·N with probability 1 − δ:
/// w = ⌈e / ε⌉, d = max(1, ⌈ln(1 / δ)⌉), for 0 < ε, δ < 1.
pub fn dimensions_for_error(
  epsilon: Float,
  delta: Float,
) -> Result(#(Int, Int), Error) {
  case epsilon >. 0.0 && epsilon <. 1.0 && delta >. 0.0 && delta <. 1.0 {
    False -> Error(InvalidParameters)
    True ->
      Ok(#(
        math.ceil(e /. epsilon),
        float.truncate(float.max(1.0, float.ceiling(math.ln(1.0 /. delta)))),
      ))
  }
}

/// A sketch sized by `dimensions_for_error`.
pub fn with_error(
  epsilon epsilon: Float,
  delta delta: Float,
  counter_bits bits: Int,
  update update: Update,
) -> Result(CountMinSketch, Error) {
  use #(w, d) <- result.try(dimensions_for_error(epsilon, delta))
  new(w, d, bits, update)
}

fn max(cms: CountMinSketch) -> Int {
  int.bitwise_shift_left(1, cms.bits) - 1
}

/// Counter indexes: row j uses the j-th SplitMix64(h) output modulo w.
fn indexes(cms: CountMinSketch, h: Int) -> List(Int) {
  let #(_, out) =
    int.range(0, cms.depth, #(splitmix64.new(h), []), fn(acc, row) {
      let #(g, out) = acc
      let #(col, g) = splitmix64.below(g, cms.width)
      #(g, [row * cms.width + col, ..out])
    })
  list.reverse(out)
}

fn get(cms: CountMinSketch, i: Int) -> Int {
  iv.get_or_default(cms.counters, i, 0)
}

/// Add `amount` (≥ 0) occurrences of an item.
pub fn add(
  cms: CountMinSketch,
  item: BitArray,
  amount: Int,
) -> Result(CountMinSketch, Error) {
  add_hash(cms, hash.hash_bytes(item), amount)
}

pub fn add_hash(
  cms: CountMinSketch,
  h: Int,
  amount: Int,
) -> Result(CountMinSketch, Error) {
  let total = cms.total + amount
  let max = max(cms)
  case amount {
    0 -> Ok(cms)
    _ if amount < 0 -> Error(InvalidParameters)
    _ if total > u64.mask -> Error(Overflow)
    _ -> {
      let idx = indexes(cms, h)
      case cms.update {
        Standard ->
          case list.any(idx, fn(i) { get(cms, i) + amount > max }) {
            True -> Error(Overflow)
            False ->
              Ok(
                CountMinSketch(
                  ..cms,
                  total:,
                  counters: list.fold(idx, cms.counters, fn(c, i) {
                    iv.try_update(c, i, fn(x) { x + amount })
                  }),
                ),
              )
          }
        Conservative -> {
          let v = min_of(cms, idx) + amount
          case v > max {
            True -> Error(Overflow)
            False ->
              Ok(
                CountMinSketch(
                  ..cms,
                  total:,
                  counters: list.fold(idx, cms.counters, fn(c, i) {
                    iv.try_update(c, i, int.max(_, v))
                  }),
                ),
              )
          }
        }
      }
    }
  }
}

fn min_of(cms: CountMinSketch, idx: List(Int)) -> Int {
  list.fold(idx, u64.mask, fn(m, i) { int.min(m, get(cms, i)) })
}

/// Estimated count: never below the true count.
pub fn count(cms: CountMinSketch, item: BitArray) -> Int {
  count_hash(cms, hash.hash_bytes(item))
}

pub fn count_hash(cms: CountMinSketch, h: Int) -> Int {
  min_of(cms, indexes(cms, h))
}

/// N: the sum of all added amounts.
pub fn total(cms: CountMinSketch) -> Int {
  cms.total
}

pub fn width(cms: CountMinSketch) -> Int {
  cms.width
}

pub fn depth(cms: CountMinSketch) -> Int {
  cms.depth
}

/// Additive error bound ε·N for the current total, with ε = e / w.
pub fn error_bound(cms: CountMinSketch) -> Float {
  e /. int.to_float(cms.width) *. int.to_float(cms.total)
}

/// Sum of two sketches of the same dimensions (the sketch of the combined
/// stream). The result keeps `a`'s update rule; for conservative sketches
/// the sum is still an upper bound, but looser.
pub fn merge(
  a: CountMinSketch,
  b: CountMinSketch,
) -> Result(CountMinSketch, Error) {
  let max = max(a)
  let total = a.total + b.total
  case a.width == b.width && a.depth == b.depth && a.bits == b.bits {
    False -> Error(IncompatibleSketches)
    True -> {
      let counters = iv.map2(a.counters, b.counters, fn(x, y) { x + y })
      case total > u64.mask || iv.any(counters, fn(c) { c > max }) {
        True -> Error(Overflow)
        False -> Ok(CountMinSketch(..a, counters:, total:))
      }
    }
  }
}

pub fn clear(cms: CountMinSketch) -> CountMinSketch {
  CountMinSketch(..cms, counters: iv.repeat(0, cms.width * cms.depth), total: 0)
}

/// Wire body (tag 7): u8 flags (counter bits in bits 0–6, conservative in bit
/// 7), u32 d, u64 w, u64 N, then d·w counters row-major, each little-endian
/// in ceil(bits / 8) bytes.
pub fn serialize(cms: CountMinSketch) -> BitArray {
  let size = { cms.bits + 7 } / 8 * 8
  let flags = case cms.update {
    Standard -> cms.bits
    Conservative -> cms.bits + 0x80
  }
  bit_array.concat([
    wire.header(serde.CountMinSketch),
    <<
      flags,
      { cms.depth }:little-size(32),
      { cms.width }:little-size(64),
      { cms.total }:little-size(64),
    >>,
    ..iv.to_list(iv.map(cms.counters, fn(c) { <<c:little-size(size)>> }))
  ])
}

pub fn deserialize(
  bytes: BitArray,
) -> Result(CountMinSketch, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.CountMinSketch))
  use #(flags, rest) <- result.try(wire.u8(rest))
  use #(d, rest) <- result.try(wire.u32(rest))
  use #(w, rest) <- result.try(wire.u64(rest))
  use #(total, rest) <- result.try(wire.u64(rest))
  let bits = int.bitwise_and(flags, 0x7f)
  let update = case flags >= 0x80 {
    True -> Conservative
    False -> Standard
  }
  use cms <- result.try(
    new(w, d, bits, update) |> result.replace_error(serde.InvalidData),
  )
  let size = { bits + 7 } / 8 * 8
  let max = max(cms)
  use <- wire.check(bit_array.byte_size(rest) >= w * d * size / 8)
  use #(counters, rest) <- result.try(
    wire.many(rest, w * d, fn(input) {
      use #(c, rest) <- result.try(wire.uint(input, size))
      use <- wire.check(c <= max)
      Ok(#(c, rest))
    }),
  )
  wire.finish(
    rest,
    CountMinSketch(..cms, counters: iv.from_list(counters), total:),
  )
}
