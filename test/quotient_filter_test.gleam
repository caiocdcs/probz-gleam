import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/set
import probz/hash
import probz/quotient_filter.{Entry} as qf
import probz/splitmix64
import vectors

fn new(q: Int, r: Int) {
  let assert Ok(f) = qf.new(q, r)
  f
}

fn add_all(f, items) {
  list.fold(items, f, fn(f, item) {
    let assert Ok(f) = qf.add(f, item)
    f
  })
}

pub fn new_validates_test() {
  assert qf.new(0, 8) == Error(qf.InvalidParameters)
  assert qf.new(33, 32) == Error(qf.InvalidParameters)
  assert qf.new(4, 0) == Error(qf.InvalidParameters)
}

pub fn add_contains_remove_test() {
  let f = new(8, 8)
  let assert Ok(f) = qf.add(f, <<"hello">>)
  let assert Ok(f2) = qf.add(f, <<"hello">>)
  assert f2 == f
  assert qf.contains(f, <<"hello">>)
  assert !qf.contains(f, <<"world">>)
  let assert Ok(f) = qf.remove(f, <<"hello">>)
  assert !qf.contains(f, <<"hello">>)
  assert qf.remove(f, <<"hello">>) == Error(Nil)
  assert qf.count(f) == 0
}

pub fn remove_keeps_other_items_test() {
  let f = add_all(new(4, 8), vectors.items(0, 14))
  let f =
    int.range(0, 14, f, fn(f, i) {
      case i % 2 {
        0 -> {
          let assert Ok(f) = qf.remove(f, vectors.item(i))
          f
        }
        _ -> f
      }
    })
  assert int.range(0, 14, True, fn(ok, i) {
    ok && { i % 2 == 0 || qf.contains(f, vectors.item(i)) }
  })
}

pub fn fill_to_capacity_then_full_test() {
  let key = hash.hash_int(_, bytes: 8)
  let #(f, n) = fill(new(6, 16), key, 0)
  assert qf.add_hash(f, key(1_000_000)) == Error(qf.Full)
  assert int.range(0, n, True, fn(ok, j) { ok && qf.contains_hash(f, key(j)) })
}

fn fill(f, key, i) {
  case qf.count(f) < qf.slot_count(f) {
    False -> #(f, i)
    True -> {
      let assert Ok(f) = qf.add_hash(f, key(i))
      fill(f, key, i + 1)
    }
  }
}

/// Random adds and removes against a set of entries, checking membership,
/// count and iteration after every operation.
fn check_against_oracle(r: Int, q: Int, ops: Int, seed: Int) {
  let f = new(q, r)
  let universe = qf.slot_count(f) * 2
  let _ =
    int.range(0, ops, #(f, set.new(), splitmix64.new(seed)), fn(state, _) {
      let #(f, oracle, g) = state
      let #(x, g) = splitmix64.below(g, universe)
      let e = qf.entry_for_hash(f, hash.hash_int(x, bytes: 8))
      let #(coin, g) = splitmix64.below(g, 3)
      let #(f, oracle) = case coin {
        0 -> {
          let was = set.contains(oracle, e)
          let removed = qf.remove_entry(f, e)
          assert { removed != Error(Nil) } == was
          case removed {
            Ok(f) -> #(f, set.delete(oracle, e))
            Error(_) -> #(f, oracle)
          }
        }
        _ ->
          case set.size(oracle) < qf.slot_count(f) {
            False -> #(f, oracle)
            True -> {
              let fresh = !set.contains(oracle, e)
              let assert Ok(f2) = qf.add_entry(f, e)
              assert { f2 != f } == fresh
              #(f2, set.insert(oracle, e))
            }
          }
      }
      assert qf.count(f) == set.size(oracle)
      assert set.to_list(oracle) |> list.all(qf.contains_entry(f, _))
      let seen = qf.entries(f)
      assert list.length(seen) == set.size(oracle)
      assert set.from_list(seen) == oracle
      #(f, oracle, g)
    })
  Nil
}

pub fn model_check_test() {
  check_against_oracle(2, 3, 2000, 1)
  check_against_oracle(3, 4, 3000, 2)
  check_against_oracle(4, 5, 3000, 3)
  check_against_oracle(8, 6, 3000, 4)
}

pub fn false_positive_rate_test() {
  let f = add_all(new(14, 8), vectors.items(0, 12_000))
  let probes = 50_000
  let fp =
    int.range(0, probes, 0, fn(acc, i) {
      case qf.contains(f, <<"absent-", { int.to_string(i) }:utf8>>) {
        True -> acc + 1
        False -> acc
      }
    })
  assert int.to_float(fp) /. int.to_float(probes) <. 1.0 /. 256.0
}

pub fn merge_test() {
  let a = add_all(new(6, 8), [<<"x">>])
  let b = add_all(new(6, 8), [<<"y">>, <<"x">>])
  let assert Ok(m) = qf.merge(a, b)
  assert qf.contains(m, <<"x">>) && qf.contains(m, <<"y">>)
  assert qf.count(m) == 2
  assert qf.merge(a, new(7, 8)) == Error(qf.IncompatibleFilters)
}

pub fn serialize_round_trip_test() {
  let f = add_all(new(5, 8), vectors.items(0, 20))
  assert qf.deserialize(qf.serialize(f)) == Ok(f)
}

pub fn vectors_test() {
  let doc = vectors.load("quotient_filter")
  let #(f, added) =
    list.map_fold(vectors.items(0, 28), new(5, 4), fn(f, item) {
      let fresh = !qf.contains(f, item)
      let assert Ok(f) = qf.add(f, item)
      #(f, fresh)
    })
  assert added == vectors.get(doc, ["added"], decode.list(decode.bool))
  let after_add =
    vectors.get(doc, ["serialized_after_add"], vectors.hex_bytes())
  assert qf.serialize(f) == after_add
  assert qf.deserialize(after_add) == Ok(f)
  let f =
    list.index_fold(vectors.items(0, 28), f, fn(f, item, i) {
      case i % 3 {
        0 ->
          case qf.remove(f, item) {
            Ok(f) -> f
            Error(_) -> f
          }
        _ -> f
      }
    })
  assert qf.count(f) == vectors.get(doc, ["count_after_remove"], decode.int)
  let entry = {
    use quotient <- decode.field("quotient", decode.int)
    use remainder <- decode.field("remainder", decode.int)
    decode.success(Entry(quotient:, remainder:))
  }
  assert qf.entries(f)
    == vectors.get(doc, ["entries_after_remove"], decode.list(entry))
  assert list.map(vectors.items(0, 60), qf.contains(f, _))
    == vectors.get(doc, ["contains_after_remove"], decode.list(decode.bool))
  let after_remove =
    vectors.get(doc, ["serialized_after_remove"], vectors.hex_bytes())
  assert qf.serialize(f) == after_remove
  assert qf.deserialize(after_remove) == Ok(f)
}
