# SQLGlot-first Active Record analysis spike

> Historical note: this prototype led to the Upkeep 0.2 production analyzer.
> The current runtime owns its `Upkeep::SQLGlot` binding and lowers qualified
> generated SQL through `Upkeep::SQLDependencyAnalysis`.

This spike asks whether `Relation#to_sql` plus database schema metadata can replace
the Arel decoder. The analyzer never calls `Relation#arel` and produces the same
small semantic contract Upkeep needs:

- physical tables and referenced columns;
- simple constant predicates in DNF groups;
- column-equality edges (joins and correlations);
- limit and appendability shape.

Run:

```sh
mise x ruby@3.4.7 -- ruby sqlglot_active_record_query_test.rb
mise x ruby@3.4.7 -- ruby benchmark.rb
```

The important comparison is not “can SQLGlot understand every SQL node?” It is
whether both structured Active Record and raw SQL lower into this generic contract.
The tests include raw predicates, raw joins, a correlated `EXISTS`, a CTE inside a
derived source, and collection-shape modifiers.

The analyzer caches schema metadata by connection for the benchmark. A real
integration should key that cache by Active Record's schema version and clear it
when Rails clears its schema cache.
