import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option
import probz/space_saving.{Item} as ss
import probz/splitmix64
import vectors

fn new(m: Int) {
  let assert Ok(s) = ss.new(m)
  s
}

fn add(s, item, w) {
  let assert Ok(s) = ss.add(s, item, w)
  s
}

pub fn exact_under_capacity_test() {
  let s = new(4) |> add(<<"a">>, 5) |> add(<<"b">>, 2) |> add(<<"a">>, 1)
  assert ss.count(s, <<"a">>) == 6
  assert ss.count(s, <<"b">>) == 2
  assert ss.count(s, <<"c">>) == 0
  assert ss.top_k(s, 10) == [Item(<<"a">>, 6, 0), Item(<<"b">>, 2, 0)]
}

pub fn replacement_inherits_minimum_test() {
  let s = new(2) |> add(<<"a">>, 3) |> add(<<"b">>, 1) |> add(<<"c">>, 1)
  assert ss.get(s, <<"c">>) == Ok(Item(<<"c">>, 2, 1))
  assert ss.get(s, <<"b">>) == Error(Nil)
}

pub fn guarantees_on_skewed_stream_test() {
  let m = 50
  let #(_, stream) =
    int.range(0, 20_000, #(splitmix64.new(3), []), fn(acc, _) {
      let #(g, out) = acc
      let #(x, g) = splitmix64.below(g, 500)
      let #(y, g) = splitmix64.below(g, x + 1)
      #(g, [y, ..out])
    })
  let s =
    list.fold(stream, new(m), fn(s, x) {
      add(s, <<"k", { int.to_string(x) }:utf8>>, 1)
    })
  let truth =
    list.fold(stream, dict.new(), fn(d, x) {
      dict.upsert(d, x, fn(v) { option.unwrap(v, 0) + 1 })
    })
  let sum = list.fold(ss.top_k(s, m), 0, fn(acc, i) { acc + i.count })
  assert sum == ss.total(s)
  let min = ss.min_count(s)
  assert min <= ss.total(s) / m
  dict.each(truth, fn(x, f) {
    case ss.get(s, <<"k", { int.to_string(x) }:utf8>>) {
      Ok(e) -> {
        assert e.count >= f && e.count - e.err <= f && e.err <= min
      }
      Error(_) -> {
        assert f <= min
      }
    }
  })
}

pub fn serialize_round_trip_test() {
  let s =
    list.fold(["a", "b", "a", "c", "d", "a", "e"], new(3), fn(s, k) {
      add(s, <<k:utf8>>, 1)
    })
  let bytes = ss.serialize(s)
  let assert Ok(back) = ss.deserialize(bytes)
  assert ss.serialize(back) == bytes
  assert ss.top_k(back, 3) == ss.top_k(s, 3)
  // The restored summary evicts the same entry next.
  let a = add(s, <<"z">>, 1)
  let b = add(back, <<"z">>, 1)
  assert ss.serialize(a) == ss.serialize(b)
}

pub fn vectors_test() {
  let doc = vectors.load("space_saving")
  let s =
    int.range(0, 400, new(8), fn(s, t) {
      add(s, vectors.item(t * t % 20), t % 3 + 1)
    })
  assert ss.total(s) == vectors.get(doc, ["total"], decode.int)
  let item = {
    use key <- decode.field("key", decode.string)
    use count <- decode.field("count", decode.int)
    use err <- decode.field("err", decode.int)
    decode.success(Item(<<key:utf8>>, count, err))
  }
  assert ss.top_k(s, 8) == vectors.get(doc, ["top"], decode.list(item))
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert ss.serialize(s) == bytes
  let assert Ok(back) = ss.deserialize(bytes)
  assert ss.serialize(back) == bytes
}
