#!/bin/bash
# Oracle OPS Installer library: action: update credentials
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

db_password_guidance() {
  say "      Oracle OPS reads its database password from $CRED_DIR/database.credentials."
  say "      No Oracle OPS tool replaces that file. To change the password:"
  say "        1. Have the DBA change the password of the Oracle OPS runtime account."
  say "        2. As root, edit $CRED_DIR/database.credentials and set the new db.password value"
  say "           (Java properties format: write a backslash as \\\\ and a space as '\\ ')."
  say "           Keep the file owned by root, group = the service group, mode 0640."
  say "        3. Restart Oracle OPS:  systemctl restart $UNIT_NAME"
  say "        4. Check for \"$DB_HEALTHY_LINE\" in <installation directory>/$SERVICE_LOG_REL."
  say "      Never put the password on a command line."
}

op_credentials() {
  local c rc=0 f st
  OPERATION="credential update"
  echo
  say "  Which credential?"
  say "    1) WebLogic administration account (stored for Oracle OPS)"
  say "    2) Database password of the Oracle OPS runtime account"
  say "    3) Cancel"
  choose c "  Choose 1, 2 or 3: " 1 2 3
  case "$c" in
    3) finish 5 "no credential was changed" ;;
    2) echo; db_password_guidance; SUCCESS_TEXT="No changes were made."; finish 0 ;;
  esac
  STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  require_installation
  if [ ! -d "$CRED_DIR" ] || [ -L "$CRED_DIR" ]; then finish 6 "the Oracle OPS credential directory $CRED_DIR does not exist"; fi
  stage 3 "Configuring source..."
  get_source
  stage 4 "Updating the WebLogic credential..."
  say "      The Oracle OPS credential manager now asks for the WebLogic user name and password"
  say "      (input hidden). Its messages are shown below and recorded in the log."
  say "------------------------------------------------------------------------------------------"
  run_interactive "manage-app-credentials.sh" ops_run manage-app-credentials.sh || rc=$?
  say "------------------------------------------------------------------------------------------"
  case "$rc" in
    0) ;;
    3) finish 5 "the existing WebLogic credential was kept" ;;
    *) finish 1 "the Oracle OPS credential manager did not complete (exit $rc)" ;;
  esac
  stage 5 "Finalizing..."
  f="$CRED_DIR/apps.credentials"
  st="$(stat -c '%a %u %g %h' "$f" 2>/dev/null)" || st=""
  if [ -L "$f" ] || [ ! -f "$f" ] || [ "$st" != "400 $(getent passwd "$INST_USER" | cut -d: -f3) $(getent group "$INST_GROUP" | cut -d: -f3) 1" ]; then
    finish 1 "the stored WebLogic credential file does not have the expected owner and permissions"
  fi
  log "credential file verified: $f mode 0400 owner $INST_USER:$INST_GROUP (content not read)"
  SUCCESS_TEXT="WebLogic credential updated successfully. (Oracle OPS was not restarted.)"
  finish 0
}
