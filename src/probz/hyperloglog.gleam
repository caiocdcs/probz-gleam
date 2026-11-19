//// HyperLogLog: distinct counting in m = 2^p one-byte registers, with
//// standard error 1.04 / √m (p = 14: 16 KiB, about 0.8%). SPEC.md §5.6.
////
//// Each item sets register j = h >> (64 − p) to the maximum of its value and
//// ρ = clz((h << p) | 2^(p−1)) + 1. The cardinality uses Ertl's improved raw
//// estimator (Algorithm 6) over a histogram of register values kept up to
//// date on add and merge, so it is unbiased across the whole range and costs
//// O(64 − p) rather than O(m).
////
//// - Philippe Flajolet, Éric Fusy, Olivier Gandouet, Frédéric Meunier,
////   "HyperLogLog: the analysis of a near-optimal cardinality estimation
////   algorithm", AofA 2007, DMTCS Proceedings AH:137–156.
////   <https://doi.org/10.46298/dmtcs.3545>
//// - Stefan Heule, Marc Nunkesser, Alexander Hall, "HyperLogLog in
////   Practice", EDBT 2013, §5.1 (64-bit hashing).
////   <https://doi.org/10.1145/2452376.2452456>
//// - Otmar Ertl, "New cardinality estimation algorithms for HyperLogLog
////   sketches", arXiv:1702.01284, 2017, Eq. 32 and Algorithm 6.
////   <https://arxiv.org/abs/1702.01284>

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import iv
import probz/hash
import probz/internal/math
import probz/internal/u64
import probz/internal/wire
import probz/serde

pub const min_precision = 4

pub const max_precision = 18

/// Returned by `cardinality` when every register is saturated (the estimate
/// is +∞, which BEAM floats cannot represent).
pub const saturated = 1.7976931348623157e308

pub opaque type HyperLogLog {
  HyperLogLog(p: Int, registers: iv.Array(Int), hist: iv.Array(Int))
}

pub type Error {
  InvalidParameters
  IncompatiblePrecision
}

/// A sketch with 2^`precision` registers, `precision` in [4, 18].
pub fn new(precision p: Int) -> Result(HyperLogLog, Error) {
  case p >= min_precision && p <= max_precision {
    False -> Error(InvalidParameters)
    True -> {
      let m = int.bitwise_shift_left(1, p)
      Ok(HyperLogLog(
        p:,
        registers: iv.repeat(0, m),
        hist: iv.repeat(0, 64) |> iv.try_set(0, m),
      ))
    }
  }
}

pub fn add(hll: HyperLogLog, item: BitArray) -> HyperLogLog {
  add_hash(hll, hash.hash_bytes(item))
}

pub fn add_hash(hll: HyperLogLog, h: Int) -> HyperLogLog {
  let j = int.bitwise_shift_right(h, 64 - hll.p)
  let w =
    int.bitwise_or(u64.shl(h, hll.p), int.bitwise_shift_left(1, hll.p - 1))
  let rho = u64.leading_zeros(w, 64) + 1
  let old = iv.get_or_default(hll.registers, j, 0)
  case rho > old {
    False -> hll
    True -> set_register(hll, j, old, rho)
  }
}

fn set_register(hll: HyperLogLog, j: Int, old: Int, new: Int) -> HyperLogLog {
  HyperLogLog(
    ..hll,
    registers: iv.try_set(hll.registers, j, new),
    hist: hll.hist
      |> iv.try_update(old, fn(c) { c - 1 })
      |> iv.try_update(new, fn(c) { c + 1 }),
  )
}

