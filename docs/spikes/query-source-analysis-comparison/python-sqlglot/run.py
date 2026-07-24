#!/usr/bin/env python3

import json
import pathlib
import statistics
import sys
import time

from sqlglot import parse_one
from sqlglot.optimizer.scope import traverse_scope


CORPUS_PATH = pathlib.Path(__file__).parents[1] / "corpus.json"
PHYSICAL_CORPUS_PATH = pathlib.Path(__file__).parents[1] / "physical_corpus.json"


def physical_tables(sql, dialect):
    expression = parse_one(sql, read=dialect)
    tables = set()

    for scope in traverse_scope(expression):
        for _alias, source in scope.sources.items():
            if source.__class__.__name__ != "Table":
                continue

            parts = [source.catalog, source.db, source.name]
            table = ".".join(part for part in parts if part)
            if table:
                tables.add(table.removeprefix("public.").removeprefix("main."))

    return sorted(tables)


def main():
    corpus = json.loads(CORPUS_PATH.read_text())
    physical_corpus = json.loads(PHYSICAL_CORPUS_PATH.read_text())
    failures = []
    timings = []

    for query_case in corpus:
        started = time.perf_counter()
        actual = physical_tables(query_case["sql"], query_case["dialect"])
        timings.append(time.perf_counter() - started)
        expected = sorted(query_case["tables"])
        if actual != expected:
            failures.append(
                {"name": query_case["name"], "expected": expected, "actual": actual}
            )

    benchmark_case = next(
        query_case
        for query_case in corpus
        if query_case["name"] == "PostgreSQL nested IN subquery"
    )
    started = time.perf_counter()
    for _ in range(10_000):
        physical_tables(benchmark_case["sql"], benchmark_case["dialect"])
    benchmark_seconds = time.perf_counter() - started

    result = {
        "approach": "python-sqlglot",
        "cases": len(corpus),
        "failures": failures,
        "median_cold_case_us": round(statistics.median(timings) * 1_000_000, 1),
        "benchmark_us_per_parse": round(benchmark_seconds * 100, 1),
        "physical_source_failures": compare_physical_sources(physical_corpus),
    }
    print(json.dumps(result, indent=2))
    return 1 if failures else 0


def compare_physical_sources(corpus):
    failures = []
    for query_case in corpus:
        actual = physical_tables(query_case["sql"], query_case["dialect"])
        expected = sorted(query_case["tables"])
        if actual != expected:
            failures.append(
                {"name": query_case["name"], "expected": expected, "actual": actual}
            )
    return failures


if __name__ == "__main__":
    sys.exit(main())
