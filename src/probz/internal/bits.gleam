//// Fixed-size bit array stored as `u64` words in a persistent array.
////
//// Bit `i` lives in word `i / 64` at bit position `i % 64` (LSB first). Bits
//// past `len` in the last word are always zero. This layout is the wire
//// format of SPEC.md §3.1.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import iv
import probz/internal/u64
import probz/internal/wire
import probz/serde.{type DecodeError}

pub type Bits {
  Bits(words: iv.Array(Int), len: Int)
}

pub fn word_count(len: Int) -> Int {
  { len + 63 } / 64
}

pub fn new(len: Int) -> Bits {
  Bits(words: iv.repeat(0, word_count(len)), len:)
}

fn mask(i: Int) -> Int {
  int.bitwise_shift_left(1, i % 64)
}

fn word(b: Bits, w: Int) -> Int {
  iv.get_or_default(b.words, w, 0)
}

pub fn is_set(b: Bits, i: Int) -> Bool {
  int.bitwise_and(word(b, i / 64), mask(i)) != 0
}

pub fn set(b: Bits, i: Int) -> Bits {
  let m = mask(i)
  Bits(..b, words: iv.try_update(b.words, i / 64, int.bitwise_or(_, m)))
}

pub fn unset(b: Bits, i: Int) -> Bits {
  let m = u64.not(mask(i))
  Bits(..b, words: iv.try_update(b.words, i / 64, int.bitwise_and(_, m)))
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
  bit_array.concat([
    <<{ b.len }:little-size(64)>>,
    ..iv.to_list(iv.map(b.words, fn(w) { <<w:little-size(64)>> }))
  ])
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
  Ok(#(Bits(words: iv.from_list(words), len:), rest))
}
