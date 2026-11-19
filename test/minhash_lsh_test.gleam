import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import probz/minhash_lsh.{Candidate} as lsh
import vectors

fn new(b, r, seed) {
  let assert Ok(l) = lsh.new(b, r, seed)
  l
}

fn tokens(prefix: String, from: Int, to: Int) -> List(BitArray) {
  int.range(from, to, [], fn(acc, i) {
    [<<prefix:utf8, { int.to_string(i) }:utf8>>, ..acc]
  })
}

pub fn invalid_parameters_test() {
  assert lsh.new(0, 4, 0) == Error(lsh.InvalidParameters)
  assert lsh.new(4, 0, 0) == Error(lsh.InvalidParameters)
  assert lsh.params_for_threshold(0.0, 64) == Error(lsh.InvalidParameters)
  assert lsh.params_for_threshold(0.5, 0) == Error(lsh.InvalidParameters)
}

pub fn empty_set_signature_test() {
  assert lsh.signature(new(2, 2, 0), []) == list.repeat(lsh.prime, 4)
}

pub fn estimated_similarity_test() {
  let l = new(32, 4, 1)
  let a = tokens("t", 0, 100)
  let assert Ok(l) = lsh.add(l, <<"a">>, a)
  list.each([20, 50, 80], fn(overlap) {
    // b shares `overlap` of a's 100 tokens and has 100 - overlap others.
    let b =
      list.append(
        tokens("t", 100 - overlap, 100),
        tokens("u", 0, 100 - overlap),
      )
    let id = <<"b", overlap>>
    let assert Ok(l) = lsh.add(l, id, b)
    let truth = int.to_float(overlap) /. int.to_float(200 - overlap)
    let assert Ok(s) = lsh.similarity(l, <<"a">>, id)
    assert float.absolute_value(s -. truth) <=. 0.1
  })
}

pub fn query_test() {
  let l = new(16, 4, 0)
  let base = tokens("w", 0, 50)
  let assert Ok(l) =
    lsh.add(l, <<"near">>, list.append(tokens("w", 0, 45), tokens("x", 0, 5)))
  let assert Ok(l) = lsh.add(l, <<"far">>, tokens("z", 0, 50))
  assert lsh.add(l, <<"near">>, [<<"x">>]) == Error(lsh.DuplicateId)
  let assert [Candidate(id, _)] = lsh.query(l, base)
  assert id == <<"near">>
  assert lsh.add_signature(l, <<"bad">>, [1]) == Error(lsh.InvalidSignature)
}

pub fn serialize_round_trip_test() {
  let assert Ok(l) = lsh.add(new(8, 2, 3), <<"doc">>, tokens("t", 0, 20))
  let assert Ok(back) = lsh.deserialize(lsh.serialize(l))
  assert lsh.serialize(back) == lsh.serialize(l)
  assert lsh.query(back, tokens("t", 0, 20)) == [Candidate(<<"doc">>, 1.0)]
}

pub fn vectors_test() {
  let doc = vectors.load("minhash_lsh")
  let l = new(4, 4, 7)
  let coeff = {
    use a <- decode.field("a", vectors.hex64())
    use b <- decode.field("b", vectors.hex64())
    decode.success(#(a, b))
  }
  assert list.take(lsh.coefficients(l), 4)
    == vectors.get(doc, ["first_coefficients"], decode.list(coeff))
  let item = {
    use id <- decode.field("id", decode.string)
    use sig <- decode.field("signature", decode.list(vectors.hex64()))
    use bands <- decode.field("band_hashes", decode.list(vectors.hex64()))
    decode.success(#(id, sig, bands))
  }
  let expected = vectors.get(doc, ["items"], decode.list(item))
  let l =
    list.index_fold(expected, l, fn(l, want, j) {
      let set = vectors.items(10 * j, 10 * j + 30)
      let assert Ok(l) = lsh.add(l, <<"set-", { int.to_string(j) }:utf8>>, set)
      let sig = lsh.signature(l, set)
      assert want.0 == "set-" <> int.to_string(j)
      assert sig == want.1
      assert list.map([0, 1, 2, 3], lsh.band_hash(l, sig, _)) == want.2
      l
    })
  let candidate = {
    use id <- decode.field("id", decode.string)
    use s <- decode.field("similarity", vectors.number())
    decode.success(Candidate(<<id:utf8>>, s))
  }
  assert lsh.query(l, vectors.items(5, 35))
    == vectors.get(doc, ["query_results"], decode.list(candidate))
  let bytes = vectors.get(doc, ["serialized"], vectors.hex_bytes())
  assert lsh.serialize(l) == bytes
  let assert Ok(back) = lsh.deserialize(bytes)
  assert lsh.serialize(back) == bytes
}

pub fn params_for_threshold_test() {
  // 128 = 16 · 8: (1/16)^(1/8) ≈ 0.707.
  assert lsh.params_for_threshold(0.7, 128) == Ok(#(16, 8))
}
