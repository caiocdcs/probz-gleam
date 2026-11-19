//// MinHash LSH: index sets of tokens and find those with high Jaccard
//// similarity to a query. SPEC.md §5.11.
////
//// Each set gets a signature of n = b·r MinHash values, h_i(x) = (a_i·x +
//// b_i) mod (2^61 − 1) with coefficients from SplitMix64(seed). The
//// signature is split into b bands of r rows; two sets become candidates
//// when any band hashes equal, which happens with probability
//// 1 − (1 − s^r)^b for Jaccard similarity s. Candidates are scored by the
//// fraction of equal signature entries.
////
//// - Andrei Z. Broder, "On the Resemblance and Containment of Documents",
////   SEQUENCES 1997, pp. 21–29. <https://doi.org/10.1109/SEQUEN.1997.666900>
//// - Jure Leskovec, Anand Rajaraman, Jeffrey D. Ullman, Mining of Massive
////   Datasets, Chapter 3. <http://www.mmds.org/>

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/set
import iv
import probz/hash
import probz/internal/math
import probz/internal/wire
import probz/serde
import probz/splitmix64

/// The Mersenne prime 2^61 − 1.
pub const prime = 0x1FFFFFFFFFFFFFFF

pub opaque type MinHashLsh {
  MinHashLsh(
    bands: Int,
    rows: Int,
    seed: Int,
    coeffs: List(#(Int, Int)),
    /// Insertion order.
    items: iv.Array(#(BitArray, List(Int))),
    by_id: Dict(BitArray, Int),
    /// (band, band hash) → item indexes.
    buckets: Dict(#(Int, Int), List(Int)),
  )
}

/// A query result.
pub type Candidate {
  Candidate(id: BitArray, similarity: Float)
}

pub type Error {
  InvalidParameters
  DuplicateId
  /// A signature of the wrong length.
  InvalidSignature
}

/// An index with `bands` × `rows` hash functions.
pub fn new(
  bands b: Int,
  rows r: Int,
  seed seed: Int,
) -> Result(MinHashLsh, Error) {
  case b > 0 && r > 0 && b * r < 0x100000000 {
    False -> Error(InvalidParameters)
    True -> {
      let #(_, coeffs) =
        int.range(0, b * r, #(splitmix64.new(seed), []), fn(acc, _) {
          let #(g, out) = acc
          let #(a, g) = splitmix64.below(g, prime - 1)
          let #(c, g) = splitmix64.below(g, prime)
          #(g, [#(1 + a, c), ..out])
        })
      Ok(MinHashLsh(
        bands: b,
        rows: r,
        seed:,
        coeffs: list.reverse(coeffs),
        items: iv.new(),
        by_id: dict.new(),
        buckets: dict.new(),
      ))
    }
  }
}

/// An index whose candidate threshold (1/b)^(1/r) is closest to `threshold`
/// among the factorizations b·r = `num_hashes` (ties go to the larger b).
pub fn with_threshold(
  threshold t: Float,
  num_hashes n: Int,
  seed seed: Int,
) -> Result(MinHashLsh, Error) {
  use #(b, r) <- result.try(params_for_threshold(t, n))
  new(b, r, seed)
}

/// `#(bands, rows)` for `with_threshold`.
pub fn params_for_threshold(
  threshold t: Float,
  num_hashes n: Int,
) -> Result(#(Int, Int), Error) {
  case t >. 0.0 && t <. 1.0 && n > 0 {
    False -> Error(InvalidParameters)
    True -> {
      let #(best, _) =
        int.range(1, n + 1, #(1, -1.0), fn(best, b) {
          case n % b {
            0 -> {
              let r = n / b
              let at = math.pow(1.0 /. int.to_float(b), 1.0 /. int.to_float(r))
              let diff = float.absolute_value(at -. t)
              case best.1 <. 0.0 || diff <=. best.1 {
                True -> #(b, diff)
                False -> best
              }
            }
            _ -> best
          }
        })
      Ok(#(best, n / best))
    }
  }
}

pub fn num_hashes(lsh: MinHashLsh) -> Int {
  lsh.bands * lsh.rows
}

/// The coefficient pairs `#(a_i, b_i)`, in order.
pub fn coefficients(lsh: MinHashLsh) -> List(#(Int, Int)) {
  lsh.coeffs
}

/// Probability that two sets with Jaccard similarity `s` become candidates:
/// 1 − (1 − s^r)^b.
pub fn candidate_probability(lsh: MinHashLsh, s: Float) -> Float {
  1.0
  -. math.pow(
    1.0 -. math.pow(s, int.to_float(lsh.rows)),
    int.to_float(lsh.bands),
  )
}

/// The MinHash signature of a token set: n values, each p for an empty set.
pub fn signature(lsh: MinHashLsh, tokens: List(BitArray)) -> List(Int) {
  let xs = list.map(tokens, fn(t) { hash.hash_bytes(t) % prime })
  list.map(lsh.coeffs, fn(c) {
    list.fold(xs, prime, fn(m, x) { int.min(m, { c.0 * x + c.1 } % prime) })
  })
}

/// XXH64 of band `band`'s r signature values, each as 8 little-endian bytes.
pub fn band_hash(lsh: MinHashLsh, sig: List(Int), band: Int) -> Int {
  sig
  |> list.drop(band * lsh.rows)
  |> list.take(lsh.rows)
  |> list.fold(<<>>, fn(acc, v) { <<acc:bits, v:little-size(64)>> })
  |> hash.hash_bytes
}

/// Index the token set `tokens` under the unique `id`.
pub fn add(
  lsh: MinHashLsh,
  id: BitArray,
  tokens: List(BitArray),
) -> Result(MinHashLsh, Error) {
  add_signature(lsh, id, signature(lsh, tokens))
}

pub fn add_signature(
  lsh: MinHashLsh,
  id: BitArray,
  sig: List(Int),
) -> Result(MinHashLsh, Error) {
  case list.length(sig) == num_hashes(lsh), dict.has_key(lsh.by_id, id) {
    False, _ -> Error(InvalidSignature)
    _, True -> Error(DuplicateId)
    True, False -> {
      let index = iv.size(lsh.items)
      let buckets =
        int.range(0, lsh.bands, lsh.buckets, fn(buckets, b) {
          dict.upsert(buckets, #(b, band_hash(lsh, sig, b)), fn(l) {
            [index, ..option.unwrap(l, [])]
          })
        })
      Ok(
        MinHashLsh(
          ..lsh,
          items: iv.append(lsh.items, #(id, sig)),
          by_id: dict.insert(lsh.by_id, id, index),
          buckets:,
        ),
      )
    }
  }
}

/// Items sharing at least one band with `tokens`, by estimated similarity
/// descending, then id ascending.
pub fn query(lsh: MinHashLsh, tokens: List(BitArray)) -> List(Candidate) {
  query_signature(lsh, signature(lsh, tokens))
}

pub fn query_signature(lsh: MinHashLsh, sig: List(Int)) -> List(Candidate) {
  int.range(0, lsh.bands, set.new(), fn(seen, b) {
    dict.get(lsh.buckets, #(b, band_hash(lsh, sig, b)))
    |> result.unwrap([])
    |> list.fold(seen, set.insert)
  })
  |> set.to_list
  |> list.filter_map(fn(i) { iv.get(lsh.items, i) })
  |> list.map(fn(item) { Candidate(item.0, estimate_similarity(sig, item.1)) })
  |> list.sort(fn(a, b) {
    case float.compare(b.similarity, a.similarity) {
      order.Eq -> bit_array.compare(a.id, b.id)
      o -> o
    }
  })
}

/// Estimated Jaccard similarity of two indexed items.
pub fn similarity(
  lsh: MinHashLsh,
  a: BitArray,
  b: BitArray,
) -> Result(Float, Nil) {
  use i <- result.try(dict.get(lsh.by_id, a))
  use j <- result.try(dict.get(lsh.by_id, b))
  use x <- result.try(iv.get(lsh.items, i))
  use y <- result.map(iv.get(lsh.items, j))
  estimate_similarity(x.1, y.1)
}

/// Fraction of equal signature entries.
pub fn estimate_similarity(a: List(Int), b: List(Int)) -> Float {
  let same = list.zip(a, b) |> list.count(fn(p) { p.0 == p.1 })
  int.to_float(same) /. int.to_float(list.length(a))
}

/// Number of indexed items.
pub fn size(lsh: MinHashLsh) -> Int {
  iv.size(lsh.items)
}

/// Wire body (tag 11): u32 b, u32 r, u64 seed, u32 item count, then items in
/// insertion order: bytes id, n × u64 signature. Band maps are rebuilt on
/// load.
pub fn serialize(lsh: MinHashLsh) -> BitArray {
  bit_array.concat([
    wire.header(serde.MinHashLsh),
    <<
      { lsh.bands }:little-size(32),
      { lsh.rows }:little-size(32),
      { lsh.seed }:little-size(64),
      { iv.size(lsh.items) }:little-size(32),
    >>,
    ..iv.to_list(
      iv.map(lsh.items, fn(item) {
        list.fold(item.1, wire.bytes_field(item.0), fn(acc, v) {
          <<acc:bits, v:little-size(64)>>
        })
      }),
    )
  ])
}

pub fn deserialize(bytes: BitArray) -> Result(MinHashLsh, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.MinHashLsh))
  use #(b, rest) <- result.try(wire.u32(rest))
  use #(r, rest) <- result.try(wire.u32(rest))
  use #(seed, rest) <- result.try(wire.u64(rest))
  use lsh <- result.try(
    new(b, r, seed) |> result.replace_error(serde.InvalidData),
  )
  use #(n, rest) <- result.try(wire.u32(rest))
  let n_hashes = num_hashes(lsh)
  use <- wire.check(n * { 4 + 8 * n_hashes } <= bit_array.byte_size(rest))
  use #(items, rest) <- result.try(
    wire.many(rest, n, fn(input) {
      use #(id, rest) <- result.try(wire.bytes(input))
      use #(sig, rest) <- result.try(wire.many(rest, n_hashes, wire.u64))
      use <- wire.check(list.all(sig, fn(v) { v <= prime }))
      Ok(#(#(id, sig), rest))
    }),
  )
  use lsh <- result.try(
    list.try_fold(items, lsh, fn(lsh, item) {
      add_signature(lsh, item.0, item.1)
    })
    |> result.replace_error(serde.InvalidData),
  )
  wire.finish(rest, lsh)
}
