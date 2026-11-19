import gleam/float
import gleam/int
import gleam/io
import gleam/list
import probz/qdigest

pub fn main() -> Nil {
  // Response sizes in bytes, universe [0, 2^20), k = 256: rank error ≤ 20/256 · n.
  let assert Ok(qd) = qdigest.new(log_universe: 20, k: 256)
  let qd =
    int.range(1, 10_001, qd, fn(qd, i) {
      let assert Ok(qd) = qdigest.add(qd, i * 37 % 100_000)
      qd
    })
  io.println(
    "nodes: "
    <> int.to_string(qdigest.node_count(qd))
    <> ", error bound: "
    <> float.to_string(qdigest.error_bound(qd)),
  )
  list.each([0.5, 0.9, 0.99], fn(q) {
    let assert Ok(v) = qdigest.quantile(qd, q)
    io.println("  q" <> float.to_string(q) <> ": " <> int.to_string(v))
  })
  io.println("rank(50000) ≥ " <> int.to_string(qdigest.rank(qd, 50_000)))
}
