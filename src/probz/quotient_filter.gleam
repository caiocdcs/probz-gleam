//// Quotient filter: a compact hash table of fingerprints that supports
//// deletion, merging and ordered iteration. SPEC.md §5.5.
////
//// A hash is split into a q-bit quotient (the canonical slot) and an r-bit
//// remainder (what is stored). Three bits per slot — is_occupied,
//// is_continuation, is_shifted — let lookups recover each remainder's
//// quotient after collisions push it right (paper §3, Figure 3). Runs are
//// kept sorted by remainder. The false-positive rate is at most n / 2^(q+r)
//// ≤ 2^-r.
////
//// - Michael A. Bender, Martin Farach-Colton, Rob Johnson, Russell Kraner,
////   Bradley C. Kuszmaul, Dzejla Medjedovic, Pablo Montes, Pradeep Shetty,
////   Richard P. Spillane, Erez Zadok, "Don't Thrash: How to Cache Your Hash
////   on Flash", PVLDB 5(11):1627–1637, 2012, §3 and Figure 3.
////   <https://doi.org/10.14778/2350229.2350275>

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import iv
import probz/hash
import probz/internal/bits.{type Bits}
import probz/internal/math
import probz/internal/wire
import probz/serde

pub opaque type QuotientFilter {
  QuotientFilter(
    q: Int,
    r: Int,
    size: Int,
    remainders: iv.Array(Int),
    occ: Bits,
    cont: Bits,
    shf: Bits,
    len: Int,
  )
}

/// A stored fingerprint.
pub type Entry {
  Entry(quotient: Int, remainder: Int)
}

pub type Error {
  InvalidParameters
  /// Every slot is in use.
  Full
  /// `merge` of filters with different q or r.
  IncompatibleFilters
}

/// A filter with 2^q slots (q in 1–63) and r-bit remainders (1–32, 8 is a
/// good default), with q + r ≤ 64.
pub fn new(q q: Int, remainder_bits r: Int) -> Result(QuotientFilter, Error) {
  case q >= 1 && q <= 63 && r >= 1 && r <= 32 && q + r <= 64 {
    False -> Error(InvalidParameters)
    True -> {
      let size = int.bitwise_shift_left(1, q)
      Ok(QuotientFilter(
        q:,
        r:,
        size:,
        remainders: iv.repeat(0, size),
        occ: bits.new(size),
        cont: bits.new(size),
        shf: bits.new(size),
        len: 0,
      ))
    }
  }
}

/// Split a hash: remainder = h mod 2^r, quotient = (h >> r) mod 2^q.
pub fn entry_for_hash(qf: QuotientFilter, h: Int) -> Entry {
  Entry(
    quotient: int.bitwise_and(int.bitwise_shift_right(h, qf.r), qf.size - 1),
    remainder: int.bitwise_and(h, int.bitwise_shift_left(1, qf.r) - 1),
  )
}

pub fn slot_count(qf: QuotientFilter) -> Int {
  qf.size
}

/// Number of distinct fingerprints stored.
pub fn count(qf: QuotientFilter) -> Int {
  qf.len
}

pub fn load_factor(qf: QuotientFilter) -> Float {
  int.to_float(qf.len) /. int.to_float(qf.size)
}

/// Upper bound on the false-positive rate at the current load.
pub fn fp_rate_bound(qf: QuotientFilter) -> Float {
  load_factor(qf) /. math.pow(2.0, int.to_float(qf.r))
}

// -- slots ---------------------------------------------------------------

fn incr(qf: QuotientFilter, i: Int) -> Int {
  int.bitwise_and(i + 1, qf.size - 1)
}

fn decr(qf: QuotientFilter, i: Int) -> Int {
  int.bitwise_and(i - 1, qf.size - 1)
}

fn rem(qf: QuotientFilter, i: Int) -> Int {
  iv.get_or_default(qf.remainders, i, 0)
}

fn is_occupied(qf: QuotientFilter, i: Int) -> Bool {
  bits.is_set(qf.occ, i)
}

fn is_continuation(qf: QuotientFilter, i: Int) -> Bool {
  bits.is_set(qf.cont, i)
}

