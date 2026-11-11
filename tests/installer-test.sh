#!/bin/bash
# Hermetic tests for oracle-ops-installer.sh. Run: tests/run-tests.sh (or this file directly).
# The numbers in brackets are the scenarios of the installer requirements (docs/DEVELOPER.md, "Test coverage").

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOME_DIR() { printf '%s' "$SB/u01/oracle_ops_runtime"; }
DEPLOY_ARGS() { printf -- '--home %s --user %s --group %s --db-host dbhost.example --db-port 1521 --db-service OPSPDB --db-user OPS_RUNTIME --enable-api --api-bind-address 127.0.0.1 --api-port %s' "$(HOME_DIR)" "$(id -un)" "$(id -gn)" "$TEST_API_PORT"; }

# ---- invocation ----------------------------------------------------------------------------------------------------------

test_help_version_and_bad_argument() {
  run_installer --help;    assert_rc 0; assert_out "Usage:"; assert_out "Oracle APEX is not part of this installer"
  run_installer --version; assert_rc 0; assert_out "$FIX_COMMIT"
  run_installer --bogus;   assert_rc 2; assert_out "unknown argument"
  run_installer --java-archive relative/jdk.tar.gz; assert_rc 2
  assert_absent "$SB/var/log/oracle-ops-installer"
}

test_requires_root() {
  EXTRA='is_root() { return 1; }'
  run_installer
  assert_rc 2; assert_out "run the installer as root"
  assert_absent "$SB/var/log/oracle-ops-installer"; assert_absent "$SB/var/lib/oracle-ops-installer"
}

test_requires_terminal() {
  EXTRA='stdin_is_tty() { return 1; }'
  run_installer
  assert_rc 2; assert_out "run it from a terminal"
}

test_exit_option_changes_nothing() {
  input "$MENU_EXIT"
  run_installer
  assert_rc 0; assert_out "1) Fresh Installation"; assert_out "$MENU_EXIT) Exit"
  assert_clean; assert_no_trace; assert_absent "$SB/git-trace"
}

test_end_of_input_at_menu_is_a_cancellation() {   # [22]
  run_installer
  assert_rc 5; assert_out "Cancelled"; assert_clean
}

test_invalid_menu_choice() {   # [13]
  input 11 x 0
  run_installer
  assert_rc 2; assert_out "Please enter one of"; assert_clean
}

# ---- install ---------------------------------------------------------------------------------------------------------------

test_install_success() {   # [1] [6] [14] [17] [19] [20] [24]
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_out "[1/9] Checking the system (read-only)..."; assert_out "[2/9] Installation settings (nothing is changed yet)..."
  assert_out "[3/9] Review..."; assert_out "[4/9] Database prerequisites (DBA)..."; assert_out "[5/9] Configuring source..."
  assert_out "[6/9] Creating the Oracle OPS database objects..."; assert_out "[7/9] Creating the REST API keys..."
  assert_out "[8/9] Installing Oracle OPS..."; assert_out "[9/9] Final validation..."
  # the database step: one check, then the deploy of the pinned scripts in order, as OPS_OWNER, password on stdin only
  [ "$(grep -c '^args=' "$SB/dbtool-trace")" = 2 ] || fail "the database tool did not run exactly twice"
  grep -q '^args=check jdbc:oracle:thin:@//dbhost.example:1521/OPSPDB DBA_ARGUMENTS,DBA_COL_PRIVS,' "$SB/dbtool-trace" || fail "check was not called as expected"
  grep -q '^args=deploy jdbc:oracle:thin:@//dbhost.example:1521/OPSPDB [A-Z_,]* V4_001__create_ops_run.sql V4_002__create_ops_run_api.sql installer_grant_ops_run_api.sql V5_001__add_ops_run_get_run.sql V8_001__create_ops_wls_action.sql$' "$SB/dbtool-trace" \
    || fail "deploy did not get the scripts in the pinned order: $(grep '^args=deploy' "$SB/dbtool-trace")"
  [ "$(grep -c '^pw=expected' "$SB/dbtool-trace")" = 2 ] || fail "the tool did not receive the password on stdin"
  ! grep -q 'pwenv=1\|pwargv=1' "$SB/dbtool-trace" || fail "the OPS_OWNER password reached the tool's environment or arguments"
  grep -q 'files=.*OpsSchemaDeploy.java .*V8_001__ops_wls_action_api_body.sql .*ojdbc8.jar\|files=.*OpsSchemaDeploy.java.*ojdbc8.jar' "$SB/dbtool-trace" || fail "the tool directory is incomplete: $(grep -m1 files= "$SB/dbtool-trace")"
  assert_secret_nowhere "$TEST_OWNER_PW" terminal
  assert_trace "provision-java.sh authdirs=0"; assert_trace "provision-java.sh tokenfiles=0"
  assert_out "Oracle OPS installation completed successfully."
  [ "$(readlink "$(HOME_DIR)/current")" = "$(HOME_DIR)/releases/$FIX_VERSION" ] || fail "current does not select $FIX_VERSION"
  # the pinned commit, not the newer tip of the default branch, was installed
  assert_trace "deploy-oracle-ops.sh args=$(DEPLOY_ARGS)"
  assert_trace "head=$FIX_COMMIT"
  # credential material was gone before any downloaded code ran
  assert_trace "deploy-oracle-ops.sh authdirs=0"; assert_trace "deploy-oracle-ops.sh tokenenv=0"; assert_trace "deploy-oracle-ops.sh tokenfiles=0"
  # the Oracle OPS script gets root's umask and no TMPDIR (its database check stages files in /tmp)
  assert_trace "umask=0022 tmpdir=unset lc_all=C"
  # no internal git operation or repository URL reaches the terminal
  assert_not_out "github.com"; assert_not_out "clone"; assert_not_out "git "
  assert_clean; assert_no_token; assert_log_protected
  assert_log "source verified: HEAD=$FIX_COMMIT"
}

test_install_runs_only_the_deploy_script_and_nothing_apex() {   # [24]
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  local scripts
  scripts="$(sed -n 's/^\([^ ]*\) args=.*/\1/p' "$SB/roothome/trace" | sort -u | tr '\n' ' ')"
  [ "$scripts" = "deploy-oracle-ops.sh provision-java.sh service-identity.sh " ] || fail "unexpected Oracle OPS scripts were run: $scripts"
  # static: the installer never invokes anything APEX-related. APEX appears in messages (what the APEX Web Credentials
  # need), comments and the API catalogue text only: no command word (by command position, tests/guard-scan.py) names it.
  local words
  words="$(python3 -I "$REPO_ROOT/tests/guard-scan.py" commands "$INSTALLER" "$(dirname "$INSTALLER")"/lib/*.sh | awk '{ print $3 }' | grep -i apex)"
  [ -z "$words" ] || fail "a command names APEX: $words"
}

test_install_passes_java_archive() {
  : > "$SB/jdk-21.tar.gz"
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer --java-archive "$SB/jdk-21.tar.gz"
  assert_rc 0
  assert_trace "deploy-oracle-ops.sh args=$(DEPLOY_ARGS) --java-archive $SB/jdk-21.tar.gz"
}

test_missing_prerequisite_manual() {   # [2] [4]
  rm -f "$SB/bin/git"
  input 1 2
  run_installer
  assert_rc 3
  assert_out "git (package git)"; assert_out "yum install -y git"
  assert_not_out "Access token"; assert_absent "$SB/git-trace"; assert_no_trace; assert_clean
}

test_missing_prerequisite_automatic() {   # [3]
  rm -f "$SB/bin/git" "$SB/bin/unzip"
  input 1 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  grep -qF "yum -y install git unzip" "$SB/yum-trace" || fail "yum was not asked for exactly the missing packages"
  assert_out "Oracle OPS installation completed successfully."
}

test_prerequisite_installation_fails() {   # [5]
  rm -f "$SB/bin/git"
  echo fail > "$SB/yum-mode"
  input 1 1
  run_installer
  assert_rc 3; assert_out "Reason: the package manager could not install: git"; assert_no_trace; assert_clean
}

test_prerequisite_still_missing_after_installation() {   # [5]
  rm -f "$SB/bin/git"
  echo noop > "$SB/yum-mode"
  input 1 1
  run_installer
  assert_rc 3; assert_out "still missing"; assert_no_trace; assert_clean
}

test_unsupported_operating_system() {
  printf 'ID="ubuntu"\nVERSION_ID="22.04"\n' > "$SB/etc/os-release"
  input 1
  run_installer
  assert_rc 3; assert_out "operating system ubuntu:22 is not supported"; assert_clean
}

test_authentication_fails() {   # [7]
  printf 'ghp_WRONGtoken0123456789abcdefABCDEF0123\n' > "$SB/expected-token"
  input 1 "" "${ANS[@]}" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "Reason: GitHub rejected the access token."
  assert_out "Review the administrator installation log"
  assert_no_trace; assert_clean; assert_no_token
}

test_repository_access_denied() {   # [8]
  git_mode AUTH denied
  input 1 "" "${ANS[@]}" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "has no access to the Oracle OPS repository"; assert_no_trace; assert_clean; assert_no_token
}

test_network_failure() {
  git_mode AUTH network
  input 1 "" "${ANS[@]}" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "could not be reached"; assert_clean
}

test_invalid_token_format_is_rejected_before_use() {
  input 1 "" "${ANS[@]}" "not a token" "short" "ab'cd\"ef ghij klmn opqr"
  run_installer
  assert_rc 4; assert_out "That is not a GitHub access token"; assert_absent "$SB/git-trace"; assert_clean
}

test_pasted_token_with_surrounding_whitespace_is_accepted() {
  input 1 "" "${ANS[@]}" "   $TEST_TOKEN  " "${POST[@]}"
  run_installer
  assert_rc 0; assert_no_token
}

