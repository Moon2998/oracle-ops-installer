#!/bin/bash
# Tests of the read-only checks (status, validate), their strict command-line start-up, their menu items, the static guard and
# the security boundary. Sourced by tests/installer-test.sh (so tests/run-tests.sh and tests/mutation-tests.sh run them);
# hermetic, non-root, no network, no database.

CHECK_NAMES="unit home current-release build-commit other-releases runtime service service-log configuration credential-directory credential-files installer-state ops-check"
VALIDATE_NAMES="source-repository source-commit source-archive source-verify config-validate service-identity run-directory"
MARK_YAML="MARKER-APPLICATION-YAML-5c1f77"
MARK_CRED="MARKER-CREDENTIAL-9e2b41"
JDK_VERSION="21.0.12.1"

LOGD() { printf '%s' "$SB/var/log/oracle-ops-installer"; }
STATED() { printf '%s' "$SB/var/lib/oracle-ops-installer"; }
CRED() { printf '%s' "$SB/etc/oracle-ops"; }
check_logs() { ls "$(LOGD)" 2>/dev/null | grep '^oracle-ops-check-[0-9]*T[0-9]*Z-[0-9]*\.log$'; }
install_logs() { ls "$(LOGD)" 2>/dev/null | grep '^oracle-ops-installer-[0-9]*T[0-9]*Z-[0-9]*\.log$'; }
check_log_file() { local n; n="$(check_logs | tail -n 1)"; [ -n "$n" ] || fail "no check log was written"; printf '%s/%s' "$(LOGD)" "$n"; }

# A healthy installation of the pinned fixture release: unit, current release with its jar, runtime, configuration, credential
# files (with unique marker content: no check may ever print it), service log, and the fake service process of the proc seam.
healthy_install() {
  local h cr f
  h="$(HOME_DIR)"; cr="$(CRED)"
  existing_install "$FIX_VERSION" "${FIX_COMMIT:0:7}" active
  printf 'jdk.version=%s\n' "$JDK_VERSION" > "$h/releases/$FIX_VERSION/runtime.properties"
  mkdir -p "$h/runtime/java/$JDK_VERSION/bin"
  printf '#!/bin/bash\necho "java called: $*" >> %q\nexit 1\n' "$SB/java-called" > "$h/runtime/java/$JDK_VERSION/bin/java"
  chmod 0755 "$h/runtime/java/$JDK_VERSION/bin/java"
  ln -s "$JDK_VERSION" "$h/runtime/java/current"
  printf '%s\n' "$MARK_YAML" > "$h/config/application.yaml"; chmod 0640 "$h/config/application.yaml"
  chmod 0750 "$cr"
  for f in database api api-control; do printf '%s %s\n' "$MARK_CRED" "$f" > "$cr/$f.credentials"; chmod 0640 "$cr/$f.credentials"; done
  printf '%s apps\n' "$MARK_CRED" > "$cr/apps.credentials"; chmod 0400 "$cr/apps.credentials"
  chmod 0644 "$SB/etc/systemd/system/oracle-ops.service"
  printf '%s\n' "2026-11-03 10:00:00.000 INFO Starting Oracle OPS v$FIX_VERSION (build 2026-11-03T09:00:00Z, commit ${FIX_COMMIT:0:7})" \
    "2026-11-03 10:00:03.000 INFO Database connectivity startup health check: HEALTHY (12ms)" \
    "2026-11-03 10:00:04.000 INFO Oracle OPS is RUNNING" > "$h/logs/oracle-ops.log"
  printf 'OWNER=%s:%s\nEXE=%s\n' "$(id -un)" "$(id -gn)" "$(readlink -f "$h")/runtime/java/$JDK_VERSION/bin/java" > "$SB/proc-owner-exe"
}
reset_healthy() { chmod -R u+rwx "$SB/u01" "$SB/etc/oracle-ops" 2>/dev/null; rm -rf "$SB/u01/oracle_ops_runtime" "$SB/etc/oracle-ops" "$SB/etc/systemd/system/oracle-ops.service" "$SB/proc-owner-exe" "$SB/systemctl-show" "$SB/systemctl-show-fail"; healthy_install; }

item_is() {   # item_is <OK|WARN|FAIL> <item name>
  local l
  l="$(grep -E "^(OK|WARN|FAIL)  $2:" "$SB/out" | head -n 1)"
  [ "${l%% *}" = "$1" ] || fail "item $2 is '${l:-<missing>}', expected $1"
}
item_text() { grep -E "^(OK|WARN|FAIL)  $1:" "$SB/out" | head -n 1; }
assert_items() {   # assert_items <status> <names...>
  local s="$1" n
  shift
  for n in "$@"; do item_is "$s" "$n"; done
}
assert_markers_absent() {
  local hits
  hits="$(grep -rlF -e "$MARK_YAML" -e "$MARK_CRED" "$SB/out" "$(LOGD)" "$SB/systemctl-trace" "$SB/git-local-trace" "$SB/roothome/trace" 2>/dev/null)"
  [ -z "$hits" ] || fail "configuration or credential content appeared in: $hits"
}
assert_readonly_traces() {   # status: systemctl is-active/show only; no git, no OPS script, no forbidden tool, no java
  local bad
  bad="$(grep -vE '^(is-active|show) ' "$SB/systemctl-trace" 2>/dev/null)"
  [ -z "$bad" ] || fail "systemctl was called with something other than is-active/show: $bad"
  assert_absent "$SB/forbidden-trace"; assert_absent "$SB/java-called"
}
assert_status_only() { assert_readonly_traces; assert_absent "$SB/git-trace"; assert_absent "$SB/git-local-trace"; assert_no_trace; }

# ---- status ----------------------------------------------------------------------------------------------------------------

test_status_healthy_installation_is_all_ok() {
  healthy_install
  run_installer status
  assert_rc 0
  assert_out "status: OK 13, WARN 0, FAIL 0"
  assert_items OK $CHECK_NAMES
  assert_status_only; assert_clean; assert_markers_absent
  [ "$(check_logs | wc -l)" = 1 ] || fail "expected one check log"
  [ -z "$(install_logs)" ] || fail "a command-line status wrote an installer log"
  [ "$(stat -c %a "$(check_log_file)")" = 600 ] || fail "the check log is not mode 600"
  grep -qF "OK  unit:" "$(check_log_file)" || fail "the items are not in the check log"
  assert_out "Log: $(check_log_file)"
  assert_out "latest state: "; assert_out "Oracle OPS is RUNNING"
  # the same status needs no terminal and asks nothing
  EXTRA='stdin_is_tty() { return 1; }'
  run_installer status; assert_rc 0; assert_out "status: OK 13, WARN 0, FAIL 0"
}

test_status_pin_differences_are_warnings_only() {
  healthy_install
  EXTRA='OPS_COMMIT=1111111111111111111111111111111111111111; OPS_VERSION=9.9.9'
  run_installer status
  assert_rc 0; assert_out "status: OK 11, WARN 2, FAIL 0"
  item_is WARN current-release; item_is WARN build-commit
  assert_out "differs from the pinned commit"
}

test_status_not_installed_is_exit_6() {
  run_installer status
  assert_rc 6; assert_out "not installed"; assert_not_out "status: OK"
  assert_status_only; assert_clean
  # an explicit --home without a unit is examined, and the missing unit is a failure
  run_installer status --home "$(HOME_DIR)"
  assert_rc 1; item_is FAIL unit; item_is FAIL home
}