fn is_shifted(qf: QuotientFilter, i: Int) -> Bool {
  bits.is_set(qf.shf, i)
}

fn is_empty(qf: QuotientFilter, i: Int) -> Bool {
  !is_occupied(qf, i) && !is_continuation(qf, i) && !is_shifted(qf, i)
}

fn set_bit(b: Bits, i: Int, on: Bool) -> Bits {
  case on {
    True -> bits.set(b, i)
    False -> bits.unset(b, i)
  }
}

fn set_occupied(qf: QuotientFilter, i: Int, on: Bool) -> QuotientFilter {
  QuotientFilter(..qf, occ: set_bit(qf.occ, i, on))
}

fn write(
  qf: QuotientFilter,
  i: Int,
  remainder: Int,
  cont: Bool,
  shifted: Bool,
) -> QuotientFilter {
  QuotientFilter(
    ..qf,
    remainders: iv.try_set(qf.remainders, i, remainder),
    cont: set_bit(qf.cont, i, cont),
    shf: set_bit(qf.shf, i, shifted),
  )
}

/// Next slot after `i` (circular) whose occupied bit is set.
fn next_occupied(qf: QuotientFilter, i: Int) -> Int {
  let b = incr(qf, i)
  case is_occupied(qf, b) {
    True -> b
    False -> next_occupied(qf, b)
  }
}

/// Slot where the run of quotient `fq` starts. Requires occupied[fq].
fn run_start(qf: QuotientFilter, fq: Int) -> Int {
  let b = cluster_start(qf, fq)
  run_start_loop(qf, b, b, fq)
}

fn cluster_start(qf: QuotientFilter, b: Int) -> Int {
  case is_shifted(qf, b) {
    True -> cluster_start(qf, decr(qf, b))
    False -> b
  }
}

fn run_start_loop(qf: QuotientFilter, b: Int, s: Int, fq: Int) -> Int {
  case b == fq {
    True -> s
    False ->
      run_start_loop(qf, next_occupied(qf, b), skip_run(qf, incr(qf, s)), fq)
  }
}

fn skip_run(qf: QuotientFilter, s: Int) -> Int {
  case is_continuation(qf, s) {
    True -> skip_run(qf, incr(qf, s))
    False -> s
  }
}

/// Scan the run starting at `s` for `fr`: `Ok(slot)` if found, otherwise
/// `Error(slot)` where it would be inserted.
fn scan_run(qf: QuotientFilter, s: Int, fr: Int) -> Result(Int, Int) {
  let r = rem(qf, s)
  case r == fr, r > fr {
    True, _ -> Ok(s)
    False, True -> Error(s)
    False, False -> {
      let next = incr(qf, s)
      case is_continuation(qf, next) {
        True -> scan_run(qf, next, fr)
        False -> Error(next)
      }
    }
  }
}

// -- operations ----------------------------------------------------------

pub fn contains(qf: QuotientFilter, item: BitArray) -> Bool {
  contains_hash(qf, hash.hash_bytes(item))
}

pub fn contains_hash(qf: QuotientFilter, h: Int) -> Bool {
  contains_entry(qf, entry_for_hash(qf, h))
}

/// Paper Figure 3.
pub fn contains_entry(qf: QuotientFilter, e: Entry) -> Bool {
  is_occupied(qf, e.quotient)
  && result.is_ok(scan_run(qf, run_start(qf, e.quotient), e.remainder))
}

/// Insert an item. Adding a fingerprint that is already present leaves the
/// filter unchanged. Fails with `Full` when every slot is in use.
pub fn add(
  qf: QuotientFilter,
  item: BitArray,
) -> Result(QuotientFilter, Error) {
  add_hash(qf, hash.hash_bytes(item))
}

pub fn add_hash(qf: QuotientFilter, h: Int) -> Result(QuotientFilter, Error) {
  add_entry(qf, entry_for_hash(qf, h))
}

