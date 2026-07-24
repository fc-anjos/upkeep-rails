use serde::Serialize;
use serde_json::{Value, json};
use sqlglot_rust::ast::{DataType, Expr, Statement, TableRef};
use sqlglot_rust::dialects::Dialect;
use sqlglot_rust::optimizer::lineage::{LineageConfig, LineageGraph, LineageNode, lineage};
use sqlglot_rust::optimizer::qualify_columns::qualify_columns;
use sqlglot_rust::optimizer::scope_analysis::{ColumnRef, Scope, Source, build_scope};
use sqlglot_rust::schema::MappingSchema;
use std::collections::{BTreeMap, HashMap};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::ptr;

#[derive(Serialize)]
struct ColumnRefView<'a> {
    table: &'a Option<String>,
    name: &'a str,
}

#[derive(Serialize)]
enum SourceView<'a> {
    Table(&'a TableRef),
    Scope(Box<ScopeView<'a>>),
}

#[derive(Serialize)]
struct ScopeView<'a> {
    scope_type: String,
    sources: BTreeMap<&'a str, SourceView<'a>>,
    columns: Vec<ColumnRefView<'a>>,
    external_columns: Vec<ColumnRefView<'a>>,
    derived_table_scopes: Vec<ScopeView<'a>>,
    subquery_scopes: Vec<ScopeView<'a>>,
    union_scopes: Vec<ScopeView<'a>>,
    cte_scopes: Vec<ScopeView<'a>>,
    selected_sources: BTreeMap<&'a str, SourceView<'a>>,
    is_correlated: bool,
}

#[derive(Serialize)]
struct LineageNodeView<'a> {
    name: &'a str,
    expression: &'a Option<Expr>,
    source_name: &'a Option<String>,
    source: &'a Option<Expr>,
    downstream: Vec<LineageNodeView<'a>>,
    alias: &'a Option<String>,
    depth: usize,
}

#[derive(Serialize)]
struct LineageGraphView<'a> {
    node: LineageNodeView<'a>,
    sql: &'a Option<String>,
    dialect: String,
}

fn column_view(column: &ColumnRef) -> ColumnRefView<'_> {
    ColumnRefView {
        table: &column.table,
        name: &column.name,
    }
}

fn source_view(source: &Source) -> SourceView<'_> {
    match source {
        Source::Table(table) => SourceView::Table(table),
        Source::Scope(scope) => SourceView::Scope(Box::new(scope_view(scope))),
    }
}

fn sources_view(sources: &HashMap<String, Source>) -> BTreeMap<&str, SourceView<'_>> {
    sources
        .iter()
        .map(|(name, source)| (name.as_str(), source_view(source)))
        .collect()
}

fn scope_view(scope: &Scope) -> ScopeView<'_> {
    ScopeView {
        scope_type: format!("{:?}", scope.scope_type),
        sources: sources_view(&scope.sources),
        columns: scope.columns.iter().map(column_view).collect(),
        external_columns: scope.external_columns.iter().map(column_view).collect(),
        derived_table_scopes: scope.derived_table_scopes.iter().map(scope_view).collect(),
        subquery_scopes: scope.subquery_scopes.iter().map(scope_view).collect(),
        union_scopes: scope.union_scopes.iter().map(scope_view).collect(),
        cte_scopes: scope.cte_scopes.iter().map(scope_view).collect(),
        selected_sources: sources_view(&scope.selected_sources),
        is_correlated: scope.is_correlated,
    }
}

fn lineage_node_view(node: &LineageNode) -> LineageNodeView<'_> {
    LineageNodeView {
        name: &node.name,
        expression: &node.expression,
        source_name: &node.source_name,
        source: &node.source,
        downstream: node.downstream.iter().map(lineage_node_view).collect(),
        alias: &node.alias,
        depth: node.depth,
    }
}

fn lineage_graph_view(graph: &LineageGraph) -> LineageGraphView<'_> {
    LineageGraphView {
        node: lineage_node_view(&graph.node),
        sql: &graph.sql,
        dialect: format!("{:?}", graph.dialect),
    }
}

fn parse_statement(statement_json: &str) -> Result<Statement, String> {
    serde_json::from_str(statement_json)
        .map_err(|error| format!("invalid SQLGlot statement JSON: {error}"))
}

fn parse_dialect(name: &str) -> Result<Dialect, String> {
    Dialect::from_str(name).ok_or_else(|| format!("unknown dialect: {name}"))
}

fn data_type(name: &str) -> DataType {
    match name.trim().to_ascii_uppercase().as_str() {
        "BIGINT" => DataType::BigInt,
        "BLOB" => DataType::Blob,
        "BOOLEAN" | "BOOL" => DataType::Boolean,
        "DATE" => DataType::Date,
        "DATETIME" => DataType::DateTime,
        "DOUBLE" | "DOUBLE PRECISION" => DataType::Double,
        "FLOAT" => DataType::Float,
        "INTEGER" | "INT" => DataType::Int,
        "JSON" => DataType::Json,
        "JSONB" => DataType::Jsonb,
        "REAL" => DataType::Real,
        "SMALLINT" => DataType::SmallInt,
        "TEXT" => DataType::Text,
        "UUID" => DataType::Uuid,
        value if value.starts_with("VARCHAR") => DataType::Varchar(None),
        value => DataType::Unknown(value.to_string()),
    }
}