test_pinned_reference_unavailable() {   # [9]
  EXTRA='OPS_COMMIT=1111111111111111111111111111111111111111'
  input 1 "" "${ANS[@]}" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "is not available in the repository"; assert_no_trace; assert_clean
}

test_release_version_mismatch() {
  EXTRA='OPS_VERSION=9.9.9'
  input 1 "" "${ANS[@]}" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "the installer expects 9.9.9"; assert_no_trace; assert_clean
}

test_partial_clone_is_removed() {   # [10]
  git_mode CLONE partial
  input 1 "" "${ANS[@]}" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_log "removed the incomplete download"; assert_no_trace; assert_clean
}

test_leftover_staging_directory_of_an_interrupted_run() {   # [11]
  mkdir -p "$SB/var/lib/oracle-ops-installer/run.OLDRUN01/src"
  chmod 0700 "$SB/var/lib/oracle-ops-installer" "$SB/var/lib/oracle-ops-installer/run.OLDRUN01"
  echo "oracle-ops-installer-run 1 x" > "$SB/var/lib/oracle-ops-installer/run.OLDRUN01/.oracle-ops-installer-run"
  mkdir -m 0700 "$SB/run/oracle-ops-installer.OLDAUTH1"
  echo "oracle-ops-installer-run 1" > "$SB/run/oracle-ops-installer.OLDAUTH1/.oracle-ops-installer-run"
  echo stale > "$SB/run/oracle-ops-installer.OLDAUTH1/token"
  input "$MENU_EXIT"
  run_installer
  assert_rc 0; assert_clean
  assert_log "earlier, interrupted run"
}

test_unrelated_data_in_staging_directory_stops_the_run() {   # [11]
  mkdir -m 0700 -p "$SB/var/lib/oracle-ops-installer"
  echo keep > "$SB/var/lib/oracle-ops-installer/notes.txt"
  mkdir "$SB/var/lib/oracle-ops-installer/run.FOREIGN1"
  input "$MENU_EXIT"
  run_installer
  assert_rc 1; assert_out "not created by this installer"
  [ "$(cat "$SB/var/lib/oracle-ops-installer/notes.txt")" = keep ] || fail "unrelated file was changed"
  assert_exists "$SB/var/lib/oracle-ops-installer/run.FOREIGN1"
}

test_symlinked_or_foreign_owned_directories_are_refused() {   # [12]
  mkdir -p "$SB/elsewhere"
  ln -s "$SB/elsewhere" "$SB/var/lib/oracle-ops-installer"
  input "$MENU_EXIT"
  run_installer
  assert_rc 1; assert_out "is a symbolic link"
  [ -z "$(ls -A "$SB/elsewhere")" ] || fail "something was written through the link"
  rm -f "$SB/var/lib/oracle-ops-installer"
  rm -rf "$SB/var/log/oracle-ops-installer"
  ln -s "$SB/elsewhere" "$SB/var/log/oracle-ops-installer"
  run_installer
  assert_rc 1; assert_out "cannot use the log directory"
  [ -z "$(ls -A "$SB/elsewhere")" ] || fail "a log was written through the link"
  rm -f "$SB/var/log/oracle-ops-installer"
  EXTRA='ADMIN_UID=99999'   # the parent directories are not owned by the expected administrative account
  run_installer
  assert_rc 1; assert_out "must be a real directory owned by root"
}

test_invalid_installation_directory() {   # [13]
  input 1 "relative/dir" "$SB/u01/../etc" "/etc/oracle-ops-x"
  run_installer
  assert_rc 2; assert_out "Not usable"; assert_absent "$SB/git-trace"; assert_clean
}

test_installation_directory_symlink_or_foreign() {   # [12] [21]
  mkdir -p "$SB/u01/real"; ln -s "$SB/u01/real" "$SB/u01/link"
  input 1 "$SB/u01/link"
  run_installer
  assert_rc 6; assert_out "is a symbolic link"
  mkdir -p "$SB/u01/data"; echo precious > "$SB/u01/data/file"
  input 1 "$SB/u01/data"
  run_installer
  assert_rc 6; assert_out "is not an Oracle OPS installation directory"
  [ "$(cat "$SB/u01/data/file")" = precious ] || fail "unrelated data was changed"
}

test_setup_assistant_fails() {   # [15] [18]
  stub_mode DEPLOY_MODE fail
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "$TEST_OWNER_PW" yes
  run_installer
  assert_rc 1; assert_out "Oracle OPS installation failed."; assert_out "the Oracle OPS setup assistant did not complete (exit 1)"
  assert_out "database validation failed"   # the assistant's own message was shown
  assert_log "database validation failed"   # and recorded
  assert_clean; assert_no_token
}

test_verification_failure_is_reported_and_runtime_kept() {   # [16] [21]
  stub_mode DEPLOY_MODE wrongcommit
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "the installation is not complete"; assert_out "commit 'deadbee'"
  assert_not_out "completed successfully"
  assert_exists "$(HOME_DIR)/releases/$FIX_VERSION/oracle-ops.jar"   # no invented rollback
  assert_clean
}

test_verification_failure_without_active_release() {   # [16]
  stub_mode DEPLOY_MODE nocurrent
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "the active release is 'none'"; assert_clean
}

test_token_is_redacted_if_a_tool_prints_it() {   # [20]
  git_mode AUTH leak
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_log "[REDACTED]"; assert_no_token
}

test_token_without_a_known_prefix_is_redacted() {   # [20] a classic 40-hex token matches no GitHub token pattern
  TEST_TOKEN="0123456789abcdef0123456789abcdef01234567"
  printf '%s\n' "$TEST_TOKEN" > "$SB/expected-token"
  printf 'TEST_TOKEN=%s\n' "$TEST_TOKEN" >> "$SB/roothome/stub.conf"
  git_mode AUTH leak
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_log "[REDACTED]"; assert_no_token
}

test_git_runs_isolated_and_askpass_is_host_bound() {   # [19] [20]
  printf 'touch %q\n' "$SB/bash-env-ran" > "$SB/evil-bash-env.sh"
  EXTRA="export BASH_ENV=$SB/evil-bash-env.sh LEAKY_SENTINEL=1"
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_absent "$SB/bash-env-ran"
  grep -q "LEAKY_SENTINEL\|BASH_ENV" "$SB/git-trace" && fail "the caller's environment reached git"
  grep -q "LEAKY_SENTINEL\|BASH_ENV" "$SB/roothome/trace" && fail "the caller's environment reached an Oracle OPS script"
  grep -q "token-in-argv\|token-in-env" "$SB/git-trace" && fail "the token reached git's arguments or environment"
  grep -q "askpass-answered-foreign" "$SB/git-trace" && fail "the askpass helper answered a prompt for another host"
  grep -q "env HOME=$SB/var/lib/oracle-ops-installer/run\.[A-Za-z0-9]*/githome GIT_ASKPASS=.* GIT_CONFIG_NOSYSTEM=1" "$SB/git-trace" \
    || fail "git did not run with an empty HOME and without system configuration"
  grep -q "askpass-mode=700 token-mode=600" "$SB/git-trace" || fail "credential helper or token file permissions are wrong"
  grep -q "^envnames: .*BASH_ENV" "$SB/git-trace" && fail "BASH_ENV reached git"
  return 0
}

test_token_directory_on_tmpfs_is_used_and_removed() {   # [19]
  TEST_TMPFS=1
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  grep -q "GIT_ASKPASS=$SB/run/oracle-ops-installer\.[A-Za-z0-9]*/askpass" "$SB/git-trace" || fail "the token directory was not placed in AUTH_BASE"
  assert_clean
}

test_existing_installation_is_never_overwritten_by_install() {   # [21]
  existing_install 0.1.4 abcdef1
  local before
  before="$(tree_digest "$(HOME_DIR)")"
  input 1
  run_installer
  assert_rc 6; assert_out "Oracle OPS is already installed"; assert_out "Choose 'Upgrade Existing Installation'"
  [ "$(tree_digest "$(HOME_DIR)")" = "$before" ] || fail "the existing installation was changed"
  assert_absent "$SB/git-trace"; assert_clean
}

test_repeated_install_is_safe() {   # [23]
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  local before
  before="$(tree_digest "$(HOME_DIR)")"
  cp "$SB/git-trace" "$SB/git-trace.first"
  input 1
  run_installer
  assert_rc 0; assert_out "already installed at $(HOME_DIR) and running. Nothing was changed."
  cmp -s "$SB/git-trace" "$SB/git-trace.first" || fail "the second run contacted the repository"
  [ "$(tree_digest "$(HOME_DIR)")" = "$before" ] || fail "the second run changed the installation"
  assert_clean
}

test_incomplete_earlier_installation_needs_confirmation() {
  mkdir -p "$(HOME_DIR)/releases" "$(HOME_DIR)/logs"
  input 1 "" no
  run_installer
  assert_rc 5; assert_out "incomplete Oracle OPS installation"; assert_absent "$SB/git-trace"
  input 1 "" yes "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0; assert_out "completed successfully"
}

test_interrupt_during_installation_cleans_up() {   # [22]
  stub_mode DEPLOY_MODE selfkill
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "$TEST_OWNER_PW" yes
  run_installer
  assert_rc 143; assert_out "Oracle OPS installation was interrupted."; assert_clean; assert_no_token
}

# ---- REST API keys, Fresh Installation questions, discovery (0.3.0) --------------------------------------------------------

