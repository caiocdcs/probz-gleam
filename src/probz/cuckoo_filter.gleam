//// Cuckoo filter: set membership with deletion, storing a short fingerprint
//// of each item in one of two candidate buckets. SPEC.md §5.4.
////
//// With f-bit fingerprints and b slots per bucket, the false-positive rate is
//// at most 2b / 2^f (paper Eq. 5). When an insert runs out of kicks the last
//// displaced fingerprint goes to a one-entry victim cache (as in the
//// reference implementation), so no stored item is ever lost; further adds
//// then fail with `Full` until a remove frees a slot. Random choices come
//// from a seeded SplitMix64 (SPEC.md §2.3), so results are reproducible.
////
//// - Bin Fan, David G. Andersen, Michael Kaminsky, Michael D. Mitzenmacher,
////   "Cuckoo Filter: Practically Better Than Bloom", CoNEXT 2014, pp. 75–88:
////   §3.1–3.3, Algorithms 1–2, Eq. (5). <https://doi.org/10.1145/2674005.2674994>
//// - Reference implementation (victim cache, AltIndex, sizing):
////   <https://github.com/efficient/cuckoofilter>

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import iv
import probz/hash
import probz/internal/math
import probz/internal/u64
import probz/internal/wire
import probz/serde
import probz/splitmix64.{type SplitMix64}

/// Paper Algorithm 1, MaxNumKicks.
pub const max_kicks = 500

pub opaque type CuckooFilter {
  CuckooFilter(
    /// `buckets * b` slots; 0 means empty.
    slots: iv.Array(Int),
    buckets: Int,
    b: Int,
    f: Int,
    /// Stored fingerprints, including the victim.
    len: Int,
    victim: Option(#(Int, Int)),
    rng: SplitMix64,
  )
}

pub type Error {
  InvalidParameters
  /// The victim cache is occupied: remove something first.
  Full
}

/// A filter for `capacity` items: the next power of two ≥ max(1, capacity /
/// b) buckets, doubled if that would mean a load above 96%.
/// `fingerprint_bits` is 4–32 (16 is a good default), `bucket_size` 1–8
/// (the paper recommends 4).
pub fn new(
  capacity capacity: Int,
  fingerprint_bits f: Int,
  bucket_size b: Int,
  seed seed: Int,
) -> Result(CuckooFilter, Error) {
  case capacity > 0 && b >= 1 && b <= 8 {
    False -> Error(InvalidParameters)
    True -> {
      let buckets = next_pow2(int.max(1, capacity / b))
      let buckets = case
        int.to_float(capacity) /. int.to_float(buckets * b) >. 0.96
      {
        True -> buckets * 2
        False -> buckets
      }
      new_buckets(buckets:, fingerprint_bits: f, bucket_size: b, seed:)
    }
  }
}

fn next_pow2(n: Int) -> Int {
  case n <= 1 {
    True -> 1
    False -> int.bitwise_shift_left(1, u64.bit_length(n - 1))
  }
}

/// Exactly `buckets` buckets, a power of two.
pub fn new_buckets(
  buckets buckets: Int,
  fingerprint_bits f: Int,
  bucket_size b: Int,
  seed seed: Int,
) -> Result(CuckooFilter, Error) {
  let valid =
    buckets > 0
    && buckets <= u64.mask
    && int.bitwise_and(buckets, buckets - 1) == 0
    && f >= 4
    && f <= 32
    && b >= 1
    && b <= 8
  case valid {
    False -> Error(InvalidParameters)
    True ->
      Ok(CuckooFilter(
        slots: iv.repeat(0, buckets * b),
        buckets:,
        b:,
        f:,
        len: 0,
        victim: None,
        rng: splitmix64.new(seed),
      ))
  }
}

/// fp = (h >> 32) mod 2^f, 0 mapped to 1; i1 = (h mod 2^32) mod buckets.
fn locate(filter: CuckooFilter, h: Int) -> #(Int, Int, Int) {
  let fp =
    int.bitwise_and(u64.shr(h, 32), int.bitwise_shift_left(1, filter.f) - 1)
  let fp = case fp {
    0 -> 1
    _ -> fp
  }
  let i1 = int.bitwise_and(h, u64.mask32) % filter.buckets
  #(i1, alt_index(filter, i1, fp), fp)
}

/// (i XOR (fp · 0x5bd1e995 mod 2^32)) mod buckets: an involution.
fn alt_index(filter: CuckooFilter, i: Int, fp: Int) -> Int {
  let mixed = int.bitwise_and(fp * 0x5bd1e995, u64.mask32)
  int.bitwise_exclusive_or(i, mixed) % filter.buckets
}

