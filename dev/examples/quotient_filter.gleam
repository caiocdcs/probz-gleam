import gleam/int
import gleam/io
import gleam/list
import probz/quotient_filter as qf

pub fn main() -> Nil {
  // 2^10 slots, 8-bit remainders.
  let assert Ok(f) = qf.new(q: 10, remainder_bits: 8)
  let assert Ok(f) =
    list.try_fold(["a", "b", "c", "d"], f, fn(f, s) { qf.add(f, <<s:utf8>>) })
  let assert Ok(other) = qf.new(q: 10, remainder_bits: 8)
  let assert Ok(other) = qf.add(other, <<"e">>)
  let assert Ok(merged) = qf.merge(f, other)
  io.println("count after merge: " <> int.to_string(qf.count(merged)))
  io.println("stored fingerprints (quotient, remainder):")
  list.each(qf.entries(merged), fn(e) {
    io.println(
      "  " <> int.to_string(e.quotient) <> ", " <> int.to_string(e.remainder),
    )
  })
}
