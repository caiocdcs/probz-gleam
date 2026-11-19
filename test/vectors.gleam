//// Loading the golden vectors in testdata/vectors (SPEC.md §4).

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import simplifile

pub fn load(name: String) -> Dynamic {
  let assert Ok(text) = simplifile.read("testdata/vectors/" <> name <> ".json")
  let assert Ok(doc) = json.parse(text, decode.dynamic)
  doc
}

pub fn get(doc: Dynamic, path: List(String), decoder: Decoder(a)) -> a {
  case decode.run(doc, decode.at(path, decoder)) {
    Ok(value) -> value
    Error(errors) ->
      panic as {
        "vector field "
        <> string.join(path, ".")
        <> ": "
        <> string.inspect(errors)
      }
  }
}

/// `"0x" + 16 hex digits` as an Int.
pub fn hex64() -> Decoder(Int) {
  use s <- decode.then(decode.string)
  case int.base_parse(string.drop_start(s, 2), 16) {
    Ok(n) -> decode.success(n)
    Error(_) -> decode.failure(0, "hex64")
  }
}

/// A lowercase hex string of bytes.
pub fn hex_bytes() -> Decoder(BitArray) {
  use s <- decode.then(decode.string)
  case bit_array.base16_decode(string.uppercase(s)) {
    Ok(b) -> decode.success(b)
    Error(_) -> decode.failure(<<>>, "hex bytes")
  }
}

/// JSON numbers that may be written as integers or floats.
pub fn number() -> Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

pub fn item(i: Int) -> BitArray {
  bit_array.from_string("item-" <> int.to_string(i))
}

pub fn items(from: Int, to: Int) -> List(BitArray) {
  int.range(from, to, [], fn(acc, i) { [item(i), ..acc] }) |> list.reverse
}

pub fn hex(b: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(b))
}

/// Relative closeness, for floats computed through libm functions.
pub fn close(a: Float, b: Float, tolerance: Float) -> Bool {
  let diff = float.absolute_value(a -. b)
  diff
  <=. tolerance *. float.max(float.absolute_value(a), float.absolute_value(b))
  || diff <=. 1.0e-12
}

/// A Zig `[]u8` field, which std.json writes as a string: one code point per
/// byte.
pub fn byte_string() -> Decoder(List(Int)) {
  use s <- decode.then(decode.string)
  decode.success(
    string.to_utf_codepoints(s) |> list.map(string.utf_codepoint_to_int),
  )
}
