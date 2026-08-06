#!/bin/bash
# Test runner: runs every suite, prints tail summary lines, exits nonzero on any failure.
cd "$(dirname "$0")" || exit 1
fail=0
for f in test/*_test.rb; do
  echo "== $f"
  if [ -n "$BUNDLE_GEMFILE" ]; then
    out=$(bundle exec ruby -Itest -Ilib "$f" 2>&1)
  else
    out=$(ruby -Itest -Ilib "$f" 2>&1)
  fi
  status=$?
  echo "$out" | tail -2
  if [ $status -ne 0 ]; then
    echo "$out" | tail -40
    fail=1
  fi
done
exit $fail
