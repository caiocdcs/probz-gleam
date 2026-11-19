//// Canonical hashing shared by every probz structure. SPEC.md §2.
////
//// Every structure hashes keys with XxHash64 (seed 0) and derives its
//// indexes from that single 64-bit value, so a filter built here is
//// bit-identical to one built by any other conforming implementation.
////
//// - xxHash specification (XXH64):
////   <https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md>
//// - Adam Kirsch, Michael Mitzenmacher, "Less Hashing, Same Performance:
////   Building a Better Bloom Filter", Random Structures & Algorithms
////   33(2):187–218, 2008. <https://doi.org/10.1002/rsa.20208>

import gleam/bit_array
import gleam/int
import probz/internal/u64

const p1 = 0x9E3779B185EBCA87

const p2 = 0xC2B2AE3D27D4EB4F

const p3 = 0x165667B19E3779F9

const p4 = 0x85EBCA77C2B2AE63

const p5 = 0x27D4EB2F165667C5

/// XxHash64 of `bytes` with seed 0: the key hash `H(item)` of SPEC.md §2.1.
pub fn hash_bytes(bytes: BitArray) -> Int {
  xxh64(bytes, 0)
}

/// Hash a UTF-8 string (its bytes).
pub fn hash_string(s: String) -> Int {
  xxh64(bit_array.from_string(s), 0)
}

/// Hash an integer as `bytes` little-endian two's-complement bytes, like a
/// Zig `u32`/`i64`... key (`bytes` = 1, 2, 4 or 8).
pub fn hash_int(value: Int, bytes bytes: Int) -> Int {
  let size = bytes * 8
  hash_bytes(<<value:little-size(size)>>)
}

/// Hash a float as the little-endian bytes of its IEEE-754 binary64 bits.
pub fn hash_float(value: Float) -> Int {
  hash_bytes(<<value:little-float-size(64)>>)
}

/// Hash a bool as one byte, 0 or 1.
pub fn hash_bool(value: Bool) -> Int {
  case value {
    True -> hash_bytes(<<1>>)
    False -> hash_bytes(<<0>>)
  }
}

/// XXH64 with an explicit seed.
pub fn xxh64(bytes: BitArray, seed: Int) -> Int {
  let len = bit_array.byte_size(bytes)
  let #(acc, rest) = case len >= 32 {
    True -> {
      let #(v1, v2, v3, v4, rest) =
        stripes(
          bytes,
          u64.add(u64.add(seed, p1), p2),
          u64.add(seed, p2),
          seed,
          u64.sub(seed, p1),
        )
      let acc =
        u64.rotl(v1, 1)
        |> u64.add(u64.rotl(v2, 7))
        |> u64.add(u64.rotl(v3, 12))
        |> u64.add(u64.rotl(v4, 18))
        |> merge(v1)
        |> merge(v2)
        |> merge(v3)
        |> merge(v4)
      #(acc, rest)
    }
    False -> #(u64.add(seed, p5), bytes)
  }
  acc
  |> u64.add(len)
  |> tail(rest)
  |> avalanche
}

fn round(acc: Int, lane: Int) -> Int {
  u64.add(acc, u64.mul(lane, p2))
  |> u64.rotl(31)
  |> u64.mul(p1)
}

fn merge(acc: Int, v: Int) -> Int {
  u64.xor(acc, round(0, v))
  |> u64.mul(p1)
  |> u64.add(p4)
}

fn stripes(
  bytes: BitArray,
  v1: Int,
  v2: Int,
  v3: Int,
  v4: Int,
) -> #(Int, Int, Int, Int, BitArray) {
  case bytes {
    <<
      a:little-size(64),
      b:little-size(64),
      c:little-size(64),
      d:little-size(64),
      rest:bytes,
    >> -> stripes(rest, round(v1, a), round(v2, b), round(v3, c), round(v4, d))
    _ -> #(v1, v2, v3, v4, bytes)
  }
}

fn tail(acc: Int, bytes: BitArray) -> Int {
  case bytes {
    <<lane:little-size(64), rest:bytes>> ->
      u64.xor(acc, round(0, lane))
      |> u64.rotl(27)
      |> u64.mul(p1)
      |> u64.add(p4)
      |> tail(rest)
    <<lane:little-size(32), rest:bytes>> ->
      u64.xor(acc, u64.mul(lane, p1))
      |> u64.rotl(23)
      |> u64.mul(p2)
      |> u64.add(p3)
      |> tail(rest)
    <<byte, rest:bytes>> ->
      u64.xor(acc, u64.mul(byte, p5))
      |> u64.rotl(11)
      |> u64.mul(p1)
      |> tail(rest)
    _ -> acc
  }
}

fn avalanche(acc: Int) -> Int {
  let acc = u64.mul(u64.xor(acc, u64.shr(acc, 33)), p2)
  let acc = u64.mul(u64.xor(acc, u64.shr(acc, 29)), p3)
  u64.xor(acc, u64.shr(acc, 32))
}

/// Two 32-bit hashes derived from one 64-bit hash, for double hashing
/// (SPEC.md §2.2). `h1` is the low half; `h2` is the high half forced odd.
pub type HashPair {
  HashPair(h1: Int, h2: Int)
}

pub fn pair(h: Int) -> HashPair {
  HashPair(
    h1: int.bitwise_and(h, u64.mask32),
    h2: int.bitwise_or(int.bitwise_shift_right(h, 32), 1),
  )
}

/// The i-th derived index in `[0, m)`: `(h1 + i·h2) mod m`.
pub fn index(p: HashPair, i: Int, m: Int) -> Int {
  { p.h1 + i * p.h2 } % m
}
