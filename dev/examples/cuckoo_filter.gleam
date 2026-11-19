import gleam/bool
import gleam/float
import gleam/int
import gleam/io
import probz/cuckoo_filter as cf

pub fn main() -> Nil {
  // 16-bit fingerprints, 4 slots per bucket; evictions use a seeded PRNG.
  let assert Ok(f) =
    cf.new(capacity: 1000, fingerprint_bits: 16, bucket_size: 4, seed: 0)
  let assert Ok(f) = cf.add(f, <<"apple">>)
  let assert Ok(f) = cf.add(f, <<"banana">>)
  io.println("contains apple: " <> bool.to_string(cf.contains(f, <<"apple">>)))
  let assert Ok(f) = cf.remove(f, <<"apple">>)
  io.println("after remove: " <> bool.to_string(cf.contains(f, <<"apple">>)))
  io.println("count: " <> int.to_string(cf.count(f)))
  io.println("FPR bound: " <> float.to_string(cf.fp_rate_bound(f)))
}
