import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import probz/splitmix64
import probz/tdigest.{type Centroid, Centroid, K1, K2}
import vectors

fn new(delta, scale) {
  let assert Ok(td) = tdigest.new(delta, scale)
  td
}

fn add_all(td, xs) {
  list.fold(xs, td, fn(td, x) {
    let assert Ok(td) = tdigest.add(td, x)
    td
  })
}

fn uniform(seed: Int, n: Int) -> List(Float) {
  let #(_, xs) =
    int.range(0, n, #(splitmix64.new(seed), []), fn(acc, _) {
      let #(g, xs) = acc
      let #(x, g) = splitmix64.next(g)
      let v =
        int.to_float(int.bitwise_shift_right(x, 11))
        *. 1.1102230246251565e-16
        *. 1000.0
      #(g, [v, ..xs])
    })
  list.reverse(xs)
}

pub fn invalid_parameters_test() {
  assert tdigest.new(9.0, K1) == Error(tdigest.InvalidParameters)
  assert tdigest.new(10_001.0, K1) == Error(tdigest.InvalidParameters)
  let td = new(100.0, K1)
  assert tdigest.quantile(td, 0.5) == Error(tdigest.EmptyDigest)
  assert tdigest.cdf(td, 0.5) == Error(tdigest.EmptyDigest)
  let td = add_all(td, [1.0])
  assert tdigest.quantile(td, 1.5) == Error(tdigest.InvalidParameters)
}

pub fn single_value_test() {
  let td = add_all(new(100.0, K1), [42.0])
  assert tdigest.quantile(td, 0.0) == Ok(42.0)
  assert tdigest.quantile(td, 0.5) == Ok(42.0)
  assert tdigest.quantile(td, 1.0) == Ok(42.0)
}

pub fn accuracy_on_uniform_values_test() {
  let xs = uniform(5, 20_000)
  list.each([K1, K2], fn(scale) {
    let td = add_all(new(100.0, scale), xs) |> tdigest.flush
    assert list.length(tdigest.centroids(td)) <= 102
    list.each([0.01, 0.1, 0.5, 0.9, 0.99], fn(q) {
      let assert Ok(v) = tdigest.quantile(td, q)
      assert float.absolute_value(v -. q *. 1000.0) <. 10.0
      let assert Ok(c) = tdigest.cdf(td, q *. 1000.0)
      assert float.absolute_value(c -. q) <. 0.01
    })
  })
}

pub fn merge_test() {
  let xs = uniform(6, 4000)
  let #(a, b) = list.split(xs, 2000)
  let assert Ok(m) =
    tdigest.merge(add_all(new(100.0, K1), a), add_all(new(100.0, K1), b))
  assert tdigest.count(m) == 4000
  let assert Ok(v) = tdigest.quantile(m, 0.5)
  assert float.absolute_value(v -. 500.0) <. 20.0
  assert tdigest.min(m) == list.reduce(xs, float.min)
  assert tdigest.max(m) == list.reduce(xs, float.max)
}

pub fn serialize_round_trip_test() {
  let td = add_all(new(50.0, K2), uniform(7, 333))
  assert tdigest.deserialize(tdigest.serialize(td)) == Ok(td)
  let empty = new(50.0, K1)
  assert tdigest.deserialize(tdigest.serialize(empty)) == Ok(empty)
}

fn close(a: Float, b: Float) -> Bool {
  vectors.close(a, b, 1.0e-9)
}

fn centroid() {
  use mean <- decode.field("mean", vectors.number())
  use weight <- decode.field("weight", decode.int)
  decode.success(Centroid(mean, weight))
}

fn pairs(key: String) {
  decode.list({
    use a <- decode.field(key, vectors.number())
    use b <- decode.field(
      case key {
        "q" -> "value"
        _ -> "cdf"
      },
      vectors.number(),
    )
    decode.success(#(a, b))
  })
}

fn same_centroids(got: List(Centroid), want: List(Centroid)) -> Bool {
  list.length(got) == list.length(want)
  && list.all(list.zip(got, want), fn(p: #(Centroid, Centroid)) {
    let #(a, b) = p
    a.weight == b.weight && close(a.mean, b.mean)
  })
}

pub fn vectors_test() {
  let doc = vectors.load("tdigest")
  let xs = uniform(1, 2000)
  let td = add_all(new(20.0, K1), xs) |> tdigest.flush
  assert same_centroids(
    tdigest.centroids(td),
    vectors.get(doc, ["centroids"], decode.list(centroid())),
  )
  assert tdigest.min(td) == Ok(vectors.get(doc, ["min"], vectors.number()))
  assert tdigest.max(td) == Ok(vectors.get(doc, ["max"], vectors.number()))
  list.each(vectors.get(doc, ["quantiles"], pairs("q")), fn(p) {
    let assert Ok(v) = tdigest.quantile(td, p.0)
    assert close(v, p.1)
  })
  list.each(vectors.get(doc, ["cdf"], pairs("x")), fn(p) {
    let assert Ok(c) = tdigest.cdf(td, p.0)
    assert close(c, p.1)
  })
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert tdigest.serialize(td) == bytes
  assert tdigest.deserialize(bytes) == Ok(td)

  let td2 = add_all(new(20.0, K2), xs) |> tdigest.flush
  assert same_centroids(
    tdigest.centroids(td2),
    vectors.get(doc, ["k2", "centroids"], decode.list(centroid())),
  )
  list.each(vectors.get(doc, ["k2", "quantiles"], pairs("q")), fn(p) {
    let assert Ok(v) = tdigest.quantile(td2, p.0)
    assert close(v, p.1)
  })
  let bytes = vectors.get(doc, ["k2", "serialized"], vectors.hex_bytes())
  assert tdigest.serialize(td2) == bytes
  assert tdigest.deserialize(bytes) == Ok(td2)
}
