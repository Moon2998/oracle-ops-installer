#!/bin/bash
# Test library for the Oracle OPS Installer: sandbox, fixture repository, test doubles, assertions.
# Hermetic: no root, no network, no real Oracle OPS repository, nothing outside the sandbox is changed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# INSTALLER_UNDER_TEST lets tests/compare-command-sequences.sh run the same tests against the vendored baseline installer.
INSTALLER="${INSTALLER_UNDER_TEST:-$REPO_ROOT/oracle-ops-installer.sh}"
# The menu number of "Exit": 10 in this release (0.3.0). tests/compare-command-sequences.sh (retired with 0.3.0) set 5 / 7.
MENU_EXIT="${MENU_EXIT:-10}"
# Fresh Installation answers after the installation directory: service user, group (default: the user's primary group),
# REST API bind address (default 127.0.0.1), port, and the "yes" of the review screen.
TEST_API_PORT=18888
TEST_OWNER_PW='Owner-Pw_0123456789-secret'
# service user, group (default), database host, port (default 1521), service name, API bind (default 127.0.0.1), API port,
# the review "yes", and "2" = the DBA has already created the schema
ANS=("$(id -un)" "" dbhost.example "" OPSPDB "" "$TEST_API_PORT" yes 2)
# after the access token: the OPS_OWNER password, "yes" to create the objects, "yes" for the setup assistant, Enter after the keys
POST=("$TEST_OWNER_PW" yes yes "")
# Record mode (COMPARE_MODE=1, set only by tests/compare-command-sequences.sh): fail() records the assertion instead of
# exiting, and every run_installer call dumps what it did into $COMPARE_OUT/<test>/run<N>/ (see compare_record below).
COMPARE_MODE="${COMPARE_MODE:-0}"
COMPARE_OUT="${COMPARE_OUT:-}"
CURRENT_TEST=""
COMPARE_RUN=0
COMPARE_LOGNAMES=""
COMPARE_LOGS_BEFORE=""
REAL_GIT="$(command -v git)"
TEST_ROOT=""
FIXTURE=""
FIX_COMMIT=""        # the commit the tests pin (service/VERSION 0.1.5)
FIX_LATER_COMMIT=""  # a later commit on the default branch (service/VERSION 0.1.6) that must never be installed
FIX_VERSION="0.1.5"
FIX_DB_SCRIPTS=()
DB_FIXTURE_FILES="db/migrations/V4_001__create_ops_run.sql db/migrations/V4_002__create_ops_run_api.sql db/migrations/V5_001__add_ops_run_get_run.sql docs/12-ddl/V8_001__create_ops_wls_action.sql docs/12-ddl/V8_001__ops_wls_action_api_body.sql"
TEST_TOKEN="ghp_TESTtoken0123456789abcdefABCDEF012345"
OPS_URL="https://github.com/Moon2998/oracle-ops.git"
SB=""
RC=""

