//// Space-Saving: streaming top-k / heavy hitters with m counters.
//// SPEC.md §5.8.
////
//// Monitors at most m items. An unmonitored item replaces the entry with the
//// smallest count, inheriting that count as its error. Guarantees (paper
//// Lemmas 1–3): Σ count = N, the minimum count is at most N / m, and every
//// monitored item satisfies true ≤ count ≤ true + error with error ≤ min.
//// With m = ⌈1/ε⌉ every item more frequent than ε·N is monitored.
////
//// Ties are broken deterministically: the evicted entry is the one with the
//// smallest (count, seq), where seq is a global update counter.
////
//// - Ahmed Metwally, Divyakant Agrawal, Amr El Abbadi, "Efficient
////   Computation of Frequent and Top-k Elements in Data Streams", ICDT 2005,
////   LNCS 3363, pp. 398–412, §3–4. <https://doi.org/10.1007/978-3-540-30570-5_27>

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import iv
import probz/internal/heap.{type Heap}
import probz/internal/u64
import probz/internal/wire
import probz/serde

pub opaque type SpaceSaving {
  SpaceSaving(
    capacity: Int,
    /// Entries in slot order.
    entries: iv.Array(Entry),
    index: Dict(BitArray, Int),
    /// (count, seq) → slot. Stale nodes (seq no longer current) are skipped.
    heap: Heap(Int),
    heap_size: Int,
    total: Int,
    seq: Int,
  )
}

type Entry {
  Entry(key: BitArray, count: Int, err: Int, seq: Int)
}

/// One monitored item. `count - err` is a lower bound on the true count.
pub type Item {
  Item(key: BitArray, count: Int, err: Int)
}

pub type Error {
  InvalidParameters
  /// A count or the total would exceed 2^64 − 1.
  Overflow
}

/// A summary with `capacity` counters (1 ≤ m < 2^32).
pub fn new(capacity m: Int) -> Result(SpaceSaving, Error) {
  case m > 0 && m < 0x100000000 {
    False -> Error(InvalidParameters)
    True ->
      Ok(SpaceSaving(
        capacity: m,
        entries: iv.new(),
        index: dict.new(),
        heap: heap.new(),
        heap_size: 0,
        total: 0,
        seq: 0,
      ))
  }
}

/// Add `amount` (≥ 0) occurrences of `item`.
pub fn add(
  ss: SpaceSaving,
  item: BitArray,
  amount: Int,
) -> Result(SpaceSaving, Error) {
  let total = ss.total + amount
  let seq = ss.seq + 1
  case amount {
    0 -> Ok(ss)
    _ if amount < 0 -> Error(InvalidParameters)
    _ if total > u64.mask -> Error(Overflow)
    _ ->
      case dict.get(ss.index, item) {
        Ok(slot) -> {
          let assert Ok(e) = iv.get(ss.entries, slot)
          let count = e.count + amount
          case count > u64.mask {
            True -> Error(Overflow)
            False -> Ok(put(ss, slot, Entry(..e, count:, seq:), total, seq))
          }
        }
        Error(_) ->
          case iv.size(ss.entries) < ss.capacity {
            True -> {
              let slot = iv.size(ss.entries)
              let ss =
                SpaceSaving(
                  ..ss,
                  entries: iv.append(ss.entries, Entry(item, 0, 0, 0)),
                  index: dict.insert(ss.index, item, slot),
                )
              Ok(put(ss, slot, Entry(item, amount, 0, seq), total, seq))
            }
            False -> {
              // Replacement: evict the entry with the smallest (count, seq).
              let #(ss, slot, victim) = pop_min(ss)
              let count = victim.count + amount
              case count > u64.mask {
                True -> Error(Overflow)
                False -> {
                  let index =
                    ss.index
                    |> dict.delete(victim.key)
                    |> dict.insert(item, slot)
                  Ok(put(
                    SpaceSaving(..ss, index:),
                    slot,
                    Entry(item, count, victim.count, seq),
                    total,
                    seq,
                  ))
                }
              }
            }
          }
      }
  }
}

