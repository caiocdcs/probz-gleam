# probz

## Development

```sh
direnv allow   # or: nix develop
just           # list recipes
just check     # gleam format, tests
just ci        # what CI runs: nix flake check
```

## Release

Add a `## [X.Y.Z]` section to `CHANGELOG.md`, then `just release X.Y.Z` and
`just push`. The tag publishes a Forgejo release with that section as notes.

Renovate needs the `BOT_TOKEN` and `CI_SIGNING_KEY` secrets on the repo.