test_status_home_option_must_match_the_unit() {
  healthy_install
  run_installer status --home "$SB/u01/other"
  assert_rc 1; item_is FAIL home; assert_out "does not match the installation directory the unit names"
  run_installer status --home "$(HOME_DIR)";  assert_rc 0
  run_installer status "--home=$(HOME_DIR)/"; assert_rc 0
}

test_status_service_problems_are_failures() {
  healthy_install
  echo inactive > "$SB/systemctl-state"
  run_installer status; assert_rc 1; item_is FAIL service; assert_out "is not running"
  echo active > "$SB/systemctl-state"
  printf 'OWNER=nobody:nobody\nEXE=%s/runtime/java/%s/bin/java\n' "$(readlink -f "$(HOME_DIR)")" "$JDK_VERSION" > "$SB/proc-owner-exe"
  run_installer status; assert_rc 1; item_is FAIL service; assert_out "runs as nobody:nobody"
  printf 'OWNER=%s:%s\nEXE=/usr/bin/java\n' "$(id -un)" "$(id -gn)" > "$SB/proc-owner-exe"
  run_installer status; assert_rc 1; item_is FAIL service; assert_out "not a program under"
  healthy_install
  printf 'ActiveState=active\nSubState=running\nMainPID=0\nActiveEnterTimestamp=x\n' > "$SB/systemctl-show"
  run_installer status; assert_rc 1; item_is FAIL service; assert_out "no main process"
  printf 'ActiveState=active\nSubState=running\nMainPID=4242\nActiveEnterTimestamp=x\n' > "$SB/systemctl-show"
  rm -f "$SB/proc-owner-exe"
  run_installer status; assert_rc 1; item_is FAIL service; assert_out "cannot be read from /proc"
  healthy_install
  touch "$SB/systemctl-show-fail"
  run_installer status; assert_rc 1; item_is FAIL service; assert_out "cannot be determined"
  assert_readonly_traces
}

test_status_metadata_deviations_are_failures() {
  local h cr
  h="$(HOME_DIR)"; cr="$(CRED)"
  healthy_install
  chmod 0644 "$h/config/application.yaml"
  run_installer status; assert_rc 1; item_is FAIL configuration; assert_out "mode is 644, expected 640"
  reset_healthy; rm "$h/config/application.yaml"
  run_installer status; assert_rc 1; item_is FAIL configuration; assert_out "does not exist"
  reset_healthy; rm "$h/config/application.yaml"; ln -s "$SB/etc/os-release" "$h/config/application.yaml"
  run_installer status; assert_rc 1; item_is FAIL configuration; assert_out "is a symbolic link"
  reset_healthy; chmod 0755 "$cr"
  run_installer status; assert_rc 1; item_is FAIL credential-directory; assert_out "mode is 755, expected 750"
  reset_healthy; chmod 0644 "$cr/database.credentials"
  run_installer status; assert_rc 1; item_is FAIL credential-files; assert_out "database.credentials: mode is 644"
  reset_healthy; chmod 0440 "$cr/apps.credentials"
  run_installer status; assert_rc 1; item_is FAIL credential-files; assert_out "apps.credentials: mode is 440"
  reset_healthy; rm "$cr/api.credentials"; ln -s "$cr/database.credentials" "$cr/api.credentials"
  run_installer status; assert_rc 1; item_is FAIL credential-files; assert_out "api.credentials: $cr/api.credentials is a symbolic link"
  reset_healthy; ln "$cr/api-control.credentials" "$SB/hardlink-to-credential"
  run_installer status; assert_rc 1; item_is FAIL credential-files; assert_out "2 hard links"
  reset_healthy; rm -rf "$cr/api.credentials"; mkdir "$cr/api.credentials"
  run_installer status; assert_rc 1; item_is FAIL credential-files; assert_out "not a regular file (directory)"
  reset_healthy; chmod 0664 "$SB/etc/systemd/system/oracle-ops.service"
  run_installer status; assert_rc 1; item_is FAIL unit; assert_out "writable by group or other users"
  reset_healthy; rm "$SB/etc/systemd/system/oracle-ops.service"; ln -s "$SB/etc/os-release" "$SB/etc/systemd/system/oracle-ops.service"
  run_installer status; assert_rc 1; item_is FAIL unit; assert_out "is a symbolic link"
  # optional credential files may be absent
  reset_healthy; rm "$cr/api.credentials" "$cr/api-control.credentials" "$cr/apps.credentials"
  run_installer status; assert_rc 0; item_is OK credential-files; assert_out "not present: api.credentials, api-control.credentials, apps.credentials"
  assert_markers_absent
}

test_status_undeterminable_items_are_failures() {
  local h
  h="$(HOME_DIR)"
  healthy_install
  rm -f "$SB/bin/unzip"
  run_installer status; assert_rc 1; item_is FAIL build-commit; assert_out "required tool unzip is missing"
  ln -s "$SB/reserve/unzip" "$SB/bin/unzip"
  reset_healthy; rm "$h/logs/oracle-ops.log"
  run_installer status; assert_rc 1; item_is FAIL service-log
  reset_healthy; rm "$h/releases/$FIX_VERSION/runtime.properties"
  run_installer status; assert_rc 1; item_is FAIL runtime; assert_out "no jdk.version"
  reset_healthy; rm "$h/runtime/java/current"; ln -s other "$h/runtime/java/current"
  run_installer status; assert_rc 1; item_is FAIL runtime
  reset_healthy; rm "$h/current"
  run_installer status; assert_rc 1; item_is FAIL current-release; item_is FAIL build-commit
  reset_healthy; rm -rf "$h/releases"; mkdir "$h/releases"
  run_installer status; assert_rc 1; item_is FAIL current-release
  reset_healthy; printf 'junk\n' > "$h/releases/$FIX_VERSION/VERSION"
  run_installer status; assert_rc 1; item_is FAIL current-release; assert_out "VERSION is 'junk'"
  reset_healthy; printf '%s\n' "no lifecycle lines here" > "$h/logs/oracle-ops.log"
  run_installer status; assert_rc 0; item_is WARN service-log
  reset_healthy; : > "$SB/etc/systemd/system/oracle-ops.service"; chmod 0644 "$SB/etc/systemd/system/oracle-ops.service"
  run_installer status; assert_rc 1; item_is FAIL unit; assert_out "no usable User="
}

test_status_other_releases_are_listed() {
  local h
  h="$(HOME_DIR)"
  healthy_install
  mkdir -p "$h/releases/0.1.4"; printf '0.1.4\n' > "$h/releases/0.1.4/VERSION"
  python3 -I - "$h/releases/0.1.4/oracle-ops.jar" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('com/oracleops/core/version.properties', 'version=0.1.4\nbuild.gitCommit=abc1234\n')
z.close()
PY
  run_installer status; assert_rc 0; item_is OK other-releases; assert_out "0.1.4 (commit abc1234)"
}

