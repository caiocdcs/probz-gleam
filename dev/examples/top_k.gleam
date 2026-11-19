import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import probz/count_min_sketch as cms
import probz/space_saving
import probz/top_k_tracker

pub fn main() -> Nil {
  let stream = ["a", "b", "a", "c", "a", "b", "d", "a", "e", "b"]

  // Unknown heavy hitters: Space-Saving with 3 counters.
  let assert Ok(ss) = space_saving.new(capacity: 3)
  let assert Ok(ss) =
    list.try_fold(stream, ss, fn(s, x) { space_saving.add(s, <<x:utf8>>, 1) })
  io.println("space-saving top 2:")
  list.each(space_saving.top_k(ss, 2), fn(i) {
    let assert Ok(key) = bit_array.to_string(i.key)
    io.println(
      "  "
      <> key
      <> ": "
      <> int.to_string(i.count)
      <> " (at least "
      <> int.to_string(i.count - i.err)
      <> ")",
    )
  })

  // Known candidates: rank them by a Count-Min sketch.
  let assert Ok(sketch) =
    cms.new(width: 64, depth: 4, counter_bits: 32, update: cms.Standard)
  let assert Ok(sketch) =
    list.try_fold(stream, sketch, fn(s, x) { cms.add(s, <<x:utf8>>, 1) })
  let assert Ok(top) =
    top_k_tracker.top_k([<<"c">>, <<"b">>, <<"e">>], k: 2, count: cms.count(
      sketch,
      _,
    ))
  io.println("top 2 of c, b, e:")
  list.each(top, fn(i) {
    let assert Ok(key) = bit_array.to_string(i.item)
    io.println("  " <> key <> ": " <> int.to_string(i.frequency))
  })
}
