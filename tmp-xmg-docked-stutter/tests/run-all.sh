#!/bin/bash
# Run every test script in this folder (no GPU or Plasma needed: all fakes).
HERE=$(cd "$(dirname "$0")" && pwd)
fail=0
for t in "$HERE"/test-*.sh; do
    echo "################ $(basename "$t")"
    bash "$t" || { echo "!!!!!!!! $(basename "$t") FAILED"; fail=1; }
    echo
done
exit $fail
