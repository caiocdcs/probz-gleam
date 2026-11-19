import gleam/bool
import gleam/int
import gleam/io
import probz/counting_bloom_filter as cbf

pub fn main() -> Nil {
  // 4-bit counters: items can be removed.
  let assert Ok(f) =
    cbf.new(expected_items: 1000, fp_rate: 0.01, counter_bits: 4)
  let f =
    f |> cbf.add(<<"apple">>) |> cbf.add(<<"apple">>) |> cbf.add(<<"pear">>)
  io.println("count(apple): " <> int.to_string(cbf.count(f, <<"apple">>)))
  let assert Ok(f) = cbf.remove(f, <<"pear">>)
  io.println(
    "contains pear after remove: "
    <> bool.to_string(cbf.contains(f, <<"pear">>)),
  )
}
