# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Gleam port of probz (Zig): Bloom, blocked Bloom, counting Bloom, scalable
  Bloom, cuckoo and quotient filters; HyperLogLog; Count-Min sketch
  (standard and conservative update); Space-Saving and TopKTracker;
  t-digest (k₁ and k₂ scale functions); q-digest; MinHash LSH.
- XxHash64, double hashing and SplitMix64 per SPEC.md §2, and the portable
  wire format (format version 1, SPEC.md §3) for every structure.
- Golden vectors from the Zig library, replayed by `gleam test`: every
  structure serializes to the same bytes as the reference.
- Examples for each structure in `dev/examples`, and `just bench`.