test_status_requires_root_and_checks_usage() {
  EXTRA='is_root() { return 1; }'
  run_installer status; assert_rc 2; assert_out "run the installer as root"
  assert_absent "$SB/var/log/oracle-ops-installer"; assert_absent "$SB/var/lib/oracle-ops-installer"
  EXTRA=""
  local bad
  for bad in "status --bogus" "status extra" "status --java-archive /x" "status --home" "status --home a" "status --home $SB/u01/a --home $SB/u01/b" \
             "status --source-repo $SB/u01/a" "validate --source-repo" "validate --source-repo rel" "validate --source-repo $SB/u01/a --source-repo $SB/u01/b" \
             "validate --home /etc" "validate --java-archive x" "validate --bogus" "validate x" "--java-archive $SB/a status" "status --version"; do
    # shellcheck disable=SC2086
    run_installer $bad
    [ "$RC" = 2 ] || fail "'$bad' exited $RC, expected 2"
  done
  assert_absent "$SB/var/log/oracle-ops-installer"; assert_absent "$SB/var/lib/oracle-ops-installer"; assert_absent "$SB/systemctl-trace"
  run_installer status --help; assert_rc 0; assert_out "sudo bash"; assert_out "validate [--home DIR] [--source-repo DIR]"
}

# ---- strict command-line start-up (R2) ---------------------------------------------------------------------------------------

test_check_cli_creates_missing_directories_and_the_lock() {
  healthy_install
  run_installer status
  assert_rc 0
  [ "$(stat -c %a "$(LOGD)")" = 700 ] && [ "$(stat -c %a "$(STATED)")" = 700 ] || fail "the directories were not created with mode 0700"
  assert_exists "$(STATED)/.lock"; assert_clean
}

test_check_cli_refuses_unsafe_directories() {
  healthy_install
  mkdir -p "$SB/var/log" "$SB/var/lib"
  ln -s "$SB/elsewhere" "$(LOGD)"; mkdir "$SB/elsewhere"
  run_installer status; assert_rc 1; assert_out "symbolic link"; assert_absent "$SB/elsewhere/oracle-ops-check-x"
  [ -z "$(ls "$SB/elsewhere")" ] || fail "something was written through the link"
  rm "$(LOGD)"; mkdir -m 0770 "$(LOGD)"
  run_installer status; assert_rc 1; assert_out "writable by group or other users"
  [ "$(stat -c %a "$(LOGD)")" = 770 ] || fail "the mode of the log directory was changed"
  rmdir "$(LOGD)"; mkdir -m 0700 "$(LOGD)"
  ln -s "$SB/elsewhere" "$(STATED)"
  run_installer status; assert_rc 1; assert_out "state directory"; assert_out "symbolic link"
  rm "$(STATED)"; mkdir -m 0777 "$(STATED)"; chmod 0777 "$(STATED)"
  run_installer status; assert_rc 1; assert_out "writable by group or other users"
  rmdir "$(STATED)"; mkdir -m 0700 "$(STATED)"
  EXTRA='ADMIN_UID=99999'
  run_installer status; assert_rc 1; assert_out "not owned by root"
  EXTRA=""
  run_installer status; assert_rc 0                                                            # control: the same directories are fine
  rm -rf "$(LOGD)"; chmod 0777 "$SB/var/log"
  run_installer status; assert_rc 1; assert_out "writable by group or other users"            # a missing directory under an unsafe parent
  assert_absent "$(LOGD)"; chmod 0755 "$SB/var/log"
  printf 'x' > "$(LOGD)"
  run_installer status; assert_rc 1; assert_out "not a directory"
}

test_check_cli_other_modes_warn_and_are_not_changed() {
  healthy_install
  mkdir -m 0750 -p "$(LOGD)" "$(STATED)"; chmod 0750 "$(LOGD)" "$(STATED)"
  : > "$(STATED)/.lock"
  run_installer status
  assert_rc 0; item_is WARN installer-state; assert_out "has mode 750, not 0700"
  [ "$(stat -c %a "$(LOGD)")" = 750 ] && [ "$(stat -c %a "$(STATED)")" = 750 ] || fail "a read-only check changed a directory mode"
}

test_check_cli_leftovers_are_reported_and_never_removed() {
  healthy_install
  mkdir -m 0700 -p "$(LOGD)" "$(STATED)"
  mkdir -m 0700 "$(STATED)/run.DEADDEAD" "$(STATED)/run.LIVELIVE" "$(STATED)/run.NOMARKER"
  printf '%s %s 2026-11-03T00:00:00Z\n' "$MARKER_TEXT_T" 999999 > "$(STATED)/run.DEADDEAD/.oracle-ops-installer-run"
  sleep 30 & local live=$!
  printf '%s %s 2026-11-03T00:00:00Z\n' "$MARKER_TEXT_T" "$live" > "$(STATED)/run.LIVELIVE/.oracle-ops-installer-run"
  : > "$(STATED)/.lock"; echo stray > "$(STATED)/stray-file"
  mkdir -m 0700 "$SB/run/oracle-ops-installer.TOKENDIR"; printf '%s 999998\n' "$MARKER_TEXT_T" > "$SB/run/oracle-ops-installer.TOKENDIR/.oracle-ops-installer-run"
  run_installer status
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  assert_rc 0; item_is WARN installer-state
  assert_out "leftover of an interrupted run, its process is gone: run.DEADDEAD"
  assert_out "$SB/run/oracle-ops-installer.TOKENDIR (token directory)"
  assert_out "unexpected entry not created by this installer: run.NOMARKER, stray-file"
  assert_out "in use by a running installer: run.LIVELIVE (pid $live)"
  assert_exists "$(STATED)/run.DEADDEAD"; assert_exists "$(STATED)/run.LIVELIVE"; assert_exists "$(STATED)/run.NOMARKER"
  assert_exists "$SB/run/oracle-ops-installer.TOKENDIR"; assert_exists "$(STATED)/stray-file"
}
MARKER_TEXT_T="oracle-ops-installer-run"

test_check_cli_log_name_is_its_own_and_install_logs_are_not_pruned() {
  healthy_install
  mkdir -m 0700 -p "$(LOGD)"
  local i
  for i in $(seq -w 1 25); do : > "$(LOGD)/oracle-ops-installer-202601${i}T000000Z-1.log"; : > "$(LOGD)/oracle-ops-check-202601${i}T000000Z-1.log"; done
  run_installer status
  assert_rc 0
  [ "$(install_logs | wc -l)" = 25 ] || fail "a command-line check pruned installer logs"
  [ "$(check_logs | wc -l)" = 26 ] || fail "a command-line check pruned check logs (it must not)"
}

test_check_lock_shared_holder_allows_status_and_exclusive_holder_refuses() {
  healthy_install
  mkdir -m 0700 -p "$(STATED)" "$(LOGD)"; : > "$(STATED)/.lock"
  local holder
  ( exec 9>>"$(STATED)/.lock"; flock -s 9; exec sleep 6 ) & holder=$!
  sleep 0.5
  run_installer status
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_rc 0; assert_out "status: OK 13"
  ( exec 9>>"$(STATED)/.lock"; flock -x 9; exec sleep 6 ) & holder=$!
  sleep 0.5
  rm -f "$SB/systemctl-trace"
  run_installer status
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_rc 1; assert_out "another run of the Oracle OPS Installer"; assert_not_out "status: OK"
  assert_absent "$SB/systemctl-trace"
}

# ---- read trap: credential and configuration files are never opened --------------------------------------------------------

