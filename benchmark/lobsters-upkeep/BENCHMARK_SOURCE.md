# Benchmark Source

Source: `refs/rails-ecosystem/yjit-bench/benchmarks/lobsters`
Source commit: `184b1a9f79b21c12c4aaa6be3bad23a1ebe4b439`

This benchmark app is vendored for Upkeep dogfooding. It keeps the YJIT
Lobsters benchmark's SQLite and deterministic-data discipline while replacing
the VM-only harness with server-mode Upkeep live-update workloads.

Intentional variant differences live in Upkeep wiring, relay configuration,
Upkeep schema, subscription tests, and Upkeep-specific app assertions.
