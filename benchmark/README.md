# Benchmark

The maintained benchmark apps for this package live here:

- `benchmark/upkeep-app`
- `benchmark/turbo-app`

The committed tree is source-only. Generated benchmark output, Rails logs,
runtime SQLite databases, temporary files, Bundler lockfiles, and credentials
are excluded from version control.

`benchmark/bin/run` defaults to the `matrix` family, which targets these two
apps. The Rails cable subscription path still needs package-native subscriber
identity derivation before streamed delivery is a benchmark gate.

The root package test command runs both benchmark app test suites after the gem
tests and before the proof runner:

```sh
bin/test
```

The benchmark app suites are smoke gates for the Rails surfaces the harness
drives: authenticated boards, shared feeds, rooms, authorization boundaries, and
the Upkeep app's helper-hidden render idioms.
