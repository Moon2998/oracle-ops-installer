#!/usr/bin/env python3
"""The mutations tests/mutation-tests.sh injects, one at a time, into a COPY of the installer tree.

  mutations.py list                  one line per mutation: index, name
  mutations.py apply <root> <index>  apply mutation <index> to the copy at <root> (nothing else is touched)

Each mutation is a described, single change that the read-only checks must never contain. The harness regenerates the library
digests in the copy afterwards (so the loader accepts it), runs the status/validate/boundary/guard tests against the copy and
requires at least one of them to fail; it prints which ones did.
"""
import sys

STATUS = 'lib/ops-status.sh'
VALIDATE = 'lib/ops-validate.sh'
STARTUP = 'lib/check-startup.sh'

# (name, file, kind, anchor/old text, new text/inserted text, expected number of occurrences of the anchor)
MUTATIONS = [
    ('systemctl restart', STATUS, 'after', '  item_need systemctl || { item_finish ""; return 0; }\n', '  systemctl restart "$UNIT_NAME"\n', 1),
    ('systemctl stop', STATUS, 'after', '  item_need systemctl || { item_finish ""; return 0; }\n', '  systemctl stop "$UNIT_NAME"\n', 1),
    ('touch in the installation directory', STATUS, 'after', '  [ -z "$STATUS_HOME_MISMATCH" ] || item_fail "$STATUS_HOME_MISMATCH"\n',
     '  touch "$STATUS_HOME/.touched-by-status"\n', 1),
    ('chmod (same mode) on a credential file', STATUS, 'after', '  local spec name kind mode present="" absent="" p\n',
     '  chmod 0640 "$CRED_DIR/database.credentials"\n', 1),
    ('cat of a credential file', STATUS, 'after', '  local spec name kind mode present="" absent="" p\n',
     '  cat "$CRED_DIR/database.credentials"\n', 1),
    ('rm of a release', STATUS, 'after',
     '  if [ -z "$STATUS_HOME" ] || [ ! -d "$STATUS_HOME/releases" ]; then item_fail "there is no releases/ directory"; item_finish ""; return 0; fi\n',
     '  rm -rf "$STATUS_HOME/releases/$STATUS_RELEASE"\n', 1),
    ('ln -sfn on current', STATUS, 'after', '  STATUS_RELEASE="$rel"\n', '  ln -sfn "releases/$rel" "$STATUS_HOME/current"\n', 1),
    ('git clone', VALIDATE, 'after', '  local got=""\n', '  if git clone "$SOURCE_REPO" "$RUN_DIR/clone-attempt" > /dev/null 2>&1; then :; fi\n', 1),
    ('git ls-remote', VALIDATE, 'after', '  local got=""\n', '  if git ls-remote "$SOURCE_REPO" > /dev/null 2>&1; then :; fi\n', 1),
    ('sqlplus', VALIDATE, 'after', '  local got=""\n', '  if sqlplus -v > /dev/null 2>&1; then :; fi\n', 1),
    ('java by absolute path', STATUS, 'after', '  props="$STATUS_HOME/releases/$STATUS_RELEASE/runtime.properties"\n',
     '  if "$STATUS_HOME/runtime/java/current/bin/java" -version > /dev/null 2>&1; then :; fi\n', 1),
    ('kill', STATUS, 'after', '  local st own mode\n', '  kill -0 "$BASHPID"\n', 1),
    ('mktemp', STATUS, 'after', '  local st own mode\n', '  mktemp > /dev/null\n', 1),
    ('flock -x instead of -s', STARTUP, 'replace', 'flock -s -n "$LOCK_FD"', 'flock -x -n "$LOCK_FD"', 1),
    ('config-migrate.sh apply', VALIDATE, 'replace', 'run_item config-validate validate_item_ops config-migrate.sh validate',
     'run_item config-validate validate_item_ops config-migrate.sh apply', 1),
    ('service-identity.sh retire', VALIDATE, 'replace', 'run_item service-identity validate_item_ops service-identity.sh check',
     'run_item service-identity validate_item_ops service-identity.sh retire', 1),
    ('prune_logs in the command-line path', STARTUP, 'after',
     '  log "Oracle OPS Installer $INSTALLER_VERSION: $1 (read-only); pinned Oracle OPS $OPS_VERSION ($OPS_COMMIT); pid $BASHPID"\n', '  prune_logs\n', 1),
    ('leftover removal', STATUS, 'replace', 'else dead="${dead:+$dead, }$e"; fi', 'else dead="${dead:+$dead, }$e"; rm -rf --one-file-system -- "$d"; fi', 1),
    ('run directory not removed', STARTUP, 'replace', 'remove_own_dir "$RUN_DIR"', ': # mutated: not removed', 2),
    ('reading the working tree instead of git archive', VALIDATE, 'replace',
     '  if ! run_as_repo_owner "$SOURCE_REPO" git "--git-dir=$SOURCE_REPO/.git" archive --format=tar "$OPS_COMMIT" -- "${VALIDATE_PATHS[@]}" > "$RUN_DIR/src.tar" 2> "$RUN_DIR/archive.err"; then\n',
     '  if ! tar -cf "$RUN_DIR/src.tar" -C "$SOURCE_REPO" "${VALIDATE_PATHS[@]}" 2> "$RUN_DIR/archive.err"; then\n', 1),
    ('skipping the R1 manifest check', VALIDATE, 'replace',
     '      [ "$got" = "$digest" ] || item_fail "$rel does not match the SHA-256 recorded in this installer for Oracle OPS $OPS_VERSION"\n', '      :\n', 1),
]


def apply(root, index):
    name, rel, kind, anchor, text, count = MUTATIONS[index]
    path = '%s/%s' % (root, rel)
    s = open(path).read()
    found = s.count(anchor)
    if found != count:
        print('mutation %d (%s): the anchor occurs %d times, expected %d' % (index, name, found, count))
        return 2
    if kind == 'after':
        s = s.replace(anchor, anchor + text, 1)
    else:
        s = s.replace(anchor, text)
    open(path, 'w').write(s)
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == 'list':
        for i, m in enumerate(MUTATIONS):
            print('%d\t%s' % (i, m[0]))
        return 0
    if len(argv) == 4 and argv[1] == 'apply':
        return apply(argv[2], int(argv[3]))
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
