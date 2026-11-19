import gleam/float
import gleam/int
import gleam/io
import gleam/list
import probz/splitmix64
import probz/tdigest

pub fn main() -> Nil {
  // Simulated request latencies in ms (exponential, mean 20).
  let assert Ok(td) = tdigest.new(compression: 100.0, scale: tdigest.K1)
  let #(td, g) =
    int.range(0, 100_000, #(td, splitmix64.new(1)), fn(acc, _) {
      let #(td, g) = acc
      let #(u, g) = uniform(g)
      let assert Ok(td) = tdigest.add(td, 0.0 -. 20.0 *. ln(1.0 -. u))
      #(td, g)
    })
  let td = tdigest.flush(td)
  io.println(
    "latency quantiles over "
    <> int.to_string(tdigest.count(td))
    <> " requests:",
  )
  list.each([0.5, 0.9, 0.99, 0.999], fn(q) {
    let assert Ok(v) = tdigest.quantile(td, q)
    io.println("  p" <> float.to_string(q *. 100.0) <> ": " <> show(v) <> " ms")
  })
  let assert Ok(c) = tdigest.cdf(td, 50.0)
  io.println("  fraction <= 50 ms: " <> show(c))

  // Digests from different shards merge into one.
  let assert Ok(shard) = tdigest.new(compression: 100.0, scale: tdigest.K1)
  let #(shard, _) =
    int.range(0, 1000, #(shard, g), fn(acc, _) {
      let #(td, g) = acc
      let #(u, g) = uniform(g)
      let assert Ok(td) = tdigest.add(td, 500.0 +. u *. 100.0)
      #(td, g)
    })
  let assert Ok(td) = tdigest.merge(td, shard)
  let assert Ok(p999) = tdigest.quantile(td, 0.999)
  let assert Ok(max) = tdigest.quantile(td, 1.0)
  io.println(
    "after merging a slow shard: p99.9 = "
    <> show(p999)
    <> " ms, max = "
    <> show(max)
    <> " ms",
  )
}

fn uniform(g) {
  let #(x, g) = splitmix64.next(g)
  #(int.to_float(int.bitwise_shift_right(x, 11)) *. 1.1102230246251565e-16, g)
}

fn show(x: Float) -> String {
  float.to_string(float.to_precision(x, 2))
}

fn ln(x: Float) -> Float {
  let assert Ok(y) = float.logarithm(x)
  y
}
