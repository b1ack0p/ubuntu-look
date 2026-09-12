#!/bin/bash
# Both suites, one rig build. Exits non-zero if anything failed.
set -u
cd "$(dirname "$0")"
rc=0
bash ./run.sh          || rc=1
KEEP_RIG=0 bash ./run-offline.sh || rc=1
echo
[ $rc -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit $rc
