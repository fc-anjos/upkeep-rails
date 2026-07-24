use serde::Deserialize;
use serde_json::json;
use sqlparser::ast::{ObjectName, Query, Visit, Visitor};
use sqlparser::dialect::{Dialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};
use sqlparser::parser::Parser;
use std::collections::BTreeSet;
use std::convert::Infallible;
use std::fs;
use std::ops::ControlFlow;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Deserialize)]
struct QueryCase {
    name: String,
    dialect: String,
    sql: String,
    tables: Vec<String>,
}

#[derive(Default)]
struct RelationVisitor {
    ctes: BTreeSet<String>,
    relations: BTreeSet<(String, bool)>,
}

impl Visitor for RelationVisitor {
    type Break = Infallible;

    fn pre_visit_query(&mut self, query: &Query) -> ControlFlow<Self::Break> {
        if let Some(with) = &query.with {
            for cte in &with.cte_tables {
                self.ctes.insert(canonical_name(&cte.alias.name.value));
            }
        }
        ControlFlow::Continue(())
    }

    fn pre_visit_relation(&mut self, relation: &ObjectName) -> ControlFlow<Self::Break> {
        let rendered = relation.to_string();
        self.relations
            .insert((canonical_name(&rendered), rendered.contains('.')));
        ControlFlow::Continue(())
    }
}

fn canonical_name(name: &str) -> String {
    name.replace(['"', '`', '[', ']'], "")
        .strip_prefix("public.")
        .or_else(|| name.strip_prefix("main."))
        .unwrap_or(name)
        .replace(['"', '`', '[', ']'], "")
}

fn dialect(name: &str) -> Box<dyn Dialect> {
    match name {
        "postgres" => Box::new(PostgreSqlDialect {}),
        "mysql" => Box::new(MySqlDialect {}),
        "sqlite" => Box::new(SQLiteDialect {}),
        other => panic!("unsupported dialect: {other}"),
    }
}

fn tables(query_case: &QueryCase) -> Result<Vec<String>, String> {
    let statements = Parser::parse_sql(dialect(&query_case.dialect).as_ref(), &query_case.sql)
        .map_err(|error| error.to_string())?;
    let mut visitor = RelationVisitor::default();
    let _ = statements.visit(&mut visitor);
    Ok(visitor
        .relations
        .into_iter()
        .filter_map(|(relation, qualified)| {
            (qualified || !visitor.ctes.contains(&relation)).then_some(relation)
        })
        .collect())
}

fn main() {
    let corpus_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("comparison directory")
        .join("corpus.json");
    let cases: Vec<QueryCase> =
        serde_json::from_str(&fs::read_to_string(corpus_path).expect("read corpus"))
            .expect("parse corpus");
    let physical_corpus_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("comparison directory")
        .join("physical_corpus.json");
    let physical_cases: Vec<QueryCase> = serde_json::from_str(
        &fs::read_to_string(physical_corpus_path).expect("read physical corpus"),
    )
    .expect("parse physical corpus");
    let mut failures = Vec::new();

    for query_case in &cases {
        match tables(query_case) {
            Ok(actual) if actual == query_case.tables => {}
            Ok(actual) => failures.push(json!({
                "name": query_case.name,
                "expected": query_case.tables,
                "actual": actual,
            })),
            Err(error) => failures.push(json!({
                "name": query_case.name,
                "expected": query_case.tables,
                "parse_error": error,
            })),
        }
    }

    let benchmark_case = cases
        .iter()
        .find(|query_case| query_case.name == "PostgreSQL nested IN subquery")
        .expect("benchmark case");
    let iterations = 10_000;
    let started = Instant::now();
    for _ in 0..iterations {
        tables(benchmark_case).expect("benchmark parse");
    }
    let microseconds = started.elapsed().as_secs_f64() * 1_000_000.0 / iterations as f64;
    let physical_source_failures: Vec<_> = physical_cases
        .iter()
        .filter_map(|query_case| match tables(query_case) {
            Ok(actual) if actual == query_case.tables => None,
            Ok(actual) => Some(json!({
                "name": query_case.name,
                "expected": query_case.tables,
                "actual": actual,
            })),
            Err(error) => Some(json!({
                "name": query_case.name,
                "expected": query_case.tables,
                "parse_error": error,
            })),
        })
        .collect();

    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            "approach": "sqlparser-rs",
            "cases": cases.len(),
            "failures": failures,
            "physical_source_failures": physical_source_failures,
            "benchmark_us_per_parse": (microseconds * 10.0).round() / 10.0,
        }))
        .expect("serialize result")
    );

    if !failures.is_empty() {
        std::process::exit(1);
    }
}
