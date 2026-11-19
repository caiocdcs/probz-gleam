//// The portable wire format shared by every probz structure. SPEC.md §3.
////
//// Every serialized structure starts with a 6-byte header — the magic
//// `"PRBZ"`, the format version (currently 1) and a structure tag — then a
//// structure-specific body. All integers are little-endian; floats are the
//// little-endian bytes of their IEEE-754 bits.

pub const version = 1

/// Structure tags. The values are part of the wire format.
pub type Tag {
  BloomFilter
  CountingBloomFilter
  ScalableBloomFilter
  CuckooFilter
  QuotientFilter
  HyperLogLog
  CountMinSketch
  SpaceSaving
  TDigest
  QDigest
  MinHashLsh
  BlockedBloomFilter
}

pub fn tag_to_int(tag: Tag) -> Int {
  case tag {
    BloomFilter -> 1
    CountingBloomFilter -> 2
    ScalableBloomFilter -> 3
    CuckooFilter -> 4
    QuotientFilter -> 5
    HyperLogLog -> 6
    CountMinSketch -> 7
    SpaceSaving -> 8
    TDigest -> 9
    QDigest -> 10
    MinHashLsh -> 11
    BlockedBloomFilter -> 12
  }
}

pub fn tag_from_int(value: Int) -> Result(Tag, Nil) {
  case value {
    1 -> Ok(BloomFilter)
    2 -> Ok(CountingBloomFilter)
    3 -> Ok(ScalableBloomFilter)
    4 -> Ok(CuckooFilter)
    5 -> Ok(QuotientFilter)
    6 -> Ok(HyperLogLog)
    7 -> Ok(CountMinSketch)
    8 -> Ok(SpaceSaving)
    9 -> Ok(TDigest)
    10 -> Ok(QDigest)
    11 -> Ok(MinHashLsh)
    12 -> Ok(BlockedBloomFilter)
    _ -> Error(Nil)
  }
}

/// Why `deserialize` rejected its input.
pub type DecodeError {
  /// The first four bytes are not `"PRBZ"`.
  InvalidMagic
  /// The format version is not one this library reads.
  UnsupportedVersion
  /// The bytes hold a different structure.
  WrongStructure
  /// The body is inconsistent: bad lengths or parameters, or trailing bytes.
  InvalidData
  /// The input ended in the middle of a field.
  UnexpectedEnd
}

/// The structure tag of serialized bytes, after checking magic and version.
pub fn peek_tag(bytes: BitArray) -> Result(Tag, DecodeError) {
  case bytes {
    <<"PRBZ", v, t, _:bits>> if v == version ->
      case tag_from_int(t) {
        Ok(tag) -> Ok(tag)
        Error(_) -> Error(WrongStructure)
      }
    <<"PRBZ", _, _, _:bits>> -> Error(UnsupportedVersion)
    <<m:bytes-size(4), _:bits>> if m != <<"PRBZ">> -> Error(InvalidMagic)
    _ -> Error(UnexpectedEnd)
  }
}