fn mapping_schema(schema_json: &str, dialect: Dialect) -> Result<MappingSchema, String> {
    let tables: BTreeMap<String, BTreeMap<String, String>> = serde_json::from_str(schema_json)
        .map_err(|error| format!("invalid MappingSchema JSON: {error}"))?;
    let mut schema = MappingSchema::new(dialect);

    for (table, columns) in tables {
        let path: Vec<&str> = table.split('.').collect();
        let typed_columns = columns
            .into_iter()
            .map(|(column, sql_type)| (column, data_type(&sql_type)))
            .collect();
        schema
            .replace_table(&path, typed_columns)
            .map_err(|error| error.to_string())?;
    }

    Ok(schema)
}

fn qualify_columns_call(
    statement_json: &str,
    schema_json: &str,
    dialect_name: &str,
) -> Result<Value, String> {
    let statement = parse_statement(statement_json)?;
    let dialect = parse_dialect(dialect_name)?;
    let schema = mapping_schema(schema_json, dialect)?;
    serde_json::to_value(qualify_columns(statement, &schema)).map_err(|error| error.to_string())
}

fn build_scope_call(statement_json: &str) -> Result<Value, String> {
    let statement = parse_statement(statement_json)?;
    serde_json::to_value(scope_view(&build_scope(&statement))).map_err(|error| error.to_string())
}

fn lineage_call(
    column: &str,
    statement_json: &str,
    schema_json: &str,
    config_json: &str,
) -> Result<Value, String> {
    let statement = parse_statement(statement_json)?;
    let config_value: Value = serde_json::from_str(config_json)
        .map_err(|error| format!("invalid LineageConfig JSON: {error}"))?;
    let dialect_name = config_value
        .get("dialect")
        .and_then(Value::as_str)
        .unwrap_or("ansi");
    let dialect = parse_dialect(dialect_name)?;
    let schema = mapping_schema(schema_json, dialect)?;
    let sources: HashMap<String, String> = serde_json::from_value(
        config_value
            .get("sources")
            .cloned()
            .unwrap_or_else(|| json!({})),
    )
    .map_err(|error| format!("invalid LineageConfig sources: {error}"))?;
    let trim_qualifiers = config_value
        .get("trim_qualifiers")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let config = LineageConfig::new(dialect)
        .with_sources(sources)
        .with_trim_qualifiers(trim_qualifiers);
    let graph = lineage(column, &statement, &schema, &config).map_err(|error| error.to_string())?;

    serde_json::to_value(lineage_graph_view(&graph)).map_err(|error| error.to_string())
}

unsafe fn required_string<'a>(pointer: *const c_char, name: &str) -> Result<&'a str, String> {
    if pointer.is_null() {
        return Err(format!("{name} is required"));
    }
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|error| format!("{name} is not UTF-8: {error}"))
}

fn response(result: Result<Value, String>) -> *mut c_char {
    let value = match result {
        Ok(result) => json!({"ok": true, "result": result}),
        Err(error) => json!({"ok": false, "error": error}),
    };
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

/// Qualify a serialized SQLGlot statement with a serialized MappingSchema.
///
/// # Safety
///
/// Every pointer must be null or point to a valid NUL-terminated UTF-8 string
/// for the duration of the call. The returned pointer must be released exactly
/// once with [`upkeep_sqlglot_semantics_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn upkeep_sqlglot_semantics_qualify_columns(
    statement_json: *const c_char,
    schema_json: *const c_char,
    dialect: *const c_char,
) -> *mut c_char {
    response((|| {
        qualify_columns_call(
            unsafe { required_string(statement_json, "statement_json") }?,
            unsafe { required_string(schema_json, "schema_json") }?,
            unsafe { required_string(dialect, "dialect") }?,
        )
    })())
}

/// Build a scope tree from a serialized SQLGlot statement.
///
/// # Safety
///
/// `statement_json` must be null or point to a valid NUL-terminated UTF-8
/// string for the duration of the call. The returned pointer must be released
/// exactly once with [`upkeep_sqlglot_semantics_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn upkeep_sqlglot_semantics_build_scope(
    statement_json: *const c_char,
) -> *mut c_char {
    response((|| {
        build_scope_call(unsafe { required_string(statement_json, "statement_json") }?)
    })())
}

/// Build output-column lineage from serialized SQLGlot inputs.
///
/// # Safety
///
/// Every pointer must be null or point to a valid NUL-terminated UTF-8 string
/// for the duration of the call. The returned pointer must be released exactly
/// once with [`upkeep_sqlglot_semantics_free`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn upkeep_sqlglot_semantics_lineage(
    column: *const c_char,
    statement_json: *const c_char,
    schema_json: *const c_char,
    config_json: *const c_char,
) -> *mut c_char {
    response((|| {
        lineage_call(
            unsafe { required_string(column, "column") }?,
            unsafe { required_string(statement_json, "statement_json") }?,
            unsafe { required_string(schema_json, "schema_json") }?,
            unsafe { required_string(config_json, "config_json") }?,
        )
    })())
}

/// Release a response allocated by this library.
///
/// # Safety
///
/// `pointer` must be null or a pointer returned by this library that has not
/// already been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn upkeep_sqlglot_semantics_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}
