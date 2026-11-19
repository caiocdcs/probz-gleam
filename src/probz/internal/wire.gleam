//// Readers and writers for the wire format (SPEC.md §3). Each reader takes
//// the remaining input and returns the value and what follows it.

import gleam/bit_array
import gleam/list
import gleam/result
import probz/serde.{type DecodeError, type Tag}

pub fn header(tag: Tag) -> BitArray {
  <<"PRBZ", serde.version, { serde.tag_to_int(tag) }>>
}

pub fn read_header(bytes: BitArray, tag: Tag) -> Result(BitArray, DecodeError) {
  case bytes {
    <<"PRBZ", v, t, rest:bits>> ->
      case v == serde.version, t == serde.tag_to_int(tag) {
        True, True -> Ok(rest)
        False, _ -> Error(serde.UnsupportedVersion)
        _, False -> Error(serde.WrongStructure)
      }
    <<m:bytes-size(4), _:bits>> if m != <<"PRBZ">> -> Error(serde.InvalidMagic)
    _ -> Error(serde.UnexpectedEnd)
  }
}

/// The input must be fully consumed.
pub fn finish(rest: BitArray, value: a) -> Result(a, DecodeError) {
  case rest {
    <<>> -> Ok(value)
    _ -> Error(serde.InvalidData)
  }
}

pub fn u8(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    <<x, rest:bits>> -> Ok(#(x, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

pub fn u16(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    <<x:little-size(16), rest:bits>> -> Ok(#(x, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

pub fn u32(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    <<x:little-size(32), rest:bits>> -> Ok(#(x, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

pub fn u64(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    <<x:little-size(64), rest:bits>> -> Ok(#(x, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

pub fn i64(bytes: BitArray) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    <<x:little-signed-size(64), rest:bits>> -> Ok(#(x, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

/// An unsigned little-endian integer of `bits` bits.
pub fn uint(
  bytes: BitArray,
  bits: Int,
) -> Result(#(Int, BitArray), DecodeError) {
  case bytes {
    <<x:little-size(bits), rest:bits>> -> Ok(#(x, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

/// A binary64 float. NaN and infinities have no BEAM representation and are
/// rejected as invalid data.
pub fn f64(bytes: BitArray) -> Result(#(Float, BitArray), DecodeError) {
  case bytes {
    <<x:little-float-size(64), rest:bits>> -> Ok(#(x, rest))
    <<_:size(64), _:bits>> -> Error(serde.InvalidData)
    _ -> Error(serde.UnexpectedEnd)
  }
}

pub fn f64_bytes(x: Float) -> BitArray {
  <<x:little-float-size(64)>>
}

/// A u32-length-prefixed byte string.
pub fn bytes(input: BitArray) -> Result(#(BitArray, BitArray), DecodeError) {
  use #(len, rest) <- result.try(u32(input))
  case rest {
    <<b:bytes-size(len), rest:bits>> -> Ok(#(b, rest))
    _ -> Error(serde.UnexpectedEnd)
  }
}

pub fn bytes_field(b: BitArray) -> BitArray {
  <<{ bit_array.byte_size(b) }:little-size(32), b:bits>>
}

/// `n` values read with `reader`, in order.
pub fn many(
  input: BitArray,
  n: Int,
  reader: fn(BitArray) -> Result(#(a, BitArray), DecodeError),
) -> Result(#(List(a), BitArray), DecodeError) {
  many_loop(input, n, reader, [])
}

fn many_loop(input, n, reader, acc) {
  case n <= 0 {
    True -> Ok(#(list.reverse(acc), input))
    False ->
      case reader(input) {
        Ok(#(x, rest)) -> many_loop(rest, n - 1, reader, [x, ..acc])
        Error(e) -> Error(e)
      }
  }
}

/// Fail with `InvalidData` unless `ok`.
pub fn check(ok: Bool, next: fn() -> Result(a, DecodeError)) {
  case ok {
    True -> next()
    False -> Error(serde.InvalidData)
  }
}
