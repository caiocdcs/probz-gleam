//// q-digest: quantiles and ranks over integers in [0, 2^b) with a hard
//// rank-error bound ε = b / k. SPEC.md §5.10.
////
//// A sparse complete binary tree over the universe: node 1 is the root,
//// node i has children 2i and 2i + 1, and the leaf for v is 2^b + v. Adding
//// counts at leaves and periodically folding light sibling pairs into their
//// parent (Compress, paper Algorithm 1) keeps at most about 3k nodes.
////
//// - Nisheeth Shrivastava, Chiranjeeb Buragohain, Divyakant Agrawal,
////   Subhash Suri, "Medians and Beyond: New Aggregation Techniques for Sensor
////   Networks", SenSys 2004, §3.1, Algorithms 1–2, §4.1.
////   <https://doi.org/10.1145/1031495.1031524>

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import probz/internal/u64
import probz/internal/wire
import probz/serde

pub opaque type QDigest {
  QDigest(b: Int, k: Int, nodes: Dict(Int, Int), total: Int)
}

pub type Error {
  InvalidParameters
  /// The value is not below 2^b.
  OutOfRange
  /// The total would exceed 2^64 − 1.
  Overflow
  IncompatibleDigests
  EmptyDigest
}

/// A digest over [0, 2^`log_universe`) (`log_universe` in 1–63) with
/// compression `k` ≥ 1.
pub fn new(log_universe b: Int, k k: Int) -> Result(QDigest, Error) {
  case b >= 1 && b <= 63 && k >= 1 && k < 0x100000000 {
    False -> Error(InvalidParameters)
    True -> Ok(QDigest(b:, k:, nodes: dict.new(), total: 0))
  }
}

pub fn universe(qd: QDigest) -> Int {
  int.bitwise_shift_left(1, qd.b)
}

/// Relative rank error bound ε = log₂ σ / k.
pub fn error_bound(qd: QDigest) -> Float {
  int.to_float(qd.b) /. int.to_float(qd.k)
}

pub fn add(qd: QDigest, value: Int) -> Result(QDigest, Error) {
  add_weighted(qd, value, 1)
}

/// Add `weight` copies of `value` (0 ≤ value < 2^b).
pub fn add_weighted(
  qd: QDigest,
  value: Int,
  weight: Int,
) -> Result(QDigest, Error) {
  let total = qd.total + weight
  case value >= 0 && value < universe(qd), weight {
    False, _ -> Error(OutOfRange)
    _, 0 -> Ok(qd)
    _, _ if weight < 0 -> Error(InvalidParameters)
    _, _ if total > u64.mask -> Error(Overflow)
    _, _ -> {
      let nodes =
        dict.upsert(qd.nodes, universe(qd) + value, fn(c) {
          case c {
            option.Some(c) -> c + weight
            option.None -> weight
          }
        })
      let qd = QDigest(..qd, nodes:, total:)
      case dict.size(nodes) > 6 * qd.k {
        True -> Ok(compress(qd))
        False -> Ok(qd)
      }
    }
  }
}

type Node {
  Node(id: Int, count: Int)
}

fn depth(id: Int) -> Int {
  u64.bit_length(id) - 1
}

/// Algorithm 1: from the leaf level up to the root's children, fold a
/// sibling pair into its parent when count(2j) + count(2j+1) + count(j) ≤
/// ⌊n/k⌋. Runs automatically when the digest holds more than 6k nodes.
pub fn compress(qd: QDigest) -> QDigest {
  let limit = qd.total / qd.k
  let levels =
    dict.fold(qd.nodes, dict.new(), fn(levels, id, c) {
      dict.upsert(levels, depth(id), fn(l) {
        [Node(id, c), ..option.unwrap(l, [])]
      })
    })
    |> dict.map_values(fn(_, l) {
      list.sort(l, fn(x, y) { int.compare(x.id, y.id) })
    })
  let level = fn(levels, d) { dict.get(levels, d) |> result.unwrap([]) }
  let levels =
    int.range(qd.b, 0, levels, fn(levels, d) {
      let #(kept, up) =
        fold_level(level(levels, d), level(levels, d - 1), limit, [], [])
      levels |> dict.insert(d, kept) |> dict.insert(d - 1, up)
    })
  let nodes =
    dict.fold(levels, dict.new(), fn(nodes, _, l) {
      list.fold(l, nodes, fn(nodes, n) { dict.insert(nodes, n.id, n.count) })
    })
  QDigest(..qd, nodes:)
}

/// One pass over a depth (`cur`) and its parent depth (`up`), both sorted by
/// id. Returns the kept nodes of `cur` and the new parent level, sorted.
fn fold_level(
  cur: List(Node),
  up: List(Node),
  limit: Int,
  kept: List(Node),
  new_up: List(Node),
) -> #(List(Node), List(Node)) {
  case cur {
    [] -> #(list.reverse(kept), list.append(list.reverse(new_up), up))
    [first, ..rest] -> {
      let parent = int.bitwise_shift_right(first.id, 1)
      let #(group, rest) = case rest {
        [second, ..more] if second.id / 2 == parent -> #([first, second], more)
        _ -> #([first], rest)
      }
      // Copy parent-level nodes that come before this parent.
      let #(before, up) = list.split_while(up, fn(n) { n.id < parent })
      let new_up = list.append(list.reverse(before), new_up)
      let #(cp, up) = case up {
        [p, ..more] if p.id == parent -> #(p.count, more)
        _ -> #(0, up)
      }
      let sum = list.fold(group, 0, fn(s, n) { s + n.count })
      case sum + cp <= limit {
        True ->
          fold_level(rest, up, limit, kept, [Node(parent, cp + sum), ..new_up])
        False -> {
          let up = case cp {
            0 -> up
            _ -> [Node(parent, cp), ..up]
          }
          fold_level(
            rest,
            up,
            limit,
            list.append(list.reverse(group), kept),
            new_up,
          )
        }
      }
    }
  }
}

