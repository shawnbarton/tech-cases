#!/bin/bash
# Test nv-powermizer against a mock libnvidia-ml.so.1 built from mocknvml/mock.c.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PM=$HERE/../testbed/bin/nv-powermizer
T=$(mktemp -d "${TMPDIR:-/tmp}/pm.XXXXXX")
gcc -shared -fPIC -o "$T/libnvidia-ml.so.1" "$HERE/mocknvml/mock.c" || exit 1
for args in "" "consistent" "max" "bogus" "--index 1" "--index" "--index 0 adaptive"; do
    echo "== nv-powermizer $args"
    # shellcheck disable=SC2086
    LD_LIBRARY_PATH=$T python3 -I "$PM" $args 2>&1 | grep -v '^  \|^$\|^Get or\|^Works\|^through\|^(nvml'
    echo "exit ${PIPESTATUS[0]}"
done
echo "== permission denied"; MOCK_EPERM=1 LD_LIBRARY_PATH=$T python3 -I "$PM" max; echo "exit $?"
echo "== no NVML library"; LD_LIBRARY_PATH=/nonexistent python3 -I "$PM"; echo "exit $?"