fail() { if [ "$COMPARE_MODE" = 1 ]; then compare_note_failure "$*"; return 0; fi; printf 'ASSERTION FAILED: %s\n' "$*"; [ -z "$SB" ] || { echo "--- installer output ---"; cat "$SB/out" 2>/dev/null; echo "--- log ---"; cat "$SB"/var/log/oracle-ops-installer/*.log 2>/dev/null | tail -n 60; }; exit 1; }
assert_rc() { [ "$RC" = "$1" ] || fail "exit status $RC, expected $1"; }
assert_out() { grep -qF -- "$1" "$SB/out" || fail "output does not contain: $1"; }
assert_not_out() { ! grep -qF -- "$1" "$SB/out" || fail "output contains: $1"; }
assert_log() { cat "$SB"/var/log/oracle-ops-installer/oracle-ops-installer-*.log | grep -qF -- "$1" || fail "log does not contain: $1"; }
assert_trace() { grep -qF -- "$1" "$SB/roothome/trace" 2>/dev/null || fail "OPS trace does not contain: $1"; }
assert_no_trace() { [ ! -s "$SB/roothome/trace" ] || fail "an Oracle OPS script was run: $(head -n 1 "$SB/roothome/trace")"; }
assert_exists() { [ -e "$1" ] || [ -L "$1" ] || fail "missing: $1"; }
assert_absent() { [ ! -e "$1" ] && [ ! -L "$1" ] || fail "should not exist: $1"; }

# No staging, token or helper material may remain: the state directory holds only the lock file, /run nothing of ours.
assert_clean() {
  local left
  left="$(find "$SB/var/lib/oracle-ops-installer" -mindepth 1 -maxdepth 1 ! -name .lock -printf '%f\n' 2>/dev/null)"
  [ -z "$left" ] || fail "staging material left behind: $left"
  left="$(find "$SB/run" -mindepth 1 -maxdepth 1 -name 'oracle-ops-installer.*' 2>/dev/null)"
  [ -z "$left" ] || fail "token directory left behind: $left"
}

# The token must not appear in the terminal output, the logs, the staging area, /run, the homes, /etc or the traces.
assert_no_token() {
  local hits
  hits="$(grep -rlF -- "$TEST_TOKEN" "$SB/out" "$SB/var" "$SB/run" "$SB/u01" "$SB/etc" "$SB/roothome/trace" "$SB/git-trace" 2>/dev/null)"
  [ -z "$hits" ] || fail "the token was found in: $hits"
}

assert_log_protected() {
  local f
  [ "$(stat -c %a "$SB/var/log/oracle-ops-installer")" = 700 ] || fail "log directory mode is not 700"
  for f in "$SB"/var/log/oracle-ops-installer/oracle-ops-installer-*.log; do
    [ "$(stat -c %a "$f")" = 600 ] || fail "log file $f mode is not 600"
  done
  [ "$(stat -c %a "$SB/var/lib/oracle-ops-installer")" = 700 ] || fail "state directory mode is not 700"
}

input() { printf '%s\n' "$@" > "$SB/in"; }

# ---------------------------------------------------------------------------------------------------------------------------
# The fixture "private repository": two commits; deployment scripts are test doubles that record what they receive.
# ---------------------------------------------------------------------------------------------------------------------------

write_stub_library() {
  cat > "$1/deploy/scripts/_stub.sh" <<'STUB'
# Test double support for the Oracle OPS deployment scripts (fixture only — not Oracle OPS code).
set -u
. "$HOME/stub.conf"
NAME="$(basename "$0")"
SRC_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
record() { printf '%s\n' "$*" >> "$HOME/trace"; }
n=0
for f in "$AUTH_BASE"/oracle-ops-installer.* "$STATE_DIR"/run.*/auth "$STATE_DIR"/run.*/auth/token; do
  if [ -e "$f" ]; then n=$((n + 1)); fi
done
record "$NAME args=$*"
record "$NAME authdirs=$n"
if env | grep -qF "$TEST_TOKEN"; then record "$NAME tokenenv=1"; else record "$NAME tokenenv=0"; fi
if grep -rqsF "$TEST_TOKEN" "$STATE_DIR" "$AUTH_BASE"; then record "$NAME tokenfiles=1"; else record "$NAME tokenfiles=0"; fi
record "$NAME umask=$(umask) tmpdir=${TMPDIR-unset} lc_all=${LC_ALL-unset} head=$(cd "$SRC_ROOT" && git rev-parse HEAD)"
record "$NAME envnames=$(env | cut -d= -f1 | sort | tr '\n' ' ')"
make_release() {  # <home> <version> <commit>
  mkdir -p "$1/releases/$2" "$1/config" "$1/logs" "$1/evidence" "$1/runtime"
  printf '%s\n' "$2" > "$1/releases/$2/VERSION"
  python3 -I - "$1/releases/$2/oracle-ops.jar" "$2" "$3" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('com/oracleops/core/version.properties',
           'version=%s\nbuild.timestamp=2026-10-26T00:00:00Z\nbuild.gitCommit=%s\n' % (sys.argv[2], sys.argv[3]))
z.close()
PY
}
activate() {  # <home> <version>
  ln -sfn "$1/releases/$2" "$1/current"
  echo active > "$SYSTEMCTL_STATE"
  echo "2026-10-26 10:00:00.000 INFO Database connectivity startup health check: ${HEALTH:-HEALTHY} (1ms)" >> "$1/logs/oracle-ops.log"
  [ "${ROUTES_MODE:-ok}" = none ] || echo "2026-10-26 10:00:00.100 INFO [com.oracleops.core.OracleOpsService] API routes served: [/api/v1/about, /api/v1/ops/status, /api/v1/linux/host, /api/v1/node/identity]" >> "$1/logs/oracle-ops.log"
}
write_unit() {  # <home>
  mkdir -p "$(dirname "$UNIT_FILE")"
  printf '[Service]\nUser=%s\nGroup=%s\nEnvironment=ORACLE_OPS_HOME=%s\n' "$TEST_USER" "$TEST_GROUP" "$1" > "$UNIT_FILE"
}
short_commit() { (cd "$SRC_ROOT" && git rev-parse --short HEAD); }
src_version() { head -n 1 "$SRC_ROOT/service/VERSION"; }
STUB

  cat > "$1/deploy/scripts/deploy-oracle-ops.sh" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/_stub.sh"
home=""; bind=""; port=""
while [ $# -gt 0 ]; do case "$1" in --home) home="$2"; shift 2 ;; --api-bind-address) bind="$2"; shift 2 ;; --api-port) port="$2"; shift 2 ;; --java-archive) shift 2 ;; *) shift ;; esac; done
echo "== Oracle OPS guided deployment (test double) =="
case "${DEPLOY_MODE:-ok}" in
  fail) echo "deploy-oracle-ops: ERROR: the database validation failed; nothing was deployed" >&2; exit 1 ;;
  selfkill) kill -TERM "$(awk '{ print $2 }' "$STATE_DIR"/run.*/.oracle-ops-installer-run | head -n 1)"; sleep 1; exit 1 ;;
esac
printf 'Type "yes" to apply these changes: '
IFS= read -r a || exit 1
[ "$a" = yes ] || { echo "not confirmed — nothing was changed"; exit 1; }
c="$(short_commit)"
[ "${DEPLOY_MODE:-ok}" != wrongcommit ] || c=deadbee
make_release "$home" "$(src_version)" "$c"
printf 'ops:\n  node: n1\napi:\n  enabled: true\n  bind-address: "%s"\n  port: %s\n  admission:\n    queue-capacity: 20\nebs:\n  enabled: false\n' "$bind" "$port" > "$home/config/application.yaml"
write_unit "$home"
[ "${DEPLOY_MODE:-ok}" = nocurrent ] || activate "$home" "$(src_version)"
echo "  [PASS] health"
STUB

  cat > "$1/deploy/scripts/install-release.sh" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/_stub.sh"
pre=0; home=""
while [ $# -gt 0 ]; do case "$1" in --preflight) pre=1; shift ;; --home) home="$2"; shift 2 ;; --user|--group|--java-archive) shift 2 ;; *) shift ;; esac; done
if [ "$pre" = 1 ]; then
  if [ "${PREFLIGHT_MODE:-ok}" = ok ]; then echo "Preflight OK — nothing was changed."; exit 0; fi
  echo "install-release: ERROR: not enough free space" >&2; exit 7
fi
[ "${INSTALL_MODE:-ok}" != fail ] || { echo "Oracle OPS INSTALLATION FAILED during: build" >&2; exit 1; }
make_release "$home" "$(src_version)" "$(short_commit)"
[ "${INSTALL_MODE:-ok}" != unhealthy ] || HEALTH=UNHEALTHY
activate "$home" "$(src_version)"
echo "Oracle OPS $(src_version) installed and running."
STUB

  cat > "$1/deploy/scripts/activate-release.sh" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/_stub.sh"
home=""; rel=""
while [ $# -gt 0 ]; do case "$1" in --home) home="$2"; shift 2 ;; --release) rel="$2"; shift 2 ;; *) shift ;; esac; done
activate "$home" "$rel"
STUB

  cat > "$1/deploy/scripts/service-identity.sh" <<'STUB'
#!/bin/bash
if [ -f "$(dirname "$0")/_stub.sh" ]; then
  . "$(dirname "$0")/_stub.sh"
else   # run by "validate" from a copy that holds only the six manifest files: record standalone
  . "$HOME/stub.conf"
  NAME="$(basename "$0")"
  record() { printf '%s\n' "$*" >> "$HOME/trace"; }
  record "$NAME args=$*"; record "$NAME cwd=$PWD"
fi
sub="$1"; shift; home=""; apply=0
while [ $# -gt 0 ]; do case "$1" in --home) home="$2"; shift 2 ;; --apply) apply=1; shift ;; *) shift ;; esac; done
case "$sub" in
  check) if [ "${CHECK_MODE:-ok}" = ok ]; then echo COMPLIANT; else echo "1 deviation(s)"; exit 1; fi ;;
  retire)
    if [ "$apply" = 1 ]; then
      mv -T -- "$home" "$home.retired-$(date -u +%Y%m%dT%H%M%SZ)"; rm -f -- "$UNIT_FILE"; echo inactive > "$SYSTEMCTL_STATE"; echo Retired.
    else echo "Dry run complete."; fi ;;
esac
STUB

  cat > "$1/deploy/scripts/manage-app-credentials.sh" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/_stub.sh"
case "${CRED_MODE:-ok}" in decline) echo "The existing file was kept."; exit 3 ;; fail) echo "ERROR" >&2; exit 1 ;; esac
printf 'WebLogic user name: '; IFS= read -r u || exit 1
printf 'Password (hidden): '; IFS= read -r p || exit 1
echo
( umask 077; printf 'weblogic.username=%s\nweblogic.password=%s\n' "$u" "$p" > "$CRED_DIR/.staged" )
mode=0400; [ "${CRED_MODE:-ok}" != badperm ] || mode=0644
chmod "$mode" "$CRED_DIR/.staged"; mv -f -- "$CRED_DIR/.staged" "$CRED_DIR/apps.credentials"
echo "Stored and verified."
STUB
  cat > "$1/deploy/scripts/config-migrate.sh" <<'STUB'
