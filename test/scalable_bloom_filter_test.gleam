import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/internal/bits
import probz/scalable_bloom_filter as sbf
import vectors

fn add_all(f, items) {
  list.fold(items, f, fn(f, item) {
    let assert Ok(f) = sbf.add(f, item)
    f
  })
}

pub fn new_validates_options_test() {
  assert sbf.new(0, 0.01, 2, 0.9) == Error(sbf.InvalidParameters)
  assert sbf.new(10, 0.01, 1, 0.9) == Error(sbf.InvalidParameters)
  assert sbf.new(10, 0.01, 2, 1.0) == Error(sbf.InvalidParameters)
  assert sbf.new(10, 0.0, 2, 0.9) == Error(sbf.InvalidParameters)
}

pub fn add_and_contains_test() {
  let assert Ok(f) = sbf.with_defaults(100, 0.01)
  assert !sbf.contains(f, <<"apple">>)
  let f = add_all(f, [<<"apple">>, <<"apple">>])
  assert sbf.contains(f, <<"apple">>)
  assert sbf.count(f) == 1
}

pub fn grows_by_stages_test() {
  let assert Ok(f) = sbf.with_defaults(100, 0.01)
  let f = add_all(f, vectors.items(0, 10_000))
  assert sbf.stage_count(f) == 7
  assert list.all(vectors.items(0, 10_000), sbf.contains(f, _))
  assert sbf.fp_rate_bound(f) <. 0.01
}

pub fn compound_rate_under_target_test() {
  let assert Ok(f) = sbf.with_defaults(1000, 0.01)
  let n = 20_000
  let f = add_all(f, vectors.items(0, n))
  let fp =
    int.range(0, n, 0, fn(acc, i) {
      case sbf.contains(f, <<"absent-", { int.to_string(i) }:utf8>>) {
        True -> acc + 1
        False -> acc
      }
    })
  assert int.to_float(fp) /. int.to_float(n) <. 0.01
}

pub fn clear_test() {
  let assert Ok(f) = sbf.with_defaults(5, 0.01)
  let f = add_all(f, vectors.items(0, 50))
  assert sbf.stage_count(f) > 1
  let f = sbf.clear(f)
  assert sbf.stage_count(f) == 1
  assert sbf.count(f) == 0
  assert !sbf.contains(f, vectors.item(0))
}

pub fn serialize_round_trip_test() {
  let assert Ok(f) = sbf.with_defaults(10, 0.01)
  let f = add_all(f, vectors.items(0, 40))
  assert sbf.deserialize(sbf.serialize(f)) == Ok(f)
}

pub fn vectors_test() {
  let doc = vectors.load("scalable_bloom_filter")
  let assert Ok(f) = sbf.new(20, 0.01, 2, 0.9)
  let f = add_all(f, vectors.items(0, 100))
  let stage = {
    use capacity <- decode.field("capacity", decode.int)
    use count <- decode.field("count", decode.int)
    use bit_count <- decode.field("bit_count", decode.int)
    use hash_count <- decode.field("hash_count", decode.int)
    decode.success(#(capacity, count, bit_count, hash_count))
  }
  assert list.map(sbf.stages(f), fn(s) {
      #(s.capacity, s.count, s.bits.len, s.k)
    })
    == vectors.get(doc, ["stages"], decode.list(stage))
  assert list.map(vectors.items(0, 200), sbf.contains(f, _))
    == vectors.get(doc, ["contains"], decode.list(decode.bool))
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert sbf.serialize(f) == bytes
  assert sbf.deserialize(bytes) == Ok(f)
  let _ = bits.word_count
}
