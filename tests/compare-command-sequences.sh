#!/bin/bash
# Proves that the split installer does exactly what the single-file installer it was split from did.
#
# Phase 1  source identity: every function of the baseline (tests/baseline/oracle-ops-installer-96c8b73.sh, the installer at
#          commit 96c8b73, SHA-256 pinned below) exists byte-for-byte in oracle-ops-installer.sh or lib/*.sh, except the four
#          functions that 0.2.0 is allowed to change, each by an exactly described edit: main() (three added lines: the loader's
#          ownership check, the command-line dispatch of status/validate, the pruning of check logs), parse_args() (a prelude that
#          hands "status"/"validate" to parse_check_args), menu() (items 5 Status, 6 Validate, 7 Exit) and usage() (the text). No
#          other non-comment line of the baseline is missing from the new code (the lines replaced by those edits and the version
#          string are listed explicitly below). init_logging, init_state, prune_logs and every install/upgrade/de-install/
#          credential function are byte-identical.
# Phase 2  behaviour: each of the 58 baseline tests runs once against the baseline and once against the new entry script, in
#          record mode (a failed assertion is recorded, not fatal, so multi-run tests run to the end). For EVERY run_installer
#          call the following are compared after normalisation: exit status; terminal output; the Oracle OPS script trace
#          (roothome/trace); the git, local-git, yum, systemctl and forbidden-tool traces; and the sandbox tree (path, type,
#          mode, size, link target; jars by the content of their entries; the installer log directory listing, the logs
#          created by the run normalised); and the lines the run appended to the installer log (time stamps and pids
#          normalised). Normalised: the sandbox and test-root paths, the fixture commit ids, random
#          run.XXXXXXXX / oracle-ops-installer.XXXXXXXX names, .retired-<time stamp>, the names of the logs the runs created (a single token: two runs in the same second share one log file).
# Prints one line per test; exits 0 only if all tests are equal. Needs no root, no network, nothing outside TMPDIR.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO="$PWD"

BASELINE="tests/baseline/oracle-ops-installer-96c8b73.sh"
BASELINE_SHA256="ee07539450b8517d7d7378b38e94eb1b10715eb6df8b478f0646386e791891d4"

# The ONLY differences accepted between the baseline and 0.2.0 in what an operator sees or the log records (everything else:
# exit status, every trace, the sandbox tree, every other line of output and log must be equal). The sed programs below are
# applied to the output and to the log delta of one side (the baseline's menu has "5) Exit" and [1-5], 0.2.0 has 7 entries):
#   1. the menu lines "5) Status" and "6) Validate" (new) and the number of "Exit" (5 in the baseline, 7 now)
#   2. the menu prompt range ("[1-5]" / "[1-7]") and the list of choices repeated after an invalid answer
#   3. the installer version string (0.1.0 / 0.2.0)
#   4. the --help / usage text (the whole block from "Usage:" to "Logs:")
#   5. the log line "menu choice: N" when N is the Exit entry (5 in the baseline, 7 now)
ALLOWED_DIFFS_DESCRIPTION="menu entries 5 Status/6 Validate/Exit number, prompt range, version string, --help text, 'menu choice' of Exit"
allowed_sed() {   # allowed_sed <base|new>: sed program for that side
  if [ "$1" = base ]; then
    printf '%s\n' 's/^  5) Exit$/  <EXIT-ENTRY>/' 's/Choose an option \[1-5\]: /Choose an option [<RANGE>]: /' \
      's/Please enter one of: 1 2 3 4 5$/Please enter one of: <CHOICES>/' 's/Oracle OPS Installer 0\.1\.0/Oracle OPS Installer <VERSION>/' \
      's/menu choice: 5$/menu choice: <EXIT>/'
  else
    printf '%s\n' '/^  5) Status$/d' '/^  6) Validate$/d' 's/^  7) Exit$/  <EXIT-ENTRY>/' 's/Choose an option \[1-7\]: /Choose an option [<RANGE>]: /' \
      's/Please enter one of: 1 2 3 4 5 6 7$/Please enter one of: <CHOICES>/' 's/Oracle OPS Installer 0\.2\.0/Oracle OPS Installer <VERSION>/' \
      's/menu choice: 7$/menu choice: <EXIT>/'
  fi
}
# the usage text block (from the line "Usage: " to the line "Logs: ") is one allowed difference
USAGE_AWK='/^Usage: /{ if (!u) print "<USAGE TEXT>"; u = 1; skip = 1 } skip { if (/^Logs: /) skip = 0; next } { print }'
# Functions whose text may differ from the baseline (each checked below against an exactly described edit).
CHANGED_FUNCTIONS="main parse_args menu usage"
# main(): exactly these lines were added (each once); with them removed the text is the baseline's.
MAIN_ADDED_LINES=(
  '  ldr_check_sourced_install'
  '  [ -z "$CLI_MODE" ] || check_main "$CLI_MODE"   # status / validate: the strict read-only path; never returns'
  '  prune_check_logs'
)
# parse_args(): this prelude follows the first line "parse_args() {"; the rest is the baseline's.
PARSE_ARGS_PRELUDE='  if [ "${1:-}" = status ] || [ "${1:-}" = validate ]; then
    parse_check_args "$@"
    return 0
  fi'
