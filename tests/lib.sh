#!/bin/bash
# Test library for the Oracle OPS Installer: sandbox, fixture repository, test doubles, assertions.
# Hermetic: no root, no network, no real Oracle OPS repository, nothing outside the sandbox is changed.

INSTALLER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/oracle-ops-installer.sh"
REAL_GIT="$(command -v git)"
TEST_ROOT=""
FIXTURE=""
FIX_COMMIT=""        # the commit the tests pin (service/VERSION 0.1.5)
FIX_LATER_COMMIT=""  # a later commit on the default branch (service/VERSION 0.1.6) that must never be installed
FIX_VERSION="0.1.5"
TEST_TOKEN="ghp_TESTtoken0123456789abcdefABCDEF012345"
OPS_URL="https://github.com/Moon2998/oracle-ops.git"
SB=""
RC=""

fail() { printf 'ASSERTION FAILED: %s\n' "$*"; [ -z "$SB" ] || { echo "--- installer output ---"; cat "$SB/out" 2>/dev/null; echo "--- log ---"; cat "$SB"/var/log/oracle-ops-installer/*.log 2>/dev/null | tail -n 60; }; exit 1; }
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
home=""
while [ $# -gt 0 ]; do case "$1" in --home) home="$2"; shift 2 ;; --java-archive) shift 2 ;; *) shift ;; esac; done
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
. "$(dirname "$0")/_stub.sh"
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
  printf '# placeholder (fixture)\n' > "$1/deploy/scripts/ownership-lib.sh"
  printf '# placeholder (fixture)\n' > "$1/deploy/scripts/provision-java.sh"
  chmod 0755 "$1"/deploy/scripts/*.sh
}

make_fixture() {
  local d="$TEST_ROOT/fixture"
  mkdir -p "$d/service" "$d/deploy/scripts" "$TEST_ROOT/fixhome"
  printf '%s\n' "$FIX_VERSION" > "$d/service/VERSION"
  printf '#!/bin/bash\necho "fixture build"\n' > "$d/service/build.sh"
  printf 'jdk.version=21.0.12.1\njdk.platforms=ol:7\n' > "$d/deploy/java-runtime.properties"
  write_stub_library "$d"
  ( cd "$d" && export HOME="$TEST_ROOT/fixhome" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
    "$REAL_GIT" init -q . && "$REAL_GIT" add -A && "$REAL_GIT" commit -q -m "fixture release 0.1.5" ) || return 1
  FIX_COMMIT="$(cd "$d" && "$REAL_GIT" rev-parse HEAD)"
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
    grep find sort head tail tr cut tee env getent id uname df timeout flock setpriv sha256sum cmp tar gzip curl unzip \
    python3 sleep kill touch wc dirname basename stty xargs od true false comm diff printf
  # git test double: authentication goes through the installer's real askpass helper and token file.
  cat > "$SB/reserve/git" <<EOF
#!/bin/bash
SB='$SB'; REAL='$REAL_GIT'; FIXTURE='$FIXTURE'; URL='$OPS_URL'
. "\$SB/git.conf"
args=("\$@"); i=0
while [ "\${args[\$i]:-}" = "-c" ]; do i=\$((i + 2)); done
sub="\${args[\$i]:-}"
case "\$sub" in ls-remote|clone) ;; *) exec "\$REAL" "\$@" ;; esac
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
case "\$1" in is-active) [ "\$(cat '$SB/systemctl-state' 2>/dev/null)" = active ] ;; *) exit 0 ;; esac
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
  {
    printf 'AUTH_BASE=%q\nSTATE_DIR=%q\nUNIT_FILE=%q\nCRED_DIR=%q\n' "$SB/run" "$SB/var/lib/oracle-ops-installer" \
      "$SB/etc/systemd/system/oracle-ops.service" "$SB/etc/oracle-ops"
    printf 'SYSTEMCTL_STATE=%q\nTEST_TOKEN=%q\nTEST_USER=%q\nTEST_GROUP=%q\n' "$SB/systemctl-state" "$TEST_TOKEN" "$(id -un)" "$(id -gn)"
  } > "$SB/roothome/stub.conf"
  : > "$SB/in"
  TEST_TMPFS=0
  EXTRA=""
}

stub_mode() { printf '%s=%s\n' "$1" "$2" >> "$SB/roothome/stub.conf"; }
git_mode() { printf '%s=%s\n' "$1" "$2" >> "$SB/git.conf"; }

# run_installer [arguments...]: sources the installer, points every host location into the sandbox, applies $EXTRA
# (per-test overrides), and runs main with stdin from $SB/in.
run_installer() {
  (
    cd "$SB" || exit 99
    # shellcheck source=../oracle-ops-installer.sh
    . "$INSTALLER"
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
    is_root() { return 0; }
    stdin_is_tty() { return 0; }
    root_home() { printf '%s' "$SB/roothome"; }
    is_tmpfs() { [ "$TEST_TMPFS" = 1 ]; }
    eval "$EXTRA"
    main "$@"
  ) < "$SB/in" > "$SB/out" 2>&1
  RC=$?
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
