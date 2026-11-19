import gleam/bit_array
import gleam/float
import gleam/io
import gleam/list
import gleam/string
import probz/minhash_lsh as lsh

fn shingles(text: String) -> List(BitArray) {
  string.split(text, " ") |> list.map(bit_array.from_string)
}

pub fn main() -> Nil {
  // 128 hashes split for a ~0.5 similarity threshold.
  let assert Ok(index) =
    lsh.with_threshold(threshold: 0.5, num_hashes: 128, seed: 0)
  let docs = [
    #("a", "the quick brown fox jumps over the lazy dog"),
    #("b", "the quick brown fox jumps over the sleepy dog"),
    #("c", "lorem ipsum dolor sit amet consectetur adipiscing"),
  ]
  let assert Ok(index) =
    list.try_fold(docs, index, fn(idx, d) {
      lsh.add(idx, bit_array.from_string(d.0), shingles(d.1))
    })
  io.println("similar to 'the quick brown fox jumps over a lazy dog':")
  list.each(
    lsh.query(index, shingles("the quick brown fox jumps over a lazy dog")),
    fn(c) {
      let assert Ok(id) = bit_array.to_string(c.id)
      io.println(
        "  "
        <> id
        <> ": "
        <> float.to_string(float.to_precision(c.similarity, 3)),
      )
    },
  )
}