make_fifos() {   # replaces the configuration and the credential files by FIFOs
  local h cr f
  h="$(HOME_DIR)"; cr="$(CRED)"
  rm -f "$h/config/application.yaml"; mkfifo -m 0640 "$h/config/application.yaml"
  for f in database api api-control; do rm -f "$cr/$f.credentials"; mkfifo -m 0640 "$cr/$f.credentials"; done
  rm -f "$cr/apps.credentials"; mkfifo -m 0400 "$cr/apps.credentials"
}
with_fifo_watchdog() {   # with_fifo_watchdog <seconds>: a watchdog that releases anything stuck on a FIFO, so a failing test cannot hang
  local h cr
  h="$(HOME_DIR)"; cr="$(CRED)"
  (
    sleep "$1"
    for f in "$h/config/application.yaml" "$cr/database.credentials" "$cr/api.credentials" "$cr/api-control.credentials" "$cr/apps.credentials"; do
      { exec 3<>"$f"; } 2>/dev/null && exec 3>&-
    done
  ) &
  WATCHDOG=$!
}
stop_watchdog() { pkill -P "$WATCHDOG" 2>/dev/null; kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null; }

test_status_never_opens_fifos_cli() {
  local start=$SECONDS
  healthy_install; make_fifos
  with_fifo_watchdog 15
  run_installer status
  stop_watchdog
  [ $((SECONDS - start)) -lt 13 ] || fail "status blocked on a FIFO (only the watchdog released it): a credential or configuration file was opened"
  assert_rc 1
  item_is FAIL configuration; item_is FAIL credential-files
  assert_out "not a regular file (fifo)"
  assert_status_only; assert_markers_absent
}

test_status_never_opens_fifos_menu() {
  local start=$SECONDS
  healthy_install; make_fifos
  input 5
  with_fifo_watchdog 15
  run_installer
  stop_watchdog
  [ $((SECONDS - start)) -lt 13 ] || fail "the menu status blocked on a FIFO: a credential or configuration file was opened"
  assert_rc 1; assert_out "not a regular file (fifo)"; assert_out "Oracle OPS status check failed"
  assert_status_only; assert_markers_absent; assert_clean
}

test_status_does_not_read_files_it_cannot_open_or_touch_their_access_time() {
  local h cr f t0 t1 control
  h="$(HOME_DIR)"; cr="$(CRED)"
  healthy_install
  t0="2020-01-01 00:00:00"
  # control: reading a file does move its access time here (otherwise this check is vacuous on this file system)
  cp -p "$cr/api.credentials" "$SB/atime-control"; touch -a -d "$t0" "$SB/atime-control"; cat "$SB/atime-control" > /dev/null
  control="$(stat -c %X "$SB/atime-control")"
  for f in "$h/config/application.yaml" "$cr/database.credentials" "$cr/api.credentials" "$cr/api-control.credentials" "$cr/apps.credentials"; do touch -a -d "$t0" "$f"; done
  run_installer status
  assert_rc 0; assert_markers_absent
  if [ "$control" != "$(date -d "$t0" +%s)" ]; then
    for f in "$h/config/application.yaml" "$cr/database.credentials" "$cr/api.credentials" "$cr/api-control.credentials" "$cr/apps.credentials"; do
      t1="$(stat -c %X "$f")"
      [ "$t1" = "$(date -d "$t0" +%s)" ] || fail "the access time of $f changed: it was read"
    done
  fi
  # mode 000 files with marker content: examined by stat, reported, never shown
  chmod 000 "$h/config/application.yaml" "$cr/database.credentials" "$cr/api.credentials" "$cr/api-control.credentials" "$cr/apps.credentials"
  run_installer status
  assert_rc 1; item_is FAIL configuration; item_is FAIL credential-files; assert_out "mode is 0, expected 640"
  assert_markers_absent
  chmod 640 "$h/config/application.yaml" "$cr/database.credentials" "$cr/api.credentials" "$cr/api-control.credentials"; chmod 400 "$cr/apps.credentials"
}

# ---- validate ----------------------------------------------------------------------------------------------------------------

assert_validate_trace() {   # exactly the two Oracle OPS checks ran, from the run directory, with the installation directory
  local scripts
  scripts="$(sed -n 's/^\([^ ]*\) args=.*/\1/p' "$SB/roothome/trace" | sort | tr '\n' ' ')"
  [ "$scripts" = "config-migrate.sh service-identity.sh " ] || fail "the Oracle OPS scripts that ran were: $scripts"
  assert_trace "config-migrate.sh args=validate --home $(HOME_DIR)"
  assert_trace "service-identity.sh args=check --home $(HOME_DIR)"
  [ "$(grep -c "cwd=$(STATED)/run\." "$SB/roothome/trace")" = 2 ] || fail "the Oracle OPS checks did not run with the run directory as working directory: $(cat "$SB/roothome/trace")"
  assert_trace "umask=0022"
}
assert_git_only_archive_and_revparse() {   # through the seam: cwd=/, rev-parse then archive, nothing else
  local n
  n="$(wc -l < "$SB/git-local-trace")"
  [ "$n" = 2 ] || fail "expected exactly 2 git calls, saw $n: $(cat "$SB/git-local-trace")"
  grep -qE '^cwd=/ argv: --git-dir=.*/\.git rev-parse --verify '"$FIX_COMMIT"'\^\{commit\}$' "$SB/git-local-trace" || fail "no rev-parse --verify of the pin: $(cat "$SB/git-local-trace")"
  grep -qE '^cwd=/ argv: --git-dir=.*/\.git archive --format=tar '"$FIX_COMMIT"' -- deploy/scripts/config-migrate.sh deploy/scripts/service-identity.sh deploy/scripts/ownership-lib.sh deploy/scripts/provision-java.sh deploy/java-runtime.properties service/VERSION$' "$SB/git-local-trace" || fail "no archive of exactly the manifest paths: $(cat "$SB/git-local-trace")"
  assert_absent "$SB/git-trace"
}

test_validate_healthy_installation() {
  healthy_install
  run_installer validate --source-repo "$FIXTURE"
  assert_rc 0
  assert_out "validate: OK 20, WARN 0, FAIL 0"
  assert_items OK $CHECK_NAMES $VALIDATE_NAMES
  assert_validate_trace; assert_git_only_archive_and_revparse; assert_readonly_traces; assert_clean; assert_markers_absent
  assert_out "config-migrate (test double): validate --home $(HOME_DIR)"
  assert_out " removed"
  [ -z "$(ls "$(STATED)" | grep -v '^\.lock$')" ] || fail "the run directory is still there"
  # the default repository comes from DEFAULT_SOURCE_REPO
  EXTRA="DEFAULT_SOURCE_REPO=$FIXTURE"
  run_installer validate; assert_rc 0; assert_out "validate: OK 20"
}

test_validate_uses_the_pinned_commit_only() {
  healthy_install
  cp -a "$FIXTURE" "$SB/repo"
  printf '# tampered after the pin\n' >> "$SB/repo/deploy/scripts/service-identity.sh"        # a modified working-tree file
  printf 'echo evil\n' > "$SB/repo/deploy/scripts/extra.sh"                                  # an uncommitted file
  printf 'JUNK\n' > "$SB/repo/service/VERSION"                                               # the later commit says 0.1.6, the tree JUNK
  [ "$(cd "$SB/repo" && "$REAL_GIT" rev-parse HEAD)" = "$FIX_LATER_COMMIT" ] || fail "the fixture copy is not at the later commit"
  run_installer validate --source-repo "$SB/repo"
  assert_rc 0; assert_items OK source-verify
  assert_git_only_archive_and_revparse; assert_validate_trace; assert_clean
}

