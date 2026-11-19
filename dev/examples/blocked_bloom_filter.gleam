import gleam/bool
import gleam/float
import gleam/int
import gleam/io
import probz/blocked_bloom_filter as bbf

pub fn main() -> Nil {
  // Every add and lookup touches one 512-bit block.
  let assert Ok(f) = bbf.new(expected_items: 100_000, fp_rate: 0.01)
  io.println(
    "blocks: "
    <> int.to_string(bbf.block_count(f))
    <> ", bits set per item: "
    <> int.to_string(bbf.hash_count(f)),
  )
  let f =
    int.range(0, 100_000, f, fn(f, i) {
      bbf.add(f, <<"user-", { int.to_string(i) }:utf8>>)
    })
  io.println(
    "contains user-42: " <> bool.to_string(bbf.contains(f, <<"user-42">>)),
  )
  io.println(
    "expected FPR at 100k items: "
    <> float.to_string(float.to_precision(
      bbf.false_positive_rate(f, 100_000),
      4,
    )),
  )
}
