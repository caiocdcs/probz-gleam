import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/counting_bloom_filter as cbf
import probz/serde
import vectors

fn new(n: Int, w: Int) {
  let assert Ok(f) = cbf.new(expected_items: n, fp_rate: 0.01, counter_bits: w)
  f
}

pub fn add_contains_remove_test() {
  let f = new(100, 4)
  assert !cbf.contains(f, <<"test">>)
  let f = cbf.add(f, <<"test">>)
  assert cbf.contains(f, <<"test">>)
  let assert Ok(f) = cbf.remove(f, <<"test">>)
  assert !cbf.contains(f, <<"test">>)
  assert cbf.remove(f, <<"test">>) == Error(Nil)
}

pub fn multiplicity_test() {
  let f = new(100, 8) |> cbf.add(<<"test">>) |> cbf.add(<<"test">>)
  assert cbf.count(f, <<"test">>) == 2
  let assert Ok(f) = cbf.remove(f, <<"test">>)
  assert cbf.contains(f, <<"test">>)
  let assert Ok(f) = cbf.remove(f, <<"test">>)
  assert !cbf.contains(f, <<"test">>)
}

pub fn remove_keeps_other_items_test() {
  let f = list.fold(vectors.items(0, 1000), new(1000, 4), cbf.add)
  let f =
    list.fold(vectors.items(0, 500), f, fn(f, item) {
      let assert Ok(f) = cbf.remove(f, item)
      f
    })
  assert list.all(vectors.items(500, 1000), cbf.contains(f, _))
}

pub fn saturated_counters_never_cause_false_negatives_test() {
  let assert Ok(f) = cbf.new_exact(cells: 64, hashes: 3, counter_bits: 2)
  let f =
    int.range(0, 5, f, fn(f, _) { cbf.add(f, <<"a">>) }) |> cbf.add(<<"b">>)
  assert cbf.count(f, <<"a">>) == 3
  let f =
    int.range(0, 5, f, fn(f, _) {
      case cbf.remove(f, <<"a">>) {
        Ok(f) -> f
        Error(_) -> f
      }
    })
  assert cbf.contains(f, <<"b">>)
}

pub fn estimated_items_test() {
  let f = new(100, 4)
  assert cbf.estimated_items(f) == Ok(0.0)
  let f =
    f |> cbf.add(<<"test1">>) |> cbf.add(<<"test2">>) |> cbf.add(<<"test3">>)
  let assert Ok(est) = cbf.estimated_items(f)
  assert est >. 2.5 && est <. 3.5
}

pub fn merge_test() {
  let a = new(100, 4) |> cbf.add(<<"x">>)
  let b = new(100, 4) |> cbf.add(<<"x">>) |> cbf.add(<<"y">>)
  let assert Ok(m) = cbf.merge(a, b)
  assert cbf.count(m, <<"x">>) == 2
  assert cbf.contains(m, <<"y">>)
  assert cbf.merge(a, new(10, 4)) == Error(cbf.IncompatibleFilters)
}

pub fn invalid_parameters_test() {
  assert cbf.new_exact(10, 3, 1) == Error(cbf.InvalidParameters)
  assert cbf.new_exact(10, 3, 33) == Error(cbf.InvalidParameters)
  assert cbf.new_exact(0, 3, 4) == Error(cbf.InvalidParameters)
}

pub fn serialize_round_trip_test() {
  let assert Ok(f) = cbf.new_exact(cells: 100, hashes: 3, counter_bits: 4)
  let f = f |> cbf.add(<<"x">>) |> cbf.add(<<"x">>)
  let bytes = cbf.serialize(f)
  assert cbf.deserialize(bytes) == Ok(f)
  // 100 cells at 16 per word: the last word holds 4 cells, the rest is zero.
  let assert <<head:bytes-size(19 + 6 * 8 + 7), last>> = bytes
  assert cbf.deserialize(<<head:bits, { last + 0x80 }>>)
    == Error(serde.InvalidData)
  let assert Ok(g) = cbf.new_exact(cells: 50, hashes: 1, counter_bits: 3)
  let g = list.fold(vectors.items(0, 30), g, cbf.add)
  assert cbf.deserialize(cbf.serialize(g)) == Ok(g)
}

pub fn vectors_test() {
  let doc = vectors.load("counting_bloom_filter")
  let f = new(50, 4)
  assert cbf.cell_count(f) == vectors.get(doc, ["cell_count"], decode.int)
  assert cbf.hash_count(f) == vectors.get(doc, ["hash_count"], decode.int)
  let f =
    list.index_fold(vectors.items(0, 50), f, fn(f, item, i) {
      int.range(0, i % 3 + 1, f, fn(f, _) { cbf.add(f, item) })
    })
  let f =
    list.fold(vectors.items(0, 10), f, fn(f, item) {
      case cbf.remove(f, item) {
        Ok(f) -> f
        Error(_) -> f
      }
    })
  assert list.map(vectors.items(0, 100), cbf.count(f, _))
    == vectors.get(doc, ["counts"], vectors.byte_string())
  assert cbf.non_zero_count(f) == vectors.get(doc, ["non_zero"], decode.int)
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert cbf.serialize(f) == bytes
  assert cbf.deserialize(bytes) == Ok(f)
}
