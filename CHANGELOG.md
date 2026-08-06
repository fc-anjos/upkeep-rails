# Changelog

## 0.3.0 — 2026-08-06

Complete architectural replacement. The 0.2.x implementation (SQL parsing via
a vendored SQLGlot Rust extension, template rewriting, DAG planner, controller
replay) is deleted; none of it was ever deployed.

The new architecture:

- **Read sets from execution, not parsing.** Loaded ids plus narrow Arel
  predicate walks recorded at Active Record choke points, with a
  `sql.active_record` completeness audit that warns on anything unaccounted.
- **Two-tier delivery.** Debounced Turbo 8 page refresh is the sole
  correctness mechanism; render-once scrubbed region broadcast is a server-cost
  optimization that surfaces earn through runtime evidence (multi-viewer
  digest equivalence + anonymous scrubbed renders) and lose on the first
  divergence. No configuration surface: promotion evidence is the gate, and
  `UPKEEP_DISABLE_REGION_BROADCAST=1` is an emergency kill switch only.
- **Fact/verdict change semantics.** Writes become facts (with before/after
  values where knowable); each surface evaluates enter / leave / in place /
  irrelevant. Irrelevant writes cost nothing; enter/leave churn inside one
  debounce window nets out; unknowable before-values degrade conservatively.
- **Exact bulk-write identity where the database can answer.** A boot-time
  probe (no adapter catalogs) enables `RETURNING` on `update_all`/`delete_all`;
  `insert_all`/`upsert_all` ids are read from Rails' own return value.
  Adapters that can't answer fall back to conservative matching with a
  warning.
- **Per-member divergence ejection.** A write to rows only one viewer's render
  read ejects that viewer to a personal refresh; a digest-matching re-render
  re-admits them. Closes the promoted-surface flag-flip window.
- **Platform signals over parallel bookkeeping.** Transaction outcomes,
  affected-row counts, Rails' own write classifier, and cache-hit flags are
  consumed rather than reimplemented; version-gated where 7.1 lacks them.
- **Operational honesty.** Boot-time cable topology check (warns when the
  async adapter cannot cross processes; never rewrites app config), cohort
  TTL/pruning/claim sweeping, optimistic locking on surface state, real
  multi-process + real cable adapter tests, and a real two-browser smoke test.

Documented bound: entitlement changes not backed by any database row the
viewer's render read (time- or constant-based branching) heal one debounce
beat late. This is the price of not constraining the app's programming model.

## 0.2.x and earlier

Historical; see docs/archive/.