/// Estimated number of distinct items (Ertl, Algorithm 6):
///
///     z = m·τ(1 − C_{q+1}/m);  z = (z + C_k) / 2 for k = q … 1;
///     z += m·σ(C_0/m);  E = α_∞·m² / z,  α_∞ = 1 / (2 ln 2)
///
/// Bit-identical to the reference. `saturated` when every register is at
/// its maximum.
pub fn cardinality(hll: HyperLogLog) -> Float {
  let c = fn(k) { int.to_float(iv.get_or_default(hll.hist, k, 0)) }
  let m = int.to_float(iv.size(hll.registers))
  let q = 64 - hll.p
  case c(0) == m {
    // σ(1) = +∞, so the estimate is 0.
    True -> 0.0
    False -> {
      let z = m *. tau(1.0 -. c(q + 1) /. m)
      let z = int.range(q, 0, z, fn(z, k) { 0.5 *. { z +. c(k) } })
      let z = z +. m *. sigma(c(0) /. m)
      case z == 0.0 {
        True -> saturated
        False -> alpha_inf *. m *. m /. z
      }
    }
  }
}

/// α_∞ = 1 / (2 ln 2).
const alpha_inf = 0.7213475204444817

/// σ(x) = x + Σ_{k≥1} x^(2^k) · 2^(k−1), for x < 1.
fn sigma(x: Float) -> Float {
  sigma_loop(x, 1.0, x)
}

fn sigma_loop(x: Float, y: Float, z: Float) -> Float {
  let x = x *. x
  let next = z +. x *. y
  case next == z {
    True -> next
    False -> sigma_loop(x, y +. y, next)
  }
}

/// τ(x) = (1 − x − Σ_{k≥1} (1 − x^(2^−k))² · 2^−k) / 3.
fn tau(x: Float) -> Float {
  case x == 0.0 || x == 1.0 {
    True -> 0.0
    False -> tau_loop(x, 1.0, 1.0 -. x)
  }
}

fn tau_loop(x: Float, y: Float, z: Float) -> Float {
  let x = math.sqrt(x)
  let y = y *. 0.5
  let next = z -. { 1.0 -. x } *. { 1.0 -. x } *. y
  case next == z {
    True -> next /. 3.0
    False -> tau_loop(x, y, next)
  }
}

/// Relative standard error 1.04 / √m.
pub fn standard_error(hll: HyperLogLog) -> Float {
  1.04 /. math.sqrt(int.to_float(iv.size(hll.registers)))
}

pub fn precision(hll: HyperLogLog) -> Int {
  hll.p
}

/// The m register values.
pub fn registers(hll: HyperLogLog) -> List(Int) {
  iv.to_list(hll.registers)
}

/// Union: register-wise maximum. Both must have the same precision.
pub fn merge(a: HyperLogLog, b: HyperLogLog) -> Result(HyperLogLog, Error) {
  case a.p == b.p {
    False -> Error(IncompatiblePrecision)
    True ->
      Ok(
        iv.index_fold(b.registers, a, fn(acc, y, j) {
          let x = iv.get_or_default(acc.registers, j, 0)
          case y > x {
            True -> set_register(acc, j, x, y)
            False -> acc
          }
        }),
      )
  }
}

pub fn clear(hll: HyperLogLog) -> HyperLogLog {
  let assert Ok(empty) = new(hll.p)
  empty
}

/// Wire body (tag 6): u8 p, then m register bytes.
pub fn serialize(hll: HyperLogLog) -> BitArray {
  bit_array.concat([
    wire.header(serde.HyperLogLog),
    <<{ hll.p }>>,
    iv.fold(hll.registers, <<>>, fn(acc, r) { <<acc:bits, r>> }),
  ])
}

pub fn deserialize(bytes: BitArray) -> Result(HyperLogLog, serde.DecodeError) {
  use rest <- result.try(wire.read_header(bytes, serde.HyperLogLog))
  use #(p, rest) <- result.try(wire.u8(rest))
  use hll <- result.try(new(p) |> result.replace_error(serde.InvalidData))
  let m = iv.size(hll.registers)
  use #(regs, rest) <- result.try(wire.many(rest, m, wire.u8))
  let max_rho = 64 - p + 1
  use <- wire.check(list.all(regs, fn(r) { r <= max_rho }))
  let hist =
    list.fold(regs, iv.repeat(0, 64), fn(h, r) {
      iv.try_update(h, r, fn(c) { c + 1 })
    })
  wire.finish(rest, HyperLogLog(p:, registers: iv.from_list(regs), hist:))
}
