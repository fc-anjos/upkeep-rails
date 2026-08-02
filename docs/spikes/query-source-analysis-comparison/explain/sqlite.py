#!/usr/bin/env python3

import json
import pathlib
import re
import sqlite3
import sys
import time


CORPUS_PATH = pathlib.Path(__file__).parents[1] / "corpus.json"
PHYSICAL_CORPUS_PATH = pathlib.Path(__file__).parents[1] / "physical_corpus.json"
TABLE_FROM_DETAIL = re.compile(r"(?:SCAN|SEARCH)(?: TABLE)? ([^ ]+)")


def prepare_schema(connection):
    connection.executescript(
        """
        CREATE TABLE stories (
          id INTEGER PRIMARY KEY,
          score INTEGER,
          created_at TEXT
        );
        CREATE TABLE users (id INTEGER PRIMARY KEY);
        CREATE TABLE posts (
          id INTEGER PRIMARY KEY,
          user_id INTEGER,
          published INTEGER,
          created_at TEXT
        );
        CREATE VIEW published_posts AS
          SELECT * FROM posts WHERE published = 1;
        """
    )


def plan_tables(connection, sql, known_tables):
    rows = connection.execute(f"EXPLAIN QUERY PLAN {sql}").fetchall()
    tables = set()
    for _id, _parent, _unused, detail in rows:
        match = TABLE_FROM_DETAIL.search(detail)
        if match and match.group(1) in known_tables:
            tables.add(match.group(1))
    return sorted(tables)


def authorizer_tables(connection, sql, known_tables):
    tables = set()

    def authorizer(action, table, _column, database, _source):
        if action == sqlite3.SQLITE_READ:
            normalized = (
                f"{database}.{table}" if database and database != "main" else table
            )
            if normalized in known_tables:
                tables.add(normalized)
        return sqlite3.SQLITE_OK

    connection.set_authorizer(authorizer)
    try:
        connection.execute(f"EXPLAIN QUERY PLAN {sql}").fetchall()
    finally:
        connection.set_authorizer(None)

    return sorted(tables)


def main():
    connection = sqlite3.connect(":memory:", cached_statements=0)
    prepare_schema(connection)
    cases = [
        query_case
        for query_case in json.loads(CORPUS_PATH.read_text())
        if query_case["dialect"] == "sqlite"
    ]
    physical_cases = [
        query_case
        for query_case in json.loads(PHYSICAL_CORPUS_PATH.read_text())
        if query_case["dialect"] == "sqlite"
    ]
    cases.extend(physical_cases)
    known_tables = {"stories", "users", "posts"}
    plan_failures = []
    authorizer_failures = []

    for query_case in cases:
        expected = sorted(query_case["tables"])
        plan_actual = plan_tables(connection, query_case["sql"], known_tables)
        authorizer_actual = authorizer_tables(
            connection, query_case["sql"], known_tables
        )
        if plan_actual != expected:
            plan_failures.append(
                {
                    "name": query_case["name"],
                    "expected": expected,
                    "actual": plan_actual,
                }
            )
        if authorizer_actual != expected:
            authorizer_failures.append(
                {
                    "name": query_case["name"],
                    "expected": expected,
                    "actual": authorizer_actual,
                }
            )

    benchmark_case = next(
        query_case
        for query_case in cases
        if query_case["name"] == "SQLite correlated EXISTS subquery"
    )
    iterations = 10_000
    plan_started = time.perf_counter()
    for _ in range(iterations):
        plan_tables(connection, benchmark_case["sql"], known_tables)
    plan_seconds = time.perf_counter() - plan_started

    authorizer_started = time.perf_counter()
    for _ in range(iterations):
        authorizer_tables(connection, benchmark_case["sql"], known_tables)
    authorizer_seconds = time.perf_counter() - authorizer_started

    print(
        json.dumps(
            [
                {
                    "approach": "sqlite-explain-query-plan",
                    "cases": len(cases),
                    "failures": plan_failures,
                    "benchmark_us_per_explain": round(
                        plan_seconds * 1_000_000 / iterations, 1
                    ),
                },
                {
                    "approach": "sqlite-authorizer",
                    "cases": len(cases),
                    "failures": authorizer_failures,
                    "benchmark_us_per_prepare": round(
                        authorizer_seconds * 1_000_000 / iterations, 1
                    ),
                },
            ],
            indent=2,
        )
    )
    return 1 if authorizer_failures else 0


if __name__ == "__main__":
    sys.exit(main())
