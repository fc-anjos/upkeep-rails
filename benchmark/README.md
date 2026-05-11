# Benchmark

The maintained benchmark apps for this package live here:

- `benchmark/upkeep-app`
- `benchmark/turbo-app`

The committed tree is source-only. Generated benchmark output, Rails logs,
runtime SQLite databases, temporary files, Bundler lockfiles, Playwright install
artifacts, and credentials are excluded from version control.

`benchmark/bin/run` defaults to the `matrix` family, which targets these two
apps. The Rails cable subscription path still needs package-native subscriber
identity derivation before streamed delivery is a benchmark gate.
