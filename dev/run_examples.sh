#!/bin/sh
# Run every example in dev/examples; fail on the first error.
set -eu
for f in dev/examples/*.gleam; do
  name=$(basename "$f" .gleam)
  echo "== $name"
  gleam run --no-print-progress --module "examples/$name"
done
