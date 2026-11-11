#!/usr/bin/env python3
"""Checks the installer's database step against the PINNED Oracle OPS source, and the SQL splitter of the database tool.

  python3 -I tests/db-check.py [--ops-repo DIR] [--java FILE]
      defaults: $OPS_SOURCE_REPO or /u01/oracle_ops; $OPS_TEST_JAVA or /u01/oracle_ops_runtime/runtime/java/current/bin/java

  1. every OPS_DB_SCRIPTS digest (oracle-ops-installer.sh) equals the blob at OPS_COMMIT;
  2. DB_DICTIONARY_VIEWS (lib/env.sh) is exactly the set of DBA_* views the run/include scripts read, so the DBA SQL grants
     neither too little (the scripts would fail as OPS_OWNER) nor more than they need;
  3. the database tool (lib/db-tool.sh) splits each pinned script into the expected statements (Java, no database), and
     handles the hard cases of the SQL*Plus subset (strings and comments with ';', '/'-terminated SQL, includes, refusals).
Parts that need the repository or a JDK print NOT RUN and do not fail; any mismatch exits 1.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXPECTED_SPLIT = {   # statements per pinned script, includes inlined (counted by hand from the files, 2026-11-11)
    'V4_001__create_ops_run.sql': 11,
    'V4_002__create_ops_run_api.sql': 6,
    'V5_001__add_ops_run_get_run.sql': 6,
    'V8_001__create_ops_wls_action.sql': 11,
}


def read(rel):
    with open(os.path.join(ROOT, rel)) as f:
        return f.read()


def git(repo, *args):
    return subprocess.check_output(['git', '--git-dir=' + os.path.join(repo, '.git')] + list(args),
                                   stderr=subprocess.DEVNULL)


def main():
    repo = os.environ.get('OPS_SOURCE_REPO', '/u01/oracle_ops')
    java = os.environ.get('OPS_TEST_JAVA', '/u01/oracle_ops_runtime/runtime/java/current/bin/java')
    a = sys.argv[1:]
    while a:
        if a[0] == '--ops-repo' and len(a) > 1:
            repo = a[1]; a = a[2:]
        elif a[0] == '--java' and len(a) > 1:
            java = a[1]; a = a[2:]
        else:
            print('usage: db-check.py [--ops-repo DIR] [--java FILE]'); return 2
    entry = read('oracle-ops-installer.sh')
    env = read('lib/env.sh')
    commit = re.search(r'^OPS_COMMIT="([0-9a-f]{40})"', entry, re.M).group(1)
    block = re.search(r'^OPS_DB_SCRIPTS=\(\n(.*?)\n\)', entry, re.M | re.S).group(1)
    rows = [re.match(r'\s*"(\S+)  (\S+)  (\S+)"', l).groups() for l in block.split('\n') if l.strip()]
    views = set(re.search(r'^DB_DICTIONARY_VIEWS="([^"]*)"', env, re.M).group(1).split())
    problems = []
    tmp = tempfile.mkdtemp(prefix='db-check.')
    try:
        try:
            git(repo, 'cat-file', '-e', commit + '^{commit}')
            have_repo = True
        except Exception:
            have_repo = False
            print('NOT RUN (digests, views, real-script split): the pinned commit %s is not in %s' % (commit[:12], repo))
        if have_repo:
            used = set()
            for digest, kind, path in rows:
                if kind == 'grant':
                    if not re.fullmatch(r'[a-z_]+', path):
                        problems.append('grant row names %r' % path)
                    continue
                blob = git(repo, 'show', '%s:%s' % (commit, path))
                import hashlib
                if hashlib.sha256(blob).hexdigest() != digest:
                    problems.append('%s: the digest in OPS_DB_SCRIPTS is not the pinned blob' % path)
                with open(os.path.join(tmp, os.path.basename(path)), 'wb') as f:
                    f.write(blob)
                used |= {v.upper() for v in re.findall(r'\bdba_[a-z_]+\b', blob.decode('utf-8'), re.I)}
            if used != views:
                problems.append('DB_DICTIONARY_VIEWS differs from the views the scripts read: missing %s, extra %s'
                                % (sorted(used - views), sorted(views - used)))
            # the grant row sits right after V4_002 (V5_001 requires the grant)
            kinds = [(k, os.path.basename(p)) for _, k, p in rows]
            gi = [i for i, (k, _) in enumerate(kinds) if k == 'grant']
            if not gi or kinds[gi[0] - 1][1] != 'V4_002__create_ops_run_api.sql':
                problems.append('the installer grant is not right after V4_002')

        if not (os.path.isfile(java) and os.access(java, os.X_OK)):
            print('NOT RUN (splitter): no JDK at %s (set OPS_TEST_JAVA)' % java)
        else:
            src = subprocess.check_output(['bash', '-c', '. lib/db-tool.sh; db_tool_source'], cwd=ROOT)
            with open(os.path.join(tmp, 'OpsSchemaDeploy.java'), 'wb') as f:
                f.write(src)

            def split(*files):
                p = subprocess.run([java, '-XX:-UsePerfData', 'OpsSchemaDeploy.java', 'split'] + list(files), cwd=tmp,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                return p.returncode, p.stdout.decode('utf-8', 'replace')

            if have_repo:
                for name, n in EXPECTED_SPLIT.items():
                    rc, out = split(name)
                    got = re.search(r'^FILE %s (\d+)$' % re.escape(name), out, re.M)
                    if rc != 0 or not got or int(got.group(1)) != n:
                        problems.append('%s: split into %s statements (rc %d), expected %d' % (name, got.group(1) if got else '?', rc, n))
            cases = {
                'semi_in_string.sql': ("insert into t values ('a;\nb;');\nselect 1 from dual -- trailing; comment\n;\n"
                                       "/* block; */\nselect 2 from dual\n/\n", 0, 3),
                'plsql.sql': ("create or replace procedure p as\nbegin\n  null; -- ;\nend;\n/\nshow errors\nprompt done\n", 0, 3),
                'include_main.sql': ("whenever sqlerror exit failure\nset echo on\n@@include_child.sql\nexit\nselect 9 from dual;\n", 0, 1),
                'include_child.sql': ("select 1 from dual;\n", 0, 1),
                'unterminated.sql': ("select 1 from dual\n", 1, None),
                'define.sql': ("define x = 1\n", 1, None),
                'connect.sql': ("connect sys/x as sysdba\n", 1, None),
            }
            for name, (text, _, _) in cases.items():
                with open(os.path.join(tmp, name), 'w') as f:
                    f.write(text)
            for name, (text, want_rc, n) in cases.items():
                if name == 'include_child.sql':
                    continue
                rc, out = split(name)
                if (rc != 0) != (want_rc != 0):
                    problems.append('splitter case %s: exit %d (%s)' % (name, rc, out.strip().split('\n')[-1]))
                    continue
                if n is not None:
                    got = re.search(r'^FILE %s (\d+)$' % re.escape(name), out, re.M)
                    if not got or int(got.group(1)) != n:
                        problems.append('splitter case %s: %s statements, expected %d' % (name, got.group(1) if got else '?', n))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if problems:
        for p in problems:
            print('FAIL: ' + p)
        return 1
    print('PASS: database scripts, DBA view list and SQL splitter match the pinned Oracle OPS source')
    return 0


if __name__ == '__main__':
    sys.exit(main())
