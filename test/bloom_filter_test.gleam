import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/bloom_filter
import probz/hash
import probz/serde
import vectors

pub fn sizing_test() {
  assert bloom_filter.optimal_bits(4000, 1.0e-7) == Ok(134_191)
  assert bloom_filter.optimal_hashes(134_191, 4000) == 23
  assert bloom_filter.optimal_bits(1000, 0.01) == Ok(9586)
  assert bloom_filter.optimal_hashes(9586, 1000) == 7
  assert bloom_filter.optimal_hashes(1, 1000) == 1
}

pub fn invalid_parameters_test() {
  assert bloom_filter.new(0, 0.01) == Error(bloom_filter.InvalidParameters)
  assert bloom_filter.new(10, 0.0) == Error(bloom_filter.InvalidParameters)
  assert bloom_filter.new(10, 1.0) == Error(bloom_filter.InvalidParameters)
  assert bloom_filter.new_exact(0, 3) == Error(bloom_filter.InvalidParameters)
}

pub fn add_and_contains_test() {
  let assert Ok(f) = bloom_filter.new(100, 0.01)
  assert !bloom_filter.contains(f, <<"test">>)
  let f = bloom_filter.add(f, <<"test">>)
  assert bloom_filter.contains(f, <<"test">>)
  assert !bloom_filter.contains(f, <<"test_2">>)
  assert bloom_filter.contains_hash(f, hash.hash_string("test"))
}

pub fn estimated_items_test() {
  let assert Ok(f) = bloom_filter.new(1000, 0.01)
  assert bloom_filter.estimated_items(f) == Ok(0.0)
  let f = list.fold(vectors.items(0, 500), f, bloom_filter.add)
  let assert Ok(est) = bloom_filter.estimated_items(f)
  assert est >. 475.0 && est <. 525.0
}

pub fn false_positive_rate_holds_test() {
  let n = 20_000
  let assert Ok(f) = bloom_filter.new(n, 0.01)
  let f = list.fold(vectors.items(0, n), f, bloom_filter.add)
  assert list.all(vectors.items(0, n), bloom_filter.contains(f, _))
  let fp =
    int.range(0, n, 0, fn(acc, i) {
      case bloom_filter.contains(f, <<"absent-", { int.to_string(i) }:utf8>>) {
        True -> acc + 1
        False -> acc
      }
    })
  assert int.to_float(fp) /. int.to_float(n) <. 0.013
}

pub fn merge_test() {
  let assert Ok(a) = bloom_filter.new(100, 0.01)
  let assert Ok(b) = bloom_filter.new(100, 0.01)
  let assert Ok(m) =
    bloom_filter.merge(
      bloom_filter.add(a, <<"a">>),
      bloom_filter.add(b, <<"b">>),
    )
  assert bloom_filter.contains(m, <<"a">>) && bloom_filter.contains(m, <<"b">>)
  let assert Ok(c) = bloom_filter.new(200, 0.01)
  assert bloom_filter.merge(a, c) == Error(bloom_filter.IncompatibleFilters)
  assert !bloom_filter.contains(bloom_filter.clear(m), <<"a">>)
}

pub fn serialize_round_trip_test() {
  let assert Ok(f) = bloom_filter.new(100, 0.01)
  let f = bloom_filter.add(f, <<"x">>)
  let bytes = bloom_filter.serialize(f)
  assert bloom_filter.deserialize(bytes) == Ok(f)
  assert serde.peek_tag(bytes) == Ok(serde.BloomFilter)
  assert bloom_filter.deserialize(<<bytes:bits, 0>>) == Error(serde.InvalidData)
  assert bloom_filter.deserialize(<<"XXXX", 1, 1>>) == Error(serde.InvalidMagic)
  assert bloom_filter.deserialize(<<"PRBZ", 9, 1>>)
    == Error(serde.UnsupportedVersion)
  assert bloom_filter.deserialize(<<"PRBZ", 1, 6>>)
    == Error(serde.WrongStructure)
}

pub fn bit_tail_must_be_zero_test() {
  let assert Ok(f) = bloom_filter.new_exact(70, 1)
  let assert <<head:bytes-size(33), _>> = bloom_filter.serialize(f)
  assert bloom_filter.deserialize(<<head:bits, 0x80>>)
    == Error(serde.InvalidData)
}

pub fn vectors_test() {
  let doc = vectors.load("bloom_filter")
  let assert Ok(f) = bloom_filter.new(1000, 0.01)
  assert bloom_filter.bit_count(f)
    == vectors.get(doc, ["bit_count"], decode.int)
  assert bloom_filter.hash_count(f)
    == vectors.get(doc, ["hash_count"], decode.int)
  let f = list.fold(vectors.items(0, 100), f, bloom_filter.add)
  assert list.map(vectors.items(0, 200), bloom_filter.contains(f, _))
    == vectors.get(doc, ["contains"], decode.list(decode.bool))
  assert bloom_filter.set_bits(f) == vectors.get(doc, ["set_bits"], decode.int)
  let assert Ok(est) = bloom_filter.estimated_items(f)
  assert vectors.close(
    est,
    vectors.get(doc, ["estimated_items"], vectors.number()),
    1.0e-12,
  )
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert bloom_filter.serialize(f) == bytes
  assert bloom_filter.deserialize(bytes) == Ok(f)
}