test_validate_missing_commit_is_exit_4() {
  healthy_install
  EXTRA='OPS_COMMIT=1111111111111111111111111111111111111111'
  run_installer validate --source-repo "$FIXTURE"
  assert_rc 4; item_is FAIL source-commit; assert_out "is not in the repository"; assert_out "no Oracle OPS script was run"
  assert_no_trace; assert_clean; assert_not_out "source-archive"
}

test_validate_refuses_a_repository_that_can_change_what_archive_writes() {
  local kind
  healthy_install
  for kind in attributes filter replace grafts packed-replace link-git; do
    rm -rf "$SB/repo"; cp -a "$FIXTURE" "$SB/repo"
    case "$kind" in
      attributes) printf 'service/VERSION export-ignore\n' > "$SB/repo/.git/info/attributes" ;;
      filter) printf 'deploy/scripts/service-identity.sh filter=evil\n' > "$SB/repo/.git/info/attributes"
              ( cd "$SB/repo" && "$REAL_GIT" config filter.evil.smudge "sed s/fixture/XXXXXXX/" ) ;;
      replace) ( cd "$SB/repo" && "$REAL_GIT" replace "$FIX_LATER_COMMIT" "$FIX_COMMIT" ) ;;
      grafts) printf '%s %s\n' "$FIX_COMMIT" "$FIX_LATER_COMMIT" > "$SB/repo/.git/info/grafts" ;;
      packed-replace) printf '%s refs/replace/%s\n' "$FIX_COMMIT" "$FIX_LATER_COMMIT" > "$SB/repo/.git/packed-refs" ;;
      link-git) mv "$SB/repo/.git" "$SB/gitdir"; ln -s "$SB/gitdir" "$SB/repo/.git" ;;
    esac
    rm -f "$SB/roothome/trace" "$SB/git-local-trace"
    run_installer validate --source-repo "$SB/repo"
    [ "$RC" = 4 ] || fail "$kind: exit status $RC, expected 4"
    item_is FAIL source-repository
    assert_no_trace; assert_absent "$SB/git-local-trace"; assert_clean
  done
}

test_validate_r1_digest_mismatch_is_exit_4() {
  local c
  healthy_install
  cp -a "$FIXTURE" "$SB/repo"
  ( cd "$SB/repo" && export HOME="$TEST_ROOT/fixhome" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    "$REAL_GIT" checkout -q "$FIX_COMMIT" && printf '# one more line\n' >> deploy/scripts/config-migrate.sh && "$REAL_GIT" commit -q -am "tampered config-migrate" )
  c="$(cd "$SB/repo" && "$REAL_GIT" rev-parse HEAD)"
  EXTRA="OPS_COMMIT=$c"
  run_installer validate --source-repo "$SB/repo"
  assert_rc 4; item_is FAIL source-verify; assert_out "deploy/scripts/config-migrate.sh does not match the SHA-256 recorded in this installer"
  assert_no_trace; assert_clean
}

test_validate_version_mismatch_is_exit_4() {
  healthy_install
  EXTRA='OPS_VERSION=9.9.9'
  run_installer validate --source-repo "$FIXTURE"
  assert_rc 4; item_is FAIL source-verify; assert_out "service/VERSION is '$FIX_VERSION', the installer expects 9.9.9"
  assert_no_trace; assert_clean
}

test_validate_repository_problems_are_exit_4() {
  healthy_install
  run_installer validate --source-repo "$SB/nope";  assert_rc 4; item_is FAIL source-repository; assert_out "is not a real directory"
  mkdir "$SB/norepo"
  run_installer validate --source-repo "$SB/norepo"; assert_rc 4; item_is FAIL source-repository; assert_out ".git is not a real directory"
  assert_no_trace; assert_clean
}

test_validate_archive_entries_are_checked() {
  local what
  healthy_install
  for what in symlink hardlink dotdot absolute extra missing; do
    rm -rf "$SB/probe"; mkdir -p "$SB/probe/src"
    python3 -I - "$SB/probe/src.tar" "$what" "$TEST_ROOT/fixture" "$FIX_COMMIT" <<'PY'
import io, subprocess, sys, tarfile
out, what, repo, commit = sys.argv[1:5]
paths = ["deploy/scripts/config-migrate.sh", "deploy/scripts/service-identity.sh", "deploy/scripts/ownership-lib.sh",
         "deploy/scripts/provision-java.sh", "deploy/java-runtime.properties", "service/VERSION"]
t = tarfile.open(out, "w")
def add(name, data=b"x\n", kind=None, link=None):
    i = tarfile.TarInfo(name)
    if kind == "symlink": i.type = tarfile.SYMTYPE; i.linkname = link
    elif kind == "hardlink": i.type = tarfile.LNKTYPE; i.linkname = link
    else: i.size = len(data)
    t.addfile(i, None if kind else io.BytesIO(data))
for p in paths:
    if what == "missing" and p == "service/VERSION": continue
    if what == "symlink" and p == "deploy/scripts/ownership-lib.sh": add(p, kind="symlink", link="/etc/passwd"); continue
    if what == "hardlink" and p == "deploy/scripts/ownership-lib.sh": add(p, kind="hardlink", link="deploy/java-runtime.properties"); continue
    data = subprocess.check_output(["git", "--git-dir=" + repo + "/.git", "show", commit + ":" + p])
    add(p, data)
if what == "dotdot": add("../escape.sh")
if what == "absolute": add("/tmp/escape.sh")
if what == "extra": add("deploy/scripts/extra.sh")
t.close()
PY
    ( . "$INSTALLER" || exit 99
      RUN_DIR="$SB/probe"; OPS_VERSION="$FIX_VERSION"; OPS_FILE_MANIFEST=("${FIX_MANIFEST[@]}")
      validate_item_verify; echo "STATUS=$ITEM_STATUS DETAIL=$ITEM_DETAIL" ) > "$SB/out" 2>&1
    grep -q '^STATUS=FAIL ' "$SB/out" || fail "$what: the archive was accepted: $(cat "$SB/out")"
    [ ! -e "$SB/escape.sh" ] && [ ! -e /tmp/escape.sh ] || fail "$what: something was extracted outside the staging directory"
    case "$what" in
      symlink|hardlink) grep -q 'neither a regular file nor a directory' "$SB/out" || fail "$what: $(cat "$SB/out")" ;;
      dotdot|absolute) grep -q 'unsafe name' "$SB/out" || fail "$what: $(cat "$SB/out")" ;;
      extra|missing) grep -q 'not exactly the expected set' "$SB/out" || fail "$what: $(cat "$SB/out")" ;;
    esac
  done
  # control: a faithful archive is accepted
  rm -rf "$SB/probe"; mkdir -p "$SB/probe/src"
  ( cd "$FIXTURE" && "$REAL_GIT" archive --format=tar "$FIX_COMMIT" -- $MANIFEST_PATHS ) > "$SB/probe/src.tar"
  ( . "$INSTALLER" || exit 99
    RUN_DIR="$SB/probe"; OPS_VERSION="$FIX_VERSION"; OPS_FILE_MANIFEST=("${FIX_MANIFEST[@]}")
    validate_item_verify; echo "STATUS=$ITEM_STATUS DETAIL=$ITEM_DETAIL" ) > "$SB/out" 2>&1
  grep -q '^STATUS=OK ' "$SB/out" || fail "a faithful archive was refused: $(cat "$SB/out")"
}

