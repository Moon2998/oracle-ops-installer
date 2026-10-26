#!/bin/bash
# OPTIONAL check that needs outbound HTTPS to github.com; not part of the hermetic suite.
# It proves, with the host's REAL git, that (1) git's credential prompts are the ones the installer's askpass helper
# answers, and (2) a rejected token is classified as such. It uses a deliberately INVALID token — never a real one —
# and needs no root. Nothing outside a temporary directory is created; that directory is removed at the end.
set -u
# shellcheck source=../oracle-ops-installer.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/oracle-ops-installer.sh"

SB="$(mktemp -d "${TMPDIR:-/tmp}/oracle-ops-installer-online.XXXXXX")"
trap 'rm -rf -- "$SB"' EXIT
RUN_DIR="$SB/run.ONLINE00"
mkdir -p "$RUN_DIR/githome"
printf '%s\n' "$MARKER_TEXT" > "$RUN_DIR/$MARKER_NAME"
LOG_FILE="$SB/online.log"
AUTH_BASE="$SB"
is_tmpfs() { return 1; }
TOKEN="ghp_INVALIDinvalidINVALIDinvalid00000000"
make_auth
# Record the prompts git sends (their wording only; the helper's answers are not recorded).
mv "$AUTH_DIR/askpass" "$AUTH_DIR/askpass.real"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> %s\nexec %s "$1"\n' "'$SB/prompts'" "'$AUTH_DIR/askpass.real'" > "$AUTH_DIR/askpass"
chmod 0700 "$AUTH_DIR/askpass"

rc=0
run_quiet "online: git ls-remote with an invalid token" git_net 60 ls-remote --heads "$OPS_REPO_URL" || rc=$?
reason="$(classify_git_failure "$rc")"
echo "git: $(git --version)"
echo "exit status: $rc"
echo "prompts git sent:"; sed 's/^/  /' "$SB/prompts" 2>/dev/null || echo "  (none)"
echo "classification: $reason"
if grep -qF "$TOKEN" "$LOG_FILE"; then echo "FAIL: the token reached the log"; exit 1; fi
destroy_auth
if [ "$rc" != 0 ] && [ "$reason" = "GitHub rejected the access token" ] \
   && grep -qxF "Username for '$GIT_HOST_URL': " "$SB/prompts" \
   && grep -qxF "Password for '$GIT_PASSWORD_URL': " "$SB/prompts"; then
  echo "online check: PASS"
else
  echo "online check: FAIL (see above)"; echo "--- log ---"; cat "$LOG_FILE"; exit 1
fi
