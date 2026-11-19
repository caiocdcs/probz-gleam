//// Float helpers over gleam/float for the formulas in SPEC.md.

import gleam/float

pub const ln2 = 0.6931471805599453

/// Natural logarithm; `x` must be positive.
pub fn ln(x: Float) -> Float {
  let assert Ok(y) = float.logarithm(x)
  y
}

pub fn exp(x: Float) -> Float {
  float.exponential(x)
}

pub fn pow(x: Float, y: Float) -> Float {
  let assert Ok(z) = float.power(x, y)
  z
}

pub fn sqrt(x: Float) -> Float {
  let assert Ok(y) = float.square_root(x)
  y
}

/// Ceiling as an Int.
pub fn ceil(x: Float) -> Int {
  float.truncate(float.ceiling(x))
}

/// Floor as an Int.
pub fn floor(x: Float) -> Int {
  float.truncate(float.floor(x))
}
