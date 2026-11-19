import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/qdigest
import probz/splitmix64
import vectors

fn new(b, k) {
  let assert Ok(qd) = qdigest.new(b, k)
  qd
}

fn add(qd, v) {
  let assert Ok(qd) = qdigest.add(qd, v)
  qd
}

pub fn init_and_range_checks_test() {
  assert qdigest.new(0, 10) == Error(qdigest.InvalidParameters)
  assert qdigest.new(10, 0) == Error(qdigest.InvalidParameters)
  let qd = new(4, 10)
  assert qdigest.add(qd, 16) == Error(qdigest.OutOfRange)
  assert qdigest.quantile(qd, 0.5) == Error(qdigest.EmptyDigest)
}

pub fn rank_error_and_size_test() {
  let n = 10_000
  let #(_, values) =
    int.range(0, n, #(splitmix64.new(4), []), fn(acc, _) {
      let #(g, out) = acc
      let #(v, g) = splitmix64.below(g, 65_536)
      #(g, [v, ..out])
    })
  let qd = list.fold(values, new(16, 64), add) |> qdigest.compress
  assert qdigest.node_count(qd) <= 3 * 64
  let eps = qdigest.error_bound(qd)
  let sorted = list.sort(values, int.compare)
  list.each([0.1, 0.25, 0.5, 0.75, 0.9, 0.99], fn(q) {
    let assert Ok(v) = qdigest.quantile(qd, q)
    let rank = list.count(sorted, fn(x) { x <= v })
    let rq = int.to_float(rank) /. int.to_float(n)
    assert rq >=. q && rq <=. q +. eps
    assert qdigest.rank(qd, v) <= rank
  })
}

pub fn merge_test() {
  let a = int.range(0, 500, new(10, 20), add)
  let b = int.range(500, 1000, new(10, 20), add)
  let assert Ok(m) = qdigest.merge(a, b)
  assert qdigest.count(m) == 1000
  let assert Ok(median) = qdigest.quantile(m, 0.5)
  assert median >= 500 && median <= 500 + 1000 * 10 / 20
  assert qdigest.merge(a, new(10, 21)) == Error(qdigest.IncompatibleDigests)
}

pub fn serialize_round_trip_test() {
  let qd = int.range(0, 300, new(8, 4), fn(qd, i) { add(qd, i * 7 % 256) })
  assert qdigest.deserialize(qdigest.serialize(qd)) == Ok(qd)
}

pub fn vectors_test() {
  let doc = vectors.load("qdigest")
  let #(qd, _) =
    int.range(0, 600, #(new(8, 8), splitmix64.new(2)), fn(acc, _) {
      let #(qd, g) = acc
      let #(u, g) = splitmix64.below(g, 16)
      #(add(qd, u * u), g)
    })
  let qd = qdigest.compress(qd)
  assert qdigest.count(qd) == vectors.get(doc, ["total"], decode.int)
  assert qdigest.node_count(qd) == vectors.get(doc, ["node_count"], decode.int)
  let qs =
    vectors.get(
      doc,
      ["quantiles"],
      decode.list({
        use q <- decode.field("q", vectors.number())
        use v <- decode.field("value", decode.int)
        decode.success(#(q, v))
      }),
    )
  list.each(qs, fn(p) {
    assert qdigest.quantile(qd, p.0) == Ok(p.1)
  })
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert qdigest.serialize(qd) == bytes
  assert qdigest.deserialize(bytes) == Ok(qd)
}
