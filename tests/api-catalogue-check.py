#!/usr/bin/env python3
"""Checks the installer's view of Oracle OPS against the source of the PINNED Oracle OPS commit (no network, read-only).

  python3 -I tests/api-catalogue-check.py [--ops-repo DIR]      (default: $OPS_SOURCE_REPO, else /u01/oracle_ops)

What must match the pinned source exactly:
  1. the API catalogue (lib/api-catalogue.sh): the set of endpoint paths equals the route constants of the pinned
     service/src/main/java/com/oracleops/api/*.java (every resolved "static final String" that starts with /api/v1/ and is
     not a prefix ending in "/"); POST exactly for .../start and .../stop (ApiService.serverAction accepts only POST),
     GET for everything else; the catalogue's API version equals ApiService.API_VERSION;
  2. the API key files (lib/env.sh API_KEY_FILES): the fixed paths and property names in ApiTokenLoader, and its
     MIN_TOKEN_CHARS (API_KEY_MIN_CHARS);
  3. the start-up log lines the installer reads (API_ROUTES_LINE, API_DISABLED_LINE) appear in OracleOpsService.java,
     and API_STATUS_PATH is one of the routes.
The pinned commit is read from oracle-ops-installer.sh (OPS_COMMIT). When the repository or the commit is not available the
check prints NOT RUN and exits 0 (it never reports a pass it did not make); any mismatch exits 1.
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
API_DIR = 'service/src/main/java/com/oracleops/api'


def read(rel):
    with open(os.path.join(ROOT, rel)) as f:
        return f.read()


def git(repo, *args):
    return subprocess.check_output(['git', '--git-dir=' + os.path.join(repo, '.git')] + list(args),
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def shell_value(text, name):
    m = re.search(r'^%s="([^"]*)"' % re.escape(name), text, re.M)
    if not m:
        raise SystemExit('cannot find %s' % name)
    return m.group(1)


def constants(sources):
    """{Class: {NAME: expression}} for every 'static final String NAME = expr;' (single line)."""
    out = {}
    for cls, text in sources.items():
        out[cls] = dict(re.findall(r'static\s+final\s+String\s+([A-Z_][A-Z0-9_]*)\s*=\s*([^;]+);', text))
    return out


def resolve(consts):
    values = {}

    def value(cls, name, depth=0):
        key = (cls, name)
        if key in values:
            return values[key]
        if depth > 20 or name not in consts.get(cls, {}):
            return None
        parts = [p.strip() for p in re.split(r'\+(?=(?:[^"]*"[^"]*")*[^"]*$)', consts[cls][name])]
        acc = ''
        for p in parts:
            if re.fullmatch(r'"(?:[^"\\]|\\.)*"', p):
                acc += p[1:-1]
            elif re.fullmatch(r'[A-Z][A-Za-z0-9]*\.[A-Z_][A-Z0-9_]*', p):
                c, n = p.split('.')
                v = value(c, n, depth + 1)
                if v is None:
                    return None
                acc += v
            elif re.fullmatch(r'[A-Z_][A-Z0-9_]*', p):
                v = value(cls, p, depth + 1)
                if v is None:
                    return None
                acc += v
            else:
                return None
        values[key] = acc
        return acc

    for cls, names in consts.items():
        for name in names:
            value(cls, name)
    return values


def main():
    repo = os.environ.get('OPS_SOURCE_REPO', '/u01/oracle_ops')
    if len(sys.argv) == 3 and sys.argv[1] == '--ops-repo':
        repo = sys.argv[2]
    entry = read('oracle-ops-installer.sh')
    env = read('lib/env.sh')
    catalogue = read('lib/api-catalogue.sh')
    commit = shell_value(entry, 'OPS_COMMIT')
    try:
        git(repo, 'cat-file', '-e', commit + '^{commit}')
    except Exception:
        print('NOT RUN: the pinned Oracle OPS commit %s is not available in %s (set OPS_SOURCE_REPO)' % (commit[:12], repo))
        return 0

    names = [n for n in git(repo, 'ls-tree', '--name-only', commit + ':' + API_DIR).split('\n') if n.endswith('.java')]
    sources = {n[:-5]: git(repo, 'show', '%s:%s/%s' % (commit, API_DIR, n)) for n in names}
    values = resolve(constants(sources))
    routes = sorted({v for v in values.values() if v.startswith('/api/v1/') and not v.endswith('/')})

    m = re.search(r"cat <<'ROWS'\n(.*?)\nROWS\n", catalogue, re.S)
    if not m:
        print('FAIL: no catalogue rows found in lib/api-catalogue.sh')
        return 1
    rows = [r.split('|') for r in m.group(1).split('\n') if r.strip()]
    problems = []
    for i, r in enumerate(rows, start=1):
        if len(r) != 12:
            problems.append('catalogue row %d has %d fields, expected 12' % (i, len(r)))
            continue
        if r[0] != str(i):
            problems.append('catalogue row %d is numbered %s' % (i, r[0]))
        want = 'POST' if re.search(r'/(start|stop)$', r[2]) else 'GET'
        if r[1] != want:
            problems.append('%s is listed as %s, the source serves it as %s' % (r[2], r[1], want))
        if r[5] not in ('read', 'control', 'read or control'):
            problems.append('%s has an unknown key scope %r' % (r[2], r[5]))
    listed = sorted(r[2] for r in rows if len(r) == 12)
    for p in sorted(set(routes) - set(listed)):
        problems.append('route %s exists in the pinned source but is not in the catalogue' % p)
    for p in sorted(set(listed) - set(routes)):
        problems.append('catalogue lists %s, which the pinned source does not define' % p)
    if len(listed) != len(set(listed)):
        problems.append('the catalogue lists a path twice')

    api_version = values.get(('ApiService', 'API_VERSION'))
    if api_version != shell_value(catalogue, 'API_CATALOGUE_VERSION'):
        problems.append('API_CATALOGUE_VERSION differs from ApiService.API_VERSION (%s)' % api_version)

    loader = sources.get('ApiTokenLoader', '')
    for item in shell_value(env, 'API_KEY_FILES').split():
        name, prop, _scope = item.split(':')
        if ('"/etc/oracle-ops/%s"' % name) not in loader:
            problems.append('ApiTokenLoader does not read /etc/oracle-ops/%s' % name)
        if ('"%s"' % prop) not in loader:
            problems.append('ApiTokenLoader has no property %s' % prop)
    mm = re.search(r'MIN_TOKEN_CHARS\s*=\s*(\d+)', loader)
    if not mm or mm.group(1) != shell_value_int(env, 'API_KEY_MIN_CHARS'):
        problems.append('API_KEY_MIN_CHARS differs from ApiTokenLoader.MIN_TOKEN_CHARS')

    service = git(repo, 'show', commit + ':service/src/main/java/com/oracleops/core/OracleOpsService.java')
    if shell_value(env, 'API_ROUTES_LINE').rstrip('[') not in service:
        problems.append('OracleOpsService does not log "%s"' % shell_value(env, 'API_ROUTES_LINE'))
    if shell_value(env, 'API_DISABLED_LINE') not in service:
        problems.append('OracleOpsService does not log "%s"' % shell_value(env, 'API_DISABLED_LINE'))
    if shell_value(env, 'API_STATUS_PATH') not in routes:
        problems.append('API_STATUS_PATH is not a route of the pinned source')

    if problems:
        for p in problems:
            print('FAIL: ' + p)
        return 1
    print('PASS: catalogue = %d routes of commit %s; key files, minimum length and log lines match' % (len(routes), commit[:12]))
    return 0


def shell_value_int(text, name):
    m = re.search(r'^%s=(\d+)' % re.escape(name), text, re.M)
    return m.group(1) if m else None


if __name__ == '__main__':
    sys.exit(main())