#!/bin/bash
# Stand-in for deploy/scripts/config-migrate.sh (fixture only): records what it is called with and where, then succeeds or fails.
. "$HOME/stub.conf"
NAME="$(basename "$0")"
printf '%s\n' "$NAME args=$*" "$NAME cwd=$PWD" "$NAME umask=$(umask) home=$HOME" >> "$HOME/trace"
echo "config-migrate (test double): $*"
case "${CONFIG_MIGRATE_MODE:-ok}" in
  fail) echo "config-migrate: ERROR: application.yaml is not valid (test double)" >&2; exit 21 ;;
esac
echo "configuration is valid"
STUB
  printf '# placeholder (fixture)\n' > "$1/deploy/scripts/ownership-lib.sh"
  cat > "$1/deploy/scripts/provision-java.sh" <<'STUB'
#!/bin/bash
. "$(dirname "$0")/_stub.sh"
home=""
while [ $# -gt 0 ]; do case "$1" in --home) home="$2"; shift 2 ;; --group|--archive) shift 2 ;; *) shift ;; esac; done
[ "${JDK_MODE:-ok}" != fail ] || { echo "provision-java: ERROR: checksum mismatch" >&2; exit 4; }
mkdir -p "$home/runtime/java/21.0.12.1/bin"
printf '#!/bin/sh\nexit 0\n' > "$home/runtime/java/21.0.12.1/bin/java"; chmod 0755 "$home/runtime/java/21.0.12.1/bin/java"
echo "Private JDK ready (test double)"
STUB
  chmod 0755 "$1"/deploy/scripts/*.sh
}

# The Oracle OPS file manifest (R1) of the fixture: SHA-256 of the six blobs at the pinned fixture commit, in the entry script's format.
FIX_MANIFEST=()
MANIFEST_PATHS="deploy/scripts/config-migrate.sh deploy/scripts/service-identity.sh deploy/scripts/ownership-lib.sh deploy/scripts/provision-java.sh deploy/java-runtime.properties service/VERSION"
fixture_manifest() {   # fixture_manifest <repository> <commit>
  local p
  FIX_MANIFEST=()
  for p in $MANIFEST_PATHS; do
    FIX_MANIFEST+=("$("$REAL_GIT" --git-dir="$1/.git" show "$2:$p" | sha256sum | cut -d' ' -f1)  $p")
  done
}

make_fixture() {
  local d="$TEST_ROOT/fixture"
  mkdir -p "$d/service" "$d/deploy/scripts" "$TEST_ROOT/fixhome"
  printf '%s\n' "$FIX_VERSION" > "$d/service/VERSION"
  mkdir -p "$d/service/vendor" "$d/db/migrations" "$d/docs/12-ddl"
  printf 'fake jdbc driver\n' > "$d/service/vendor/ojdbc8-19.27.0.0.jar"
  printf '#!/bin/bash\necho "fixture build"\nOJDBC8_JAR="vendor/ojdbc8-19.27.0.0.jar"\nOJDBC8_SHA256="%s"\n' \
    "$(sha256sum < "$d/service/vendor/ojdbc8-19.27.0.0.jar" | cut -d' ' -f1)" > "$d/service/build.sh"
  local f
  for f in $DB_FIXTURE_FILES; do printf -- '-- fixture %s\nselect 1 from dual;\n' "$f" > "$d/$f"; done
  printf 'jdk.version=21.0.12.1\njdk.platforms=ol:7\n' > "$d/deploy/java-runtime.properties"
  write_stub_library "$d"
  ( cd "$d" && export HOME="$TEST_ROOT/fixhome" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    "$REAL_GIT" init -q . && "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m "fixture release 0.1.5" ) || return 1
  FIX_COMMIT="$(cd "$d" && "$REAL_GIT" rev-parse HEAD)"
  fixture_manifest "$d" "$FIX_COMMIT"
  FIX_DB_SCRIPTS=(
    "$(sha256sum < "$d/db/migrations/V4_001__create_ops_run.sql" | cut -d' ' -f1)  run  db/migrations/V4_001__create_ops_run.sql"
    "$(sha256sum < "$d/db/migrations/V4_002__create_ops_run_api.sql" | cut -d' ' -f1)  run  db/migrations/V4_002__create_ops_run_api.sql"
    "-  grant  ops_run_api"
    "$(sha256sum < "$d/db/migrations/V5_001__add_ops_run_get_run.sql" | cut -d' ' -f1)  run  db/migrations/V5_001__add_ops_run_get_run.sql"
    "$(sha256sum < "$d/docs/12-ddl/V8_001__create_ops_wls_action.sql" | cut -d' ' -f1)  run  docs/12-ddl/V8_001__create_ops_wls_action.sql"
    "$(sha256sum < "$d/docs/12-ddl/V8_001__ops_wls_action_api_body.sql" | cut -d' ' -f1)  include  docs/12-ddl/V8_001__ops_wls_action_api_body.sql"
  )
  printf '0.1.6\n' > "$d/service/VERSION"
  ( cd "$d" && export HOME="$TEST_ROOT/fixhome" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    "$REAL_GIT" commit -q -am "later work, not a pinned release" ) || return 1
  FIX_LATER_COMMIT="$(cd "$d" && "$REAL_GIT" rev-parse HEAD)"
  FIXTURE="$d"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Per-test sandbox: host directories, a curated PATH (so a missing tool can be simulated), test doubles for git,
# systemctl and yum.
# ---------------------------------------------------------------------------------------------------------------------------

link_tools() {  # link_tools <dir> <tool...>
  local d="$1" t p
  shift
  for t in "$@"; do
    p="$(PATH=/usr/bin:/bin:/usr/sbin:/sbin; command -v "$t" 2>/dev/null)" || continue
    ln -s "$p" "$d/$t"
  done
}

new_sandbox() {
  SB="$(mktemp -d "$TEST_ROOT/sb.XXXXXX")"
  chmod 0755 "$SB"
  mkdir -p "$SB/bin" "$SB/reserve" "$SB/var/lib" "$SB/var/log" "$SB/run/systemd/system" "$SB/etc/systemd/system" \
           "$SB/etc/logrotate.d" "$SB/u01" "$SB/roothome"
  chmod 0755 "$SB/run"
  printf 'NAME="Oracle Linux Server"\nVERSION="7.9"\nID="ol"\nVERSION_ID="7.9"\n' > "$SB/etc/os-release"
  link_tools "$SB/bin" bash sh cat ls ln mkdir rm rmdir mv cp install chmod chown chgrp stat readlink mktemp date sed awk \
    grep find sort head tail tr cut tee env getent id uname df timeout flock setpriv sha256sum cmp tar gzip unzip \
    python3 sleep kill touch wc dirname basename stty xargs od true false comm diff printf ip
  # git test double: authentication goes through the installer's real askpass helper and token file.
  cat > "$SB/reserve/git" <<EOF
#!/bin/bash
SB='$SB'; REAL='$REAL_GIT'; FIXTURE='$FIXTURE'; URL='$OPS_URL'
. "\$SB/git.conf"
args=("\$@"); i=0
while [ "\${args[\$i]:-}" = "-c" ]; do i=\$((i + 2)); done
sub="\${args[\$i]:-}"
case "\$sub" in
  ls-remote|clone) ;;
  *) { printf 'cwd=%s argv:' "\$PWD"; printf ' %s' "\$@"; printf '\n'; } >> "\$SB/git-local-trace"; exec "\$REAL" "\$@" ;;
esac
tok="\$(cat "\$SB/expected-token")"
{
  printf 'argv:'; printf ' %s' "\$@"; printf '\n'
  printf 'env HOME=%s GIT_ASKPASS=%s GIT_CONFIG_NOSYSTEM=%s\n' "\${HOME-}" "\${GIT_ASKPASS-}" "\${GIT_CONFIG_NOSYSTEM-}"
  printf 'envnames: %s\n' "\$(env | cut -d= -f1 | sort | tr '\n' ' ')"
  case "\$*" in *"\$tok"*) echo "token-in-argv" ;; esac
  if env | grep -qF "\$tok"; then echo "token-in-env"; fi
  printf 'askpass-mode=%s token-mode=%s\n' "\$(stat -c %a "\$GIT_ASKPASS")" "\$(stat -c %a "\$(dirname "\$GIT_ASKPASS")/token")"
} >> "\$SB/git-trace"
u="\$("\$GIT_ASKPASS" "Username for 'https://github.com': ")" || u=""
p="\$("\$GIT_ASKPASS" "Password for 'https://\${u}@github.com': ")" || p=""
if "\$GIT_ASKPASS" "Password for 'https://x-access-token@evil.example': " >/dev/null 2>&1; then echo askpass-answered-foreign >> "\$SB/git-trace"; fi
if "\$GIT_ASKPASS" "Username for 'https://evil.example': " >/dev/null 2>&1; then echo askpass-answered-foreign >> "\$SB/git-trace"; fi
if [ "\${AUTH:-ok}" = network ]; then echo "fatal: unable to access '\$URL/': Could not resolve host: github.com" >&2; exit 128; fi
if [ "\$u" != x-access-token ] || [ "\$p" != "\$tok" ]; then echo "fatal: Authentication failed for '\$URL/'" >&2; exit 128; fi
case "\${AUTH:-ok}" in
  denied) echo "remote: Repository not found." >&2; echo "fatal: repository '\$URL/' not found" >&2; exit 128 ;;
  leak) echo "debug: sent \$p to https://x-access-token:\$p@github.com" >&2 ;;
esac
new=(); for a in "\$@"; do [ "\$a" != "\$URL" ] || a="\$FIXTURE"; new+=("\$a"); done
if [ "\$sub" = clone ] && [ "\${CLONE:-ok}" = partial ]; then
  dest="\${new[\$((\${#new[@]} - 1))]}"; mkdir -p "\$dest/.git"; echo junk > "\$dest/partial"
  echo "fatal: early EOF" >&2; exit 128
fi
exec "\$REAL" "\${new[@]}"
EOF
  chmod 0755 "$SB/reserve/git"
  cp -p "$SB/reserve/git" "$SB/bin/git"
  link_tools "$SB/reserve" unzip
  printf 'AUTH=ok\nCLONE=ok\n' > "$SB/git.conf"
  printf '%s\n' "$TEST_TOKEN" > "$SB/expected-token"
  cat > "$SB/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> '$SB/systemctl-trace'
quiet=0; for a in "\$@"; do [ "\$a" != --quiet ] || quiet=1; done
case "\$1" in
  is-active)
    if [ "\$(cat '$SB/systemctl-state' 2>/dev/null)" = active ]; then [ "\$quiet" = 1 ] || echo active; exit 0; fi
    [ "\$quiet" = 1 ] || echo inactive; exit 3 ;;
  show)
    [ ! -e '$SB/systemctl-show-fail' ] || exit 1
    if [ -f '$SB/systemctl-show' ]; then cat '$SB/systemctl-show'; exit 0; fi
    if [ "\$(cat '$SB/systemctl-state' 2>/dev/null)" = active ]; then
      printf 'ActiveState=active\nSubState=running\nMainPID=%s\nActiveEnterTimestamp=Tue 2026-11-03 10:00:00 UTC\n' "\$(cat '$SB/mainpid' 2>/dev/null || echo 4242)"
    else
      printf 'ActiveState=inactive\nSubState=dead\nMainPID=0\nActiveEnterTimestamp=\n'
    fi ;;
  *) exit 0 ;;
esac
EOF
  cat > "$SB/bin/yum" <<EOF
#!/bin/bash
echo "yum \$*" >> '$SB/yum-trace'
case "\$(cat '$SB/yum-mode' 2>/dev/null)" in
  fail) echo "Error: Cannot retrieve repository metadata (repomd.xml)"; exit 1 ;;
  noop) exit 0 ;;
esac
for p in "\$@"; do [ ! -e '$SB/reserve/'"\$p" ] || cp -P '$SB/reserve/'"\$p" '$SB/bin/'"\$p"; done
EOF
  chmod 0755 "$SB/bin/systemctl" "$SB/bin/yum"
  # Forbidden-tool sentinels: the installer must never call these. Each call is recorded and fails. (curl too: the
  # prerequisite check only tests that it exists, `command -v curl`, so a sentinel satisfies it exactly as the real tool did.)
  local ft
  for ft in sqlplus sql java curl wget nc ssh scp rsync journalctl logrotate; do
    cat > "$SB/bin/$ft" <<EOF
#!/bin/bash
echo "$ft \$*" >> '$SB/forbidden-trace'
exit 1
EOF
    chmod 0755 "$SB/bin/$ft"
  done
  cat > "$SB/fake-dbtool" <<EOF
#!/bin/bash
# Test double of the database tool: records its arguments and what it got on stdin (never the value), answers from dbtool.conf.
. '$SB/dbtool.conf'
IFS= read -r pw || pw=""
mode="\$1"
{ printf 'args=%s\n' "\$*"
  if [ "\$pw" = '$TEST_OWNER_PW' ]; then echo "pw=expected"; else echo "pw=other"; fi
  if env | grep -qF -- '$TEST_OWNER_PW'; then echo "pwenv=1"; fi
  case "\$*" in *'$TEST_OWNER_PW'*) echo "pwargv=1" ;; esac
  printf 'cwd=%s files=%s\n' "\$PWD" "\$(ls | tr '\n' ' ')"
} >> '$SB/dbtool-trace'
n=\$(cat '$SB/dbtool-calls' 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > '$SB/dbtool-calls'
case "\$LOGIN" in
  wrong) echo "ERROR login as OPS_OWNER failed: ORA-01017: invalid username/password"; exit 3 ;;
  wrong-once) if [ "\$n" = 1 ]; then echo "ERROR login as OPS_OWNER failed: ORA-01017"; exit 3; fi ;;
  locked) echo "ERROR login as OPS_OWNER failed: ORA-28000: the account is locked"; exit 4 ;;
  down) echo "ERROR login as OPS_OWNER failed: IO Error: The Network Adapter could not establish the connection"; exit 5 ;;
esac
echo "RESULT session-user PASS connected as OPS_OWNER"
if [ "\$PREREQ" = fail ]; then echo "RESULT dictionary-views FAIL not readable (the DBA SQL grants SELECT on them): DBA_USERS"; echo "STATE EMPTY objects=0/6"; exit 1; fi
echo "RESULT dictionary-views PASS 10 DBA_ views readable"
if [ "\$mode" = check ]; then echo "STATE \$STATE objects=x"; exit 0; fi
echo "RUN V4_001__create_ops_run.sql"
if [ "\$DEPLOY" = fail ]; then echo "ERROR ORA-00942: table or view does not exist"; exit 1; fi
echo "STATE COMPLETE objects=6/6 valid=6 grants=2/2"
EOF
  chmod 0755 "$SB/fake-dbtool"
  printf 'LOGIN=ok\nSTATE=EMPTY\nPREREQ=ok\nDEPLOY=ok\n' > "$SB/dbtool.conf"
  {
    printf 'AUTH_BASE=%q\nSTATE_DIR=%q\nUNIT_FILE=%q\nCRED_DIR=%q\n' "$SB/run" "$SB/var/lib/oracle-ops-installer" \
      "$SB/etc/systemd/system/oracle-ops.service" "$SB/etc/oracle-ops"
    printf 'SYSTEMCTL_STATE=%q\nTEST_TOKEN=%q\nTEST_USER=%q\nTEST_GROUP=%q\n' "$SB/systemctl-state" "$TEST_TOKEN" "$(id -un)" "$(id -gn)"
  } > "$SB/roothome/stub.conf"
  : > "$SB/in"
  TEST_TMPFS=0
  EXTRA=""
  COMPARE_RUN=0
  COMPARE_LOGNAMES=""
  }

stub_mode() { printf '%s=%s\n' "$1" "$2" >> "$SB/roothome/stub.conf"; }
git_mode() { printf '%s=%s\n' "$1" "$2" >> "$SB/git.conf"; }

# run_installer [arguments...]: sources the installer, points every host location into the sandbox, applies $EXTRA
# (per-test overrides), and runs main with stdin from $SB/in.
run_installer() {
  [ "$COMPARE_MODE" != 1 ] || COMPARE_LOGS_BEFORE="$(ls "$SB/var/log/oracle-ops-installer" 2>/dev/null)"
  (
    cd "$SB" || exit 99
    # shellcheck source=../oracle-ops-installer.sh
    . "$INSTALLER" || exit $?
    LOADER_TEST_UID="$(id -u)"   # the split installer's sourced-mode ownership check accepts the test account (unused by the baseline)
    STATE_DIR="$SB/var/lib/oracle-ops-installer"
    LOG_DIR="$SB/var/log/oracle-ops-installer"
    AUTH_BASE="$SB/run"
    CRED_DIR="$SB/etc/oracle-ops"
    UNIT_FILE="$SB/etc/systemd/system/oracle-ops.service"
    LOGROTATE_DIR="$SB/etc/logrotate.d"
    OS_RELEASE_FILE="$SB/etc/os-release"
    SYSTEMD_RUN_DIR="$SB/run/systemd/system"
    DEFAULT_HOME="$SB/u01/oracle_ops_runtime"
    SAFE_PATH="$SB/bin"
    ADMIN_UID="$(id -u)"
    HOME_FORBIDDEN="/ /etc /proc /sys /dev /run /boot /bin /sbin /lib /lib64 /usr $SB/var/lib/oracle-ops-installer $SB/etc/oracle-ops"
    OPS_COMMIT="$FIX_COMMIT"
    OPS_VERSION="$FIX_VERSION"
    OPS_FILE_MANIFEST=("${FIX_MANIFEST[@]}")
    proc_owner_exe() { [ -f "$SB/proc-owner-exe" ] || return 1; cat "$SB/proc-owner-exe"; }   # seam: the fake service process of the tests
    is_root() { return 0; }
    stdin_is_tty() { return 0; }
    root_home() { printf '%s' "$SB/roothome"; }
    is_tmpfs() { [ "$TEST_TMPFS" = 1 ]; }
    port_in_use() { [ -e "$SB/port-busy-$2" ]; }   # seam: no real connection from the tests
    tcp_open() { [ ! -e "$SB/db-down" ]; }
    local_addresses() { printf '127.0.0.1\n10.1.2.3\n'; }
    db_tool_exec() { shift; ( cd "$RUN_DIR/db" && "$SB/fake-dbtool" "$@" ); }   # seam: same working directory as the real tool
    OPS_DB_SCRIPTS=("${FIX_DB_SCRIPTS[@]}")
    restart_service() { echo "restart" >> "$SB/systemctl-trace"; echo "2026-11-11 10:00:00.000 INFO [x] API routes served: [/api/v1/about, /api/v1/ops/status]" >> "${INST_HOME:-$TARGET_HOME}/logs/oracle-ops.log"; }
    clear_screen() { echo "<CLEAR-SCREEN>"; }
    eval "$EXTRA"
    main "$@"
  ) < "$SB/in" > "$SB/out" 2>&1
  RC=$?
  [ "$COMPARE_MODE" != 1 ] || compare_record
}

# An existing installation of <version> built from <commit>, with its unit, configuration and database credential file.
existing_install() {  # existing_install <version> <commit> [active]
  local h="$SB/u01/oracle_ops_runtime"
  mkdir -p "$h/releases/$1" "$h/config" "$h/logs" "$h/evidence" "$h/runtime" "$SB/etc/oracle-ops"
  printf '%s\n' "$1" > "$h/releases/$1/VERSION"
  python3 -I - "$h/releases/$1/oracle-ops.jar" "$1" "$2" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], 'w')
z.writestr('com/oracleops/core/version.properties', 'version=%s\nbuild.gitCommit=%s\n' % (sys.argv[2], sys.argv[3]))
z.close()
PY
  ln -s "$h/releases/$1" "$h/current"
  : > "$h/config/application.yaml"
  printf 'db.username=OPS_RUNTIME\ndb.password=x\n' > "$SB/etc/oracle-ops/database.credentials"
  printf '[Service]\nUser=%s\nGroup=%s\nEnvironment=ORACLE_OPS_HOME=%s\n' "$(id -un)" "$(id -gn)" "$h" > "$SB/etc/systemd/system/oracle-ops.service"
  [ "${3:-active}" != active ] || echo active > "$SB/systemctl-state"
}

tree_digest() { (cd "$1" && find . -printf '%p %y %m %s\n' | sort | sha256sum); }

# ---------------------------------------------------------------------------------------------------------------------------
# Record mode (tests/compare-command-sequences.sh): what each run_installer call did, as plain files for later comparison.
# Raw values only; the comparison script normalises sandbox paths, random names and time stamps.
# ---------------------------------------------------------------------------------------------------------------------------

compare_note_failure() {
  mkdir -p "$COMPARE_OUT/$CURRENT_TEST"
  printf 'ASSERTION FAILED: %s\n' "$*" >> "$COMPARE_OUT/$CURRENT_TEST/assertions"
}

# One line per sandbox path: relative path, type, mode, size, link target. Directory sizes and the sizes of the installer's
# own logs (their content carries pids and times) are left out; a jar is represented by the content of its entries.
compare_tree() {
  local rel t m s l
  ( cd "$SB" && find . -mindepth 1 -printf '%P\t%y\t%m\t%s\t%l\n' ) | LC_ALL=C sort | while IFS=$'\t' read -r rel t m s l; do
    [ "$rel" != out ] || continue
    case "$t:$rel" in
      d:*) printf '%s d %s\n' "$rel" "$m" ;;
      f:*.jar) printf '%s f %s jar-content:%s\n' "$rel" "$m" "$(unzip -p "$SB/$rel" 2>/dev/null | tr '\n' '|')" ;;
      f:var/log/oracle-ops-installer/*) printf '%s f %s -\n' "$rel" "$m" ;;
      *) printf '%s %s %s %s %s\n' "$rel" "$t" "$m" "$s" "$l" ;;
    esac
  done
}

compare_record() {
  local d f n
  COMPARE_RUN=$((COMPARE_RUN + 1))
  d="$COMPARE_OUT/$CURRENT_TEST/run$COMPARE_RUN"
  mkdir -p "$d"
  printf '%s\n' "$RC" > "$d/rc"
  cp "$SB/out" "$d/out"
  for f in roothome/trace:roothome-trace git-trace:git-trace git-local-trace:git-local-trace yum-trace:yum-trace \
           systemctl-trace:systemctl-trace forbidden-trace:forbidden-trace; do
    if [ -e "$SB/${f%%:*}" ]; then cp "$SB/${f%%:*}" "$d/${f##*:}"; else echo "<absent>" > "$d/${f##*:}"; fi
  done
  # the log files this call created (all calls so far, in creation order), so their time-stamped names can be normalised
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$COMPARE_LOGS_BEFORE" | grep -qxF -- "$n" || COMPARE_LOGNAMES="$COMPARE_LOGNAMES$n"$'\n'
  done < <(ls "$SB/var/log/oracle-ops-installer" 2>/dev/null)
  {
    printf 'SB=%s\nTEST_ROOT=%s\nFIX_COMMIT=%s\nFIX_LATER_COMMIT=%s\n' "$SB" "$TEST_ROOT" "$FIX_COMMIT" "$FIX_LATER_COMMIT"
    printf '%s' "$COMPARE_LOGNAMES" | sed 's/^/LOG=/'
  } > "$d/meta"
  compare_tree > "$d/tree"
  compare_log_delta > "$d/logs"
}

# What this call added to the installer's logs: the lines appended to each log since the previous call, a new or rewritten log
# (two runs within one second share a name and the second truncates it) from its first line. Snapshots of the logs as the
# previous call left them are kept next to the records, outside the sandbox.
compare_log_delta() {
  local f n snap="$COMPARE_OUT/$CURRENT_TEST/.logsnap" old
  mkdir -p "$snap"
  for f in "$SB"/var/log/oracle-ops-installer/oracle-ops-installer-*.log; do
    [ -f "$f" ] || continue
    n="$(basename "$f")"
    if [ -f "$snap/$n" ]; then
      old="$(wc -l < "$snap/$n")"
      if [ "$(wc -l < "$f")" -ge "$old" ] && head -n "$old" "$f" | cmp -s - "$snap/$n"; then
        tail -n "+$((old + 1))" "$f"
      else
        cat "$f"
      fi
    else
      cat "$f"
    fi
  done
  rm -f "$snap"/*
  cp -p "$SB"/var/log/oracle-ops-installer/oracle-ops-installer-*.log "$snap/" 2>/dev/null || true
}