# menu(): the baseline with exactly these substitutions (applied by sed to the baseline text) is the new text.
MENU_SED='s/^  say "  5) Exit"$/  say "  5) Status"\n  say "  6) Validate"\n  say "  7) Exit"/;s/^  choose c "Choose an option \[1-5\]: " 1 2 3 4 5$/  choose c "Choose an option [1-7]: " 1 2 3 4 5 6 7/;s/^    5) finish 0 ;;$/    5) op_status ;;\n    6) op_validate ;;\n    7) finish 0 ;;/'
# baseline code lines that are not in the new code on purpose (replaced by the edits above, version, usage text)
LOST_CODE_ALLOWED=(
  'INSTALLER_VERSION="0.1.0"'
  '  say "  5) Exit"'
  '  choose c "Choose an option [1-5]: " 1 2 3 4 5'
  '    5) finish 0 ;;'
  'install, update credentials, upgrade, de-install. Oracle APEX is not part of this installer.'
)

TESTS="test_authentication_fails test_concurrent_run_is_refused test_database_password_guidance_changes_nothing
test_deinstall_declined test_deinstall_success_renames_and_keeps_credentials test_deinstall_without_installation
test_end_of_input_at_menu_is_a_cancellation test_existing_installation_is_never_overwritten_by_install
test_exit_option_changes_nothing test_git_runs_isolated_and_askpass_is_host_bound test_help_version_and_bad_argument
test_incomplete_earlier_installation_needs_confirmation test_installation_directory_symlink_or_foreign
test_install_passes_java_archive test_install_runs_only_the_deploy_script_and_nothing_apex test_install_success
test_interrupt_during_installation_cleans_up test_invalid_installation_directory test_invalid_menu_choice
test_invalid_token_format_is_rejected_before_use test_leftover_staging_directory_of_an_interrupted_run
test_log_rotation_keeps_the_newest_and_nothing_else_is_removed test_missing_prerequisite_automatic
test_missing_prerequisite_manual test_network_failure test_partial_clone_is_removed
test_pasted_token_with_surrounding_whitespace_is_accepted test_pinned_reference_unavailable
test_prerequisite_installation_fails test_prerequisite_still_missing_after_installation test_release_version_mismatch
test_repeated_install_is_safe test_repository_access_denied test_requires_root test_requires_terminal
test_setup_assistant_fails test_symlinked_or_foreign_owned_directories_are_refused
test_token_directory_on_tmpfs_is_used_and_removed test_token_is_redacted_if_a_tool_prints_it
test_token_without_a_known_prefix_is_redacted test_unrelated_data_in_staging_directory_stops_the_run
test_unsupported_operating_system test_update_weblogic_credential test_update_weblogic_credential_declined
test_update_weblogic_credential_wrong_permissions_detected test_upgrade_already_current
test_upgrade_declined_changes_nothing test_upgrade_identity_check_failure test_upgrade_needs_configuration_and_credentials
test_upgrade_preflight_failure test_upgrade_resumes_a_deployed_but_inactive_release
test_upgrade_same_version_from_other_source_is_refused test_upgrade_script_failure test_upgrade_success
test_upgrade_unhealthy_database_is_a_failure test_upgrade_without_installation
test_verification_failure_is_reported_and_runtime_kept test_verification_failure_without_active_release"

status=0
setup_fail() { echo "compare-command-sequences: $*" >&2; exit 2; }