CREDS() { printf '%s' "$SB/etc/oracle-ops"; }
key_value() { sed -n "s/^$2=//p" "$(CREDS)/$1" 2>/dev/null; }
READ_K="readkey0123456789abcdef0123456789abcdef01"
CTRL_K="ctrlkey0123456789abcdef0123456789abcdef02"
make_keys() {   # valid key files with known values, owned as Fresh Installation would leave them
  mkdir -p "$(CREDS)"; chmod 0750 "$(CREDS)"
  printf 'api.token=%s\n' "$READ_K" > "$(CREDS)/api.credentials"
  printf 'api.control.token=%s\n' "$CTRL_K" > "$(CREDS)/api-control.credentials"
  chmod 0640 "$(CREDS)/api.credentials" "$(CREDS)/api-control.credentials"
}
# assert_secret_nowhere <value> [also-terminal]: the value is in no log, staging area, trace or (with "terminal") output.
assert_secret_nowhere() {
  local hits
  hits="$(grep -rlF -- "$1" "$SB/var" "$SB/run" "$SB/roothome/trace" "$SB/git-trace" "$SB/systemctl-trace" "$SB/u01" 2>/dev/null)"
  [ -z "$hits" ] || fail "an API key was found in: $hits"
  if [ "${2:-}" = terminal ]; then ! grep -qF -- "$1" "$SB/out" || fail "an API key was shown on the terminal"; fi
}

