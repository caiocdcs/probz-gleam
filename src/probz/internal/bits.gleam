//// Fixed-size bit array in a persistent array of 32-bit words.
////
//// Bit `i` lives in word `i / 32` at bit position `i % 32` (LSB first), so
//// every word is a BEAM small integer: 64-bit words with a high bit set would
//// be heap-allocated bignums, and every update would allocate. Bits past `len`
//// are always zero.
////
//// On the wire (SPEC.md §3.1) the array is `ceil(len / 64)` u64 words: word j
//// is internal words 2j (low half) and 2j + 1 (high half).

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import iv
import probz/internal/u64
import probz/internal/wire
import probz/serde.{type DecodeError}

const word_bits = 32

pub type Bits {
  Bits(words: iv.Array(Int), len: Int)
}

/// Number of u64 words on the wire.
pub fn word_count(len: Int) -> Int {
  { len + 63 } / 64
}

fn internal_words(len: Int) -> Int {
  { len + word_bits - 1 } / word_bits
}

pub fn new(len: Int) -> Bits {
  Bits(words: iv.repeat(0, internal_words(len)), len:)
}

fn mask(i: Int) -> Int {
  int.bitwise_shift_left(1, i % word_bits)
}

pub fn is_set(b: Bits, i: Int) -> Bool {
  int.bitwise_and(iv.get_or_default(b.words, i / word_bits, 0), mask(i)) != 0
}

pub fn set(b: Bits, i: Int) -> Bits {
  let m = mask(i)
  Bits(..b, words: iv.try_update(b.words, i / word_bits, int.bitwise_or(_, m)))
}

pub fn unset(b: Bits, i: Int) -> Bits {
  let m = int.bitwise_exclusive_or(mask(i), u64.mask32)
  Bits(..b, words: iv.try_update(b.words, i / word_bits, int.bitwise_and(_, m)))
}

pub fn count_set(b: Bits) -> Int {
  iv.fold(b.words, 0, fn(acc, w) { acc + u64.popcount(w) })
}

pub fn clear(b: Bits) -> Bits {
  new(b.len)
}

/// Bitwise OR. Lengths must match.
pub fn union(a: Bits, b: Bits) -> Bits {
  Bits(..a, words: iv.map2(a.words, b.words, int.bitwise_or))
}

pub fn serialize(b: Bits) -> BitArray {
  let pairs =
    b.words
    |> iv.to_list
    |> list.sized_chunk(2)
    |> list.map(fn(pair) {
      case pair {
        [lo, hi] -> <<lo:little-size(32), hi:little-size(32)>>
        [lo] -> <<lo:little-size(32), 0:size(32)>>
        _ -> <<>>
      }
    })
  bit_array.concat([<<{ b.len }:little-size(64)>>, ..pairs])
}

pub fn deserialize(input: BitArray) -> Result(#(Bits, BitArray), DecodeError) {
  use #(len, rest) <- result.try(wire.u64(input))
  let n = word_count(len)
  // Each word takes 8 bytes; refuse lengths the input cannot hold.
  use <- wire.check(bit_array.byte_size(rest) >= n * 8)
  use #(words, rest) <- result.try(wire.many(rest, n, wire.u64))
  // Bits beyond `len` must be zero.
  let tail_ok = case len % 64, list.last(words) {
    0, _ -> True
    r, Ok(last) -> int.bitwise_shift_right(last, r) == 0
    _, Error(_) -> True
  }
  use <- wire.check(tail_ok)
  let halves =
    list.flat_map(words, fn(w) {
      [int.bitwise_and(w, u64.mask32), int.bitwise_shift_right(w, 32)]
    })
    |> list.take(internal_words(len))
  Ok(#(Bits(words: iv.from_list(halves), len:), rest))
}
