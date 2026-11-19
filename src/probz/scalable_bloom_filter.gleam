//// Scalable Bloom filter: a chain of Bloom filters that grows as items
//// arrive while keeping the compound false-positive rate below a target.
//// SPEC.md §5.3.
////
//// Stage i has capacity n_i = n_0 · s^i and error rate P_i = P_0 · r^i, with
//// P_0 = P · (1 − r), so the compound rate is bounded by P_0 / (1 − r) = P
//// (paper §3). A new stage is appended when the newest one has received n_i
//// items. Items the filter already reports as present are not inserted
//// again, so duplicates do not consume capacity.
////
//// Deviation from the paper: each stage is a standard Bloom filter sized for
//// (n_i, P_i) rather than a partitioned filter. Both meet P_i at n_i items.
////
//// - Paulo Sérgio Almeida, Carlos Baquero, Nuno Preguiça, David Hutchison,
////   "Scalable Bloom Filters", Information Processing Letters
////   101(6):255–261, 2007. <https://doi.org/10.1016/j.ipl.2006.10.007>

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import probz/hash
import probz/internal/bits.{type Bits}
import probz/internal/bloom
import probz/internal/math
import probz/internal/u64
import probz/internal/wire
import probz/serde

pub opaque type ScalableBloomFilter {
  ScalableBloomFilter(
    initial_capacity: Int,
    fp_rate: Float,
    growth: Int,
    tightening: Float,
    /// Newest stage first.
    stages: List(Stage),
  )
}

/// One Bloom filter in the chain.
pub type Stage {
  Stage(bits: Bits, k: Int, count: Int, capacity: Int)
}

pub type Error {
  InvalidParameters
}

/// `fp_rate` in (0, 1) is the compound target; `growth` ≥ 2 and
/// `tightening` in (0, 1) are the paper's s and r (defaults 2 and 0.9).
pub fn new(
  initial_capacity n0: Int,
  fp_rate p: Float,
  growth s: Int,
  tightening r: Float,
) -> Result(ScalableBloomFilter, Error) {
  let valid =
    n0 > 0
    && n0 <= u64.mask
    && s >= 2
    && s < 0x100000000
    && p >. 0.0
    && p <. 1.0
    && r >. 0.0
    && r <. 1.0
  case valid {
    False -> Error(InvalidParameters)
    True -> {
      let f =
        ScalableBloomFilter(
          initial_capacity: n0,
          fp_rate: p,
          growth: s,
          tightening: r,
          stages: [],
        )
      use stage <- result.map(new_stage(f, 0))
      ScalableBloomFilter(..f, stages: [stage])
    }
  }
}

/// `new` with growth 2 and tightening 0.9.
pub fn with_defaults(
  initial_capacity n0: Int,
  fp_rate p: Float,
) -> Result(ScalableBloomFilter, Error) {
  new(initial_capacity: n0, fp_rate: p, growth: 2, tightening: 0.9)
}

fn stage_capacity(f: ScalableBloomFilter, i: Int) -> Int {
  int.min(f.initial_capacity * int_pow(f.growth, i), u64.mask)
}

fn int_pow(b: Int, e: Int) -> Int {
  case e {
    0 -> 1
    _ -> b * int_pow(b, e - 1)
  }
}

fn stage_fp_rate(f: ScalableBloomFilter, i: Int) -> Float {
  f.fp_rate
  *. { 1.0 -. f.tightening }
  *. math.pow(f.tightening, int.to_float(i))
}

fn new_stage(f: ScalableBloomFilter, i: Int) -> Result(Stage, Error) {
  let capacity = stage_capacity(f, i)
  case bloom.optimal_bits(capacity, stage_fp_rate(f, i)) {
    Ok(m) ->
      Ok(Stage(
        bits: bits.new(m),
        k: bloom.optimal_hashes(m, capacity),
        count: 0,
        capacity:,
      ))
    Error(_) -> Error(InvalidParameters)
  }
}

pub fn add(
  filter: ScalableBloomFilter,
  item: BitArray,
) -> Result(ScalableBloomFilter, Error) {
  add_hash(filter, hash.hash_bytes(item))
}