test_install_creates_both_api_keys() {
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  local r c f
  r="$(key_value api.credentials api.token)"; c="$(key_value api-control.credentials api.control.token)"
  [[ "$r" =~ ^[0-9a-f]{64}$ ]] || fail "the read key is not 64 hex characters"
  [[ "$c" =~ ^[0-9a-f]{64}$ ]] || fail "the control key is not 64 hex characters"
  [ "$r" != "$c" ] || fail "the two keys are identical"
  for f in api.credentials api-control.credentials; do
    [ "$(stat -c '%u %g %a %h' "$(CREDS)/$f")" = "$(id -u) $(id -g) 640 1" ] || fail "$f has owner/mode $(stat -c '%u %g %a %h' "$(CREDS)/$f")"
    [ "$(wc -l < "$(CREDS)/$f")" = 1 ] || fail "$f is not exactly one line"
  done
  [ "$(stat -c %a "$(CREDS)")" = 750 ] || fail "the credential directory is not 0750"
  [ -z "$(find "$(CREDS)" -name '.*staged*')" ] || fail "a staged key file was left behind"
  assert_secret_nowhere "$r"; assert_secret_nowhere "$c"
  # shown once, at the end, after the final validation, followed by the screen clear
  sed -n '/REST API keys for the APEX Web Credentials/,$p' "$SB/out" | grep -qF "Bearer $r" || fail "the read key was not shown at the end"
  sed -n '/REST API keys for the APEX Web Credentials/,$p' "$SB/out" | grep -qF "Bearer $c" || fail "the control key was not shown at the end"
  sed -n '1,/REST API keys for the APEX Web Credentials/p' "$SB/out" | grep -qF "$r" && fail "the read key was shown before the end"
  assert_out "<CLEAR-SCREEN>"
  assert_out "Created the read key (GET APIs)"; assert_out "Created the control key (POST APIs: start/stop)"
  assert_out "[PASS] REST API deployed"
  assert_log "API key file created"
  # the keys are created after the download and before the setup assistant runs
  grep -n -E 'stage 4/7|API key file created|run \(interactive' "$SB"/var/log/oracle-ops-installer/*.log | awk -F: '{print $1}' | sort -n -c \
    || fail "the key files were not created between the download and the setup assistant"
}

test_install_keeps_an_existing_valid_key_and_creates_the_other() {
  make_keys; rm -f "$(CREDS)/api-control.credentials"
  local before
  before="$(sha256sum < "$(CREDS)/api.credentials")"
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_out "exists and is valid: kept as it is"; assert_out "Kept the existing read key"
  [ "$(sha256sum < "$(CREDS)/api.credentials")" = "$before" ] || fail "the existing read key file was changed"
  [ "$(key_value api-control.credentials api.control.token)" != "$READ_K" ] || fail "the new control key equals the read key"
  assert_secret_nowhere "$READ_K"
}

test_install_refuses_an_invalid_or_linked_key_file_before_any_change() {
  mkdir -p "$(CREDS)"; printf 'api.token=short\n' > "$(CREDS)/api.credentials"
  input 1 "" "${ANS[@]:0:7}"
  run_installer
  assert_rc 1; assert_out "is not a valid key file"; assert_out "nothing was changed"
  assert_absent "$SB/git-trace"; assert_no_trace; assert_absent "$(CREDS)/api-control.credentials"
  rm -f "$(CREDS)/api.credentials"; echo "top-secret-elsewhere-0123456789abcdef0123" > "$SB/elsewhere"
  ln -s "$SB/elsewhere" "$(CREDS)/api.credentials"
  run_installer
  assert_rc 1; assert_out "is a symbolic link"; assert_absent "$SB/git-trace"
  assert_not_out "top-secret-elsewhere"
}

test_install_service_account_must_exist_and_not_be_root() {
  input 1 "" root no_such_account_zz "bad name!"
  run_installer
  assert_rc 2; assert_out "root is not allowed"; assert_out "There is no account 'no_such_account_zz'"
  assert_out "Not a valid account name"; assert_absent "$SB/git-trace"; assert_absent "$(CREDS)"
}

test_install_api_listener_is_loopback_and_port_free() {
  touch "$SB/port-busy-18888"
  input 1 "" "$(id -un)" "" dbhost.example "" OPSPDB 10.0.0.5 "0.0.0.0" "" 80 18888 18889 yes 2 "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_out "10.0.0.5 is not an address of this host"; assert_out "Enter an IP address of this host"
  assert_out "Enter a number from 1024 to 65535"; assert_out "Port 18888 is already in use on this host"
  assert_trace "--enable-api --api-bind-address 127.0.0.1 --api-port 18889"
}

test_install_network_listener_for_a_remote_apex() {   # apps and database on separate servers
  input 1 "" "$(id -un)" "" dbhost.example "" OPSPDB 10.1.2.3 "10.9.9.9,bad" "10.9.9.9, 10.9.9.10" "$TEST_API_PORT" yes 2 "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 0
  assert_out "Enter 1 to 8 IP addresses"
  assert_trace "--api-bind-address 127.0.0.1"          # the setup assistant accepts loopback only; moved afterwards
  assert_trace "config-migrate.sh args=validate --home $(HOME_DIR)"
  grep -qx '  bind-address: "10.1.2.3"' "$(HOME_DIR)/config/application.yaml" || fail "bind-address not set"
  grep -qx '    client-addresses: "10.9.9.9,10.9.9.10"' "$(HOME_DIR)/config/application.yaml" || fail "client addresses not set"
  ls "$(HOME_DIR)"/config/application.yaml.before-network-listener.* >/dev/null 2>&1 || fail "no backup of application.yaml"
  grep -qx restart "$SB/systemctl-trace" || fail "the service was not restarted"
  assert_out "[PASS] REST API listener - 10.1.2.3:$TEST_API_PORT for 10.9.9.9,10.9.9.10"
  assert_out "Valid for URLs      : http://10.1.2.3:$TEST_API_PORT/"
}

test_install_network_listener_restored_when_oracle_ops_refuses_it() {
  stub_mode CONFIG_MIGRATE_MODE fail
  input 1 "" "$(id -un)" "" dbhost.example "" OPSPDB 10.1.2.3 10.9.9.9 "$TEST_API_PORT" yes 2 "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "Oracle OPS does not accept the network listener 10.1.2.3"
  grep -qx '  bind-address: "127.0.0.1"' "$(HOME_DIR)/config/application.yaml" || fail "the original configuration was not restored"
  ! grep -q 'plain-http' "$(HOME_DIR)/config/application.yaml" || fail "the client block stayed"
}

test_install_not_confirmed_at_review_changes_nothing() {   # discovery and the questions change nothing
  mkdir -p "$SB/etc/oracle-ops"; echo keep > "$SB/etc/oracle-ops/database.credentials"
  local before_etc before_u01
  before_etc="$(tree_digest "$SB/etc")"; before_u01="$(tree_digest "$SB/u01")"
  input 1 "" "$(id -un)" "" dbhost.example "" OPSPDB "" "$TEST_API_PORT" no
  run_installer
  assert_rc 5; assert_out "the installation was not confirmed; nothing was changed"
  assert_out "Operating system"; assert_out "Credential directory"; assert_out "holds: database.credentials"
  [ "$(tree_digest "$SB/etc")" = "$before_etc" ] || fail "discovery or the questions changed /etc"
  [ "$(tree_digest "$SB/u01")" = "$before_u01" ] || fail "discovery or the questions changed /u01"
  assert_absent "$SB/git-trace"; assert_no_trace; assert_clean
}

test_install_fails_when_the_api_reports_no_routes() {
  stub_mode ROUTES_MODE none
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "[FAIL] REST API deployed"; assert_out "the installation is not complete"
  assert_not_out "completed successfully"
}

test_install_fails_closed_without_random_data() {
  EXTRA="RANDOM_SOURCE=$SB/empty-random"
  : > "$SB/empty-random"
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "cannot read random data"; assert_absent "$(CREDS)/api.credentials"
  ! grep -q '^deploy-oracle-ops.sh' "$SB/roothome/trace" || fail "the setup assistant ran without API keys"
}

test_menu_shows_why_items_do_not_apply() {
  input "$MENU_EXIT"
  run_installer
  assert_rc 0
  assert_out "2) Upgrade Existing Installation    (not available: nothing installed)"
  assert_out "(not available: no keys in"; assert_out "Installed: none found on this host"
  existing_install 0.1.4 abcdef1
  run_installer
  assert_out "1) Fresh Installation               (not available: Oracle OPS is already installed)"
}

# ---- Database prerequisites, database objects (0.3.0) ------------------------------------------------------------------------

DBCONF() { printf '%s=%s\n' "$1" "$2" >> "$SB/dbtool.conf"; }
ANS_TO_REVIEW=("$(id -un)" "" dbhost.example "" OPSPDB "" "$TEST_API_PORT" yes)

test_dba_sql_is_written_shown_and_waits_for_the_dba() {
  input 1 "" "${ANS_TO_REVIEW[@]}" 1 "$SB/u01/ops-schema.sql" no
  run_installer
  assert_rc 5; assert_out "the installation waits for the DBA"
  local f="$SB/u01/ops-schema.sql"
  assert_exists "$f"
  [ "$(stat -c %a "$f")" = 644 ] || fail "the DBA SQL is not 0644"
  grep -q "^create user ops_owner identified by \"&ops_owner_pw\" default tablespace ops_data quota unlimited on ops_data;" "$f" || fail "no OPS_OWNER"
  grep -q "^create user ops_runtime identified by \"&ops_runtime_pw\" default tablespace ops_data;" "$f" || fail "no OPS_RUNTIME"
  grep -q "^accept ops_owner_pw char prompt .* hide$" "$f" || fail "the owner password is not asked hidden"
  grep -q "^grant create session, create table, create sequence, create procedure to ops_owner;" "$f" || fail "owner privileges"
  grep -q "^grant create session to ops_runtime;" "$f" || fail "runtime privilege"
  local v
  for v in dba_arguments dba_col_privs dba_errors dba_objects dba_procedures dba_role_privs dba_sys_privs dba_tablespaces dba_tab_privs dba_users; do
    grep -qx "grant select on sys.$v to ops_owner;" "$f" || fail "no grant on $v"
  done
  grep -q 'CDB\$ROOT' "$f" || fail "no root-container check"
  grep -q "set verify off" "$f" || fail "verify is not off (the passwords would be echoed)"
  assert_out "| create user ops_owner"; assert_out "sqlplus system@//dbhost.example:1521/OPSPDB @ops-schema.sql"
  # nothing on the host was changed and nothing was downloaded
  assert_absent "$SB/git-trace"; assert_no_trace; assert_absent "$(HOME_DIR)"; assert_absent "$(CREDS)"
}

test_dba_sql_then_continue_installs() {
  input 1 "" "${ANS_TO_REVIEW[@]}" 1 "" yes "$TEST_TOKEN" "${POST[@]}"
  EXTRA="ROOT_HOME=$SB/roothome"
  run_installer
  assert_rc 0; assert_exists "$SB/roothome/oracle-ops-schema-$FIX_VERSION.sql"; assert_out "completed successfully"
}

test_database_listener_unreachable_is_asked_again() {
  touch "$SB/db-down"
  input 1 "" "$(id -un)" "" h1 "" h2 "" h3 ""
  run_installer
  assert_rc 2; assert_out "No database listener answers at h1:1521"; assert_out "no reachable database listener after three attempts"
  assert_absent "$SB/git-trace"
}

test_owner_password_wrong_twice_stops_without_a_third_try() {
  DBCONF LOGIN wrong
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" bad1 bad2 bad3
  run_installer
  assert_rc 1; assert_out "rejected twice"; assert_out "more attempts could lock the account"
  [ "$(cat "$SB/dbtool-calls")" = 2 ] || fail "the tool was called $(cat "$SB/dbtool-calls") times"
  ! grep -q '^deploy-oracle-ops.sh' "$SB/roothome/trace" || fail "the setup assistant ran"
  assert_absent "$(CREDS)/api.credentials"
}

test_owner_password_wrong_once_then_right() {
  DBCONF LOGIN wrong-once
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" bad "${POST[@]}"
  run_installer
  assert_rc 0; assert_out "rejected the user name or password (ORA-01017)"
}

test_owner_locked_stops() {
  DBCONF LOGIN locked
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "locked or its password has expired"
}

test_database_down_at_login_stops() {
  DBCONF LOGIN down
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "the database could not be reached at dbhost.example:1521/OPSPDB"
}

test_missing_dba_prerequisites_are_reported() {
  DBCONF PREREQ fail
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "[FAIL] dictionary-views"; assert_out "the database prerequisites are not complete"
  ! grep -q '^args=deploy' "$SB/dbtool-trace" || fail "deploy ran"
}

test_complete_schema_is_left_as_it_is() {
  DBCONF STATE COMPLETE
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "$TEST_OWNER_PW" yes ""
  run_installer
  assert_rc 0; assert_out "already exist and are valid: nothing to create"
  ! grep -q '^args=deploy' "$SB/dbtool-trace" || fail "deploy ran on a complete schema"
}

test_partial_schema_stops_and_drops_nothing() {
  DBCONF STATE PARTIAL
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "holds only part of the Oracle OPS objects"; assert_out "never drops or replaces database objects"
  ! grep -q '^args=deploy' "$SB/dbtool-trace" || fail "deploy ran on a partial schema"
}

test_deploy_failure_stops_before_the_service() {
  DBCONF DEPLOY fail
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "creating the Oracle OPS database objects failed"; assert_out "ERROR: ORA-00942"
  ! grep -q '^deploy-oracle-ops.sh' "$SB/roothome/trace" || fail "the setup assistant ran after a failed deploy"
}

test_creating_objects_can_be_declined() {
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "$TEST_OWNER_PW" no
  run_installer
  assert_rc 5; assert_out "no database object was created"
  ! grep -q '^args=deploy' "$SB/dbtool-trace" || fail "deploy ran"
}

test_database_script_digest_mismatch_is_refused() {
  EXTRA='OPS_DB_SCRIPTS[0]="0000000000000000000000000000000000000000000000000000000000000001  run  db/migrations/V4_001__create_ops_run.sql"'
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 4; assert_out "does not match the SHA-256 recorded in the installer"; assert_absent "$SB/dbtool-trace"
}

test_private_jdk_failure_stops() {
  stub_mode JDK_MODE fail
  input 1 "" "${ANS[@]}" "$TEST_TOKEN" "${POST[@]}"
  run_installer
  assert_rc 1; assert_out "the private Java runtime could not be installed"; assert_absent "$SB/dbtool-trace"
}

# ---- Running from an unprotected clone -----------------------------------------------------------------------------------------

test_unprotected_clone_is_copied_after_confirmation() {
  mkdir -p "$SB/varlib"; chmod 0755 "$SB/varlib"
  ( . "$INSTALLER" >/dev/null 2>&1; LOADER_COPY_BASE="$SB/varlib"; LOADER_ASSUME_TTY=1
    ldr_copy_and_run --version <<< "yes" ) > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_out "can be changed by an account other than root"; assert_out "Running the copy in $SB/varlib/oracle-ops-installer-copy."
  assert_out "Oracle OPS Installer $(sed -n 's/^INSTALLER_VERSION="\(.*\)"$/\1/p' "$INSTALLER")"
  [ -z "$(ls -A "$SB/varlib")" ] || fail "the copy was not removed: $(ls -A "$SB/varlib")"
  ( . "$INSTALLER" >/dev/null 2>&1; LOADER_COPY_BASE="$SB/varlib"; LOADER_ASSUME_TTY=1
    ldr_copy_and_run --version <<< "no" ) > "$SB/out" 2>&1; RC=$?
  assert_rc 2; assert_out "not confirmed; nothing was run"; [ -z "$(ls -A "$SB/varlib")" ] || fail "a copy was made without confirmation"
  ( . "$INSTALLER" >/dev/null 2>&1; LOADER_COPY_BASE="$SB/varlib"; ldr_copy_and_run --version < /dev/null ) > "$SB/out" 2>&1; RC=$?
  assert_rc 2; assert_out "no terminal to confirm that"
}

# ---- View API Keys -----------------------------------------------------------------------------------------------------------

test_view_api_keys_needs_the_typed_word() {
  make_keys
  input 7 3 show
  run_installer
  assert_rc 5; assert_out "no key was displayed"
  assert_secret_nowhere "$READ_K" terminal; assert_secret_nowhere "$CTRL_K" terminal
}

test_view_api_keys_shows_both_and_never_logs_them() {
  make_keys
  input 7 3 SHOW ""
  run_installer
  assert_rc 0
  assert_out "Credential secret   : Bearer $READ_K"; assert_out "Credential secret   : Bearer $CTRL_K"
  assert_out "Static ID           : OPS_API_TOKEN"; assert_out "Static ID           : oracle-ops-api-token-action"
  assert_out "Authentication type : HTTP Header"; assert_out "Credential name     : Authorization"
  assert_out "<CLEAR-SCREEN>"; assert_log "value not logged"
  assert_secret_nowhere "$READ_K"; assert_secret_nowhere "$CTRL_K"
}

test_view_api_keys_uses_the_installed_listener_for_the_url() {
  existing_install 0.1.4 abcdef1; make_keys
  printf 'api:\n  enabled: true\n  bind-address: "127.0.0.1"\n  port: 18901\n' > "$(HOME_DIR)/config/application.yaml"
  input 7 1 SHOW ""
  run_installer
  assert_rc 0; assert_out "Valid for URLs      : http://127.0.0.1:18901/"; assert_secret_nowhere "$CTRL_K" terminal
}

test_view_api_keys_refuses_links_and_bad_files() {
  mkdir -p "$(CREDS)"
  echo "api.token=linked-secret-0123456789abcdef0123456789" > "$SB/elsewhere"
  ln -s "$SB/elsewhere" "$(CREDS)/api.credentials"
  input 7 3 SHOW
  run_installer
  assert_rc 6; assert_out "no API key file exists"; assert_out "a symbolic link (refused)"; assert_not_out "linked-secret"
  rm -f "$(CREDS)/api.credentials"; make_keys; printf 'api.control.token=%s\nextra=1\n' "$CTRL_K" > "$(CREDS)/api-control.credentials"
  input 7 2 SHOW
  run_installer
  assert_rc 1; assert_out "does not hold exactly one valid api.control.token line: not displayed"
  assert_secret_nowhere "$CTRL_K" terminal
}

test_view_api_keys_without_keys() {
  input 7
  run_installer
  assert_rc 6; assert_out "no API key file exists"
}

# ---- View APIs -----------------------------------------------------------------------------------------------------------------

test_view_apis_not_installed_shows_the_catalogue() {
  make_keys
  input 6 7 ""
  run_installer
  assert_rc 0
  assert_out "NOT INSTALLED"; assert_out "/api/v1/managed-servers/{name}/stop"; assert_out "acknowledge_outage"
  assert_out "Authorization: Bearer <control key>"
  assert_secret_nowhere "$READ_K" terminal; assert_secret_nowhere "$CTRL_K" terminal
}

test_view_apis_status_comes_from_the_service_log() {
  existing_install 0.1.4 abcdef1
  echo "x INFO [c] API routes served: [/api/v1/about, /api/v1/ops/status]" >> "$(HOME_DIR)/logs/oracle-ops.log"
  input 6 ""
  run_installer
  assert_rc 0
  grep -qE '/api/v1/about +read-only +read +DEPLOYED' "$SB/out" || fail "about is not DEPLOYED"
  grep -qE '/api/v1/linux/host +read-only +read +NOT DEPLOYED' "$SB/out" || fail "linux/host is not NOT DEPLOYED"
  assert_out "NOTE: the installed release is 0.1.4"
  echo "x INFO [c] REST API is disabled (api.enabled=false)" >> "$(HOME_DIR)/logs/oracle-ops.log"
  run_installer
  assert_out "API DISABLED"
  echo inactive > "$SB/systemctl-state"
  run_installer
  assert_out "SERVICE STOPPED"
}

# ---- View Configuration --------------------------------------------------------------------------------------------------------

test_view_configuration_masks_secrets_and_never_opens_credentials() {
  existing_install 0.1.4 abcdef1
  printf 'db.username=OPS_RUNTIME\ndb.password=Db-Secret-Value-99\n' > "$(CREDS)/database.credentials"
  printf 'database:\n  host: dbhost\n  password: yaml-secret-77\n# a comment about the token\napi:\n  enabled: true\n' > "$(HOME_DIR)/config/application.yaml"
  input 8
  run_installer
  assert_rc 0
  assert_out "| database:"; assert_out "host: dbhost"; assert_out "password: ******** (masked by the installer)"
  assert_out "# a comment about the token"
  assert_not_out "yaml-secret-77"; assert_not_out "Db-Secret-Value-99"
  assert_out "database.credentials"
}

test_view_configuration_needs_an_installation() {
  input 8
  run_installer
  assert_rc 6; assert_out "Oracle OPS is not installed on this host"
}

# ---- Reconfigure > Regenerate the REST API keys --------------------------------------------------------------------------------

test_reconfigure_regenerates_both_keys_and_restarts() {
  existing_install 0.1.4 abcdef1; make_keys
  input 3 3 3 yes yes
  run_installer
  assert_rc 0; assert_out "Oracle OPS was restarted with them"
  local r c
  r="$(key_value api.credentials api.token)"; c="$(key_value api-control.credentials api.control.token)"
  [ "$r" != "$READ_K" ] && [ "$c" != "$CTRL_K" ] || fail "a key was not replaced"
  [ "$r" != "$c" ] || fail "the new keys are identical"
  [ "$(stat -c '%a %h' "$(CREDS)/api.credentials")" = "640 1" ] || fail "the replaced read key file has the wrong mode"
  grep -qx restart "$SB/systemctl-trace" || fail "the service was not restarted"
  assert_secret_nowhere "$r" terminal; assert_secret_nowhere "$c" terminal
  [ -z "$(find "$(CREDS)" -name '.*staged*')" ] || fail "a staged key file was left behind"
}

test_reconfigure_regenerates_one_key_without_restart() {
  existing_install 0.1.4 abcdef1; make_keys
  input 3 3 1 yes no
  run_installer
  assert_rc 0; assert_out "Oracle OPS was NOT restarted"
  [ "$(key_value api.credentials api.token)" != "$READ_K" ] || fail "the read key was not replaced"
  [ "$(key_value api-control.credentials api.control.token)" = "$CTRL_K" ] || fail "the control key was changed"
  ! grep -qx restart "$SB/systemctl-trace" 2>/dev/null || fail "the service was restarted"
}

test_reconfigure_key_regeneration_can_be_declined() {
  existing_install 0.1.4 abcdef1; make_keys
  input 3 3 3 no
  run_installer
  assert_rc 5; assert_out "no key was replaced"
  [ "$(key_value api.credentials api.token)" = "$READ_K" ] || fail "the read key was changed"
}

# ---- upgrade -------------------------------------------------------------------------------------------------------------

test_upgrade_success() {
  existing_install 0.1.4 abcdef1
  input 2 "$TEST_TOKEN" yes
  run_installer
  assert_rc 0; assert_out "Oracle OPS upgrade completed successfully."; assert_out "release 0.1.4 is kept for rollback"
  assert_trace "install-release.sh args=--preflight --home $(HOME_DIR) --user $(id -un) --group $(id -gn)"
  assert_trace "install-release.sh args=--home $(HOME_DIR) --user $(id -un) --group $(id -gn)"
  assert_trace "service-identity.sh args=check --home $(HOME_DIR)"
  [ "$(readlink -f "$(HOME_DIR)/current")" = "$(HOME_DIR)/releases/$FIX_VERSION" ] || fail "current not switched"
  assert_exists "$(HOME_DIR)/releases/0.1.4/oracle-ops.jar"
  assert_trace "install-release.sh authdirs=0"; assert_clean; assert_no_token
}

test_upgrade_declined_changes_nothing() {   # [22]
  existing_install 0.1.4 abcdef1
  input 2 "$TEST_TOKEN" no
  run_installer
  assert_rc 5; assert_out "the upgrade was not confirmed"
  grep -q "^install-release.sh args=--home" "$SB/roothome/trace" && fail "the upgrade ran without confirmation"
  [ "$(readlink -f "$(HOME_DIR)/current")" = "$(HOME_DIR)/releases/0.1.4" ] || fail "current changed"
  assert_clean
}

test_upgrade_preflight_failure() {
  existing_install 0.1.4 abcdef1
  stub_mode PREFLIGHT_MODE fail
  input 2 "$TEST_TOKEN"
  run_installer
  assert_rc 1; assert_out "the upgrade pre-check failed"; assert_log "not enough free space"
  grep -q "^install-release.sh args=--home" "$SB/roothome/trace" && fail "installed after a failed pre-check"
  assert_clean
}

test_upgrade_script_failure() {
  existing_install 0.1.4 abcdef1
  stub_mode INSTALL_MODE fail
  input 2 "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "Oracle OPS upgrade failed."; assert_out "release 0.1.4 is still installed"
  assert_log "activate-release.sh --home $(HOME_DIR) --release 0.1.4"
  assert_clean
}

test_upgrade_unhealthy_database_is_a_failure() {   # [16]
  existing_install 0.1.4 abcdef1
  stub_mode INSTALL_MODE unhealthy
  input 2 "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "did not report a healthy database connection"; assert_clean
}

test_upgrade_identity_check_failure() {
  existing_install 0.1.4 abcdef1
  stub_mode CHECK_MODE fail
  input 2 "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "service account check"; assert_clean
}

test_upgrade_already_current() {
  existing_install "$FIX_VERSION" "${FIX_COMMIT:0:7}"
  input 2
  run_installer
  assert_rc 0; assert_out "already installed and running. Nothing was changed."; assert_absent "$SB/git-trace"
}

test_upgrade_same_version_from_other_source_is_refused() {
  existing_install "$FIX_VERSION" 3efda19
  input 2
  run_installer
  assert_rc 6; assert_out "built from different source (commit 3efda19)"; assert_absent "$SB/git-trace"; assert_clean
}

test_upgrade_needs_configuration_and_credentials() {
  existing_install 0.1.4 abcdef1
  rm -f "$SB/etc/oracle-ops/database.credentials"
  input 2
  run_installer
  assert_rc 6; assert_out "an upgrade needs both in place"; assert_absent "$SB/git-trace"
}

test_upgrade_resumes_a_deployed_but_inactive_release() {
  existing_install 0.1.4 abcdef1
  local h; h="$(HOME_DIR)"
  mkdir -p "$h/releases/$FIX_VERSION"; printf '%s\n' "$FIX_VERSION" > "$h/releases/$FIX_VERSION/VERSION"
  python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("com/oracleops/core/version.properties","build.gitCommit=%s\n"%sys.argv[2]); z.close()' \
    "$h/releases/$FIX_VERSION/oracle-ops.jar" "${FIX_COMMIT:0:7}"
  input 2 "$TEST_TOKEN" yes
  run_installer
  assert_rc 0; assert_out "already deployed but not active"
  assert_trace "activate-release.sh args=--home $h --release $FIX_VERSION"
  grep -q "^install-release.sh" "$SB/roothome/trace" && fail "install-release.sh was used for an already deployed release"
  return 0
}

test_upgrade_without_installation() {
  input 2
  run_installer
  assert_rc 6; assert_out "Oracle OPS is not installed on this host"
}

# ---- de-install -----------------------------------------------------------------------------------------------------------

test_deinstall_success_renames_and_keeps_credentials() {
  existing_install 0.1.4 abcdef1
  local cred_before
  cred_before="$(sha256sum "$SB/etc/oracle-ops/database.credentials")"
  input 9 yes "$TEST_TOKEN"
  run_installer
  assert_rc 0; assert_out "Oracle OPS de-installation completed successfully."
  assert_absent "$(HOME_DIR)"; assert_absent "$SB/etc/systemd/system/oracle-ops.service"
  ls -d "$(HOME_DIR)".retired-* >/dev/null 2>&1 || fail "the renamed installation is missing"
  assert_exists "$(ls -d "$(HOME_DIR)".retired-* | head -n 1)/releases/0.1.4/oracle-ops.jar"
  [ "$(sha256sum "$SB/etc/oracle-ops/database.credentials")" = "$cred_before" ] || fail "credentials changed"
  assert_trace "service-identity.sh args=retire --home $(HOME_DIR)"
  assert_trace "service-identity.sh args=retire --home $(HOME_DIR) --apply"
  assert_clean; assert_no_token
}

test_deinstall_declined() {
  existing_install 0.1.4 abcdef1
  input 9 no
  run_installer
  assert_rc 5; assert_exists "$(HOME_DIR)/current"; assert_absent "$SB/git-trace"; assert_clean
}

test_deinstall_without_installation() {
  input 9 "$SB/u01/nothing"
  run_installer
  assert_rc 6; assert_out "no Oracle OPS installation was found"
}

# ---- credentials ----------------------------------------------------------------------------------------------------------

test_update_weblogic_credential() {
  existing_install 0.1.4 abcdef1
  input 3 1 "$TEST_TOKEN" weblogic 'S3cret-Pass_word'
  run_installer
  assert_rc 0; assert_out "WebLogic credential updated successfully."
  [ "$(stat -c %a "$SB/etc/oracle-ops/apps.credentials")" = 400 ] || fail "apps.credentials mode"
  assert_trace "manage-app-credentials.sh args="
  assert_trace "manage-app-credentials.sh authdirs=0"
  grep -rqF 'S3cret-Pass_word' "$SB/var/log" "$SB/out" && fail "the WebLogic password appears in the output or the log"
  assert_clean; assert_no_token
}

test_update_weblogic_credential_declined() {
  existing_install 0.1.4 abcdef1
  stub_mode CRED_MODE decline
  input 3 1 "$TEST_TOKEN"
  run_installer
  assert_rc 5; assert_out "the existing WebLogic credential was kept"; assert_clean
}

test_update_weblogic_credential_wrong_permissions_detected() {
  existing_install 0.1.4 abcdef1
  stub_mode CRED_MODE badperm
  input 3 1 "$TEST_TOKEN" weblogic pw
  run_installer
  assert_rc 1; assert_out "does not have the expected owner and permissions"; assert_clean
}

test_database_password_guidance_changes_nothing() {
  input 3 2
  run_installer
  assert_rc 0; assert_out "database.credentials"; assert_out "No changes were made."
  assert_absent "$SB/git-trace"; assert_no_trace; assert_clean
}

# ---- locking and logs ------------------------------------------------------------------------------------------------------

test_concurrent_run_is_refused() {
  mkdir -m 0700 -p "$SB/var/lib/oracle-ops-installer"
  : > "$SB/var/lib/oracle-ops-installer/.lock"
  flock "$SB/var/lib/oracle-ops-installer/.lock" sleep 5 &
  local holder=$!
  sleep 0.5
  input "$MENU_EXIT"
  run_installer
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_rc 1; assert_out "another run of the Oracle OPS Installer is in progress"
}

test_log_rotation_keeps_the_newest_and_nothing_else_is_removed() {
  local d="$SB/var/log/oracle-ops-installer" i
  mkdir -m 0700 -p "$d"
  for i in $(seq -w 1 25); do : > "$d/oracle-ops-installer-202601${i}T000000Z-1.log"; done
  echo keep > "$d/admin-notes.txt"
  input "$MENU_EXIT"
  run_installer
  assert_rc 0
  [ "$(find "$d" -name 'oracle-ops-installer-*.log' | wc -l)" = 20 ] || fail "expected 20 logs to be kept"
  assert_exists "$d/admin-notes.txt"
  assert_absent "$d/oracle-ops-installer-20260101T000000Z-1.log"
}

# ---- integrity of the split installer (loader, library digests, ownership rules) ---------------------------------------------
# These tests copy the installer tree into the sandbox, damage the copy in one way and expect the loader to refuse it; each has
# a positive control (the undamaged copy, or the same copy with the damage undone, is accepted) so a refusal is known to come
# from the rule under test. Nothing runs as root: the "executed as root" branch is exercised by calling the loader function
# with a parameterised uid, and the ownership rules by calling the check function with an explicit extra owner.

ENTRY_BASENAME="oracle-ops-installer.sh"

make_copy() {   # make_copy <dir>: entry script and libraries, modes preserved
  mkdir -p "$1/lib" && cp -p "$REPO_ROOT/$ENTRY_BASENAME" "$1/" && cp -p "$REPO_ROOT"/lib/*.sh "$1/lib/"
}
regen_digests() { bash "$REPO_ROOT/tests/update-lib-digests.sh" --root "$1" > /dev/null || fail "cannot regenerate the digests of $1"; }
me() { id -u; }

# probe_source <copy>: source the copy in a subshell; reports the load status and whether any library defined anything
probe_source() {
  ( . "$1/$ENTRY_BASENAME"; rc=$?; echo "load-status=$rc"; echo "state-dir=${STATE_DIR-unset}"; declare -F is_root > /dev/null && echo "seam=defined" || echo "seam=undefined" ) > "$SB/out" 2>&1
  RC=$?
}
# probe_exec <copy> <args>: run the copy as a program (non-root)
probe_exec() { local c="$1"; shift; bash "$c/$ENTRY_BASENAME" "$@" > "$SB/out" 2>&1; RC=$?; }
# probe_check <copy> <extra owner uid or empty> [entry file]: the secure-path check on a copy
probe_check() {
  ( . "$REPO_ROOT/$ENTRY_BASENAME" && ldr_check_secure "$1" "${3:-$1/$ENTRY_BASENAME}" "$2" ) > "$SB/out" 2>&1
  RC=$?
}
# probe_main <copy> <ADMIN_UID> <LOADER_TEST_UID>: source the copy, reassign the uids like the tests do, run main --version
probe_main() {
  ( . "$1/$ENTRY_BASENAME" || exit $?; ADMIN_UID="$2"; LOADER_TEST_UID="$3"; main --version ) > "$SB/out" 2>&1
  RC=$?
}
# probe_run <copy> <executed 1|0> <euid> <admin uid> <test uid>: the loader function itself, as if run in that mode
probe_run() {
  ( . "$REPO_ROOT/$ENTRY_BASENAME"; LOADER_ADMIN_UID="$4"; LOADER_TEST_UID="$5"
    ldr_run "$1/$ENTRY_BASENAME" "$2" "$3"; rc=$?; echo "ldr_run-status=$rc"; exit "$rc" ) > "$SB/out" 2>&1
  RC=$?
}

test_integrity_real_tree_loads_and_manifest_is_current() {
  probe_source "$REPO_ROOT"; assert_rc 0; assert_out "load-status=0"; assert_out "seam=defined"
  probe_exec "$REPO_ROOT" --version; assert_rc 0; assert_out "Oracle OPS Installer 0"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --check > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_out "library manifest is current"
  # every library of the repository is listed, none twice, in the order the loader uses
  local listed on_disk
  listed="$(sed -n 's/^  "[0-9a-f]\{64\}  \(lib\/[a-z0-9-]*\.sh\)"$/\1/p' "$REPO_ROOT/$ENTRY_BASENAME" | sort | tr '\n' ' ')"
  on_disk="$(cd "$REPO_ROOT" && ls lib/*.sh | sort | tr '\n' ' ')"
  [ "$listed" = "$on_disk" ] || fail "listed libraries ($listed) differ from lib/*.sh ($on_disk)"
}

test_integrity_digest_mismatch_refuses_and_nothing_is_sourced() {
  make_copy "$SB/inst"
  probe_source "$SB/inst"; assert_rc 0; assert_out "load-status=0"           # control: the copy is accepted
  printf '\n# one more comment\n' >> "$SB/inst/lib/prereq.sh"
  probe_source "$SB/inst"
  assert_out "load-status=2"; assert_out "lib/prereq.sh does not match its recorded SHA-256 digest"
  assert_out "state-dir=unset"; assert_out "seam=undefined"                  # not even the libraries before it were sourced
  probe_exec "$SB/inst" --version
  assert_rc 2; assert_out "lib/prereq.sh does not match"; assert_not_out "Oracle OPS Installer 0"
  regen_digests "$SB/inst"                                                   # control: the new digest is accepted
  probe_exec "$SB/inst" --version; assert_rc 0; assert_out "Oracle OPS Installer 0"
}

test_integrity_missing_library_refused() {
  make_copy "$SB/inst"
  rm -f "$SB/inst/lib/menu.sh"
  probe_source "$SB/inst"; assert_out "load-status=2"; assert_out "lib/menu.sh is missing"; assert_out "state-dir=unset"
  probe_exec "$SB/inst" --version; assert_rc 2; assert_out "lib/menu.sh is missing"
  mkdir "$SB/inst/lib/menu.sh"                                               # a directory is not a regular file either
  probe_exec "$SB/inst" --version; assert_rc 2; assert_out "lib/menu.sh is missing or not a regular file"
}

test_integrity_library_symlink_refused() {
  make_copy "$SB/inst"
  cp -p "$SB/inst/lib/menu.sh" "$SB/menu-real.sh"                            # same bytes, hence the right digest
  rm -f "$SB/inst/lib/menu.sh"; ln -s "$SB/menu-real.sh" "$SB/inst/lib/menu.sh"
  probe_source "$SB/inst"; assert_out "load-status=2"; assert_out "lib/menu.sh is a symbolic link"; assert_out "state-dir=unset"
  probe_exec "$SB/inst" --version; assert_rc 2; assert_out "lib/menu.sh is a symbolic link"
  rm -f "$SB/inst/lib/menu.sh"; cp -p "$SB/menu-real.sh" "$SB/inst/lib/menu.sh"   # control
  probe_exec "$SB/inst" --version; assert_rc 0
  # the ownership check refuses it too (a link is examined, not followed)
  rm -f "$SB/inst/lib/menu.sh"; ln -s "$SB/menu-real.sh" "$SB/inst/lib/menu.sh"
  probe_check "$SB/inst" "$(me)"; assert_rc 1; assert_out "lib/menu.sh is a symbolic link"
}

test_integrity_entry_symlink_refused() {
  make_copy "$SB/inst"
  probe_check "$SB/inst" "$(me)"; assert_rc 0                                # control
  mkdir "$SB/linked"; ln -s "$SB/inst/$ENTRY_BASENAME" "$SB/linked/$ENTRY_BASENAME"; ln -s "$SB/inst/lib" "$SB/linked/lib"
  probe_check "$SB/linked" "$(me)"; assert_rc 1; assert_out "$SB/linked/$ENTRY_BASENAME is a symbolic link"
  # sourced: libraries load (they are found next to the link) but main() refuses before doing anything else
  mkdir "$SB/linked2"; ln -s "$SB/inst/$ENTRY_BASENAME" "$SB/linked2/$ENTRY_BASENAME"; cp -pr "$SB/inst/lib" "$SB/linked2/lib"
  probe_main "$SB/linked2" "$(me)" "$(me)"; assert_rc 2; assert_out "is a symbolic link"; assert_not_out "Oracle OPS Installer 0"
  # executed as root (simulated): refused before any library is hashed or sourced
  probe_run "$SB/linked2" 1 0 0 "$(me)"; assert_rc 2; assert_out "is a symbolic link"
}

test_integrity_writable_library_lib_directory_or_ancestor_refused() {
  mkdir -p "$SB/a/b"; make_copy "$SB/a/b/inst"
  probe_check "$SB/a/b/inst" "$(me)"; assert_rc 0                            # control
  local what mode path
  for mode in g+w o+w; do
    chmod "$mode" "$SB/a/b/inst/lib/common.sh"
    probe_check "$SB/a/b/inst" "$(me)"; assert_rc 1; assert_out "$SB/a/b/inst/lib/common.sh is writable by group or other users"
    chmod go-w "$SB/a/b/inst/lib/common.sh"
    chmod "$mode" "$SB/a/b/inst/lib"
    probe_check "$SB/a/b/inst" "$(me)"; assert_rc 1; assert_out "$SB/a/b/inst/lib is writable by group or other users"
    chmod go-w "$SB/a/b/inst/lib"
    chmod "$mode" "$SB/a/b/inst/$ENTRY_BASENAME"
    probe_check "$SB/a/b/inst" "$(me)"; assert_rc 1; assert_out "$SB/a/b/inst/$ENTRY_BASENAME is writable by group or other users"
    chmod go-w "$SB/a/b/inst/$ENTRY_BASENAME"
    chmod "$mode" "$SB/a/b/inst"
    probe_check "$SB/a/b/inst" "$(me)"; assert_rc 1; assert_out "$SB/a/b/inst is writable by group or other users"
    chmod go-w "$SB/a/b/inst"
    chmod "$mode" "$SB/a"                                                    # an ancestor further up
    probe_check "$SB/a/b/inst" "$(me)"; assert_rc 1; assert_out "$SB/a is writable by group or other users"
    chmod go-w "$SB/a"
  done
  probe_check "$SB/a/b/inst" "$(me)"; assert_rc 0                            # control again: everything restored
  # through the whole loader, as root (simulated) and sourced
  chmod g+w "$SB/a/b/inst/lib/menu.sh"
  probe_run "$SB/a/b/inst" 1 0 0 "$(me)"; assert_rc 2; assert_out "lib/menu.sh is writable by group or other users"
  probe_main "$SB/a/b/inst" "$(me)" "$(me)"; assert_rc 2; assert_out "lib/menu.sh is writable"
  chmod go-w "$SB/a/b/inst/lib/menu.sh"
  probe_main "$SB/a/b/inst" "$(me)" "$(me)"; assert_rc 0; assert_out "Oracle OPS Installer 0"
}

# The sticky-directory exception needs a root-owned sticky ancestor, which any temporary directory is (TMPDIR, /var/tmp, /tmp).
sticky_ancestor() {  # prints the nearest root-owned, other-writable, sticky ancestor of the sandbox
  local p="$SB" st
  while [ "$p" != "/" ]; do
    p="$(dirname "$p")"
    st="$(stat -c '%u %a' "$p")"
    case "$st" in "0 1"*[2367]) printf '%s' "$p"; return 0 ;; esac
  done
  return 1
}

test_integrity_sticky_ancestor_rule() {
  local sticky
  sticky="$(sticky_ancestor)" || fail "no root-owned sticky ancestor above $SB (run the tests with TMPDIR=/var/tmp or /tmp)"
  make_copy "$SB/inst"
  # the sandbox is a child of a sticky directory that root owns; its own next component belongs to the test account
  probe_check "$SB/inst" "$(me)"; assert_rc 0                                # sticky accepted: next component is owned by an accepted account
  probe_check "$SB/inst" "99999"                                             # the next component below $sticky is foreign to {root, 99999}
  assert_rc 1; assert_out "$sticky is a sticky directory writable by other users and its next path component"
  assert_out "is not owned by an administrative account"
  # a sticky directory that is NOT root-owned or whose rule does not apply stays subject to the ownership rule
  mkdir -p "$SB/s/inst2"; chmod 1777 "$SB/s"; make_copy "$SB/s/inst2"
  probe_check "$SB/s/inst2" "$(me)"; assert_rc 0                             # sticky, other-writable, next component accepted
  probe_check "$SB/s/inst2" "99999"; assert_rc 1                             # the first non-accepted node refuses
  chmod 0777 "$SB/s"                                                         # writable and NOT sticky
  probe_check "$SB/s/inst2" "$(me)"; assert_rc 1; assert_out "$SB/s is writable by group or other users"
}

test_integrity_owner_must_be_the_administrative_account() {
  make_copy "$SB/inst"
  probe_check "$SB/inst" "$(me)"; assert_rc 0                                # control
  # the loader's administrative uid is not this account: the root-owned "/" is the first node refused
  ( . "$REPO_ROOT/$ENTRY_BASENAME"; LOADER_ADMIN_UID=99999; ldr_check_secure "$SB/inst" "$SB/inst/$ENTRY_BASENAME" "" ) > "$SB/out" 2>&1; RC=$?
  assert_rc 1; assert_out "/ is not owned by an administrative account (owner uid 0)"
  # a tree owned by this account is refused when only root is accepted (the executed-as-root rule)
  probe_run "$SB/inst" 1 0 0 ""; assert_rc 2; assert_out "ldr_run-status=2"; assert_out "administrative account"
  probe_run "$SB/inst" 1 0 0 "$(me)"; assert_rc 0; assert_out "ldr_run-status=0"
  # sourced: main() checks against the reassigned ADMIN_UID and refuses before it creates anything
  EXTRA=""
  probe_main "$REPO_ROOT" 99999 ""; assert_rc 2; assert_out "administrative account"; assert_not_out "Oracle OPS Installer 0"
  probe_main "$REPO_ROOT" "$(me)" ""; assert_rc 0; assert_out "Oracle OPS Installer 0"
  probe_main "$REPO_ROOT" 99999 "$(me)"; assert_rc 0                          # the seam the harness uses (existing test with ADMIN_UID=99999)
  assert_absent "$SB/var/log/oracle-ops-installer"; assert_absent "$SB/var/lib/oracle-ops-installer"
}

test_integrity_unlisted_file_is_never_sourced() {
  make_copy "$SB/inst"
  printf 'touch %q\nunlisted_defined() { :; }\n' "$SB/unlisted-marker" > "$SB/inst/lib/zz-extra.sh"
  printf 'touch %q\n' "$SB/lowercase-marker" > "$SB/inst/lib/env.sh.orig"
  probe_source "$SB/inst"; assert_out "load-status=0"; assert_absent "$SB/unlisted-marker"; assert_absent "$SB/lowercase-marker"
  probe_exec "$SB/inst" --version; assert_rc 0; assert_absent "$SB/unlisted-marker"
  ( . "$SB/inst/$ENTRY_BASENAME"; declare -F unlisted_defined > /dev/null && echo defined || echo undefined ) > "$SB/out" 2>&1
  assert_out "undefined"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --check --root "$SB/inst" > "$SB/out" 2>&1; RC=$?
  assert_rc 1; assert_out "UNLISTED library file(s) (never sourced): lib/zz-extra.sh"        # the build tooling flags it
}

test_integrity_stale_digest_block_is_detected() {
  make_copy "$SB/inst"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --check --root "$SB/inst" > "$SB/out" 2>&1; RC=$?; assert_rc 0
  printf '\n# edited\n' >> "$SB/inst/lib/state.sh"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --check --root "$SB/inst" > "$SB/out" 2>&1; RC=$?
  assert_rc 1; assert_out "STALE"
  local before; before="$(sha256sum < "$SB/inst/$ENTRY_BASENAME")"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --check --root "$SB/inst" > /dev/null 2>&1                    # --check changes nothing
  [ "$(sha256sum < "$SB/inst/$ENTRY_BASENAME")" = "$before" ] || fail "--check modified the entry script"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --root "$SB/inst" > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_out "library manifest updated"
  bash "$REPO_ROOT/tests/update-lib-digests.sh" --check --root "$SB/inst" > "$SB/out" 2>&1; RC=$?; assert_rc 0
  [ -x "$SB/inst/$ENTRY_BASENAME" ] || fail "regeneration changed the mode of the entry script"
  bash -n "$SB/inst/$ENTRY_BASENAME" || fail "regeneration broke the entry script"
}

test_integrity_library_that_creates_a_file_at_load_time_is_refused_before_it_runs() {
  make_copy "$SB/inst"
  printf '\ntouch %q\n' "$SB/marker" >> "$SB/inst/lib/ops-credentials.sh"                  # the LAST library
  probe_source "$SB/inst"; assert_out "load-status=2"; assert_out "state-dir=unset"; assert_absent "$SB/marker"
  probe_exec "$SB/inst" --version; assert_rc 2; assert_absent "$SB/marker"
  probe_run "$SB/inst" 1 0 0 "$(me)"; assert_rc 2; assert_absent "$SB/marker"
  # the marker mechanism itself works: once the digest is regenerated the library is accepted and runs
  regen_digests "$SB/inst"
  probe_exec "$SB/inst" --version; assert_rc 0; assert_exists "$SB/marker"
}

test_integrity_empty_bash_source_is_refused() {
  make_copy "$SB/inst"
  printf 'touch %q\n' "$SB/marker" > "$SB/inst/lib/zz-extra.sh"
  bash < "$SB/inst/$ENTRY_BASENAME" > "$SB/out" 2>&1; RC=$?                                  # script read from standard input
  assert_rc 2; assert_out "the script name is empty"
  bash -c "$(cat "$SB/inst/$ENTRY_BASENAME")" > "$SB/out" 2>&1; RC=$?                          # script passed as a string
  assert_rc 2; assert_out "the script name is empty"
  ( . "$REPO_ROOT/$ENTRY_BASENAME"; ldr_run "" 0 "$(me)" ) > "$SB/out" 2>&1; RC=$?
  assert_rc 2; assert_out "the script name is empty"
  assert_absent "$SB/marker"
}

test_integrity_root_and_non_root_branches_of_the_loader() {
  make_copy "$SB/inst"
  chmod g+w "$SB/inst/lib/menu.sh"            # an unsafe mode: only the ownership step of a root run notices
  # executed as root (simulated: euid = the loader's administrative uid): the secure-path check runs first
  probe_run "$SB/inst" 1 0 0 "$(me)"; assert_rc 2; assert_out "is writable by group or other users"
  probe_run "$SB/inst" 1 0 0 ""; assert_rc 2; assert_out "administrative account"
  # executed as another user: only the ownership step is skipped, the digests are still verified
  probe_run "$SB/inst" 1 "$(me)" 0 ""; assert_rc 0; assert_out "ldr_run-status=0"
  probe_exec "$SB/inst" --version; assert_rc 0
  # sourced: no ownership check at load time (main() does that), even for uid 0 and with the unsafe mode in place
  probe_run "$SB/inst" 0 "$(me)" 0 ""; assert_rc 0
  probe_run "$SB/inst" 0 0 0 ""; assert_rc 0
  # ... but the digests are verified in every mode
  printf '\n# edited\n' >> "$SB/inst/lib/menu.sh"
  probe_run "$SB/inst" 1 "$(me)" 0 ""; assert_rc 2; assert_out "does not match"
  probe_run "$SB/inst" 0 "$(me)" 0 ""; assert_rc 2; assert_out "does not match"
}

test_integrity_the_loader_does_not_depend_on_path() {
  make_copy "$SB/inst"
  PATH=/nonexistent /bin/bash "$SB/inst/$ENTRY_BASENAME" --version > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_out "Oracle OPS Installer 0"
  mkdir "$SB/evilbin"
  for t in stat readlink sha256sum; do printf '#!/bin/bash\ntouch %q\nexec /usr/bin/%s "$@"\n' "$SB/path-hijack-$t" "$t" > "$SB/evilbin/$t"; chmod 0755 "$SB/evilbin/$t"; done
  PATH="$SB/evilbin:$PATH" bash "$SB/inst/$ENTRY_BASENAME" --version > "$SB/out" 2>&1; RC=$?
  assert_rc 0; assert_absent "$SB/path-hijack-stat"; assert_absent "$SB/path-hijack-readlink"; assert_absent "$SB/path-hijack-sha256sum"
}

test_integrity_seams_come_from_env_and_test_overrides_win() {
  grep -q '^is_root() ' "$REPO_ROOT/lib/env.sh" || fail "seam is_root is not in lib/env.sh"
  local s
  for s in is_root stdin_is_tty host_arch is_tmpfs service_active root_home service_state proc_owner_exe run_as_repo_owner; do
    grep -q "^$s() " "$REPO_ROOT/lib/env.sh" || fail "seam $s is not defined in lib/env.sh"
    grep -l "^$s() " "$REPO_ROOT"/lib/*.sh "$REPO_ROOT/$ENTRY_BASENAME" | grep -qv 'lib/env.sh' && fail "seam $s is defined outside lib/env.sh"
  done
  # definitions made after sourcing win over the library's, and the library's code then uses the override
  ( . "$REPO_ROOT/$ENTRY_BASENAME"
    host_arch() { echo riscv; }
    service_active() { return 0; }
    [ "$(host_arch)" = riscv ] && service_active && echo "override-wins" ) > "$SB/out" 2>&1
  assert_out "override-wins"
  ( . "$REPO_ROOT/$ENTRY_BASENAME"
    host_arch() { echo riscv; }
    scan_prerequisites; echo "unfixable=${UNFIXABLE//$'\n'/ }" ) > "$SB/out" 2>&1
  assert_out "processor architecture riscv is not supported"
}

# Top-level statements of a library: blank, comment, function definition, or plain assignments without any substitution.
toplevel_violations() {   # toplevel_violations <file>: prints each offending line
  awk '
    BEGIN {
      assign = "[A-Za-z_][A-Za-z0-9_]*=(\"[^\"]*\"|\x27[^\x27]*\x27|[^ ;\"\x27`$()|&<>]*)"
      okline = "^" assign "(;[ ]*" assign ")*;?[ \t]*(#.*)?$"
    }
    infn { if ($0 == "}") infn = 0; next }
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\) \{/ { if ($0 !~ /\(\) \{ .*\}[ \t]*$/) infn = 1; next }
    { code = $0; sub(/[ \t]+#.*$/, "", code) }
    code ~ /\$\(|`|<\(|>\(/ { print FILENAME ":" NR ": substitution at top level: " $0; next }
    $0 ~ okline { next }
    { print FILENAME ":" NR ": " $0 }
  ' "$1"
}

test_integrity_libraries_contain_no_top_level_commands() {
  local f v
  for f in "$REPO_ROOT"/lib/*.sh; do
    v="$(toplevel_violations "$f")"
    [ -z "$v" ] || fail "top-level code in a library: $v"
  done
  # the checker itself: each of these must be reported
  printf 'touch /x\n' > "$SB/bad1.sh"
  printf 'X=$(date)\n' > "$SB/bad2.sh"
  printf 'X=`date`\n' > "$SB/bad3.sh"
  printf 'A=1; touch /x\n' > "$SB/bad4.sh"
  printf 'f() {\n  :\n}\nsource /x\n' > "$SB/bad5.sh"
  printf 'X="a $(date) b"\n' > "$SB/bad6.sh"
  printf 'f() { :; }\nreadonly X=1\n' > "$SB/bad7.sh"
  printf 'if true; then X=1; fi\n' > "$SB/bad8.sh"
  for f in 1 2 3 4 5 6 7 8; do
    [ -n "$(toplevel_violations "$SB/bad$f.sh")" ] || fail "the static check did not report $SB/bad$f.sh: $(cat "$SB/bad$f.sh")"
  done
  printf '# c\nA=1; B="x y"   # note; with $(text)\nf() { :; }\ng() {\n  X=$(date)\n}\nC=\n' > "$SB/good.sh"
  [ -z "$(toplevel_violations "$SB/good.sh")" ] || fail "the static check rejected a clean library: $(toplevel_violations "$SB/good.sh")"
}

# ---- runner ----------------------------------------------------------------------------------------------------------------

. "$(dirname "${BASH_SOURCE[0]}")/check-tests.sh"   # status, validate, the strict start-up, the security boundary, the static guard

# wanted <test name> <selectors...>: no selector selects everything; a selector is a test name, or a prefix ending in "_"
wanted() {
  local t="$1" s
  shift
  [ $# -gt 0 ] || return 0
  for s in "$@"; do
    if [ "$s" = "$t" ]; then return 0; fi
    case "$s" in *_) case "$t" in "$s"*) return 0 ;; esac ;; esac
  done
  return 1
}

main_tests() {
  local t rc passed=0 failed=0 names=""
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/oracle-ops-installer-tests.XXXXXX")"
  make_fixture || { echo "cannot create the fixture repository"; exit 1; }
  for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    wanted "$t" "$@" || continue
    ( CURRENT_TEST="$t"; new_sandbox; "$t" ) > "$TEST_ROOT/$t.out" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then passed=$((passed + 1)); printf 'PASS %s\n' "$t"
    else failed=$((failed + 1)); names="$names $t"; printf 'FAIL %s\n' "$t"; sed 's/^/    /' "$TEST_ROOT/$t.out" | tail -n 80; fi
  done
  echo
  printf 'installer tests: %d passed, %d failed\n' "$passed" "$failed"
  [ "$failed" = 0 ] && rm -rf -- "$TEST_ROOT"
  [ "$failed" = 0 ] || { echo "failed:$names"; echo "artifacts: $TEST_ROOT"; exit 1; }
}

main_tests "$@"
