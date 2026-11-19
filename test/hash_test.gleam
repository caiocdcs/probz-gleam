import gleam/dynamic/decode
import gleam/int
import gleam/list
import probz/hash
import probz/splitmix64
import vectors

pub fn reference_values_test() {
  assert hash.hash_bytes(<<>>) == 0xef46db3751d8e999
  assert hash.hash_string("a") == 0xd24ec4f1a98c6e5b
  assert hash.hash_string("abc") == 0x44bc2cf5ad770999
}

pub fn long_input_test() {
  // XXH64 of 100 bytes 0..99 exercises the 32-byte stripe loop.
  let bytes = int.range(0, 100, <<>>, fn(acc, i) { <<acc:bits, i>> })
  // Reference: `xxhsum -H64` of the same 100 bytes.
  assert hash.hash_bytes(bytes) == 0x6ac1e58032166597
  assert hash.xxh64(bytes, 0) != hash.xxh64(bytes, 1)
}

pub fn pair_test() {
  let p = hash.pair(0x0000_0002_0000_0005)
  assert p.h1 == 5
  assert p.h2 == 3
  assert hash.index(p, 0, 100) == 5
  assert hash.index(p, 2, 100) == 11
  assert hash.index(p, 2, 10) == 1
}

pub fn typed_keys_test() {
  assert hash.hash_int(1, bytes: 4) == hash.hash_bytes(<<1, 0, 0, 0>>)
  assert hash.hash_int(-1, bytes: 2) == hash.hash_bytes(<<0xff, 0xff>>)
  assert hash.hash_float(1.0) == hash.hash_int(0x3ff0000000000000, bytes: 8)
  assert hash.hash_bool(True) == hash.hash_bytes(<<1>>)
}

pub fn hash_vectors_test() {
  let doc = vectors.load("hash")
  let entry = {
    use input <- decode.field("input", decode.string)
    use xxh64 <- decode.field("xxh64", vectors.hex64())
    use h1 <- decode.field("h1", decode.int)
    use h2 <- decode.field("h2", decode.int)
    use idx <- decode.field("indexes_mod_1000", decode.list(decode.int))
    decode.success(#(input, xxh64, h1, h2, idx))
  }
  let entries = vectors.get(doc, ["strings"], decode.list(entry))
  assert entries != []
  list.each(entries, fn(e) {
    let #(input, xxh64, h1, h2, idx) = e
    let h = hash.hash_string(input)
    assert h == xxh64
    let p = hash.pair(h)
    assert p.h1 == h1
    assert p.h2 == h2
    assert list.map([0, 1, 2, 3], hash.index(p, _, 1000)) == idx
  })

  let keys =
    vectors.get(
      doc,
      ["typed_keys"],
      decode.list({
        use key <- decode.field("key", decode.string)
        use xxh64 <- decode.field("xxh64", vectors.hex64())
        decode.success(#(key, xxh64))
      }),
    )
  let expected = [
    #("u32 1", hash.hash_int(1, bytes: 4)),
    #("u64 1", hash.hash_int(1, bytes: 8)),
    #("i64 -1", hash.hash_int(-1, bytes: 8)),
    #("f64 1.0", hash.hash_float(1.0)),
    #("bool true", hash.hash_bool(True)),
  ]
  assert keys == expected
}

pub fn splitmix64_vectors_test() {
  let g = splitmix64.new(0)
  let #(a, g) = splitmix64.next(g)
  let #(b, g) = splitmix64.next(g)
  let #(c, _) = splitmix64.next(g)
  assert [a, b, c]
    == [0xe220a8397b1dcdaf, 0x6e789e6aa1b965f4, 0x06c45d188009454f]

  let seqs =
    vectors.get(
      vectors.load("splitmix64"),
      ["sequences"],
      decode.list({
        use seed <- decode.field("seed", vectors.hex64())
        use outputs <- decode.field("outputs", decode.list(vectors.hex64()))
        decode.success(#(seed, outputs))
      }),
    )
  assert list.length(seqs) == 3
  list.each(seqs, fn(s) {
    let #(seed, outputs) = s
    let #(got, _) =
      list.map_fold(outputs, splitmix64.new(seed), fn(g, _) {
        let #(x, g) = splitmix64.next(g)
        #(g, x)
      })
      |> fn(r) { #(r.1, r.0) }
    assert got == outputs
  })
}
