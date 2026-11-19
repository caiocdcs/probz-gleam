# probz task runner — `just` lists recipes.
# Inside `nix develop` (or direnv) every tool used here is on PATH.

default:
    @just --list

# Download Gleam dependencies
deps:
    gleam deps download

# Run every example, or one: `just example bloom_filter`
examples:
    sh dev/run_examples.sh

example name:
    gleam run --module examples/{{name}}

# Throughput benchmarks (indicative only)
bench:
    gleam run --module probz_bench

# Build the HTML docs into build/dev/docs/probz
docs:
    gleam docs build

# Re-run the tests on change
watch:
    watchexec --restart --exts gleam -- gleam test

# Copy the golden vectors from a probz (Zig) checkout
sync-vectors zig="../../zig/probz":
    cp {{zig}}/testdata/vectors/*.json testdata/vectors/
    cp {{zig}}/SPEC.md SPEC.md

# Format all Gleam code
fmt:
    gleam format src test dev

# Check formatting without changing files
fmt-check:
    gleam format --check src test dev

# Run the test suite
test:
    gleam test

# Formatting + tests, before a commit
check: fmt-check test

# Everything CI checks, through Nix
ci:
    nix flake check --print-build-logs

# Nix build; result in ./result
nix-build:
    nix build

# Remove build artifacts
clean:
    rm -rf build result

# Bump the version, run CI checks, commit and tag. Add `## [X.Y.Z]` to CHANGELOG.md first.
release version:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(git status --porcelain -- . ':!CHANGELOG.md')" ]; then
        echo "error: commit or stash changes other than CHANGELOG.md first" >&2; exit 1
    fi
    if ! grep -q '^## \[{{version}}\]' CHANGELOG.md; then
        echo "error: CHANGELOG.md has no '## [{{version}}]' section" >&2; exit 1
    fi
    sed -i.bak 's/^version = ".*"/version = "{{version}}"/' gleam.toml && rm gleam.toml.bak
    git add --all
    just ci
    git commit --message "release: v{{version}}"
    git tag --annotate "v{{version}}" --message "v{{version}}"
    echo "Tagged v{{version}}. Publish with: just push"

# Push main and tags to every remote
push:
    #!/usr/bin/env bash
    set -euo pipefail
    for remote in $(git remote); do
        git push "$remote" main --follow-tags
    done