/// The first slot index in `bucket` holding `value`.
fn find(filter: CuckooFilter, bucket: Int, value: Int) -> Result(Int, Nil) {
  find_loop(
    filter.slots,
    bucket * filter.b,
    bucket * filter.b + filter.b,
    value,
  )
}

fn find_loop(slots, i, end, value) -> Result(Int, Nil) {
  case i >= end {
    True -> Error(Nil)
    False ->
      case iv.get_or_default(slots, i, 0) == value {
        True -> Ok(i)
        False -> find_loop(slots, i + 1, end, value)
      }
  }
}

fn put(filter: CuckooFilter, slot: Int, value: Int) -> CuckooFilter {
  CuckooFilter(..filter, slots: iv.try_set(filter.slots, slot, value))
}

fn insert_into_bucket(
  filter: CuckooFilter,
  bucket: Int,
  fp: Int,
) -> Result(CuckooFilter, Nil) {
  use slot <- result.map(find(filter, bucket, 0))
  put(filter, slot, fp)
}

pub fn add(
  filter: CuckooFilter,
  item: BitArray,
) -> Result(CuckooFilter, Error) {
  add_hash(filter, hash.hash_bytes(item))
}

/// Insert a precomputed hash. Duplicates are stored again (up to 2b copies),
/// so each `add` can be undone by one `remove`.
pub fn add_hash(filter: CuckooFilter, h: Int) -> Result(CuckooFilter, Error) {
  case filter.victim {
    Some(_) -> Error(Full)
    None -> {
      let #(i1, i2, fp) = locate(filter, h)
      Ok(insert_fingerprint(filter, i1, i2, fp))
    }
  }
}

/// Algorithm 1. Always stores `fp`: in a bucket or, out of kicks, by leaving
/// the last displaced fingerprint in the victim cache.
fn insert_fingerprint(
  filter: CuckooFilter,
  b1: Int,
  b2: Int,
  fp: Int,
) -> CuckooFilter {
  let filter = CuckooFilter(..filter, len: filter.len + 1)
  case insert_into_bucket(filter, b1, fp) {
    Ok(f) -> f
    Error(_) ->
      case insert_into_bucket(filter, b2, fp) {
        Ok(f) -> f
        Error(_) -> {
          let #(coin, rng) = splitmix64.below(filter.rng, 2)
          let bucket = case coin {
            0 -> b1
            _ -> b2
          }
          kick(CuckooFilter(..filter, rng:), bucket, fp, max_kicks)
        }
      }
  }
}

