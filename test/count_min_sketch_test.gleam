import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option
import probz/count_min_sketch.{Conservative, Standard} as cms
import probz/hash
import probz/splitmix64
import vectors

fn new(w, d, bits, update) {
  let assert Ok(s) = cms.new(w, d, bits, update)
  s
}

fn add(s, item, amount) {
  let assert Ok(s) = cms.add(s, item, amount)
  s
}

pub fn dimensions_test() {
  assert cms.dimensions_for_error(0.01, 0.01) == Ok(#(272, 5))
  assert cms.dimensions_for_error(0.0, 0.1) == Error(cms.InvalidParameters)
  assert cms.dimensions_for_error(0.1, 1.0) == Error(cms.InvalidParameters)
  assert cms.new(0, 1, 32, Standard) == Error(cms.InvalidParameters)
  assert cms.new(1, 1, 7, Standard) == Error(cms.InvalidParameters)
}

pub fn add_and_count_test() {
  let s =
    new(100, 4, 32, Standard)
    |> add(<<"apple">>, 4)
    |> add(<<"banana">>, 10)
  assert cms.count(s, <<"apple">>) == 4
  assert cms.count(s, <<"banana">>) == 10
  assert cms.count(s, <<"cherry">>) == 0
  assert cms.total(s) == 14
}

pub fn overflow_without_partial_updates_test() {
  let s = new(16, 3, 8, Standard) |> add(<<"x">>, 255)
  assert cms.add(s, <<"x">>, 1) == Error(cms.Overflow)
  assert cms.count(s, <<"x">>) == 255
  assert cms.total(s) == 255
}

fn zipf_stream(n: Int) -> List(Int) {
  let #(_, out) =
    int.range(0, n, #(splitmix64.new(9), []), fn(acc, _) {
      let #(g, out) = acc
      let #(x, g) = splitmix64.below(g, 1000)
      let #(y, g) = splitmix64.below(g, x + 1)
      #(g, [y, ..out])
    })
  out
}

pub fn conservative_update_test() {
  let stream = zipf_stream(20_000)
  let key = hash.hash_int(_, bytes: 8)
  let feed = fn(s) {
    list.fold(stream, s, fn(s, x) {
      let assert Ok(s) = cms.add_hash(s, key(x), 1)
      s
    })
  }
  let std = feed(new(64, 4, 32, Standard))
  let cu = feed(new(64, 4, 32, Conservative))
  assert cms.total(std) == cms.total(cu)
  let truth = list.fold(stream, dict_new(), fn(d, x) { dict_upsert(d, x) })
  let #(err_std, err_cu) =
    list.fold(dict_to_list(truth), #(0, 0), fn(acc, kv) {
      let #(x, t) = kv
      let a = cms.count_hash(std, key(x))
      let b = cms.count_hash(cu, key(x))
      assert b >= t && b <= a
      #(acc.0 + a - t, acc.1 + b - t)
    })
  assert err_cu * 3 < err_std * 2
}

fn dict_new() {
  dict.new()
}

fn dict_upsert(d, x) {
  dict.upsert(d, x, fn(v) {
    case v {
      option.Some(n) -> n + 1
      option.None -> 1
    }
  })
}

fn dict_to_list(d) {
  dict.to_list(d)
}

pub fn conservative_overflow_and_serialization_test() {
  let s = new(16, 3, 8, Conservative) |> add(<<"x">>, 200)
  assert cms.add(s, <<"x">>, 56) == Error(cms.Overflow)
  let s = add(s, <<"x">>, 55)
  assert cms.count(s, <<"x">>) == 255
  let bytes = cms.serialize(s)
  let assert <<_:bytes-size(6), 0x88, _:bits>> = bytes
  assert cms.deserialize(bytes) == Ok(s)
}

pub fn merge_equals_combined_stream_test() {
  let a = new(32, 3, 32, Standard) |> add(<<"a">>, 3) |> add(<<"b">>, 1)
  let b = new(32, 3, 32, Standard) |> add(<<"b">>, 2) |> add(<<"c">>, 5)
  let all =
    new(32, 3, 32, Standard)
    |> add(<<"a">>, 3)
    |> add(<<"b">>, 1)
    |> add(<<"b">>, 2)
    |> add(<<"c">>, 5)
  assert cms.merge(a, b) == Ok(all)
  assert cms.merge(a, new(16, 3, 32, Standard))
    == Error(cms.IncompatibleSketches)
}

pub fn vectors_test() {
  let doc = vectors.load("count_min_sketch")
  let rows =
    vectors.get(
      doc,
      ["row_columns"],
      decode.list({
        use input <- decode.field("input", decode.string)
        use cols <- decode.field("columns", decode.list(decode.int))
        decode.success(#(input, cols))
      }),
    )
  list.each(rows, fn(r) {
    let #(_, cols) =
      list.map_fold([0, 1, 2], splitmix64.new(hash.hash_string(r.0)), fn(g, _) {
        splitmix64.below(g, 16) |> fn(t) { #(t.1, t.0) }
      })
    assert cols == r.1
  })
  let feed = fn(update) {
    list.index_fold(
      vectors.items(0, 30),
      new(16, 3, 16, update),
      fn(s, item, i) { add(s, item, i + 1) },
    )
  }
  let s = feed(Standard)
  assert cms.total(s) == vectors.get(doc, ["total"], decode.int)
  assert list.map(vectors.items(0, 40), cms.count(s, _))
    == vectors.get(doc, ["counts"], decode.list(decode.int))
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert cms.serialize(s) == bytes
  assert cms.deserialize(bytes) == Ok(s)

  let cu = feed(Conservative)
  assert list.map(vectors.items(0, 40), cms.count(cu, _))
    == vectors.get(doc, ["conservative", "counts"], decode.list(decode.int))
  let bytes =
    vectors.get(doc, ["conservative", "serialized"], vectors.hex_bytes())
  assert cms.serialize(cu) == bytes
  assert cms.deserialize(bytes) == Ok(cu)
}
