//// t-digest: quantile and CDF estimates for real values, accurate at the
//// tails, in at most ⌈δ⌉ + 2 centroids. SPEC.md §5.9.
////
//// This is the merging t-digest (paper Algorithm 1): points are buffered and
//// merged into the sorted centroids in batches, and a centroid may grow
//// while its span in k-space stays within 1. Two scale functions:
////
//// - `K1` (Eq. 3, default): k(q) = δ / (2π) · asin(2q − 1). Accurate across
////   all quantiles; a digest typically holds about 0.6·δ centroids.
//// - `K2` (Eq. 8): k(q) = δ / Z · ln(q / (1 − q)), Z = 4 · ln(max(N, δ) / δ)
////   + 24. 5–20× more accurate at extreme tails (p99.9, p99.99), less in the
////   middle. Deviation: the paper's Z uses N directly; clamping N to at least
////   δ keeps Z ≥ 24.
////
//// Queries interpolate linearly through the knots (0, min), (c_i, mean_i)
//// and (N, max), where c_i is the weight before centroid i plus half its own.
////
//// - Ted Dunning, Otmar Ertl, "Computing Extremely Accurate Quantiles Using
////   t-Digests", arXiv:1902.04023, 2019: Eq. 3, Eq. 8, Algorithm 1.
////   <https://arxiv.org/abs/1902.04023>

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import probz/internal/math
import probz/internal/u64
import probz/internal/wire
import probz/serde

pub type Scale {
  /// Eq. 3: balanced accuracy across all quantiles.
  K1
  /// Eq. 8: more accurate at the extreme tails, less in the middle.
  K2
}

pub type Centroid {
  Centroid(mean: Float, weight: Int)
}

pub opaque type TDigest {
  TDigest(
    compression: Float,
    scale: Scale,
    /// Sorted by (mean, weight), fully merged.
    centroids: List(Centroid),
    /// Unmerged points, newest first.
    buffer: List(Centroid),
    buffered: Int,
    buffer_limit: Int,
    max_centroids: Int,
    total: Int,
    /// Meaningless while `total` is 0.
    min: Float,
    max: Float,
  )
}

pub type Error {
  InvalidParameters
  /// Total weight would exceed 2^64 − 1.
  Overflow
  /// Quantiles and CDFs of an empty digest are undefined.
  EmptyDigest
}

/// A digest with compression δ in [10, 10000] (100 is a good default).
pub fn new(
  compression delta: Float,
  scale scale: Scale,
) -> Result(TDigest, Error) {
  case delta >=. 10.0 && delta <=. 10_000.0 {
    False -> Error(InvalidParameters)
    True -> {
      let d = math.ceil(delta)
      Ok(TDigest(
        compression: delta,
        scale:,
        centroids: [],
        buffer: [],
        buffered: 0,
        buffer_limit: 5 * d,
        max_centroids: d + 2,
        total: 0,
        min: 0.0,
        max: 0.0,
      ))
    }
  }
}

pub fn add(td: TDigest, value: Float) -> Result(TDigest, Error) {
  add_weighted(td, value, 1)
}

/// Add `value` with an integer weight ≥ 0.
pub fn add_weighted(
  td: TDigest,
  value: Float,
  weight: Int,
) -> Result(TDigest, Error) {
  let total = td.total + weight
  case weight {
    0 -> Ok(td)
    _ if weight < 0 -> Error(InvalidParameters)
    _ if total > u64.mask -> Error(Overflow)
    _ -> {
      let #(lo, hi) = case td.total {
        0 -> #(value, value)
        _ -> #(float.min(td.min, value), float.max(td.max, value))
      }
      let td =
        TDigest(
          ..td,
          total:,
          min: lo,
          max: hi,
          buffer: [Centroid(value, weight), ..td.buffer],
          buffered: td.buffered + 1,
        )
      case td.buffered >= td.buffer_limit {
        True -> Ok(flush(td))
        False -> Ok(td)
      }
    }
  }
}