/// Insert a precomputed hash. Fails only if a new stage cannot be sized
/// (its rate underflows after very many stages).
pub fn add_hash(
  filter: ScalableBloomFilter,
  h: Int,
) -> Result(ScalableBloomFilter, Error) {
  case contains_hash(filter, h) {
    True -> Ok(filter)
    False -> {
      let assert [last, ..older] = filter.stages
      use stages <- result.map(case last.count >= last.capacity {
        True -> {
          use next <- result.map(new_stage(filter, list.length(filter.stages)))
          [insert(next, h), last, ..older]
        }
        False -> Ok([insert(last, h), ..older])
      })
      ScalableBloomFilter(..filter, stages:)
    }
  }
}

fn insert(stage: Stage, h: Int) -> Stage {
  Stage(
    ..stage,
    bits: bloom.add_hash(stage.bits, stage.k, h),
    count: stage.count + 1,
  )
}

pub fn contains(filter: ScalableBloomFilter, item: BitArray) -> Bool {
  contains_hash(filter, hash.hash_bytes(item))
}

pub fn contains_hash(filter: ScalableBloomFilter, h: Int) -> Bool {
  list.any(filter.stages, fn(s) { bloom.contains_hash(s.bits, s.k, h) })
}

/// Number of items inserted (duplicates are not counted).
pub fn count(filter: ScalableBloomFilter) -> Int {
  list.fold(filter.stages, 0, fn(n, s) { n + s.count })
}

pub fn stage_count(filter: ScalableBloomFilter) -> Int {
  list.length(filter.stages)
}

/// The stages, oldest first.
pub fn stages(filter: ScalableBloomFilter) -> List(Stage) {
  list.reverse(filter.stages)
}

/// Upper bound on the compound false-positive rate: Σ P_i over the stages.
pub fn fp_rate_bound(filter: ScalableBloomFilter) -> Float {
  int.range(0, stage_count(filter), 0.0, fn(t, i) {
    t +. stage_fp_rate(filter, i)
  })
}

/// Back to one empty stage.
pub fn clear(filter: ScalableBloomFilter) -> ScalableBloomFilter {
  let assert Ok(first) = new_stage(filter, 0)
  ScalableBloomFilter(..filter, stages: [first])
}

/// Wire body (tag 3): u64 n_0, f64 P, u32 s, f64 r, u32 stage count, then per
/// stage (oldest first) u64 count, u32 k and a bit array.
pub fn serialize(filter: ScalableBloomFilter) -> BitArray {
  bit_array.concat([
    wire.header(serde.ScalableBloomFilter),
    <<
      { filter.initial_capacity }:little-size(64),
      { filter.fp_rate }:little-float-size(64),
      { filter.growth }:little-size(32),
      { filter.tightening }:little-float-size(64),
      { list.length(filter.stages) }:little-size(32),
    >>,
    ..list.map(stages(filter), fn(s) {
      <<
        { s.count }:little-size(64),
        { s.k }:little-size(32),
        bits.serialize(s.bits):bits,
      >>
    })
  ])
}

pub fn deserialize(
  bytes: BitArray,
) -> Result(ScalableBloomFilter, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.ScalableBloomFilter))
  use #(n0, rest) <- result.try(wire.u64(rest))
  use #(p, rest) <- result.try(wire.f64(rest))
  use #(s, rest) <- result.try(wire.u32(rest))
  use #(r, rest) <- result.try(wire.f64(rest))
  use f <- result.try(
    new(n0, p, s, r) |> result.replace_error(serde.InvalidData),
  )
  use #(n, rest) <- result.try(wire.u32(rest))
  // Each stage takes at least 20 bytes; refuse counts the input cannot hold.
  use <- wire.check(n > 0 && n * 20 <= bit_array.byte_size(rest))
  use #(stages, rest) <- result.try(read_stages(f, rest, 0, n, []))
  wire.finish(rest, ScalableBloomFilter(..f, stages:))
}

fn read_stages(f, input, i, n, acc) -> Result(#(List(Stage), BitArray), _) {
  case i >= n {
    True -> Ok(#(acc, input))
    False -> {
      use expected <- result.try(
        new_stage(f, i) |> result.replace_error(serde.InvalidData),
      )
      use #(count, rest) <- result.try(wire.u64(input))
      use #(k, rest) <- result.try(wire.u32(rest))
      use #(b, rest) <- result.try(bits.deserialize(rest))
      use <- wire.check(
        k == expected.k
        && b.len == expected.bits.len
        && count <= expected.capacity,
      )
      read_stages(f, rest, i + 1, n, [Stage(..expected, bits: b, count:), ..acc])
    }
  }
}
