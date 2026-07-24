use serde::Serialize;
use serde_json::{Value, json};
use sqlglot_rust::ast::DataType;
use sqlglot_rust::dialects::Dialect;
use sqlglot_rust::generator::generate;
use sqlglot_rust::optimizer::lineage::{LineageConfig, LineageNode, lineage};
use sqlglot_rust::optimizer::qualify_columns::qualify_columns;
use sqlglot_rust::optimizer::scope_analysis::{ColumnRef, Scope, Source, build_scope};
use sqlglot_rust::parser::parse;
use sqlglot_rust::schema::MappingSchema;
use std::collections::BTreeMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

#[derive(Serialize)]
struct ColumnView {
    table: Option<String>,
    name: String,
}

#[derive(Serialize)]
struct SourceView {
    kind: &'static str,
    physical_name: Option<String>,
    alias: Option<String>,
    scope_type: Option<String>,
}

#[derive(Serialize)]
struct ScopeView {
    scope_type: String,
    sources: BTreeMap<String, SourceView>,
    columns: Vec<ColumnView>,
    external_columns: Vec<ColumnView>,
    correlated: bool,
    children: Vec<ScopeView>,
}

#[derive(Serialize)]
struct LineageView {
    name: String,
    source_name: Option<String>,
    alias: Option<String>,
    depth: usize,
    downstream: Vec<LineageView>,
}

fn column_view(column: &ColumnRef) -> ColumnView {
    ColumnView {
        table: column.table.clone(),
        name: column.name.clone(),
    }
}

fn scope_view(scope: &Scope) -> ScopeView {
    let sources = scope
        .sources
        .iter()
        .map(|(name, source)| {
            let view = match source {
                Source::Table(table) => SourceView {
                    kind: "table",
                    physical_name: Some(
                        [
                            table.catalog.as_deref(),
                            table.schema.as_deref(),
                            Some(&table.name),
                        ]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>()
                        .join("."),
                    ),
                    alias: table.alias.clone(),
                    scope_type: None,
                },
                Source::Scope(child) => SourceView {
                    kind: "scope",
                    physical_name: None,
                    alias: Some(name.clone()),
                    scope_type: Some(format!("{:?}", child.scope_type)),
                },
            };
            (name.clone(), view)
        })
        .collect();

    ScopeView {
        scope_type: format!("{:?}", scope.scope_type),
        sources,
        columns: scope.columns.iter().map(column_view).collect(),
        external_columns: scope.external_columns.iter().map(column_view).collect(),
        correlated: scope.is_correlated,
        children: scope.child_scopes().into_iter().map(scope_view).collect(),
    }
}

fn lineage_view(node: &LineageNode) -> LineageView {
    LineageView {
        name: node.name.clone(),
        source_name: node.source_name.clone(),
        alias: node.alias.clone(),
        depth: node.depth,
        downstream: node.downstream.iter().map(lineage_view).collect(),
    }
}

fn analyze(
    sql: &str,
    dialect_name: &str,
    schema_json: &str,
    outputs_json: &str,
) -> Result<Value, String> {
    let dialect = Dialect::from_str(dialect_name)
        .ok_or_else(|| format!("unknown dialect: {dialect_name}"))?;
    let tables: BTreeMap<String, Vec<String>> = serde_json::from_str(schema_json)
        .map_err(|error| format!("invalid schema JSON: {error}"))?;
    let outputs: Vec<String> = serde_json::from_str(outputs_json)
        .map_err(|error| format!("invalid outputs JSON: {error}"))?;

    let mut schema = MappingSchema::new(dialect);
    for (table, columns) in tables {
        let path: Vec<&str> = table.split('.').collect();
        let typed_columns = columns
            .into_iter()
            .map(|column| (column, DataType::Unknown("UNKNOWN".to_string())))
            .collect();
        schema
            .replace_table(&path, typed_columns)
            .map_err(|error| format!("invalid schema table {table}: {error}"))?;
    }

    let parsed = parse(sql, dialect).map_err(|error| error.to_string())?;
    let qualified = qualify_columns(parsed, &schema);
    let scope = build_scope(&qualified);
    let config = LineageConfig::new(dialect);
    let lineages: BTreeMap<String, Value> = outputs
        .iter()
        .map(|output| {
            let value = match lineage(output, &qualified, &schema, &config) {
                Ok(graph) => serde_json::to_value(lineage_view(&graph.node)).unwrap(),
                Err(error) => json!({"error": error.to_string()}),
            };
            (output.clone(), value)
        })
        .collect();

    Ok(json!({
        "ok": true,
        "qualified_sql": generate(&qualified, dialect),
        "scope": scope_view(&scope),
        "lineage": lineages
    }))
}

unsafe fn required_string<'a>(pointer: *const c_char, name: &str) -> Result<&'a str, String> {
    if pointer.is_null() {
        return Err(format!("{name} is required"));
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|error| format!("{name} is not UTF-8: {error}"))
}

fn c_string(value: Value) -> *mut c_char {
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn upkeep_sqlglot_analyze(
    sql: *const c_char,
    dialect: *const c_char,
    schema_json: *const c_char,
    outputs_json: *const c_char,
) -> *mut c_char {
    let result = (|| {
        let sql = unsafe { required_string(sql, "sql") }?;
        let dialect = unsafe { required_string(dialect, "dialect") }?;
        let schema = unsafe { required_string(schema_json, "schema_json") }?;
        let outputs = unsafe { required_string(outputs_json, "outputs_json") }?;
        analyze(sql, dialect, schema, outputs)
    })();

    c_string(match result {
        Ok(value) => value,
        Err(error) => json!({"ok": false, "error": error}),
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn upkeep_sqlglot_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}
