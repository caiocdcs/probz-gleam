# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-20

### Added

- Gleam port of probz (Zig): Bloom, blocked Bloom, counting Bloom, scalable
  Bloom, cuckoo and quotient filters; HyperLogLog; Count-Min sketch
  (standard and conservative update); Space-Saving and TopKTracker;
  t-digest (k₁ and k₂ scale functions); q-digest; MinHash LSH.
- XxHash64, double hashing and SplitMix64 per SPEC.md §2, and the portable
  wire format (format version 1, SPEC.md §3) for every structure.
- Golden vectors from the Zig library, replayed by `gleam test`: every
  structure serializes to the same bytes as the reference.
- `add_many` / `add_hash_many` for the Bloom and blocked Bloom filters.
- Examples for each structure in `dev/examples`, and `just bench`.

### Performance

- Bit arrays store 32-bit words, so every word is a BEAM small integer:
  Bloom add and query are about 30% faster than with 64-bit words. The wire
  format is unchanged.

[Unreleased]: https://forge.int.cdcs.dev/caiocdcs/probz-gleam/compare/v0.1.0...HEAD
[0.1.0]: https://forge.int.cdcs.dev/caiocdcs/probz-gleam/releases/tag/v0.1.0
