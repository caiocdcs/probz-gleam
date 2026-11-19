import gleam/dict
import probz/count_min_sketch
import probz/top_k_tracker.{TopKItem}

pub fn mock_estimator_test() {
  let freq =
    dict.from_list([
      #(<<"apple">>, 100),
      #(<<"banana">>, 200),
      #(<<"cherry">>, 50),
      #(<<"date">>, 150),
    ])
  let count = fn(item) {
    case dict.get(freq, item) {
      Ok(n) -> n
      Error(_) -> 0
    }
  }
  let candidates = [
    <<"apple">>,
    <<"banana">>,
    <<"cherry">>,
    <<"date">>,
    <<"elderberry">>,
  ]
  assert top_k_tracker.top_k(candidates, 3, count)
    == Ok([
      TopKItem(<<"banana">>, 200),
      TopKItem(<<"date">>, 150),
      TopKItem(<<"apple">>, 100),
    ])
}

pub fn edge_cases_test() {
  let c = fn(_) { 42 }
  assert top_k_tracker.top_k([<<"test">>], 0, c)
    == Error(top_k_tracker.InvalidK)
  assert top_k_tracker.top_k([], 5, c) == Ok([])
  assert top_k_tracker.top_k([<<"b">>, <<"a">>, <<"b">>], 5, c)
    == Ok([TopKItem(<<"a">>, 42), TopKItem(<<"b">>, 42)])
}

pub fn with_count_min_sketch_test() {
  let assert Ok(s) = count_min_sketch.new(64, 4, 32, count_min_sketch.Standard)
  let assert Ok(s) = count_min_sketch.add(s, <<"x">>, 5)
  let assert Ok(s) = count_min_sketch.add(s, <<"y">>, 3)
  assert top_k_tracker.top_k(
      [<<"y">>, <<"x">>, <<"z">>],
      2,
      count_min_sketch.count(s, _),
    )
    == Ok([TopKItem(<<"x">>, 5), TopKItem(<<"y">>, 3)])
}
