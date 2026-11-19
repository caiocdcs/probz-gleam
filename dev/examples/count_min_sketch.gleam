import gleam/float
import gleam/int
import gleam/io
import gleam/list
import probz/count_min_sketch as cms

pub fn main() -> Nil {
  // ε = 0.001, δ = 0.01: overcounts by at most 0.1% of N with 99% probability.
  let assert Ok(s) =
    cms.with_error(
      epsilon: 0.001,
      delta: 0.01,
      counter_bits: 32,
      update: cms.Conservative,
    )
  let words = ["the", "quick", "the", "lazy", "the", "dog", "quick"]
  let assert Ok(s) =
    list.try_fold(words, s, fn(s, w) { cms.add(s, <<w:utf8>>, 1) })
  list.each(["the", "quick", "fox"], fn(w) {
    io.println(w <> ": " <> int.to_string(cms.count(s, <<w:utf8>>)))
  })
  io.println(
    cms.width(s) |> int.to_string
    <> " × "
    <> int.to_string(cms.depth(s))
    <> " counters, error bound "
    <> float.to_string(cms.error_bound(s)),
  )
}
