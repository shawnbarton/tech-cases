#!/bin/bash
# Run every test script in this folder (no GPU or Plasma needed: all fakes).
HERE=$(cd "$(dirname "$0")" && pwd)
for t in "$HERE"/test-*.sh; do
    echo "################ $(basename "$t")"
    bash "$t"
    echo
done
