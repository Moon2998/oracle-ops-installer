#!/bin/bash
# Runs every check for the Oracle OPS Installer: syntax, ShellCheck (when installed), the library manifest, the hermetic test
# suite, the command-sequence comparison against the single-file baseline, and the mutation tests of the read-only checks.
# No root, no network and no access to the private Oracle OPS repository are needed.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
status=0
files="oracle-ops-installer.sh $(ls lib/*.sh | tr '\n' ' ') tests/lib.sh tests/installer-test.sh tests/check-tests.sh tests/mutation-tests.sh tests/run-tests.sh tests/online-check.sh tests/compare-command-sequences.sh tests/update-lib-digests.sh"

echo "== bash -n =="
for f in $files tests/baseline/oracle-ops-installer-96c8b73.sh; do bash -n "$f" || { echo "syntax error: $f"; status=1; }; done

echo "== ShellCheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck -x -s bash $files || status=1
else
  echo "NOT RUN: shellcheck is not installed"
fi

echo "== library manifest =="
bash tests/update-lib-digests.sh --check || status=1

echo "== static guard (scanner self-test) =="
python3 -I tests/guard-scan.py selftest || status=1

echo "== installer tests =="
bash tests/installer-test.sh "$@" || status=1

echo "== command-sequence comparison with the single-file baseline =="
if [ $# -eq 0 ]; then
  bash tests/compare-command-sequences.sh || status=1
else
  echo "SKIPPED: a single test was selected"
fi

echo "== mutation tests (read-only checks) =="
if [ $# -eq 0 ]; then
  bash tests/mutation-tests.sh || status=1
else
  echo "SKIPPED: a single test was selected"
fi
exit "$status"
