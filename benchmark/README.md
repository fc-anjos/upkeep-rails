# Benchmark

These are development-only benchmark harnesses used to verify the package. They
are not shipped with the gem—consumers who `gem install upkeep-rails` never
receive anything under `benchmark/`.

The maintained benchmark apps for this package live here:

- `benchmark/upkeep-app`
- `benchmark/turbo-app`

The committed tree is source-only. Generated benchmark output, Rails logs,
runtime SQLite databases, temporary files, Bundler lockfiles, and credentials
are excluded from version control.

`benchmark/bin/run` defaults to the `matrix` family, which targets these two
apps. The Upkeep app suite covers package-native subscriber identity derivation,
automatic subscription registration, persisted reverse-index planning, and
streamed delivery through the derived subscriber stream.

The root package test command runs both benchmark app test suites after the gem
tests and before the proof runner:

```sh
bin/test
```

The benchmark app suites are smoke gates for the Rails surfaces the harness
drives: authenticated boards, shared feeds, rooms, authorization boundaries, and
the Upkeep app's helper-hidden render idioms. The Upkeep app suite also covers
the Rails cable subscriber boundary, automatic subscription registration, and
streamed delivery through the canonical subscriber stream.

Upkeep benchmark metrics include an `upkeep_reactivity` block in
`metrics-upkeep-<timestamp>.jsonl`. It summarizes stored subscription graphs,
ambient replay input counts, replay recipe bytes, refused-boundary reasons,
live deoptimization reasons, render groups, and render counts without exposing
raw replay values.
