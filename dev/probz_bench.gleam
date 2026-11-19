//// Throughput of every structure on pre-hashed keys: `just bench`.
//// Single process on the BEAM; treat the numbers as indicative only.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import probz/blocked_bloom_filter as bbf
import probz/bloom_filter
import probz/count_min_sketch as cms
import probz/counting_bloom_filter as cbf
import probz/cuckoo_filter as cf
import probz/hash
import probz/hyperloglog as hll
import probz/qdigest
import probz/quotient_filter as qf
import probz/scalable_bloom_filter as sbf
import probz/space_saving as ss
import probz/splitmix64
import probz/tdigest

const n = 100_000

@external(erlang, "timer", "tc")
fn tc(f: fn() -> a) -> #(Int, a)

pub fn main() -> Nil {
  let keys =
    int.range(0, n, [], fn(acc, i) { [hash.hash_int(i, bytes: 8), ..acc] })
  let misses =
    int.range(n, 2 * n, [], fn(acc, i) { [hash.hash_int(i, bytes: 8), ..acc] })
  io.println(
    "probz bench: "
    <> int.to_string(n)
    <> " pre-hashed keys, ns/op\n\n"
    <> pad("structure", 38)
    <> pad("add", 10)
    <> pad("query", 10)
    <> "serialized",
  )

  let assert Ok(f) = bloom_filter.new(n, 0.01)
  filter(
    "BloomFilter (p = 1%)",
    f,
    keys,
    misses,
    bloom_filter.add_hash,
    bloom_filter.contains_hash,
    bloom_filter.serialize,
  )
  let assert Ok(f) = bbf.new(n, 0.01)
  filter(
    "BlockedBloomFilter (p = 1%)",
    f,
    keys,
    misses,
    bbf.add_hash,
    bbf.contains_hash,
    bbf.serialize,
  )
  let assert Ok(f) = cbf.new(n, 0.01, 4)
  filter(
    "CountingBloomFilter (w = 4)",
    f,
    keys,
    misses,
    cbf.add_hash,
    cbf.contains_hash,
    cbf.serialize,
  )
  let assert Ok(f) = sbf.with_defaults(10_000, 0.01)
  filter(
    "ScalableBloomFilter (n0 = 10k)",
    f,
    keys,
    misses,
    fn(f, h) {
      let assert Ok(f) = sbf.add_hash(f, h)
      f
    },
    sbf.contains_hash,
    sbf.serialize,
  )
  let assert Ok(f) = cf.new(n, 16, 4, 0)
  filter(
    "CuckooFilter (f = 16, b = 4)",
    f,
    keys,
    misses,
    fn(f, h) {
      let assert Ok(f) = cf.add_hash(f, h)
      f
    },
    cf.contains_hash,
    cf.serialize,
  )
  let assert Ok(f) = qf.new(18, 8)
  filter(
    "QuotientFilter (q = 18, r = 8)",
    f,
    keys,
    misses,
    fn(f, h) {
      let assert Ok(f) = qf.add_hash(f, h)
      f
    },
    qf.contains_hash,
    qf.serialize,
  )
  let assert Ok(s) = hll.new(14)
  filter(
    "HyperLogLog (p = 14)",
    s,
    keys,
    [0],
    hll.add_hash,
    fn(s, _) { hll.cardinality(s) },
    hll.serialize,
  )
  let assert Ok(s) = cms.with_error(0.001, 0.01, 32, cms.Standard)
  filter(
    "CountMinSketch (e = 0.001, d = 0.01)",
    s,
    keys,
    misses,
    fn(s, h) {
      let assert Ok(s) = cms.add_hash(s, h, 1)
      s
    },
    cms.count_hash,
    cms.serialize,
  )

  let zipf = zipf_keys(n)
  let assert Ok(s) = ss.new(1000)
  filter(
    "SpaceSaving (m = 1000, skewed)",
    s,
    zipf,
    zipf,
    fn(s, k) {
      let assert Ok(s) = ss.add(s, <<k:64>>, 1)
      s
    },
    fn(s, k) { ss.count(s, <<k:64>>) },
    ss.serialize,
  )

  let values = list.map(keys, fn(h) { int.to_float(h % 1_000_000) /. 1000.0 })
  let assert Ok(td) = tdigest.new(100.0, tdigest.K1)
  filter(
    "TDigest (d = 100)",
    td,
    values,
    [0.5],
    fn(td, x) {
      let assert Ok(td) = tdigest.add(td, x)
      td
    },
    fn(td, q) { tdigest.quantile(td, q) },
    tdigest.serialize,
  )
  let assert Ok(qd) = qdigest.new(32, 256)
  filter(
    "QDigest (2^32, k = 256)",
    qd,
    list.map(keys, fn(h) { h % 4_294_967_296 }),
    [0],
    fn(qd, v) {
      let assert Ok(qd) = qdigest.add(qd, v)
      qd
    },
    fn(qd, _) { qdigest.quantile(qd, 0.5) },
    qdigest.serialize,
  )
}

fn zipf_keys(n: Int) -> List(Int) {
  let #(_, out) =
    int.range(0, n, #(splitmix64.new(1), []), fn(acc, _) {
      let #(g, out) = acc
      let #(x, g) = splitmix64.below(g, 10_000)
      let #(y, g) = splitmix64.below(g, x + 1)
      #(g, [y, ..out])
    })
  out
}

fn filter(
  name: String,
  empty: s,
  adds: List(k),
  queries: List(q),
  add: fn(s, k) -> s,
  query: fn(s, q) -> r,
  serialize: fn(s) -> BitArray,
) -> Nil {
  let #(add_us, full) = tc(fn() { list.fold(adds, empty, add) })
  let #(query_us, _) = tc(fn() { list.each(queries, query(full, _)) })
  let size = bit_array.byte_size(serialize(full))
  io.println(
    pad(name, 38)
    <> pad(per_op(add_us, list.length(adds)), 10)
    <> pad(per_op(query_us, list.length(queries)), 10)
    <> bytes(size),
  )
}

fn per_op(us: Int, ops: Int) -> String {
  let ns = int.to_float(us * 1000) /. int.to_float(ops)
  case ns >=. 10_000.0 {
    True -> float.to_string(float.to_precision(ns /. 1000.0, 1)) <> " µs"
    False -> int.to_string(float.round(ns))
  }
}

fn bytes(b: Int) -> String {
  case b >= 1_000_000, b >= 1000 {
    True, _ ->
      float.to_string(float.to_precision(int.to_float(b) /. 1.0e6, 2)) <> " MB"
    _, True ->
      float.to_string(float.to_precision(int.to_float(b) /. 1000.0, 1)) <> " KB"
    _, _ -> int.to_string(b) <> " B"
  }
}

fn pad(s: String, width: Int) -> String {
  string.pad_end(s, width, " ")
}
