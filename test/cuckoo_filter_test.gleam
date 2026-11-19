import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/cuckoo_filter as cf
import vectors

fn new(capacity: Int, f: Int, b: Int) {
  let assert Ok(filter) = cf.new(capacity, f, b, 0)
  filter
}

pub fn sizing_test() {
  assert cf.bucket_count(new(1, 16, 4)) == 1
  // 1000 / 4 = 250 -> 256 buckets; load 1000 / 1024 > 0.96, so doubled.
  assert cf.bucket_count(new(1000, 16, 4)) == 512
  assert cf.new(0, 16, 4, 0) == Error(cf.InvalidParameters)
  assert cf.new_buckets(3, 16, 4, 0) == Error(cf.InvalidParameters)
  assert cf.new_buckets(4, 3, 4, 0) == Error(cf.InvalidParameters)
  assert cf.new_buckets(4, 16, 9, 0) == Error(cf.InvalidParameters)
}

pub fn add_contains_remove_test() {
  let f = new(100, 16, 4)
  assert !cf.contains(f, <<"test">>)
  let assert Ok(f) = cf.add(f, <<"test">>)
  assert cf.contains(f, <<"test">>)
  let assert Ok(f) = cf.remove(f, <<"test">>)
  assert !cf.contains(f, <<"test">>)
  assert cf.remove(f, <<"test">>) == Error(Nil)
}

pub fn duplicates_are_counted_test() {
  let f = new(100, 8, 2)
  let assert Ok(f) = cf.add(f, <<"test">>)
  let assert Ok(f) = cf.add(f, <<"test">>)
  assert cf.count(f) == 2
  let assert Ok(f) = cf.remove(f, <<"test">>)
  assert cf.contains(f, <<"test">>)
  let assert Ok(f) = cf.remove(f, <<"test">>)
  assert !cf.contains(f, <<"test">>)
}

fn fill(f, i) {
  case cf.add(f, vectors.item(i)) {
    Ok(f) -> fill(f, i + 1)
    Error(_) -> #(f, i)
  }
}

pub fn filling_never_loses_an_item_test() {
  let assert Ok(f) = cf.new_buckets(64, 8, 4, 0)
  let #(f, inserted) = fill(f, 0)
  assert cf.load_factor(f) >. 0.9
  assert cf.is_full(f)
  assert list.all(vectors.items(0, inserted), cf.contains(f, _))
  // Deleting frees space; the victim moves back into the table.
  let #(f, removed) = drain(f, 0)
  assert removed < 16
  assert list.all(vectors.items(removed, inserted), cf.contains(f, _))
  let assert Ok(f) = cf.add(f, <<"new-item">>)
  assert cf.contains(f, <<"new-item">>)
}

fn drain(f, i) {
  case cf.is_full(f) {
    False -> #(f, i)
    True -> {
      let assert Ok(f) = cf.remove(f, vectors.item(i))
      drain(f, i + 1)
    }
  }
}

pub fn false_positive_rate_test() {
  let f = new(20_000, 16, 4)
  let f =
    list.fold(vectors.items(0, 20_000), f, fn(f, item) {
      let assert Ok(f) = cf.add(f, item)
      f
    })
  let probes = 50_000
  let fp =
    int.range(0, probes, 0, fn(acc, i) {
      case cf.contains(f, <<"absent-", { int.to_string(i) }:utf8>>) {
        True -> acc + 1
        False -> acc
      }
    })
  assert int.to_float(fp) /. int.to_float(probes) <=. cf.fp_rate_bound(f)
}

pub fn serialize_round_trip_test() {
  let f = new(64, 16, 4)
  let assert Ok(f) = cf.add(f, <<"x">>)
  let assert Ok(f) = cf.add(f, <<"y">>)
  let assert Ok(back) = cf.deserialize(cf.serialize(f))
  assert back == f
  assert cf.contains(back, <<"x">>) && cf.count(back) == 2
}

pub fn vectors_test() {
  let doc = vectors.load("cuckoo_filter")
  let assert Ok(f) = cf.new_buckets(16, 8, 4, 0)
  let #(f, inserted) = fill(f, 0)
  assert inserted == vectors.get(doc, ["inserted_before_full"], decode.int)
  let after_fill =
    vectors.get(doc, ["serialized_after_fill"], vectors.hex_bytes())
  assert cf.serialize(f) == after_fill
  assert cf.deserialize(after_fill) == Ok(f)
  let f =
    list.fold(vectors.items(0, 10), f, fn(f, item) {
      case cf.remove(f, item) {
        Ok(f) -> f
        Error(_) -> f
      }
    })
  assert cf.count(f) == vectors.get(doc, ["count_after_remove"], decode.int)
  assert list.map(vectors.items(0, 100), cf.contains(f, _))
    == vectors.get(doc, ["contains_after_remove"], decode.list(decode.bool))
  let after_remove =
    vectors.get(doc, ["serialized_after_remove"], vectors.hex_bytes())
  assert cf.serialize(f) == after_remove
  assert cf.deserialize(after_remove) == Ok(f)
}