fn compare(a: Centroid, b: Centroid) -> order.Order {
  case float.compare(a.mean, b.mean) {
    order.Eq -> int.compare(a.weight, b.weight)
    o -> o
  }
}

/// Merge buffered points into the centroids (Algorithm 1). Queries flush
/// implicitly; flushing explicitly saves repeating the work per query.
pub fn flush(td: TDigest) -> TDigest {
  case td.buffered {
    0 -> td
    _ -> {
      let assert [first, ..rest] =
        list.append(td.buffer, td.centroids) |> list.sort(compare)
      let n = int.to_float(td.total)
      let z = normalizer(td)
      let limit = fn(q0) { k_inverse(td, k_plus_one(td, q0, z), z) }
      let #(out, _, sigma, _, _) =
        list.fold(rest, #([], 0, first, 0.0, limit(0.0)), fn(acc, x) {
          let #(out, emitted, sigma, q0, q_limit) = acc
          let q = q0 +. int.to_float(sigma.weight + x.weight) /. n
          case q <=. q_limit || emitted + 1 == td.max_centroids {
            True -> #(out, emitted, combine(sigma, x), q0, q_limit)
            False -> {
              let q0 = q0 +. int.to_float(sigma.weight) /. n
              #([sigma, ..out], emitted + 1, x, q0, limit(q0))
            }
          }
        })
      TDigest(
        ..td,
        centroids: list.reverse([sigma, ..out]),
        buffer: [],
        buffered: 0,
      )
    }
  }
}

/// Weighted mean, computed as m₁ + (m₂ − m₁) · w₂ / (w₁ + w₂).
fn combine(a: Centroid, b: Centroid) -> Centroid {
  let w = a.weight + b.weight
  let ratio = int.to_float(b.weight) /. int.to_float(w)
  Centroid(mean: a.mean +. { b.mean -. a.mean } *. ratio, weight: w)
}

/// k₂'s Z = 4 · ln(max(N, δ) / δ) + 24 (unused by k₁).
fn normalizer(td: TDigest) -> Float {
  let n = float.max(int.to_float(td.total), td.compression)
  4.0 *. math.ln(n /. td.compression) +. 24.0
}

/// A point on the k scale, which k₂ extends to ±∞ at q = 0 and q = 1.
type K {
  NegInf
  Finite(Float)
  PosInf
}

/// k(q) + 1.
fn k_plus_one(td: TDigest, q: Float, z: Float) -> K {
  case td.scale {
    K1 ->
      Finite(
        td.compression
        /. { 2.0 *. pi }
        *. asin(float.clamp(2.0 *. q -. 1.0, -1.0, 1.0))
        +. 1.0,
      )
    K2 ->
      case q <=. 0.0, q >=. 1.0 {
        True, _ -> NegInf
        _, True -> PosInf
        _, _ -> Finite(td.compression /. z *. math.ln(q /. { 1.0 -. q }) +. 1.0)
      }
  }
}

fn k_inverse(td: TDigest, k: K, z: Float) -> Float {
  case k, td.scale {
    NegInf, _ -> 0.0
    PosInf, _ -> 1.0
    Finite(k), K1 ->
      case k >=. td.compression /. 4.0 {
        True -> 1.0
        False -> { sin(2.0 *. pi *. k /. td.compression) +. 1.0 } /. 2.0
      }
    Finite(k), K2 -> 1.0 /. { 1.0 +. math.exp(0.0 -. k *. z /. td.compression) }
  }
}

const pi = 3.141592653589793

@external(erlang, "math", "asin")
fn asin(x: Float) -> Float

@external(erlang, "math", "sin")
fn sin(x: Float) -> Float

/// The knots (t, value) of the piecewise-linear quantile function.
fn knots(td: TDigest) -> List(#(Float, Float)) {
  let #(_, inner) =
    list.fold(td.centroids, #(0.0, []), fn(acc, c) {
      let #(cum, out) = acc
      let w = int.to_float(c.weight)
      #(cum +. w, [#(cum +. w /. 2.0, c.mean), ..out])
    })
  [#(0.0, td.min), ..list.reverse([#(int.to_float(td.total), td.max), ..inner])]
}

