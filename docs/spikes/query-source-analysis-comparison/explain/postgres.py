#!/usr/bin/env python3

import json
import os
import pathlib
import sys
import time

import psycopg


CORPUS_PATH = pathlib.Path(__file__).parents[1] / "corpus.json"
PHYSICAL_CORPUS_PATH = pathlib.Path(__file__).parents[1] / "physical_corpus.json"


def prepare_schema(connection):
    connection.execute("CREATE SCHEMA audit")
    connection.execute(
        "CREATE TABLE nodes (id bigint PRIMARY KEY, parent_id bigint)"
    )
    connection.execute(
        "CREATE TABLE stories (id bigint PRIMARY KEY, search_vector tsvector)"
    )
    connection.execute("CREATE TABLE accounts (id bigint PRIMARY KEY)")
    connection.execute(
        "CREATE TABLE audit.events (id bigint PRIMARY KEY, account_id bigint, kind text)"
    )
    connection.execute("CREATE TABLE projects (id bigint PRIMARY KEY)")
    connection.execute(
        "CREATE TABLE memberships (project_id bigint, user_id bigint)"
    )
    connection.execute(
        "CREATE VIEW active_accounts AS SELECT * FROM accounts"
    )
    connection.execute(
        """
        CREATE FUNCTION account_events(bigint)
        RETURNS SETOF audit.events
        LANGUAGE sql STABLE
        AS 'SELECT * FROM audit.events WHERE account_id = $1'
        """
    )
    connection.execute(
        """
        CREATE FUNCTION volatile_account_events(bigint)
        RETURNS SETOF audit.events
        LANGUAGE sql VOLATILE
        AS 'SELECT * FROM audit.events WHERE account_id = $1'
        """
    )
    connection.commit()


def relation_names(node, tables):
    if isinstance(node, list):
        for child in node:
            relation_names(child, tables)
    elif isinstance(node, dict):
        relation = node.get("Relation Name")
        if relation:
            schema = node.get("Schema")
            tables.add(f"{schema}.{relation}" if schema and schema != "public" else relation)
        for child in node.values():
            relation_names(child, tables)


def plan_tables(connection, sql):
    plan = connection.execute(
        f"EXPLAIN (FORMAT JSON, COSTS FALSE, VERBOSE TRUE) {sql}"
    ).fetchone()[0]
    tables = set()
    relation_names(plan, tables)
    return sorted(tables)


def main():
    connection = psycopg.connect(os.environ["DATABASE_URL"])
    prepare_schema(connection)
    cases = [
        query_case
        for query_case in json.loads(CORPUS_PATH.read_text())
        if query_case["dialect"] == "postgres"
    ]
    physical_cases = [
        query_case
        for query_case in json.loads(PHYSICAL_CORPUS_PATH.read_text())
        if query_case["dialect"] == "postgres"
    ]
    cases.extend(physical_cases)
    failures = []

    for query_case in cases:
        actual = plan_tables(connection, query_case["sql"])
        expected = sorted(query_case["tables"])
        if actual != expected:
            failures.append(
                {"name": query_case["name"], "expected": expected, "actual": actual}
            )

    benchmark_case = next(
        query_case
        for query_case in cases
        if query_case["name"] == "PostgreSQL nested IN subquery"
    )
    iterations = 1_000
    started = time.perf_counter()
    for _ in range(iterations):
        plan_tables(connection, benchmark_case["sql"])
    seconds = time.perf_counter() - started

    print(
        json.dumps(
            {
                "approach": "postgres-explain-json",
                "cases": len(cases),
                "failures": failures,
                "benchmark_us_per_explain": round(
                    seconds * 1_000_000 / iterations, 1
                ),
            },
            indent=2,
        )
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
