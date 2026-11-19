import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import probz/hash
import probz/hyperloglog as hll
import vectors

fn new(p: Int) {
  let assert Ok(s) = hll.new(p)
  s
}

pub fn precision_bounds_test() {
  assert hll.new(3) == Error(hll.InvalidParameters)
  assert hll.new(19) == Error(hll.InvalidParameters)
}

pub fn empty_and_single_item_test() {
  let s = new(14)
  assert hll.cardinality(s) == 0.0
  assert float.round(hll.cardinality(hll.add(s, <<"x">>))) == 1
}

pub fn rank_uses_all_bits_test() {
  // p = 4: register 0 with all remaining bits zero gets the maximum rank.
  let s = new(4) |> hll.add_hash(0) |> hll.add_hash(0xF800000000000000)
  let assert [r0, ..] = hll.registers(s)
  let assert Ok(r15) = list.last(hll.registers(s))
  assert r0 == 61
  assert r15 == 1
}

pub fn relative_error_within_three_standard_errors_test() {
  list.each([1000, 10_000, 50_000], fn(n) {
    let s =
      int.range(0, n, new(12), fn(s, i) {
        hll.add_hash(s, hash.hash_int(i, bytes: 8))
      })
    let err =
      float.absolute_value(hll.cardinality(s) -. int.to_float(n))
      /. int.to_float(n)
    assert err <=. 3.0 *. hll.standard_error(s)
  })
}

pub fn saturated_test() {
  let s =
    int.range(0, 16, new(4), fn(s, j) {
      hll.add_hash(s, int.bitwise_shift_left(j, 60))
    })
  assert hll.cardinality(s) == hll.saturated
}

pub fn merge_equals_union_test() {
  let add = fn(s, from, to) {
    int.range(from, to, s, fn(s, i) {
      hll.add_hash(s, hash.hash_int(i, bytes: 8))
    })
  }
  let a = add(new(10), 0, 3000)
  let b = add(new(10), 2000, 6000)
  let all = add(new(10), 0, 6000)
  let assert Ok(m) = hll.merge(a, b)
  assert hll.registers(m) == hll.registers(all)
  assert hll.cardinality(m) == hll.cardinality(all)
  assert hll.merge(a, new(11)) == Error(hll.IncompatiblePrecision)
  assert hll.cardinality(hll.clear(m)) == 0.0
}

pub fn serialize_round_trip_test() {
  let s = new(6) |> hll.add(<<"a">>) |> hll.add(<<"b">>)
  let bytes = hll.serialize(s)
  assert bytes |> bit_size == { 6 + 1 + 64 } * 8
  let assert Ok(back) = hll.deserialize(bytes)
  assert back == s
  assert hll.cardinality(back) == hll.cardinality(s)
}

@external(erlang, "erlang", "bit_size")
fn bit_size(b: BitArray) -> Int

pub fn vectors_test() {
  let doc = vectors.load("hyperloglog")
  let checkpoints =
    vectors.get(
      doc,
      ["checkpoints"],
      decode.list({
        use n <- decode.field("n", decode.int)
        use c <- decode.field("cardinality", vectors.number())
        decode.success(#(n, c))
      }),
    )
  let #(s, got) =
    list.index_fold(vectors.items(0, 5000), #(new(6), []), fn(acc, item, i) {
      let s = hll.add(acc.0, item)
      case list.contains([10, 100, 1000, 5000], i + 1) {
        True -> #(s, [#(i + 1, hll.cardinality(s)), ..acc.1])
        False -> #(s, acc.1)
      }
    })
  assert list.reverse(got) == checkpoints
  assert hll.registers(s)
    == vectors.get(doc, ["registers"], vectors.byte_string())
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert hll.serialize(s) == bytes
  assert hll.deserialize(bytes) == Ok(s)
}