/// Estimated value at quantile q in [0, 1].
pub fn quantile(td: TDigest, q: Float) -> Result(Float, Error) {
  case q >=. 0.0 && q <=. 1.0, td.total {
    False, _ -> Error(InvalidParameters)
    _, 0 -> Error(EmptyDigest)
    True, _ -> {
      let td = flush(td)
      let n = int.to_float(td.total)
      let t = q *. n
      case t <=. 0.0, t >=. n {
        True, _ -> Ok(td.min)
        _, True -> Ok(td.max)
        _, _ -> {
          // The first knot after (0, min) with t_i ≥ t, and the one before.
          let assert [first, ..rest] = knots(td)
          Ok(interpolate(first, rest, t))
        }
      }
    }
  }
}

fn interpolate(prev: #(Float, Float), rest, t: Float) -> Float {
  case rest {
    [] -> prev.1
    [next] -> lerp(prev, next, t)
    [next, ..more] ->
      case next.0 <. t {
        True -> interpolate(next, more, t)
        False -> lerp(prev, next, t)
      }
  }
}

fn lerp(a: #(Float, Float), b: #(Float, Float), t: Float) -> Float {
  case b.0 <=. a.0 {
    True -> b.1
    False -> a.1 +. { b.1 -. a.1 } *. { { t -. a.0 } /. { b.0 -. a.0 } }
  }
}

/// Estimated fraction of values ≤ x: the inverse of `quantile`'s
/// piecewise-linear function. Where that function is flat at x, the midpoint
/// of the flat range is returned.
pub fn cdf(td: TDigest, x: Float) -> Result(Float, Error) {
  case td.total {
    0 -> Error(EmptyDigest)
    _ -> {
      let td = flush(td)
      case x <. td.min, x >. td.max {
        True, _ -> Ok(0.0)
        _, True -> Ok(1.0)
        _, _ -> {
          let n = int.to_float(td.total)
          let assert [a, ..rest] = knots(td)
          let t_lo = case a.1 >=. x {
            True -> Ok(a.0)
            False -> Error(Nil)
          }
          let #(_, t_lo, t_hi) =
            list.fold(rest, #(a, t_lo, 0.0), fn(acc, b) {
              let #(a, t_lo, t_hi) = acc
              let t_lo = case t_lo, b.1 >=. x {
                Error(_), True ->
                  case b.1 == a.1 {
                    True -> Ok(a.0)
                    False -> Ok(inverse_lerp(a, b, x))
                  }
                _, _ -> t_lo
              }
              let t_hi = case a.1 <=. x, b.1 <=. x {
                True, True -> b.0
                True, False -> inverse_lerp(a, b, x)
                False, _ -> t_hi
              }
              #(b, t_lo, t_hi)
            })
          Ok({ result.unwrap(t_lo, n) +. t_hi } /. 2.0 /. n)
        }
      }
    }
  }
}

fn inverse_lerp(a: #(Float, Float), b: #(Float, Float), x: Float) -> Float {
  case b.1 == a.1 {
    True -> a.0
    False -> a.0 +. { b.0 -. a.0 } *. { { x -. a.1 } /. { b.1 -. a.1 } }
  }
}

/// Add every centroid and buffered point of `b` to `a`. The result uses
/// `a`'s compression.
pub fn merge(a: TDigest, b: TDigest) -> Result(TDigest, Error) {
  use td <- result.map(
    list.append(b.centroids, list.reverse(b.buffer))
    |> list.try_fold(a, fn(td, c) { add_weighted(td, c.mean, c.weight) }),
  )
  case b.total {
    0 -> td
    _ ->
      TDigest(
        ..td,
        min: float.min(td.min, b.min),
        max: float.max(td.max, b.max),
      )
  }
}

/// Total weight N.
pub fn count(td: TDigest) -> Int {
  td.total
}

/// The smallest value added. `Error(Nil)` when empty.
pub fn min(td: TDigest) -> Result(Float, Nil) {
  case td.total {
    0 -> Error(Nil)
    _ -> Ok(td.min)
  }
}

