import gleam/float
import gleam/int
import gleam/io
import probz/scalable_bloom_filter as sbf

pub fn main() -> Nil {
  // Starts small and adds stages as it fills, keeping the total FPR under 1%.
  let assert Ok(f) = sbf.with_defaults(initial_capacity: 100, fp_rate: 0.01)
  let f =
    int.range(0, 10_000, f, fn(f, i) {
      let assert Ok(f) = sbf.add(f, <<"item-", { int.to_string(i) }:utf8>>)
      f
    })
  io.println("items: " <> int.to_string(sbf.count(f)))
  io.println("stages: " <> int.to_string(sbf.stage_count(f)))
  io.println(
    "false-positive bound: "
    <> float.to_string(float.to_precision(sbf.fp_rate_bound(f), 5)),
  )
}
