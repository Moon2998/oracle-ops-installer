#!/bin/bash
# Oracle OPS Installer library: action: install
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

# ---------------------------------------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------------------------------------

op_install() {
  local rc=0 state
  OPERATION="installation"; STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Configuring Oracle OPS..."
  if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
    describe_installation
    if [ -n "$INST_HOME" ] && pinned_release_running; then
      SUCCESS_TEXT="Oracle OPS $OPS_VERSION is already installed at $INST_HOME and running. Nothing was changed."
      finish 0
    fi
    finish 6 "Oracle OPS is already installed${INST_HOME:+ at $INST_HOME}${INST_RELEASE:+ (release $INST_RELEASE)}. Choose 'Upgrade Oracle OPS' to install release $OPS_VERSION, or 'De-install Oracle OPS' first"
  fi
  ask_home
  state="$(home_state "$TARGET_HOME")"
  log "installation directory state: $state"
  case "$state" in
    new) ;;
    partial)
      say "      $TARGET_HOME holds an incomplete Oracle OPS installation from an earlier run."
      confirm_yes "Complete that installation?" || finish 5 "the earlier installation was left as it is"
      ;;
    symlink) finish 6 "$TARGET_HOME is a symbolic link; choose the real directory" ;;
    *) finish 6 "$TARGET_HOME exists and is not an Oracle OPS installation directory; choose a new or empty directory" ;;
  esac
  stage 3 "Configuring source..."
  get_source
  stage 4 "Installing Oracle OPS..."
  say "      The Oracle OPS setup assistant now asks for the service account, the database connection"
  say "      and the optional features. Its messages are shown below and recorded in the log."
  say "------------------------------------------------------------------------------------------"
  run_interactive "deploy-oracle-ops.sh --home $TARGET_HOME" \
    ops_run deploy-oracle-ops.sh --home "$TARGET_HOME" ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} || rc=$?
  say "------------------------------------------------------------------------------------------"
  [ "$rc" = 0 ] || finish 1 "the Oracle OPS setup assistant did not complete (exit $rc)"
  stage 5 "Finalizing installation..."
  verify_installed "$TARGET_HOME" || finish 1 "the installation could not be verified: $VERIFY_PROBLEMS"
  SUCCESS_TEXT="Oracle OPS installation completed successfully.
Release $OPS_VERSION (commit ${OPS_COMMIT:0:7}) is running from $TARGET_HOME.
Oracle APEX is not part of this installer; install and configure it separately."
  finish 0
}
