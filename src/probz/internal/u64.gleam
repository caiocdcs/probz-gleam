//// Wrapping unsigned 64-bit arithmetic on top of Gleam's arbitrary-precision
//// integers (Erlang target).

import gleam/int

pub const mask = 0xFFFFFFFFFFFFFFFF

pub const mask32 = 0xFFFFFFFF

pub fn wrap(x: Int) -> Int {
  int.bitwise_and(x, mask)
}

pub fn add(a: Int, b: Int) -> Int {
  int.bitwise_and(a + b, mask)
}

pub fn sub(a: Int, b: Int) -> Int {
  int.bitwise_and(a - b, mask)
}

pub fn mul(a: Int, b: Int) -> Int {
  int.bitwise_and(a * b, mask)
}

pub fn xor(a: Int, b: Int) -> Int {
  int.bitwise_exclusive_or(a, b)
}

pub fn and(a: Int, b: Int) -> Int {
  int.bitwise_and(a, b)
}

pub fn or(a: Int, b: Int) -> Int {
  int.bitwise_or(a, b)
}

pub fn shr(a: Int, n: Int) -> Int {
  int.bitwise_shift_right(a, n)
}

/// Left shift, truncated to 64 bits.
pub fn shl(a: Int, n: Int) -> Int {
  int.bitwise_and(int.bitwise_shift_left(a, n), mask)
}

pub fn rotl(a: Int, n: Int) -> Int {
  int.bitwise_or(shl(a, n), int.bitwise_shift_right(a, 64 - n))
}

/// Bitwise NOT within 64 bits.
pub fn not(a: Int) -> Int {
  int.bitwise_exclusive_or(a, mask)
}

/// Number of set bits.
pub fn popcount(x: Int) -> Int {
  popcount_loop(x, 0)
}

fn popcount_loop(x: Int, acc: Int) -> Int {
  case x {
    0 -> acc
    _ -> popcount_loop(int.bitwise_and(x, x - 1), acc + 1)
  }
}

/// Number of leading zero bits in a value of `width` bits (`width` if zero).
pub fn leading_zeros(x: Int, width: Int) -> Int {
  width - bit_length(x)
}

/// Number of trailing zero bits (`width` if zero).
pub fn trailing_zeros(x: Int, width: Int) -> Int {
  case x {
    0 -> width
    _ -> bit_length(int.bitwise_and(x, -x)) - 1
  }
}

/// Position of the highest set bit plus one (0 for 0).
pub fn bit_length(x: Int) -> Int {
  bit_length_loop(x, 0)
}

fn bit_length_loop(x: Int, acc: Int) -> Int {
  case x >= 0x100000000 {
    True -> bit_length_loop(int.bitwise_shift_right(x, 32), acc + 32)
    False ->
      case x {
        0 -> acc
        _ -> bit_length_loop(int.bitwise_shift_right(x, 1), acc + 1)
      }
  }
}
