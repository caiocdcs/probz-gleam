import gleam/float
import gleam/int
import gleam/io
import probz/hyperloglog as hll

pub fn main() -> Nil {
  // p = 14: 16 KiB of registers, ~0.8% standard error.
  let assert Ok(a) = hll.new(precision: 14)
  let a =
    int.range(0, 100_000, a, fn(s, i) {
      hll.add(s, <<"user-", { int.to_string(i) }:utf8>>)
    })
  io.println(
    "distinct ≈ " <> float.to_string(float.to_precision(hll.cardinality(a), 1)),
  )

  let assert Ok(b) = hll.new(precision: 14)
  let b =
    int.range(50_000, 150_000, b, fn(s, i) {
      hll.add(s, <<"user-", { int.to_string(i) }:utf8>>)
    })
  let assert Ok(union) = hll.merge(a, b)
  io.println(
    "union ≈ "
    <> float.to_string(float.to_precision(hll.cardinality(union), 1))
    <> " (true 150000)",
  )
}
