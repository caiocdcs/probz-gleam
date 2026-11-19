import gleam/bit_array
import gleam/bool
import gleam/float
import gleam/int
import gleam/io
import probz/bloom_filter
import probz/hash

pub fn main() -> Nil {
  // Sized for 1000 items at a 1% false-positive rate.
  let assert Ok(bloom) = bloom_filter.new(expected_items: 1000, fp_rate: 0.01)
  let bloom =
    bloom |> bloom_filter.add(<<"apple">>) |> bloom_filter.add(<<"banana">>)

  io.println(
    "bits: "
    <> int.to_string(bloom_filter.bit_count(bloom))
    <> ", hashes: "
    <> int.to_string(bloom_filter.hash_count(bloom)),
  )
  io.println(
    "contains 'apple': "
    <> bool.to_string(bloom_filter.contains(bloom, <<"apple">>)),
  )
  io.println(
    "contains 'grape': "
    <> bool.to_string(bloom_filter.contains(bloom, <<"grape">>)),
  )
  let assert Ok(est) = bloom_filter.estimated_items(bloom)
  io.println("estimated items: " <> float.to_string(float.to_precision(est, 1)))

  // Hash once, query by hash (useful across several structures).
  let h = hash.hash_string("apple")
  io.println(
    "contains_hash(apple): "
    <> bool.to_string(bloom_filter.contains_hash(bloom, h)),
  )

  // Serialize and load back.
  let bytes = bloom_filter.serialize(bloom)
  let assert Ok(loaded) = bloom_filter.deserialize(bytes)
  io.println(
    "serialized "
    <> int.to_string(bit_array.byte_size(bytes))
    <> " bytes; loaded contains 'apple': "
    <> bool.to_string(bloom_filter.contains(loaded, <<"apple">>)),
  )
}