test_validate_oracle_ops_check_failures_are_failures() {
  healthy_install
  stub_mode CONFIG_MIGRATE_MODE fail
  run_installer validate --source-repo "$FIXTURE"
  assert_rc 1; item_is FAIL config-validate; item_is OK service-identity; assert_out "exited with status 21"; assert_out "application.yaml is not valid"
  assert_clean
  new_sandbox; healthy_install
  stub_mode CHECK_MODE fail
  run_installer validate --source-repo "$FIXTURE"
  assert_rc 1; item_is OK config-validate; item_is FAIL service-identity; assert_out "deviation(s)"
  assert_clean
}

test_validate_status_problems_still_fail() {
  healthy_install
  echo inactive > "$SB/systemctl-state"
  run_installer validate --source-repo "$FIXTURE"
  assert_rc 1; item_is FAIL service; item_is OK source-verify; assert_clean
}

test_validate_git_runs_only_through_the_seam_with_the_owners_privileges() {
  local uid gid
  uid="$(id -u)"; gid="$(getent passwd "$uid" | cut -d: -f4)"
  # a setpriv double that records its arguments, then runs the command that follows the options
  rm -f "$SB/bin/setpriv"
  cat > "$SB/bin/setpriv" <<EOF
#!/bin/bash
echo "setpriv \$*" >> '$SB/setpriv-trace'
echo "cwd=\$PWD HOME=\$HOME" >> '$SB/setpriv-trace'
env | cut -d= -f1 | sort | tr '\n' ' ' >> '$SB/setpriv-trace'; echo >> '$SB/setpriv-trace'
while [ \$# -gt 0 ]; do case "\$1" in --reuid|--regid) shift 2 ;; --clear-groups) shift ;; *) break ;; esac; done
exec "\$@"
EOF
  chmod 0755 "$SB/bin/setpriv"
  export BASH_ENV=/nonexistent GIT_WORK_TREE=/nonexistent JAVA_HOME=/x
  # the owner is NOT the administrative account: setpriv with the owner's uid, passwd primary gid, no supplementary groups
  ( . "$INSTALLER" || exit 99
    SAFE_PATH="$SB/bin"; ADMIN_UID=99999
    run_as_repo_owner "$FIXTURE" git --git-dir="$FIXTURE/.git" rev-parse --verify "$FIX_COMMIT^{commit}" ) > "$SB/out" 2>&1
  RC=$?
  unset BASH_ENV GIT_WORK_TREE JAVA_HOME
  assert_rc 0; assert_out "$FIX_COMMIT"
  grep -qF "setpriv --reuid $uid --regid $gid --clear-groups git --git-dir=$FIXTURE/.git rev-parse" "$SB/setpriv-trace" || fail "setpriv was not given the owner's identity: $(cat "$SB/setpriv-trace")"
  grep -qF "cwd=/ HOME=/nonexistent" "$SB/setpriv-trace" || fail "not run in / with HOME=/nonexistent: $(cat "$SB/setpriv-trace")"
  grep -q 'GIT_CONFIG_NOSYSTEM' "$SB/setpriv-trace" && grep -q 'GIT_NO_REPLACE_OBJECTS' "$SB/setpriv-trace" || fail "the hardening variables are missing"
  ! grep -qE 'BASH_ENV|GIT_WORK_TREE|JAVA_HOME' "$SB/setpriv-trace" || fail "the environment was not scrubbed: $(cat "$SB/setpriv-trace")"
  # the owner IS the administrative account: no setpriv, still / and the scrubbed environment
  rm -f "$SB/setpriv-trace"
  ( . "$INSTALLER" || exit 99
    SAFE_PATH="$SB/bin"; ADMIN_UID="$uid"
    run_as_repo_owner "$FIXTURE" bash -c 'pwd; echo HOME=$HOME; echo NOREPLACE=$GIT_NO_REPLACE_OBJECTS NOSYS=$GIT_CONFIG_NOSYSTEM' ) > "$SB/out" 2>&1
  RC=$?
  assert_rc 0; assert_out "HOME=/nonexistent"; assert_out "NOREPLACE=1 NOSYS=1"; [ "$(head -n 1 "$SB/out")" = "/" ] || fail "not run in /"
  assert_absent "$SB/setpriv-trace"
  # an owner that cannot be determined is a failure
  ( . "$INSTALLER" || exit 99; SAFE_PATH="$SB/bin"; run_as_repo_owner "$SB/nowhere" true ) > "$SB/out" 2>&1; RC=$?
  [ "$RC" != 0 ] || fail "a repository without an owner was accepted"
}

test_seams_service_state_and_proc_owner_exe() {
  local out
  out="$( . "$INSTALLER" || exit 99; SAFE_PATH="$SB/bin"; PATH="$SB/bin"; echo active > "$SB/systemctl-state"; service_state )"
  printf '%s\n' "$out" | grep -qx 'IS_ACTIVE=active' && printf '%s\n' "$out" | grep -qx 'SubState=running' || fail "service_state: $out"
  [ "$(cat "$SB/systemctl-trace")" = "is-active oracle-ops.service
show -p ActiveState -p SubState -p MainPID -p ActiveEnterTimestamp oracle-ops.service" ] || fail "unexpected systemctl calls: $(cat "$SB/systemctl-trace")"
  echo inactive > "$SB/systemctl-state"
  out="$( . "$INSTALLER" || exit 99; PATH="$SB/bin"; service_state )"
  printf '%s\n' "$out" | grep -qx 'IS_ACTIVE=inactive' || fail "service_state of an inactive unit: $out"
  touch "$SB/systemctl-show-fail"
  ( . "$INSTALLER" || exit 99; PATH="$SB/bin"; service_state ) > /dev/null 2>&1 && fail "service_state ignored a failing systemctl show"
  # the real proc seam, on this shell
  out="$( . "$INSTALLER" || exit 99; proc_owner_exe "$BASHPID" )"
  printf '%s\n' "$out" | grep -qx "OWNER=$(id -un):$(id -gn)" && printf '%s\n' "$out" | grep -q '^EXE=/.*bash' || fail "proc_owner_exe: $out"
  ( . "$INSTALLER" || exit 99; proc_owner_exe 99999999 ) > /dev/null 2>&1 && fail "proc_owner_exe accepted a missing process"
  return 0
}

# ---- menu items 5, 6, 7 ----------------------------------------------------------------------------------------------------

test_menu_offers_status_validate_and_exit() {
  input "$MENU_EXIT"
  run_installer
  assert_rc 0; assert_out "5) View Installation Status"; assert_out "4) Validate Environment"; assert_out "10) Exit"; assert_out "Choose an option [1-10]"
  assert_absent "$SB/systemctl-trace"; assert_clean
}

test_menu_status() {
  healthy_install
  input 5
  run_installer
  assert_rc 0; assert_out "status: OK 13, WARN 0, FAIL 0"; assert_items OK $CHECK_NAMES
  assert_log "OK  unit:"; assert_log "status: OK 13"
  assert_status_only; assert_clean; assert_markers_absent
  [ -z "$(check_logs)" ] || fail "the menu path wrote a check log"
  healthy_install; echo inactive > "$SB/systemctl-state"
  input 5
  run_installer
  assert_rc 1; assert_out "Oracle OPS status check failed"; assert_out "FAIL  service:"
}

test_menu_status_without_installation_is_exit_6() {
  input 5
  run_installer
  assert_rc 6; assert_out "not installed"; assert_clean
}

test_menu_validate() {
  healthy_install
  input 4 "$FIXTURE"
  run_installer
  assert_rc 0; assert_out "validate: OK 19, WARN 0, FAIL 0"; assert_items OK $CHECK_NAMES source-repository source-commit source-archive source-verify config-validate service-identity
  assert_validate_trace; assert_git_only_archive_and_revparse; assert_clean
  # the default path, and a path given with a trailing slash
  EXTRA="DEFAULT_SOURCE_REPO=$FIXTURE"
  input 4 ""
  run_installer; assert_rc 0
  input 4 "$FIXTURE/"
  run_installer; assert_rc 0
  # three unusable answers
  EXTRA=""
  input 4 relative /etc "x y"
  run_installer; assert_rc 2; assert_out "Not usable"
  assert_clean
  # a repository that does not hold the pin
  input 4 "$SB/nowhere"
  rm -f "$SB/roothome/trace"
  run_installer; assert_rc 4; assert_out "validation failed"; assert_no_trace; assert_clean
}

test_menu_prunes_check_logs_and_only_check_logs() {
  local d i
  d="$(LOGD)"; mkdir -m 0700 -p "$d"
  for i in $(seq -w 1 25); do : > "$d/oracle-ops-check-202601${i}T000000Z-1.log"; done
  : > "$d/oracle-ops-check-notes.log"; : > "$d/oracle-ops-check-20260101T000000Z.txt"; echo keep > "$d/admin-notes.txt"
  input "$MENU_EXIT"
  run_installer
  assert_rc 0
  [ "$(check_logs | wc -l)" = 20 ] || fail "expected 20 check logs to be kept, found $(check_logs | wc -l)"
  assert_absent "$d/oracle-ops-check-20260101T000000Z-1.log"; assert_exists "$d/oracle-ops-check-20260125T000000Z-1.log"
  assert_exists "$d/oracle-ops-check-notes.log"; assert_exists "$d/oracle-ops-check-20260101T000000Z.txt"; assert_exists "$d/admin-notes.txt"
  assert_log "removed old check log oracle-ops-check-20260101T000000Z-1.log"
}

# ---- security boundary: nothing outside the checks' own files changes -----------------------------------------------------------

snapshot() {   # snapshot <output file> <paths...>: path, type, mode, uid, gid, size, mtime, ctime, link target, sha256 of regular files
  local out="$1" p
  shift
  : > "$out"
  for p in "$@"; do
    find "$p" -printf '%p\t%y\t%m\t%U\t%G\t%s\t%T@\t%C@\t%l\n' 2>/dev/null | LC_ALL=C sort >> "$out"
    find "$p" -type f -exec sha256sum {} + 2>/dev/null | LC_ALL=C sort >> "$out"
  done
}
tmp_entries() { find /tmp -maxdepth 1 -mindepth 1 -user "$(id -u)" ! -name 'claude-*' -printf '%f\n' 2>/dev/null | LC_ALL=C sort; }

boundary_preset() {   # the conditions every boundary case starts from
  local i d
  healthy_install
  mkdir -m 0750 "$(LOGD)" "$(STATED)" 2>/dev/null || true
  chmod 0750 "$(LOGD)" "$(STATED)"
  for i in $(seq -w 1 25); do : > "$(LOGD)/oracle-ops-installer-202601${i}T000000Z-1.log"; : > "$(LOGD)/oracle-ops-check-202601${i}T000000Z-1.log"; done
  : > "$(STATED)/.lock"
  d="$(STATED)/run.DEADDEAD"; mkdir -m 0700 "$d"; printf '%s 999999 2026-11-03T00:00:00Z\n' "$MARKER_TEXT_T" > "$d/.oracle-ops-installer-run"
  d="$SB/run/oracle-ops-installer.DEADTOKE"; mkdir -m 0700 "$d"; printf '%s 999998\n' "$MARKER_TEXT_T" > "$d/.oracle-ops-installer-run"
  rm -f "$SB/roothome/trace"
}
BOUNDARY_PROTECTED() { printf '%s\n' "$SB/u01" "$SB/etc" "$SB/run" "$FIXTURE" "$(dirname "$INSTALLER")/oracle-ops-installer.sh" "$(dirname "$INSTALLER")/lib"; }

# boundary_cli <label> <arguments...>: a command-line run; only the new check log may appear, nothing else changes
boundary_cli() {
  local label="$1" tmp0 tmp1 new
  shift
  boundary_preset
  # shellcheck disable=SC2046
  snapshot "$SB/snap-before" $(BOUNDARY_PROTECTED)
  snapshot "$SB/snap-logs-before" "$(LOGD)"
  find "$(STATED)" -mindepth 1 -printf '%p\t%y\t%m\t%U\t%G\t%s\t%T@\t%C@\n' | LC_ALL=C sort > "$SB/snap-state-before"
  stat -c '%a %Z %Y' "$(STATED)" > "$SB/snap-statedir-before"
  tmp0="$(tmp_entries)"
  run_installer "$@"
  tmp1="$(tmp_entries)"
  # shellcheck disable=SC2046
  snapshot "$SB/snap-after" $(BOUNDARY_PROTECTED)
  cmp -s "$SB/snap-before" "$SB/snap-after" || { diff "$SB/snap-before" "$SB/snap-after" | head -n 10; fail "$label: a protected tree changed"; }
  [ "$tmp0" = "$tmp1" ] || fail "$label: new files under /tmp: $(diff <(printf '%s\n' "$tmp0") <(printf '%s\n' "$tmp1") | tr '\n' ' ')"
  # LOG_DIR: only the new check log (its mode stays 0750)
  snapshot "$SB/snap-logs-after" "$(LOGD)"
  new="$(ls "$(LOGD)" | grep -c 'oracle-ops-check-')"
  [ "$new" = 26 ] || fail "$label: expected one new check log (26 in all), found $new"
  [ "$(ls "$(LOGD)" | grep -c 'oracle-ops-installer-')" = 25 ] || fail "$label: installer logs were pruned"
  [ "$(stat -c %a "$(LOGD)")" = 750 ] || fail "$label: the log directory mode changed"
  grep -v "^$(LOGD)	d	" "$SB/snap-logs-before" > "$SB/snap-logs-before-old"
  # every file that was there is byte-for-byte and attribute-for-attribute unchanged
  grep -vxFf "$SB/snap-logs-after" "$SB/snap-logs-before-old" > "$SB/snap-logs-lost" || true
  [ ! -s "$SB/snap-logs-lost" ] || { cat "$SB/snap-logs-lost"; fail "$label: an existing log file changed or disappeared"; }
  # STATE_DIR: the same entries as before (validate's run directory comes and goes); for status not even the directory's ctime
  find "$(STATED)" -mindepth 1 -printf '%p\t%y\t%m\t%U\t%G\t%s\t%T@\t%C@\n' | LC_ALL=C sort > "$SB/snap-state-after"
  cmp -s "$SB/snap-state-before" "$SB/snap-state-after" || { diff "$SB/snap-state-before" "$SB/snap-state-after" | head -n 6; fail "$label: the state directory changed"; }
  [ "$(stat -c %a "$(STATED)")" = 750 ] || fail "$label: the state directory mode changed"
  if [ "$1" = status ]; then [ "$(stat -c '%a %Z %Y' "$(STATED)")" = "$(cat "$SB/snap-statedir-before")" ] || fail "$label: the state directory was touched"; fi
  assert_exists "$(STATED)/run.DEADDEAD"; assert_exists "$SB/run/oracle-ops-installer.DEADTOKE"
  assert_readonly_traces
  assert_markers_absent
}

test_boundary_cli_status() {
  boundary_cli "status" status
  assert_rc 0; item_is WARN installer-state
  assert_status_only
}

test_boundary_cli_validate() {
  boundary_cli "validate" validate --source-repo "$FIXTURE"
  assert_rc 0; item_is WARN installer-state; assert_validate_trace; assert_git_only_archive_and_revparse
}

# boundary_menu <label> <menu input...>: today's start-up housekeeping happens, and nothing else changes
boundary_menu() {
  local label="$1" tmp0 tmp1
  shift
  boundary_preset
  # shellcheck disable=SC2046
  snapshot "$SB/snap-before" $(printf '%s\n' "$SB/u01" "$SB/etc" "$FIXTURE" "$(dirname "$INSTALLER")/oracle-ops-installer.sh" "$(dirname "$INSTALLER")/lib")
  tmp0="$(tmp_entries)"
  input "$@"
  run_installer
  tmp1="$(tmp_entries)"
  # shellcheck disable=SC2046
  snapshot "$SB/snap-after" $(printf '%s\n' "$SB/u01" "$SB/etc" "$FIXTURE" "$(dirname "$INSTALLER")/oracle-ops-installer.sh" "$(dirname "$INSTALLER")/lib")
  cmp -s "$SB/snap-before" "$SB/snap-after" || { diff "$SB/snap-before" "$SB/snap-after" | head -n 10; fail "$label: a protected tree changed"; }
  [ "$tmp0" = "$tmp1" ] || fail "$label: new files under /tmp"
  # the known housekeeping of the menu start-up: modes 0700, old logs pruned to LOG_KEEP, the leftover and the token directory removed
  [ "$(stat -c %a "$(LOGD)")" = 700 ] && [ "$(stat -c %a "$(STATED)")" = 700 ] || fail "$label: the start-up did not set mode 0700"
  assert_absent "$(STATED)/run.DEADDEAD"; assert_absent "$SB/run/oracle-ops-installer.DEADTOKE"
  [ "$(install_logs | wc -l)" = 20 ] || fail "$label: installer logs not pruned to 20 ($(install_logs | wc -l))"
  [ "$(check_logs | wc -l)" = 20 ] || fail "$label: check logs not pruned to 20 ($(check_logs | wc -l))"
  assert_readonly_traces; assert_markers_absent; assert_clean
}

test_boundary_menu_status() {
  boundary_menu "menu status" 5
  assert_rc 0; assert_status_only
}

test_boundary_menu_validate() {
  boundary_menu "menu validate" 4 "$FIXTURE"
  assert_rc 0; assert_validate_trace; assert_git_only_archive_and_revparse
}

# ---- static guard and greps ----------------------------------------------------------------------------------------------

test_static_guard_of_the_read_only_code() {
  local dir out
  dir="$(dirname "$INSTALLER")"
  python3 -I "$REPO_ROOT/tests/guard-scan.py" selftest > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_out "selftest: 25 snippets that must be flagged, 1 that must not, 1 annotation: OK"
  python3 -I "$REPO_ROOT/tests/guard-scan.py" check "$dir" > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_out "guard: 0 violation(s), 0 guard-allow annotation(s)"
  # the reviewed helpers (the transitive closure of what lib/ops-status.sh and lib/ops-validate.sh call) are exactly these
  out="$(python3 -I "$REPO_ROOT/tests/guard-scan.py" commands "$dir/lib/ops-status.sh" "$dir/lib/ops-validate.sh" | awk '{print $3}' | sort -u | tr '\n' ' ')"
  case "$out" in *" java "*|*" sqlplus "*|*" rm "*|*" mkdir "*|*" touch "*|*" git "*) fail "unexpected command words in the read-only libraries: $out" ;; esac
}

test_master_never_invokes_opsdbcheck_java_or_sqlplus() {
  # 0.3.0: the installer runs ONE Java program on purpose - its own database tool (lib/db-tool.sh), on the release's private
  # JDK, through the db_tool_exec seam only. Nothing else may start java, SQL*Plus, OpsDbCheck or a network tool.
  local dir f c
  dir="$(dirname "$INSTALLER")"
  for f in "$dir/oracle-ops-installer.sh" "$dir"/lib/*.sh; do
    if grep -n -E 'OpsDbCheck' "$f" | grep -v -E '^[0-9]+:[[:space:]]*#'; then fail "$f refers to OpsDbCheck in code"; fi
    for c in $(python3 -I "$REPO_ROOT/tests/guard-scan.py" commands "$f" | awk '{print $3}' | sort -u); do
      case "$c" in java|sqlplus|sql|sqlcl|OpsDbCheck|ojdbc*|curl|wget|nc|ssh|scp|rsync|journalctl|logrotate) fail "$f invokes $c" ;; esac
    done
  done
  # the only place a JDBC driver is put on a class path, and the only Java program started
  [ "$(grep -l -E -- '-cp ojdbc8\.jar' "$dir"/lib/*.sh "$dir/oracle-ops-installer.sh" | tr '\n' ' ')" = "$dir/lib/env.sh " ] \
    || fail "a JDBC class path appears outside db_tool_exec"
  grep -q -- '-cp ojdbc8.jar "$DB_TOOL_CLASS.java"' "$dir/lib/env.sh" || fail "db_tool_exec does not run the installer's own tool"
  ! grep -rn -E '(^|[;&|(]|\$\()[[:space:]]*(/[A-Za-z0-9_./-]*/)?java([[:space:]]|$)' "$dir"/lib/*.sh "$dir/oracle-ops-installer.sh" | grep -v -E ':[0-9]+:[[:space:]]*#' | grep -v -E 'say |printf|echo|^[^:]*db-tool\.sh:' \
    || fail "a library invokes java"
}

test_command_line_startup_rules_hold() {
  # the CLI start-up neither prunes nor chmods nor removes leftovers: statically, in lib/check-startup.sh and the entry script
  local dir
  dir="$(dirname "$INSTALLER")"
  python3 -I "$REPO_ROOT/tests/guard-scan.py" commands "$dir/lib/check-startup.sh" | awk '{print $2 " " $3}' | grep -E ' (prune_logs|ensure_private_dir|init_state|init_logging|chmod|chown|ln|mv|cp|touch|kill|eval)$' > "$SB/out" && fail "the command-line start-up calls: $(cat "$SB/out")"
  grep -n 'flock' "$dir/lib/check-startup.sh" | grep -v -E 'flock -s -n|^[0-9]+:[[:space:]]*#' && fail "check-startup.sh locks other than shared"
  return 0
}
