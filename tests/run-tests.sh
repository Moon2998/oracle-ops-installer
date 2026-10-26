#!/bin/bash
# Runs every check for the Oracle OPS Installer: syntax, ShellCheck (when installed), and the hermetic test suite.
# No root, no network and no access to the private Oracle OPS repository are needed.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
status=0
files="oracle-ops-installer.sh tests/lib.sh tests/installer-test.sh tests/run-tests.sh tests/online-check.sh"

echo "== bash -n =="
for f in $files; do bash -n "$f" || { echo "syntax error: $f"; status=1; }; done

echo "== ShellCheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  shellcheck -x -s bash $files || status=1
else
  echo "NOT RUN: shellcheck is not installed"
fi

echo "== installer tests =="
bash tests/installer-test.sh "$@" || status=1
exit "$status"