fn kick(filter: CuckooFilter, bucket: Int, fp: Int, left: Int) -> CuckooFilter {
  case left {
    0 -> CuckooFilter(..filter, victim: Some(#(bucket, fp)))
    _ -> {
      let #(s, rng) = splitmix64.below(filter.rng, filter.b)
      let slot = bucket * filter.b + s
      let displaced = iv.get_or_default(filter.slots, slot, 0)
      let filter = put(CuckooFilter(..filter, rng:), slot, fp)
      let bucket = alt_index(filter, bucket, displaced)
      case insert_into_bucket(filter, bucket, displaced) {
        Ok(f) -> f
        Error(_) -> kick(filter, bucket, displaced, left - 1)
      }
    }
  }
}

pub fn contains(filter: CuckooFilter, item: BitArray) -> Bool {
  contains_hash(filter, hash.hash_bytes(item))
}

/// Algorithm 2, plus the victim cache.
pub fn contains_hash(filter: CuckooFilter, h: Int) -> Bool {
  let #(i1, i2, fp) = locate(filter, h)
  result.is_ok(find(filter, i1, fp))
  || result.is_ok(find(filter, i2, fp))
  || victim_matches(filter, i1, i2, fp)
}

fn victim_matches(filter: CuckooFilter, i1: Int, i2: Int, fp: Int) -> Bool {
  case filter.victim {
    Some(#(vb, vf)) -> vf == fp && { vb == i1 || vb == i2 }
    None -> False
  }
}

/// Remove one copy; `Error(Nil)` if the item is not present. Only remove
/// items that were added: removing a false positive deletes another item.
pub fn remove(
  filter: CuckooFilter,
  item: BitArray,
) -> Result(CuckooFilter, Nil) {
  remove_hash(filter, hash.hash_bytes(item))
}

pub fn remove_hash(filter: CuckooFilter, h: Int) -> Result(CuckooFilter, Nil) {
  let #(i1, i2, fp) = locate(filter, h)
  let slot = result.lazy_or(find(filter, i1, fp), fn() { find(filter, i2, fp) })
  case slot {
    Ok(slot) -> {
      let filter = put(filter, slot, 0)
      Ok(reinsert_victim(CuckooFilter(..filter, len: filter.len - 1)))
    }
    Error(_) ->
      case victim_matches(filter, i1, i2, fp) {
        True -> Ok(CuckooFilter(..filter, victim: None, len: filter.len - 1))
        False -> Error(Nil)
      }
  }
}

/// After a delete frees a slot, re-run the insert for the victim.
fn reinsert_victim(filter: CuckooFilter) -> CuckooFilter {
  case filter.victim {
    None -> filter
    Some(#(vb, vf)) -> {
      let filter = CuckooFilter(..filter, victim: None, len: filter.len - 1)
      insert_fingerprint(filter, vb, alt_index(filter, vb, vf), vf)
    }
  }
}

/// Exact number of stored fingerprints.
pub fn count(filter: CuckooFilter) -> Int {
  filter.len
}

/// Fraction of slots in use.
pub fn load_factor(filter: CuckooFilter) -> Float {
  int.to_float(filter.len) /. int.to_float(filter.buckets * filter.b)
}

/// Upper bound on the false-positive rate, 2b / 2^f (paper Eq. 5).
pub fn fp_rate_bound(filter: CuckooFilter) -> Float {
  2.0 *. int.to_float(filter.b) /. math.pow(2.0, int.to_float(filter.f))
}

/// True while the victim cache is occupied: `add` fails with `Full` until a
/// `remove` makes room.
pub fn is_full(filter: CuckooFilter) -> Bool {
  option.is_some(filter.victim)
}

pub fn bucket_count(filter: CuckooFilter) -> Int {
  filter.buckets
}

pub fn clear(filter: CuckooFilter) -> CuckooFilter {
  CuckooFilter(
    ..filter,
    slots: iv.repeat(0, filter.buckets * filter.b),
    len: 0,
    victim: None,
  )
}

/// Wire body (tag 4): u8 f, u8 b, u64 buckets, u64 count, u64 PRNG state, u8
/// victim flag, u64 victim bucket, victim fingerprint, then buckets·b
/// fingerprints, each little-endian in ceil(f / 8) bytes.
pub fn serialize(filter: CuckooFilter) -> BitArray {
  let size = { filter.f + 7 } / 8 * 8
  let #(flag, vb, vf) = case filter.victim {
    Some(#(vb, vf)) -> #(1, vb, vf)
    None -> #(0, 0, 0)
  }
  bit_array.concat([
    wire.header(serde.CuckooFilter),
    <<
      { filter.f },
      { filter.b },
      { filter.buckets }:little-size(64),
      { filter.len }:little-size(64),
      { filter.rng.state }:little-size(64),
      flag,
      vb:little-size(64),
      vf:little-size(size),
    >>,
    ..iv.to_list(iv.map(filter.slots, fn(s) { <<s:little-size(size)>> }))
  ])
}

pub fn deserialize(bytes: BitArray) -> Result(CuckooFilter, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.CuckooFilter))
  use #(f, rest) <- result.try(wire.u8(rest))
  use #(b, rest) <- result.try(wire.u8(rest))
  use #(buckets, rest) <- result.try(wire.u64(rest))
  use filter <- result.try(
    new_buckets(buckets:, fingerprint_bits: f, bucket_size: b, seed: 0)
    |> result.replace_error(serde.InvalidData),
  )
  let size = { f + 7 } / 8 * 8
  let fp_max = int.bitwise_shift_left(1, f)
  let read_fp = fn(input) {
    use #(x, rest) <- result.try(wire.uint(input, size))
    use <- wire.check(x < fp_max)
    Ok(#(x, rest))
  }
  use #(len, rest) <- result.try(wire.u64(rest))
  use #(state, rest) <- result.try(wire.u64(rest))
  use #(flag, rest) <- result.try(wire.u8(rest))
  use #(vb, rest) <- result.try(wire.u64(rest))
  use #(vf, rest) <- result.try(read_fp(rest))
  use <- wire.check(flag <= 1 && vb < buckets && { flag == 0 || vf != 0 })
  let n = buckets * b
  use <- wire.check(bit_array.byte_size(rest) >= n * size / 8)
  use #(slots, rest) <- result.try(wire.many(rest, n, read_fp))
  let stored = list.count(slots, fn(s) { s != 0 }) + flag
  use <- wire.check(stored == len)
  let victim = case flag {
    1 -> Some(#(vb, vf))
    _ -> None
  }
  wire.finish(
    rest,
    CuckooFilter(
      ..filter,
      slots: iv.from_list(slots),
      len:,
      victim:,
      rng: splitmix64.SplitMix64(state:),
    ),
  )
}
