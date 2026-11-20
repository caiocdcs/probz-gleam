import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/blocked_bloom_filter as bbf
import probz/hash
import probz/serde
import vectors

pub fn sizing_test() {
  let assert Ok(#(blocks, k)) = bbf.optimal_params(1_000_000, 0.01)
  let bits_per_item = int.to_float(blocks * 512) /. 1.0e6
  assert bits_per_item >. 9.59 && bits_per_item <. 10.2
  assert k >= 6 && k <= 9
  assert bbf.optimal_params(0, 0.01) == Error(bbf.InvalidParameters)
  assert bbf.optimal_params(10, 0.0) == Error(bbf.InvalidParameters)
  assert bbf.optimal_params(10, 1.0) == Error(bbf.InvalidParameters)
  assert bbf.new_exact(1, 17) == Error(bbf.InvalidParameters)
  let assert Ok(#(1, _)) = bbf.optimal_params(1, 0.5)
}

pub fn fpr_near_target_test() {
  let n = 20_000
  let p = 0.01
  let assert Ok(f) = bbf.new(n, p)
  let key = hash.hash_int(_, bytes: 8)
  let f = int.range(0, n, f, fn(f, i) { bbf.add_hash(f, key(i)) })
  assert int.range(0, n, True, fn(ok, i) { ok && bbf.contains_hash(f, key(i)) })
  let probes = 100_000
  let fp =
    int.range(n, n + probes, 0, fn(acc, i) {
      case bbf.contains_hash(f, key(i)) {
        True -> acc + 1
        False -> acc
      }
    })
  assert int.to_float(fp) /. int.to_float(probes) <. p *. 1.3
  let rate = bbf.false_positive_rate(f, n)
  assert rate >. p *. 0.99 && rate <. p *. 1.01
}

pub fn add_contains_merge_clear_test() {
  let assert Ok(a) = bbf.new(100, 0.01)
  let assert Ok(b) = bbf.new(100, 0.01)
  assert !bbf.contains(a, <<"a">>)
  let a = bbf.add(a, <<"a">>)
  let b = bbf.add(b, <<"b">>)
  assert bbf.contains(a, <<"a">>) && !bbf.contains(a, <<"b">>)
  let assert Ok(m) = bbf.merge(a, b)
  assert bbf.contains(m, <<"a">>) && bbf.contains(m, <<"b">>)
  let assert Ok(c) = bbf.new(100_000, 0.01)
  assert bbf.merge(a, c) == Error(bbf.IncompatibleFilters)
  assert !bbf.contains(bbf.clear(a), <<"a">>) && bbf.contains(a, <<"a">>)
}

pub fn serialize_round_trip_test() {
  let assert Ok(f) = bbf.new_exact(2, 5)
  let f = bbf.add(f, <<"x">>)
  let bytes = bbf.serialize(f)
  assert bit_array.byte_size(bytes) == 6 + 4 + 8 + 2 * 64
  assert bbf.deserialize(bytes) == Ok(f)
  let assert <<head:bytes-size(6), _, rest:bits>> = bytes
  assert bbf.deserialize(<<head:bits, 17, rest:bits>>)
    == Error(serde.InvalidData)
}

pub fn vectors_test() {
  let doc = vectors.load("blocked_bloom_filter")
  assert bbf.salts()
    == vectors.get(doc, ["salts"], decode.list(vectors.hex64()))
  let assert Ok(f) = bbf.new_exact(4, 8)
  let f = list.fold(vectors.items(0, 100), f, bbf.add)
  assert list.map(vectors.items(0, 200), bbf.contains(f, _))
    == vectors.get(doc, ["contains"], decode.list(decode.bool))
  assert bbf.optimal_params(1_000_000, 0.01)
    == Ok(#(
      vectors.get(doc, ["sizing", "blocks"], decode.int),
      vectors.get(doc, ["sizing", "k"], decode.int),
    ))
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert bbf.serialize(f) == bytes
  assert bbf.deserialize(bytes) == Ok(f)
}

pub fn add_many_matches_add_test() {
  let assert Ok(f) = bbf.new_exact(4, 8)
  let items = vectors.items(0, 100)
  let one_by_one = list.fold(items, f, bbf.add)
  assert bbf.add_many(f, items) == one_by_one
  assert bbf.add_hash_many(f, list.map(items, hash.hash_bytes)) == one_by_one
  assert bbf.add_many(f, []) == f
  assert bbf.serialize(bbf.add_many(f, items))
    == vectors.get(
      vectors.load("blocked_bloom_filter"),
      ["serialized"],
      vectors.hex_bytes(),
    )
}