pub fn add_entry(
  qf: QuotientFilter,
  e: Entry,
) -> Result(QuotientFilter, Error) {
  let fq = e.quotient
  case is_empty(qf, fq) {
    True ->
      Ok(
        QuotientFilter(
          ..write(qf, fq, e.remainder, False, False)
          |> set_occupied(fq, True),
          len: qf.len + 1,
        ),
      )
    False -> {
      let run_exists = is_occupied(qf, fq)
      // run_start needs the occupied bit; for a new run, `start` is where
      // it must begin.
      let marked = set_occupied(qf, fq, True)
      let start = run_start(marked, fq)
      let found = case run_exists {
        True -> scan_run(marked, start, e.remainder)
        False -> Error(start)
      }
      case found {
        Ok(_) -> Ok(qf)
        Error(_) if qf.len == qf.size -> Error(Full)
        Error(s) -> {
          // The new remainder heads the run if it goes first; the old head
          // then becomes a continuation.
          let head = s == start
          let marked = case head && run_exists {
            True -> QuotientFilter(..marked, cont: bits.set(marked.cont, s))
            False -> marked
          }
          let shifted = shift_right_from(marked, s)
          Ok(
            QuotientFilter(
              ..write(shifted, s, e.remainder, !head, s != fq),
              len: qf.len + 1,
            ),
          )
        }
      }
    }
  }
}

/// Move remainders in [s, first empty slot) one slot right. Occupied bits
/// stay with their slots; moved remainders are always shifted.
fn shift_right_from(qf: QuotientFilter, s: Int) -> QuotientFilter {
  shift_right_loop(qf, s, first_empty(qf, s))
}

fn first_empty(qf: QuotientFilter, i: Int) -> Int {
  case is_empty(qf, i) {
    True -> i
    False -> first_empty(qf, incr(qf, i))
  }
}

fn shift_right_loop(qf: QuotientFilter, s: Int, end: Int) -> QuotientFilter {
  case end == s {
    True -> qf
    False -> {
      let prev = decr(qf, end)
      write(qf, end, rem(qf, prev), is_continuation(qf, prev), True)
      |> shift_right_loop(s, prev)
    }
  }
}

/// Remove an item's fingerprint; `Error(Nil)` if absent. Removing a false
/// positive removes another item's fingerprint.
pub fn remove(
  qf: QuotientFilter,
  item: BitArray,
) -> Result(QuotientFilter, Nil) {
  remove_hash(qf, hash.hash_bytes(item))
}

pub fn remove_hash(qf: QuotientFilter, h: Int) -> Result(QuotientFilter, Nil) {
  remove_entry(qf, entry_for_hash(qf, h))
}

pub fn remove_entry(
  qf: QuotientFilter,
  e: Entry,
) -> Result(QuotientFilter, Nil) {
  let fq = e.quotient
  use <- bool_guard(!is_occupied(qf, fq))
  let start = run_start(qf, fq)
  case scan_run(qf, start, e.remainder) {
    Error(_) -> Error(Nil)
    Ok(s) -> {
      let was_head = s == start
      let qf = case was_head && !is_continuation(qf, incr(qf, s)) {
        True -> set_occupied(qf, fq, False)
        False -> qf
      }
      let qf = shift_left(qf, fq, was_head, fq, s, incr(qf, s), True, 0)
      Ok(QuotientFilter(..qf, len: qf.len - 1))
    }
  }
}

fn bool_guard(fail: Bool, next: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case fail {
    True -> Error(Nil)
    False -> next()
  }
}

/// Shift the following remainders left while they are shifted, tracking the
/// quotients of moved run heads to fix their is_shifted bit.
fn shift_left(
  qf: QuotientFilter,
  fq: Int,
  was_head: Bool,
  cursor: Int,
  hole: Int,
  p: Int,
  first: Bool,
  steps: Int,
) -> QuotientFilter {
  case is_shifted(qf, p) && steps < qf.size {
    False -> write(qf, hole, 0, False, False)
    True -> {
      let c = is_continuation(qf, p)
      let #(c, cursor, quotient) = case first && was_head && c, c {
        True, _ -> #(False, cursor, fq)
        False, False -> {
          let cursor = next_occupied(qf, cursor)
          #(False, cursor, cursor)
        }
        // A continuation keeps its shifted bit; the quotient is unused.
        False, True -> #(True, cursor, hole)
      }
      write(qf, hole, rem(qf, p), c, c || quotient != hole)
      |> shift_left(fq, was_head, cursor, p, incr(qf, p), False, steps + 1)
    }
  }
}

