#!/bin/bash
# Mutation tests for the read-only checks: ONE harmful change at a time is injected into a COPY of the installer tree (the library
# digests regenerated in the copy, so the loader accepts it), the status / validate / boundary / guard tests are run against the
# copy, and at least one of them must fail. The table at the end says which checks caught each mutation. Also: a mutation made
# WITHOUT regenerating the digests must be refused by the integrity loader.
# The unmutated copy is the control: it must pass every one of those tests. Needs no root, no network; works under TMPDIR.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"
PARALLEL="${MUTATION_JOBS:-6}"
SELECT="test_status_ test_validate_ test_check_ test_boundary_ test_menu_ test_static_ test_seams_ test_master_ test_command_"

W="$(mktemp -d "${TMPDIR:-/tmp}/oracle-ops-mutation.XXXXXX")" || { echo "mutation-tests: cannot create a work directory" >&2; exit 2; }
mkdir -p "$W/res"
status=0

make_tree() {   # make_tree <dir>: a copy of the installer tree (entry script and libraries, modes kept)
  mkdir -p "$1/lib" && cp -p "$REPO/oracle-ops-installer.sh" "$1/" && cp -p "$REPO"/lib/*.sh "$1/lib/"
}

# run_one <index> <name>: one mutation (index "control" = none); the failing test names go to $W/res/<index>.fail
run_one() {
  local idx="$1" dir="$W/tree-$1" t="$W/tmp-$1"
  make_tree "$dir"
  mkdir -p "$t"
  if [ "$idx" != control ]; then
    if ! python3 -I "$REPO/tests/mutations.py" apply "$dir" "$idx" > "$W/res/$idx.apply" 2>&1; then echo "APPLY-FAILED" > "$W/res/$idx.fail"; return 0; fi
    if bash "$REPO/tests/update-lib-digests.sh" --root "$dir" > /dev/null 2>&1 && bash "$REPO/tests/update-lib-digests.sh" --check --root "$dir" > /dev/null 2>&1; then :; else echo "DIGEST-FAILED" > "$W/res/$idx.fail"; return 0; fi
  fi
  # shellcheck disable=SC2086
  INSTALLER_UNDER_TEST="$dir/oracle-ops-installer.sh" TMPDIR="$t" timeout 900 bash "$REPO/tests/installer-test.sh" $SELECT > "$W/res/$idx.out" 2>&1
  grep -E '^FAIL ' "$W/res/$idx.out" | sed 's/^FAIL //' | tr '\n' ' ' > "$W/res/$idx.fail"
  grep -E '^installer tests: ' "$W/res/$idx.out" > "$W/res/$idx.count" || echo "no result line" > "$W/res/$idx.count"
}

echo "== control: the unmutated copy passes the same tests =="
run_one control
echo "   $(cat "$W/res/control.count")"
if [ -s "$W/res/control.fail" ]; then echo "   CONTROL FAILED: $(cat "$W/res/control.fail")"; status=1; fi

mapfile_list() { python3 -I "$REPO/tests/mutations.py" list; }
total=0
names=()
while IFS=$'\t' read -r idx name; do names[idx]="$name"; total=$((total + 1)); done < <(mapfile_list)

# the mutation that creates a file in /tmp must not run beside others (they watch /tmp): it runs alone at the end
tmp_idx=""
for i in $(seq 0 $((total - 1))); do [ "${names[$i]}" != mktemp ] || tmp_idx="$i"; done
echo "== $total mutations (each one injected into its own copy; $PARALLEL at a time) =="
running=0
for i in $(seq 0 $((total - 1))); do
  [ "$i" != "$tmp_idx" ] || continue
  run_one "$i" &
  running=$((running + 1))
  if [ "$running" -ge "$PARALLEL" ]; then wait; running=0; fi
done
wait
if [ -n "$tmp_idx" ]; then
  before="$(find /tmp -maxdepth 1 -mindepth 1 -user "$(id -u)" ! -name 'claude-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort)"
  run_one "$tmp_idx"
  after="$(find /tmp -maxdepth 1 -mindepth 1 -user "$(id -u)" ! -name 'claude-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort)"
  # what the mutated code left in /tmp is removed again (only entries that were not there before; named like mktemp's defaults)
  LC_ALL=C comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -E '^tmp\.[A-Za-z0-9]{10}$' | while IFS= read -r e; do rm -rf -- "/tmp/$e"; done
fi

printf '\n%-52s %s\n' "mutation" "failing checks (a test that fails against the mutated copy = detected)"
undetected=0
for i in $(seq 0 $((total - 1))); do
  f="$(cat "$W/res/$i.fail" 2>/dev/null)"
  if [ -z "$f" ]; then
    printf '%-52s %s\n' "${names[$i]}" "NOT DETECTED"; undetected=$((undetected + 1))
  else
    printf '%-52s %s\n' "${names[$i]}" "$f"
  fi
done

# a mutation without digest regeneration: refused by the integrity loader before any library runs
echo
echo "== one mutation without regenerating the digests =="
make_tree "$W/tree-nodigest"
printf '\nsystemctl restart oracle-ops.service   # injected without regenerating the digest\n' >> "$W/tree-nodigest/lib/ops-status.sh"
bash "$W/tree-nodigest/oracle-ops-installer.sh" --version > "$W/res/nodigest.out" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -q 'lib/ops-status.sh does not match its recorded SHA-256 digest' "$W/res/nodigest.out"; then
  echo "refused by the integrity loader: exit $rc, $(head -n 1 "$W/res/nodigest.out")"
else
  echo "NOT REFUSED: exit $rc: $(head -n 3 "$W/res/nodigest.out")"; status=1
fi
( INSTALLER_UNDER_TEST="$W/tree-nodigest/oracle-ops-installer.sh" TMPDIR="$W" bash "$REPO/tests/installer-test.sh" test_status_healthy_installation_is_all_ok 2>&1 | grep -E '^(PASS|FAIL) ' ) | sed 's/^/   the test suite against it: /'

echo
if [ "$undetected" != 0 ]; then echo "mutation tests: $undetected mutation(s) NOT DETECTED"; status=1; fi
if [ "$status" = 0 ]; then
  rm -rf -- "$W"
  echo "mutation tests: PASS ($total mutations detected, 1 refused by integrity, control clean)"
else
  echo "mutation tests: FAIL (artifacts kept in $W)"
fi
exit "$status"
