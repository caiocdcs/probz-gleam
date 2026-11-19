//// Rank a known list of candidates by any frequency estimator, such as
//// `count_min_sketch.count` or `space_saving.count`. For a stream whose
//// heavy hitters are unknown, use `space_saving` directly.
////
//// ```gleam
//// top_k_tracker.top_k(["apple", "pear"] |> list.map(bit_array.from_string),
////   k: 1, count: count_min_sketch.count(sketch, _))
//// ```

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/order
import gleam/set

/// One ranked candidate.
pub type TopKItem {
  TopKItem(item: BitArray, frequency: Int)
}

pub type Error {
  /// `k` must be positive.
  InvalidK
}

/// The k candidates with the highest `count`, by frequency descending then
/// item bytes ascending. Duplicate candidates are counted once.
pub fn top_k(
  candidates: List(BitArray),
  k k: Int,
  count count: fn(BitArray) -> Int,
) -> Result(List(TopKItem), Error) {
  case k > 0 {
    False -> Error(InvalidK)
    True ->
      candidates
      |> list.fold(#(set.new(), []), fn(acc, c) {
        let #(seen, out) = acc
        case set.contains(seen, c) {
          True -> acc
          False -> #(set.insert(seen, c), [TopKItem(c, count(c)), ..out])
        }
      })
      |> fn(acc) { acc.1 }
      |> list.sort(compare)
      |> list.take(k)
      |> Ok
  }
}

/// Frequency descending, then item bytes ascending.
pub fn compare(a: TopKItem, b: TopKItem) -> order.Order {
  case int.compare(b.frequency, a.frequency) {
    order.Eq -> bit_array.compare(a.item, b.item)
    o -> o
  }
}