/// Every stored fingerprint, in quotient order from the first cluster start
/// in slot order.
pub fn entries(qf: QuotientFilter) -> List(Entry) {
  let begin = first_unshifted(qf, 0)
  entries_loop(qf, begin, qf.size, begin, [])
}

fn first_unshifted(qf: QuotientFilter, i: Int) -> Int {
  case i < qf.size && is_shifted(qf, i) {
    True -> first_unshifted(qf, i + 1)
    False -> i
  }
}

fn entries_loop(
  qf: QuotientFilter,
  pos: Int,
  remaining: Int,
  quotient: Int,
  acc: List(Entry),
) -> List(Entry) {
  case remaining {
    0 -> list.reverse(acc)
    _ -> {
      let p = int.bitwise_and(pos, qf.size - 1)
      case is_empty(qf, p) {
        True -> entries_loop(qf, p + 1, remaining - 1, quotient, acc)
        False -> {
          let quotient = case is_continuation(qf, p), is_shifted(qf, p) {
            True, _ -> quotient
            False, False -> p
            False, True -> next_occupied(qf, quotient)
          }
          entries_loop(qf, p + 1, remaining - 1, quotient, [
            Entry(quotient:, remainder: rem(qf, p)),
            ..acc
          ])
        }
      }
    }
  }
}

/// Insert every fingerprint of `b` into `a`. Both must have the same q and r.
pub fn merge(
  a: QuotientFilter,
  b: QuotientFilter,
) -> Result(QuotientFilter, Error) {
  case a.q == b.q && a.r == b.r {
    False -> Error(IncompatibleFilters)
    True -> list.try_fold(entries(b), a, add_entry)
  }
}

pub fn clear(qf: QuotientFilter) -> QuotientFilter {
  let assert Ok(empty) = new(qf.q, qf.r)
  empty
}

/// Wire body (tag 5): u8 q, u8 r, u64 count, 2^q remainders (each
/// little-endian in ceil(r / 8) bytes), then the occupied, continuation and
/// shifted bit arrays.
pub fn serialize(qf: QuotientFilter) -> BitArray {
  let size = { qf.r + 7 } / 8 * 8
  bit_array.concat([
    wire.header(serde.QuotientFilter),
    <<{ qf.q }, { qf.r }, { qf.len }:little-size(64)>>,
    ..list.append(
      iv.to_list(iv.map(qf.remainders, fn(x) { <<x:little-size(size)>> })),
      [bits.serialize(qf.occ), bits.serialize(qf.cont), bits.serialize(qf.shf)],
    )
  ])
}

pub fn deserialize(
  bytes: BitArray,
) -> Result(QuotientFilter, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.QuotientFilter))
  use #(q, rest) <- result.try(wire.u8(rest))
  use #(r, rest) <- result.try(wire.u8(rest))
  use #(len, rest) <- result.try(wire.u64(rest))
  use qf <- result.try(new(q, r) |> result.replace_error(serde.InvalidData))
  let width = { r + 7 } / 8 * 8
  let limit = int.bitwise_shift_left(1, r)
  use <- wire.check(bit_array.byte_size(rest) >= qf.size * width / 8)
  use #(remainders, rest) <- result.try(
    wire.many(rest, qf.size, fn(input) {
      use #(x, rest) <- result.try(wire.uint(input, width))
      use <- wire.check(x < limit)
      Ok(#(x, rest))
    }),
  )
  use #(occ, rest) <- result.try(bits.deserialize(rest))
  use #(cont, rest) <- result.try(bits.deserialize(rest))
  use #(shf, rest) <- result.try(bits.deserialize(rest))
  use <- wire.check(
    occ.len == qf.size && cont.len == qf.size && shf.len == qf.size,
  )
  let qf =
    QuotientFilter(
      ..qf,
      remainders: iv.from_list(remainders),
      occ:,
      cont:,
      shf:,
      len:,
    )
  let stored =
    int.range(0, qf.size, 0, fn(n, i) {
      case is_empty(qf, i) {
        True -> n
        False -> n + 1
      }
    })
  use <- wire.check(stored == len)
  wire.finish(rest, qf)
}