# ---- setup ----------------------------------------------------------------------------------------------------------------
[ -f "$BASELINE" ] || setup_fail "missing $BASELINE"
got="$(sha256sum "$BASELINE" | cut -d' ' -f1)"
[ "$got" = "$BASELINE_SHA256" ] || setup_fail "$BASELINE does not match its pinned SHA-256 ($got)"
n=0
for t in $TESTS; do
  n=$((n + 1))
  grep -q "^$t()" tests/installer-test.sh || setup_fail "tests/installer-test.sh has no $t"
done
[ "$n" = 58 ] || setup_fail "expected 58 baseline tests, the list has $n"

W="$(mktemp -d "${TMPDIR:-/tmp}/oracle-ops-compare.XXXXXX")" || setup_fail "cannot create a work directory"
mkdir -p "$W/fn-base" "$W/fn-new" "$W/run-base" "$W/run-new" "$W/norm-base" "$W/norm-new"

echo "baseline: $BASELINE (SHA-256 $BASELINE_SHA256)"
echo "allowed differences: $ALLOWED_DIFFS_DESCRIPTION"

# ---- phase 1: source identity ---------------------------------------------------------------------------------------------
# extract_functions <dir> <files...>: one file <name>.fn per function. A function starts at "name() {" in column 0 and ends
# on the same line (one-liner) or at the next line that is exactly "}".
extract_functions() {
  local dir="$1"
  shift
  awk -v out="$dir" '
    infn { print > path; if ($0 == "}") { infn = 0; close(path) } next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/ {
      name = $0; sub(/\(\).*/, "", name)
      if (name in seen) { print "DUPLICATE " name " in " FILENAME > "/dev/stderr"; bad = 1 }
      seen[name] = 1
      path = out "/" name ".fn"
      print > path
      if ($0 ~ /\(\) \{ .*\}[ \t]*$/) { close(path) } else { infn = 1 }
    }
    END { exit bad }
  ' "$@"
}

phase1_ok=1
extract_functions "$W/fn-base" "$BASELINE" || phase1_ok=0
extract_functions "$W/fn-new" oracle-ops-installer.sh lib/*.sh || phase1_ok=0
nbase="$(find "$W/fn-base" -name '*.fn' | wc -l)"
identical=0; changed=""; missing=""
for f in "$W"/fn-base/*.fn; do
  name="$(basename "$f" .fn)"
  if [ ! -f "$W/fn-new/$name.fn" ]; then missing="$missing $name"; continue; fi
  if cmp -s "$f" "$W/fn-new/$name.fn"; then identical=$((identical + 1)); continue; fi
  case " $CHANGED_FUNCTIONS " in
    *" $name "*)
      ok=0
      case "$name" in
        main)   # the new text, minus the added lines (each exactly once), is the baseline text
          cp "$W/fn-new/main.fn" "$W/main.stripped"
          for l in "${MAIN_ADDED_LINES[@]}"; do
            [ "$(grep -cxF -- "$l" "$W/main.stripped")" = 1 ] || { cp /dev/null "$W/main.stripped"; break; }
            grep -vxF -- "$l" "$W/main.stripped" > "$W/main.stripped2"; mv "$W/main.stripped2" "$W/main.stripped"
          done
          if cmp -s "$W/main.stripped" "$f"; then ok=1; changed="$changed main(+${#MAIN_ADDED_LINES[@]} lines)"; fi ;;
        parse_args)   # baseline first line, the prelude, the rest of the baseline
          { head -n 1 "$f"; printf '%s\n' "$PARSE_ARGS_PRELUDE"; tail -n +2 "$f"; } > "$W/parse_args.expected"
          if cmp -s "$W/parse_args.expected" "$W/fn-new/parse_args.fn"; then ok=1; changed="$changed parse_args(+prelude)"; fi ;;
        menu)   # the baseline with the described substitutions
          sed -e "$MENU_SED" "$f" > "$W/menu.expected"
          if cmp -s "$W/menu.expected" "$W/fn-new/menu.fn"; then ok=1; changed="$changed menu(items 5-7)"; fi ;;
        usage)   # only the one replaced line of the baseline text is gone; every other baseline line is still there, in order
          grep -vxF -f "$W/fn-new/usage.fn" "$f" > "$W/usage.gone"
          if [ "$(wc -l < "$W/usage.gone")" = 1 ] \
             && grep -qxF 'install, update credentials, upgrade, de-install. Oracle APEX is not part of this installer.' "$W/usage.gone"; then
            ok=1; changed="$changed usage(text)"
          fi ;;
      esac
      [ "$ok" = 1 ] || missing="$missing $name(changed beyond the allowed edit)" ;;
    *) missing="$missing $name(text differs)"; diff "$f" "$W/fn-new/$name.fn" | head -n 10 | sed 's/^/    /' ;;
  esac
done
added="$(for f in "$W"/fn-new/*.fn; do n="$(basename "$f" .fn)"; [ -f "$W/fn-base/$n.fn" ] || printf ' %s' "$n"; done)"
# no non-comment baseline line may be missing from the new code (headers/comments were rewritten)
cat oracle-ops-installer.sh lib/*.sh | LC_ALL=C sort > "$W/new-lines"
LC_ALL=C sort "$BASELINE" > "$W/base-lines"
lost="$(LC_ALL=C comm -23 "$W/base-lines" "$W/new-lines")"
printf '%s\n' "${LOST_CODE_ALLOWED[@]}" | LC_ALL=C sort > "$W/lost-allowed"
lost_code="$(printf '%s\n' "$lost" | grep -v -E '^[[:space:]]*(#|$)' | grep -vxF -f "$W/lost-allowed" || true)"
echo "phase 1 (source identity): $nbase baseline functions: $identical byte-identical, changed:${changed:- none}, missing/different:${missing:- none}"
echo "  functions added by the split:$added"
echo "  baseline comment lines not carried over: $(printf '%s\n' "$lost" | grep -c -E '^[[:space:]]*#')"
if [ -n "$lost_code" ]; then echo "  baseline code lines missing from the new code:"; printf '%s\n' "$lost_code" | sed 's/^/    /'; phase1_ok=0; fi
[ -z "$missing" ] || phase1_ok=0
[ "$phase1_ok" = 1 ] && echo "phase 1: OK" || { echo "phase 1: FAILED"; status=1; }

# ---- phase 2: behaviour ---------------------------------------------------------------------------------------------------
esc() { printf '%s' "$1" | sed 's/[][\\.*^$/]/\\&/g'; }

# normalise <side> <rundir> <outdir>: copies every recorded file of one run_installer call, normalised, into <outdir>
normalise() {
  local side="$1" rd="$2" od="$3" sb root fix later n f
  mkdir -p "$od"
  sb="$(sed -n 's/^SB=//p' "$rd/meta")"; root="$(sed -n 's/^TEST_ROOT=//p' "$rd/meta")"
  fix="$(sed -n 's/^FIX_COMMIT=//p' "$rd/meta")"; later="$(sed -n 's/^FIX_LATER_COMMIT=//p' "$rd/meta")"
  local script="$od/.sed"
  : > "$script"
  allowed_sed "$side" > "$od/.allowed"
  printf 's/%s/<SB>/g\n' "$(esc "$sb")" >> "$script"
  printf 's/%s/<TEST_ROOT>/g\n' "$(esc "$root")" >> "$script"
  printf 's/%s/<FIX_COMMIT>/g\ns/%s/<FIX_LATER_COMMIT>/g\n' "$fix" "$later" >> "$script"
  printf 's/%s/<FIX7>/g\ns/%s/<FIXLATER7>/g\n' "${fix:0:7}" "${later:0:7}" >> "$script"
  while IFS= read -r n; do   # the logs the runs of this test have created so far (two runs in the same second share a name)
    printf 's/%s/<LOG>/g\n' "$(esc "$n")" >> "$script"
  done < <(sed -n 's/^LOG=//p' "$rd/meta")
  cat >> "$script" <<'SED'
s/run\.[A-Za-z0-9]\{8\}/run.<RAND>/g
s/oracle-ops-installer\.[A-Za-z0-9]\{8\}/oracle-ops-installer.<RAND>/g
s/\.retired-[0-9]\{8\}T[0-9]\{6\}Z/.retired-<TS>/g
s/^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:]\{8\}Z /<TIME> /
s/ pid [0-9]\{1,\}/ pid <PID>/g
SED
  for f in rc out roothome-trace git-trace git-local-trace yum-trace systemctl-trace forbidden-trace tree logs; do
    case "$f" in
      out) sed -f "$script" "$rd/$f" | sed -f "$od/.allowed" | awk "$USAGE_AWK" > "$od/$f" ;;
      logs) sed -f "$script" "$rd/$f" | sed -f "$od/.allowed" > "$od/$f" ;;
      *) sed -f "$script" "$rd/$f" > "$od/$f" ;;
    esac
  done
  LC_ALL=C sort -u -o "$od/tree" "$od/tree"   # -u: several runs within one second reuse one log name, across a second they do not
  rm -f "$script" "$od/.allowed"
}

run_side() {  # run_side <side: base|new> <test>
  local side="$1" t="$2" res
  if [ "$side" = base ]; then
    res="$(COMPARE_MODE=1 MENU_EXIT=5 COMPARE_OUT="$W/run-base" INSTALLER_UNDER_TEST="$REPO/$BASELINE" bash tests/installer-test.sh "$t" 2>&1 | grep -E '^(PASS|FAIL) ')"
  else
    res="$(COMPARE_MODE=1 MENU_EXIT=7 COMPARE_OUT="$W/run-new" bash tests/installer-test.sh "$t" 2>&1 | grep -E '^(PASS|FAIL) ')"
  fi
  printf '%s\n' "$res" > "$W/run-$side/$t.result"
}

echo
printf '%-78s %-6s %s\n' "test" "runs" "result"
equal=0; different=0
for t in $TESTS; do
  run_side base "$t"
  run_side new "$t"
  problems=""
  bruns="$(find "$W/run-base/$t" -maxdepth 1 -type d -name 'run*' 2>/dev/null | wc -l)"
  nruns="$(find "$W/run-new/$t" -maxdepth 1 -type d -name 'run*' 2>/dev/null | wc -l)"
  [ "$bruns" = "$nruns" ] || problems="$problems number of installer runs differs ($bruns vs $nruns);"
  [ "$bruns" -gt 0 ] || problems="$problems no run was recorded;"
  [ "$(cat "$W/run-base/$t.result")" = "PASS $t" ] || problems="$problems baseline did not report PASS;"
  [ "$(cat "$W/run-new/$t.result")" = "PASS $t" ] || problems="$problems new code did not report PASS;"
  [ ! -s "$W/run-base/$t/assertions" ] || problems="$problems baseline assertion failed;"
  [ ! -s "$W/run-new/$t/assertions" ] || problems="$problems new code assertion failed;"
  r=1
  while [ "$r" -le "$bruns" ] && [ -d "$W/run-new/$t/run$r" ]; do
    normalise base "$W/run-base/$t/run$r" "$W/norm-base/$t/run$r"
    normalise new "$W/run-new/$t/run$r" "$W/norm-new/$t/run$r"
    for f in rc out roothome-trace git-trace git-local-trace yum-trace systemctl-trace forbidden-trace tree logs; do
      if ! cmp -s "$W/norm-base/$t/run$r/$f" "$W/norm-new/$t/run$r/$f"; then
        problems="$problems run$r $f differs;"
        diff "$W/norm-base/$t/run$r/$f" "$W/norm-new/$t/run$r/$f" | head -n 6 | sed 's/^/        /' >> "$W/diff-$t.txt"
      fi
    done
    for side in base new; do
      [ "$(sed -n '1p' "$W/norm-$side/$t/run$r/forbidden-trace")" = "<absent>" ] || problems="$problems $side run$r called a forbidden tool;"
    done
    r=$((r + 1))
  done
  if [ -z "$problems" ]; then
    equal=$((equal + 1)); printf '%-78s %-6s %s\n' "$t" "$bruns" "EQUAL"
  else
    different=$((different + 1)); printf '%-78s %-6s %s\n' "$t" "$bruns/$nruns" "DIFFERENT:$problems"
    [ ! -f "$W/diff-$t.txt" ] || cat "$W/diff-$t.txt"
  fi
done

echo
echo "comparison: $equal equal, $different different (of 58); the allowed differences: $ALLOWED_DIFFS_DESCRIPTION"
[ "$equal" = 58 ] || status=1
if [ "$status" = 0 ]; then
  rm -rf -- "$W"
  echo "command-sequence comparison: PASS (58/58 equal)"
else
  echo "command-sequence comparison: FAIL (artifacts kept in $W)"
fi
exit "$status"
