# Missing SQLGlot semantic bindings spike

The `sqlglot` Ruby gem 0.1.1 binds only parse, generate, transpile, and version.
Its underlying `protegrity/sql-glot-rust` v0.10.12 already contains semantic
APIs that are useful to Upkeep:

- `MappingSchema` and `qualify_columns`;
- `build_scope`, including physical/scoped sources, columns, external columns,
  and correlation;
- output-column `lineage`.

This spike adds one JSON-over-FFI call around those APIs and a small Ruby wrapper.
It does not fork or modify the upstream dependency.

Build and run:

```sh
cargo build --release
mise x ruby@3.4.7 -- ruby binding_test.rb
```

The output-lineage test is intentional: lineage follows a selected value back to
its source, while Upkeep also needs filter/join/order dependencies. Scope analysis
contains those columns, so `scope`, not output lineage alone, is the useful base
for a dependency decoder.

Current v0.10.12 caveat: a CTE's child scope is present and correct, but the
outer source with the CTE's name is still emitted as a table source. The test
locks this behavior down so an upstream fix is visible.