/// `#(lo, hi)`, the value range a node covers.
fn range(qd: QDigest, id: Int) -> #(Int, Int) {
  let d = depth(id)
  let width = int.bitwise_shift_left(1, qd.b - d)
  let lo = { id - int.bitwise_shift_left(1, d) } * width
  #(lo, lo + width - 1)
}

/// Nodes in post-order: increasing range end, then smaller ranges (larger
/// ids) first.
fn sorted_nodes(qd: QDigest) -> List(#(Int, Int)) {
  dict.to_list(qd.nodes)
  |> list.map(fn(n) { #({ range(qd, n.0) }.1, n.0, n.1) })
  |> list.sort(fn(a, b) {
    case int.compare(a.0, b.0) {
      order.Eq -> int.compare(b.1, a.1)
      o -> o
    }
  })
  |> list.map(fn(n) { #(n.0, n.2) })
}

/// The smallest value whose rank exceeds q·n (§4.1): the range end of the
/// first node in post-order where the running count exceeds q·n. The rank of
/// the result is within [q·n, (q + ε)·n].
pub fn quantile(qd: QDigest, q: Float) -> Result(Int, Error) {
  case q >=. 0.0 && q <=. 1.0, qd.total {
    False, _ -> Error(InvalidParameters)
    _, 0 -> Error(EmptyDigest)
    True, _ -> {
      let target = q *. int.to_float(qd.total)
      Ok(scan(sorted_nodes(qd), target, 0))
    }
  }
}

fn scan(nodes: List(#(Int, Int)), target: Float, sum: Int) -> Int {
  case nodes {
    [] -> 0
    [#(hi, _)] -> hi
    [#(hi, c), ..rest] ->
      case int.to_float(sum + c) >. target {
        True -> hi
        False -> scan(rest, target, sum + c)
      }
  }
}

/// Lower bound on the number of values ≤ x.
pub fn rank(qd: QDigest, x: Int) -> Int {
  dict.fold(qd.nodes, 0, fn(sum, id, c) {
    case { range(qd, id) }.1 <= x {
      True -> sum + c
      False -> sum
    }
  })
}

/// Algorithm 2: add the counts of identical nodes, then compress. Both
/// digests must share σ and k.
pub fn merge(a: QDigest, b: QDigest) -> Result(QDigest, Error) {
  let total = a.total + b.total
  case a.b == b.b && a.k == b.k, total > u64.mask {
    False, _ -> Error(IncompatibleDigests)
    _, True -> Error(Overflow)
    True, False -> {
      let nodes = dict.combine(a.nodes, b.nodes, fn(x, y) { x + y })
      Ok(compress(QDigest(..a, nodes:, total:)))
    }
  }
}

pub fn count(qd: QDigest) -> Int {
  qd.total
}

pub fn node_count(qd: QDigest) -> Int {
  dict.size(qd.nodes)
}

pub fn clear(qd: QDigest) -> QDigest {
  QDigest(..qd, nodes: dict.new(), total: 0)
}

/// Wire body (tag 10): u8 log σ, u32 k, u64 n, u32 node count, then nodes
/// sorted by id ascending, each u64 id, u64 count.
pub fn serialize(qd: QDigest) -> BitArray {
  let nodes =
    dict.to_list(qd.nodes)
    |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
    |> list.map(fn(n) { <<{ n.0 }:little-size(64), { n.1 }:little-size(64)>> })
  bit_array.concat([
    wire.header(serde.QDigest),
    <<
      { qd.b },
      { qd.k }:little-size(32),
      { qd.total }:little-size(64),
      { dict.size(qd.nodes) }:little-size(32),
    >>,
    ..nodes
  ])
}

pub fn deserialize(bytes: BitArray) -> Result(QDigest, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.QDigest))
  use #(b, rest) <- result.try(wire.u8(rest))
  use #(k, rest) <- result.try(wire.u32(rest))
  use qd <- result.try(new(b, k) |> result.replace_error(serde.InvalidData))
  use #(total, rest) <- result.try(wire.u64(rest))
  use #(n, rest) <- result.try(wire.u32(rest))
  use <- wire.check(n * 16 <= bit_array.byte_size(rest))
  use #(nodes, rest) <- result.try(
    wire.many(rest, n, fn(input) {
      use #(id, rest) <- result.try(wire.u64(input))
      use #(c, rest) <- result.try(wire.u64(rest))
      Ok(#(#(id, c), rest))
    }),
  )
  let #(ok, _, sum) =
    list.fold(nodes, #(True, 0, 0), fn(acc, node) {
      let #(ok, prev, sum) = acc
      let #(id, c) = node
      #(ok && id > prev && id < 2 * universe(qd) && c > 0, id, sum + c)
    })
  use <- wire.check(ok && sum == total)
  wire.finish(rest, QDigest(..qd, nodes: dict.from_list(nodes), total:))
}