/// The largest value added. `Error(Nil)` when empty.
pub fn max(td: TDigest) -> Result(Float, Nil) {
  case td.total {
    0 -> Error(Nil)
    _ -> Ok(td.max)
  }
}

/// The merged centroids, by mean. Call `flush` first to include buffered
/// points.
pub fn centroids(td: TDigest) -> List(Centroid) {
  td.centroids
}

pub fn clear(td: TDigest) -> TDigest {
  TDigest(..td, centroids: [], buffer: [], buffered: 0, total: 0)
}

const pos_inf_bits = 0x7FF0000000000000

const neg_inf_bits = 0xFFF0000000000000

/// Wire body (tag 9): f64 δ (negative for k₂), u64 N, f64 min, f64 max, u32
/// centroid count, centroids, u32 buffer count, buffered points; each entry
/// is (f64 mean, u64 weight). Empty digests write min = +∞, max = −∞.
pub fn serialize(td: TDigest) -> BitArray {
  let delta = case td.scale {
    K1 -> td.compression
    K2 -> 0.0 -. td.compression
  }
  let extremes = case td.total {
    0 -> <<pos_inf_bits:little-size(64), neg_inf_bits:little-size(64)>>
    _ -> <<{ td.min }:little-float-size(64), { td.max }:little-float-size(64)>>
  }
  let entries = fn(cs: List(Centroid)) {
    bit_array.concat([
      <<{ list.length(cs) }:little-size(32)>>,
      ..list.map(cs, fn(c) {
        <<{ c.mean }:little-float-size(64), { c.weight }:little-size(64)>>
      })
    ])
  }
  bit_array.concat([
    wire.header(serde.TDigest),
    <<delta:little-float-size(64), { td.total }:little-size(64)>>,
    extremes,
    entries(td.centroids),
    entries(list.reverse(td.buffer)),
  ])
}

pub fn deserialize(bytes: BitArray) -> Result(TDigest, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.TDigest))
  use #(signed, rest) <- result.try(wire.f64(rest))
  let #(delta, scale) = case signed <. 0.0 {
    True -> #(0.0 -. signed, K2)
    False -> #(signed, K1)
  }
  use td <- result.try(
    new(delta, scale) |> result.replace_error(serde.InvalidData),
  )
  use #(total, rest) <- result.try(wire.u64(rest))
  use #(lo, hi, rest) <- result.try(case total, rest {
    0, <<a:little-size(64), b:little-size(64), rest:bits>>
      if a == pos_inf_bits && b == neg_inf_bits
    -> Ok(#(0.0, 0.0, rest))
    _, _ -> {
      use #(lo, rest) <- result.try(wire.f64(rest))
      use #(hi, rest) <- result.try(wire.f64(rest))
      Ok(#(lo, hi, rest))
    }
  })
  use #(cs, rest) <- result.try(entries(rest, td.max_centroids))
  use #(buf, rest) <- result.try(entries(rest, td.buffer_limit))
  let sum = list.fold(list.append(cs, buf), 0, fn(s, c) { s + c.weight })
  use <- wire.check(sum == total && is_sorted(cs))
  wire.finish(
    rest,
    TDigest(
      ..td,
      centroids: cs,
      buffer: list.reverse(buf),
      buffered: list.length(buf),
      total:,
      min: lo,
      max: hi,
    ),
  )
}

fn entries(
  input: BitArray,
  cap: Int,
) -> Result(#(List(Centroid), BitArray), serde.DecodeError) {
  use #(n, rest) <- result.try(wire.u32(input))
  use <- wire.check(n <= cap)
  wire.many(rest, n, fn(input) {
    use #(mean, rest) <- result.try(wire.f64(input))
    use #(weight, rest) <- result.try(wire.u64(rest))
    use <- wire.check(weight > 0)
    Ok(#(Centroid(mean, weight), rest))
  })
}

fn is_sorted(cs: List(Centroid)) -> Bool {
  case cs {
    [a, b, ..rest] -> compare(a, b) != order.Gt && is_sorted([b, ..rest])
    _ -> True
  }
}
