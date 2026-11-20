# probz

Probabilistic data structures for Gleam, ported from
[probz](https://github.com/caiocdcs/probz) (Zig). Each structure follows its
published algorithm, links to the paper it implements, and serializes to a
portable binary format. The golden test vectors pin every structure, so a
filter built here is byte-for-byte identical to one built by the Zig library
or any other conforming port ([SPEC.md](SPEC.md)).

Erlang target only: the hashing needs exact 64-bit integers.

## Structures

| Module | Answers | Add | Remove | Merge | Paper |
|---|---|:-:|:-:|:-:|---|
| `probz/bloom_filter` | membership | ✓ | | ✓ | [Bloom 1970](https://doi.org/10.1145/362686.362692) |
| `probz/blocked_bloom_filter` | membership, cache-friendly | ✓ | | ✓ | [Putze et al. 2007](https://doi.org/10.1007/978-3-540-72845-0_9) |
| `probz/counting_bloom_filter` | membership, multiplicity | ✓ | ✓ | ✓ | [Fan et al. 2000](https://doi.org/10.1109/90.851975) |
| `probz/scalable_bloom_filter` | membership, growing sets | ✓ | | | [Almeida et al. 2007](https://doi.org/10.1016/j.ipl.2006.10.007) |
| `probz/cuckoo_filter` | membership | ✓ | ✓ | | [Fan et al. 2014](https://doi.org/10.1145/2674005.2674994) |
| `probz/quotient_filter` | membership, ordered iteration | ✓ | ✓ | ✓ | [Bender et al. 2012](https://doi.org/10.14778/2350229.2350275) |
| `probz/hyperloglog` | distinct count | ✓ | | ✓ | [Flajolet et al. 2007](https://doi.org/10.46298/dmtcs.3545), [Ertl 2017](https://arxiv.org/abs/1702.01284) |
| `probz/count_min_sketch` | frequency | ✓ | | ✓ | [Cormode & Muthukrishnan 2005](https://doi.org/10.1016/j.jalgor.2003.12.001) |
| `probz/space_saving` | top-k / heavy hitters | ✓ | | | [Metwally et al. 2005](https://doi.org/10.1007/978-3-540-30570-5_27) |
| `probz/tdigest` | quantiles, CDF (floats) | ✓ | | ✓ | [Dunning & Ertl 2019](https://arxiv.org/abs/1902.04023) |
| `probz/qdigest` | quantiles, rank (integers) | ✓ | | ✓ | [Shrivastava et al. 2004](https://doi.org/10.1145/1031495.1031524) |
| `probz/minhash_lsh` | Jaccard similarity search | ✓ | | | [Broder 1997](https://doi.org/10.1109/SEQUEN.1997.666900), [MMDS ch. 3](http://www.mmds.org/) |

`probz/top_k_tracker` ranks a known list of candidates with any
`count` function, such as a Count-Min sketch's.

Every module's documentation cites the sections and equations it follows
and notes any deliberate deviation.

### Choosing a structure

- **Is x in the set?** `bloom_filter` when you know the size up front,
  `scalable_bloom_filter` when you don't. If you need deletes, use
  `cuckoo_filter` (most compact at low false-positive rates) or
  `quotient_filter` (merge and ordered iteration); `counting_bloom_filter`
  also tracks multiplicity.
- **How many distinct items?** `hyperloglog`: precision 14 (16 KiB) gives
  about 0.8% error.
- **How often does x occur?** `count_min_sketch`. It never undercounts, and
  overcounts by at most ε·N with probability 1 − δ. The `Conservative`
  update overcounts less.
- **What are the most frequent items?** `space_saving` on a stream, or
  `top_k_tracker` over known candidates.
- **What is the p99?** `tdigest` for real values (`K2` for extreme tails
  such as p99.99), `qdigest` for integers with a hard rank-error bound.
- **What is similar to this document?** `minhash_lsh` over shingles or tokens.

## Install

```sh
gleam add probz
```

## Usage

```gleam
import gleam/io
import probz/bloom_filter
import probz/hash
import probz/hyperloglog

pub fn main() {
  let assert Ok(bloom) = bloom_filter.new(expected_items: 10_000, fp_rate: 0.01)
  let bloom = bloom_filter.add(bloom, <<"apple">>)
  echo bloom_filter.contains(bloom, <<"apple">>)
  // -> True

  // Hash once, use the hash with several structures.
  let h = hash.hash_string("apple")
  let assert Ok(hll) = hyperloglog.new(precision: 14)
  let hll = hyperloglog.add_hash(hll, h)

  // Every structure serializes to the same portable format.
  let bytes = bloom_filter.serialize(bloom)
  let assert Ok(copy) = bloom_filter.deserialize(bytes)
}
```

Conventions shared by all structures:

- Values are immutable: `add`, `remove`, `merge` and `clear` return a new
  structure. Storage is a persistent array ([iv](https://hex.pm/packages/iv)),
  so an update copies O(log n) rather than the whole structure.
- `new(...)` takes labelled parameters and returns a `Result`.
- `add` / `add_hash`, `contains` / `contains_hash`,
  `add_many` / `add_hash_many` on the Bloom filters, `remove`, `count`,
  `merge`, `clear`, `serialize`, `deserialize`. Keys are `BitArray`s, or a
  precomputed XxHash64 from `probz/hash` (`hash_bytes`, `hash_string`, or
  `hash_int` / `hash_float` / `hash_bool` with the same byte encoding as the
  Zig library).
- `deserialize` checks the header and every length and invariant, and
  returns a `serde.DecodeError`.
- Anything random (cuckoo evictions, MinHash coefficients) uses a seeded
  SplitMix64, so results are reproducible.

See [`dev/examples/`](dev/examples/) for a complete program per structure.

### Keys

Structures take a key as bytes (`add`) or as a 64-bit hash (`add_hash`), not
as a generic type. That keeps every structure serializable and the bytes
reproducible in any language: the hash is part of the format, so a filter
never depends on a function you would have to pass back in after loading.
Any Gleam value works once you turn it into one of the two:

```gleam
import probz/bloom_filter
import probz/hash

// Strings, ints, floats and bools have portable encodings (SPEC.md §2.1).
let f = bloom_filter.add_hash(f, hash.hash_string("alice"))
let f = bloom_filter.add_hash(f, hash.hash_int(user_id, bytes: 8))

// Composite keys: combine field hashes, in order.
let key = hash.hash_fields([hash.hash_string(order.shop), hash.hash_int(order.id, bytes: 8)])
let f = bloom_filter.add_hash(f, key)

// Lists, including nested ones.
let f = bloom_filter.add_hash(f, hash.hash_list(tags, hash.hash_string))

// Or build the bytes yourself.
let f = bloom_filter.add(f, <<order.shop:utf8, 0, order.id:64>>)
```

`hash_fields` is `XXH64(u64le(h_1) ++ … ++ u64le(h_n))`, so another
implementation can compute the same key. Wrap these in a small function per
key type (`fn user_key(u: User) -> Int`) to keep keys typed in your code.

## Development

The toolchain comes from the Nix flake.

```sh
direnv allow                 # or: nix develop
just                         # list recipes
just check                   # gleam format, tests (unit, statistical, model, golden vectors)
just examples                # run every example
just example tdigest         # run one example
just bench                   # throughput and serialized size
just docs                    # HTML docs into build/dev/docs/probz
just ci                      # what CI runs: nix flake check
just sync-vectors            # copy SPEC.md and the golden vectors from a probz checkout
```

## Benchmarks

Output of `just bench` on an Apple M4: 100k pre-hashed keys, one BEAM
process. The numbers are indicative only. Persistent arrays make every
update allocate, so expect the BEAM to be about two orders of magnitude
slower than the Zig library.

| Structure | add (ns) | query (ns) | serialized |
|---|--:|--:|--:|
| BloomFilter (p = 1%) | 660 | 80 | 120 KB |
| BlockedBloomFilter (p = 1%) | 540 | 150 | 124 KB |
| CountingBloomFilter (w = 4) | 2400 | 340 | 479 KB |
| ScalableBloomFilter (n₀ = 10k) | 980 | 280 | 279 KB |
| CuckooFilter (f = 16, b = 4) | 250 | 200 | 262 KB |
| QuotientFilter (q = 18, r = 8) | 620 | 80 | 361 KB |
| HyperLogLog (p = 14) | 150 | 2000 (cardinality) | 16 KB |
| CountMinSketch (ε = 0.001, δ = 0.01) | 1100 | 780 | 54 KB |
| SpaceSaving (m = 1000, skewed) | 450 | 1500 | 36 KB |
| TDigest (δ = 100) | 170 | 1000 (p50) | 1 KB |
| QDigest (σ = 2³², k = 256) | 680 | 109 µs (p50) | 15 KB |

Bit arrays use 32-bit words internally so every word stays a BEAM small
integer (64-bit words would be heap bignums), while the wire format keeps
u64 words.

## Other languages

[SPEC.md](SPEC.md), mirrored from the Zig repository, defines the hash
contract, every algorithm in enough detail to reimplement it, and the wire
format. `testdata/vectors/*.json` holds the expected outputs and serialized
bytes for fixed inputs, and `gleam test` replays all of them.

## Release

Add a `## [X.Y.Z]` section to `CHANGELOG.md`, then `just release X.Y.Z` and
`just push`. The tag publishes a Forgejo release with that section as notes.

## License

MIT. See [LICENSE](LICENSE).
