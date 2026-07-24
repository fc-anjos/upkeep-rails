# sqlglot-semantics

`sqlglot-semantics` is a sibling extension for the `sqlglot` Ruby gem. It
exposes semantic APIs already present in `sql-glot-rust` instead of defining an
Upkeep-specific analyzer:

```ruby
schema = Sqlglot::MappingSchema.new(
  {"cards" => {"id" => "INTEGER", "title" => "TEXT"}},
  dialect: :postgres
)
statement = Sqlglot.parse("SELECT id FROM cards")

qualified = Sqlglot.qualify_columns(statement, schema)
scope = Sqlglot.build_scope(qualified)
graph = Sqlglot.lineage("id", qualified, schema)
```

The public names, arguments, and result fields mirror `sql-glot-rust` v0.10.12:

- `MappingSchema`
- `qualify_columns(statement, schema)`
- `build_scope(statement)`
- `lineage(column, statement, schema, config)`

The gem is independently buildable and does not fork or modify either
`sqlglot` or `sql-glot-rust`. Source installs require Rust 1.85 or newer.
Platform gems can include `libsqlglot_semantics` and skip compilation.

Build and test a source checkout:

```sh
rake test
```

Build a precompiled gem for the current platform:

```sh
rake native:package
```

Cross-platform release jobs may set `PLATFORM` after placing the corresponding
`libsqlglot_semantics` artifact under `lib/sqlglot/semantics`. Supported release
platforms match the `sqlglot` gem: macOS and glibc Linux on arm64 and x86-64.