fn put(
  ss: SpaceSaving,
  slot: Int,
  e: Entry,
  total: Int,
  seq: Int,
) -> SpaceSaving {
  SpaceSaving(
    ..ss,
    entries: iv.try_set(ss.entries, slot, e),
    heap: heap.insert(ss.heap, #(e.count, e.seq), slot),
    heap_size: ss.heap_size + 1,
    total:,
    seq:,
  )
  |> compact
}

/// The current minimum entry; drops stale heap nodes on the way.
fn pop_min(ss: SpaceSaving) -> #(SpaceSaving, Int, Entry) {
  let assert Ok(#(#(_, seq), slot)) = heap.find_min(ss.heap)
  let assert Ok(e) = iv.get(ss.entries, slot)
  let rest =
    SpaceSaving(
      ..ss,
      heap: heap.delete_min(ss.heap),
      heap_size: ss.heap_size - 1,
    )
  case e.seq == seq {
    True -> #(rest, slot, e)
    False -> pop_min(rest)
  }
}

/// Rebuild the heap from the live entries once stale nodes dominate.
fn compact(ss: SpaceSaving) -> SpaceSaving {
  case ss.heap_size > 4 * iv.size(ss.entries) + 16 {
    False -> ss
    True -> rebuild(ss)
  }
}

fn rebuild(ss: SpaceSaving) -> SpaceSaving {
  let h =
    iv.index_fold(ss.entries, heap.new(), fn(h, e, slot) {
      heap.insert(h, #(e.count, e.seq), slot)
    })
  SpaceSaving(..ss, heap: h, heap_size: iv.size(ss.entries))
}

/// Upper bound on the item's true count: its counter if monitored, otherwise
/// the minimum counter (0 while fewer than m items are monitored).
pub fn count(ss: SpaceSaving, item: BitArray) -> Int {
  case get(ss, item) {
    Ok(i) -> i.count
    Error(_) -> min_count(ss)
  }
}

/// The monitored entry for an item.
pub fn get(ss: SpaceSaving, item: BitArray) -> Result(Item, Nil) {
  use slot <- result.try(dict.get(ss.index, item))
  use e <- result.map(iv.get(ss.entries, slot))
  Item(e.key, e.count, e.err)
}

/// The smallest counter once all m counters are in use, else 0.
pub fn min_count(ss: SpaceSaving) -> Int {
  case iv.size(ss.entries) < ss.capacity {
    True -> 0
    False -> iv.fold(ss.entries, u64.mask, fn(m, e) { int.min(m, e.count) })
  }
}

/// The k entries with the largest counts, by count descending then key
/// ascending.
pub fn top_k(ss: SpaceSaving, k: Int) -> List(Item) {
  ss.entries
  |> iv.to_list
  |> list.map(fn(e) { Item(e.key, e.count, e.err) })
  |> list.sort(fn(a, b) {
    case int.compare(b.count, a.count) {
      order.Eq -> bit_array.compare(a.key, b.key)
      o -> o
    }
  })
  |> list.take(k)
}

/// N: the sum of all added amounts.
pub fn total(ss: SpaceSaving) -> Int {
  ss.total
}

/// Number of monitored items.
pub fn size(ss: SpaceSaving) -> Int {
  iv.size(ss.entries)
}

pub fn clear(ss: SpaceSaving) -> SpaceSaving {
  let assert Ok(empty) = new(ss.capacity)
  empty
}

/// Wire body (tag 8): u32 m, u64 N, u64 S, u32 n, then n entries in slot
/// order: bytes key, u64 count, u64 error, u64 seq.
pub fn serialize(ss: SpaceSaving) -> BitArray {
  bit_array.concat([
    wire.header(serde.SpaceSaving),
    <<
      { ss.capacity }:little-size(32),
      { ss.total }:little-size(64),
      { ss.seq }:little-size(64),
      { iv.size(ss.entries) }:little-size(32),
    >>,
    ..iv.to_list(
      iv.map(ss.entries, fn(e) {
        <<
          wire.bytes_field(e.key):bits,
          { e.count }:little-size(64),
          { e.err }:little-size(64),
          { e.seq }:little-size(64),
        >>
      }),
    )
  ])
}

pub fn deserialize(bytes: BitArray) -> Result(SpaceSaving, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.SpaceSaving))
  use #(m, rest) <- result.try(wire.u32(rest))
  use #(total, rest) <- result.try(wire.u64(rest))
  use #(seq, rest) <- result.try(wire.u64(rest))
  use #(n, rest) <- result.try(wire.u32(rest))
  use ss <- result.try(new(m) |> result.replace_error(serde.InvalidData))
  use <- wire.check(n <= m && n * 28 <= bit_array.byte_size(rest))
  use #(entries, rest) <- result.try(
    wire.many(rest, n, fn(input) {
      use #(key, rest) <- result.try(wire.bytes(input))
      use #(count, rest) <- result.try(wire.u64(rest))
      use #(err, rest) <- result.try(wire.u64(rest))
      use #(s, rest) <- result.try(wire.u64(rest))
      use <- wire.check(err <= count && s <= seq)
      Ok(#(Entry(key, count, err, s), rest))
    }),
  )
  let index =
    list.index_fold(entries, dict.new(), fn(d, e, i) {
      dict.insert(d, e.key, i)
    })
  let sum = list.fold(entries, 0, fn(s, e) { s + e.count })
  use <- wire.check(dict.size(index) == n && sum == total)
  let entries = iv.from_list(entries)
  wire.finish(rest, rebuild(SpaceSaving(..ss, entries:, index:, total:, seq:)))
}
