#!/usr/bin/env python3
"""Static guard for the read-only checks of the Oracle OPS Installer (tests/installer-test.sh runs it).

It reads bash source, finds every simple command by COMMAND POSITION (assignments, redirections, keywords and the contents of
[[ ]], case patterns, here-documents and comments are not commands; $( ), backticks and <( ) are scanned recursively) and checks
each against the rules below. It is a syntactic guard: the behavioural tests (boundary snapshots, read trap, traces) are the
other half of the proof.

  guard-scan.py check <installer-dir>      rules for lib/ops-status.sh, lib/ops-validate.sh, the reviewed helpers they call and
                                           lib/check-startup.sh; prints the violations; exit 1 if there is any
  guard-scan.py commands <file>...         every command word found in the files, one "<file>:<line> <function> <words>" per line
  guard-scan.py selftest                   the scanner against snippets that must (not) be flagged

An exception on one line needs a trailing comment "# guard-allow: <reason>"; the number of such annotations is reported and
the test pins it (currently none).
"""
import re
import sys

ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=')
PREFIX = {'if', 'then', 'else', 'elif', 'do', 'while', 'until', '!', '{', 'time'}
IGNORE_FIRST = {'for', 'select', 'case', 'esac', 'fi', 'done', '}', 'function', 'in', ';;'}
REDIR_RE = re.compile(r'^[0-9]*(<<<|<<-?|<>|>>|>\||>&|<&|&>>|&>|<|>)')


def strip_quotes(w):
    return w.replace('"', '').replace("'", '').replace('\\', '')


class Parser:
    def __init__(self, src, base_line=1):
        self.s = src
        self.n = len(src)
        self.i = 0
        self.base = base_line
        self.cmds = []          # (line, words, redirs)
        self.func_at = {}

    def line_of(self, pos):
        return self.base + self.s.count('\n', 0, pos)

    # ---- words ---------------------------------------------------------------------------------------------------
    def skip_arith(self, start):
        """start points after '$((' ; returns index after the matching '))'"""
        depth = 2
        i = start
        while i < self.n and depth > 0:
            if self.s[i] == '(':
                depth += 1
            elif self.s[i] == ')':
                depth -= 1
            i += 1
        return i

    def parse_dollar(self):
        """at '$': handles $(...), $((...)), ${...}; returns after it (the whole expansion is part of the current word)."""
        s = self.s
        if s.startswith('$((', self.i):
            self.i = self.skip_arith(self.i + 3)
        elif s.startswith('$(', self.i):
            self.i += 2
            self.parse(term=')')
        elif s.startswith('${', self.i):
            depth = 0
            i = self.i + 1
            while i < self.n:
                c = s[i]
                if c == '\\':
                    i += 2
                    continue
                if c == "'":
                    j = s.find("'", i + 1)
                    i = (j if j >= 0 else self.n) + 1
                    continue
                if c == '"':
                    j = i + 1
                    while j < self.n and s[j] != '"':
                        j += 2 if s[j] == '\\' else 1
                    i = j + 1
                    continue
                if c == '{':
                    depth += 1
                elif c == '}':
                    depth -= 1
                    if depth == 0:
                        i += 1
                        break
                i += 1
            self.i = i
        else:
            self.i += 1

    def parse_backtick(self):
        s = self.s
        j = self.i + 1
        while j < self.n and s[j] != '`':
            j += 2 if s[j] == '\\' else 1
        inner = s[self.i + 1:j]
        sub = Parser(inner, self.line_of(self.i))
        sub.parse()
        self.cmds.extend(sub.cmds)
        self.i = j + 1

    def parse_word(self, dbl=False):
        """one word starting at self.i (quotes and expansions included); stops at whitespace or an operator."""
        s = self.s
        start = self.i
        while self.i < self.n:
            c = s[self.i]
            if c == '\\':
                self.i += 2
                continue
            if c == "'":
                j = s.find("'", self.i + 1)
                self.i = (j if j >= 0 else self.n) + 1
                continue
            if c == '"':
                self.i += 1
                while self.i < self.n and s[self.i] != '"':
                    if s[self.i] == '\\':
                        self.i += 2
                    elif s[self.i] == '$':
                        self.parse_dollar()
                    elif s[self.i] == '`':
                        self.parse_backtick()
                    else:
                        self.i += 1
                self.i += 1
                continue
            if c == '$':
                self.parse_dollar()
                continue
            if c == '`':
                self.parse_backtick()
                continue
            if c in ' \t\n':
                break
            if not dbl and c in ';&|()<>':
                # <( and >( inside a word are process substitutions of an argument; a plain operator ends the word
                if c in '<>' and s.startswith('(', self.i + 1):
                    self.i += 2
                    self.parse(term=')')
                    continue
                break
            self.i += 1
        return s[start:self.i]

    # ---- the command list ----------------------------------------------------------------------------------------
    def flush(self, words, redirs, line, case_stack):
        w = list(words)
        while True:
            before = len(w)
            while w and ASSIGN.match(w[0]):
                w = w[1:]
            while w and w[0] in PREFIX:
                w = w[1:]
            if w and w[0].endswith('()'):
                w = w[1:]
            if len(w) == before:
                break
        if not w:
            return
        if w[0] == 'esac' and case_stack:
            case_stack.pop()
            return
        if w[0] in IGNORE_FIRST:
            return
        self.cmds.append((line, w, list(redirs)))

    def parse(self, term=None):
        s = self.s
        words, redirs = [], []
        line = self.line_of(self.i)
        pending = []
        case_stack = []
        depth = 0
        dbl = False

        def fl():
            nonlocal words, redirs, line
            self.flush(words, redirs, line, case_stack)
            words, redirs = [], []
            line = self.line_of(self.i)

        while self.i < self.n:
            c = s[self.i]
            if c == '\n':
                self.i += 1
                if dbl:
                    continue
                fl()
                for delim, tabs in pending:
                    while self.i < self.n:
                        j = s.find('\n', self.i)
                        j = self.n if j < 0 else j
                        text = s[self.i:j]
                        self.i = min(j + 1, self.n)
                        if (text.lstrip('\t') if tabs else text) == delim:
                            break
                pending = []
                line = self.line_of(self.i)
                continue
            if c in ' \t':
                self.i += 1
                continue
            if c == '\\' and s.startswith('\n', self.i + 1):
                self.i += 2
                continue
            if c == '#' and not dbl:
                j = s.find('\n', self.i)
                self.i = self.n if j < 0 else j
                continue
            if not words:
                line = self.line_of(self.i)
            if dbl:
                start = self.i
                w = self.parse_word(dbl=True)
                if w.startswith(']]'):
                    self.i = start + 2          # "]];" or "]])": the test ends here, an operator may follow
                    w = ']]'
                    dbl = False
                words.append(w)
                continue
            if case_stack and case_stack[-1] == 'pattern':
                if c == ')':
                    self.i += 1
                    case_stack[-1] = 'body'
                elif c in '(|':
                    self.i += 1
                else:
                    w = self.parse_word()
                    if w == 'esac':
                        case_stack.pop()
                continue
            if c == ';' and s.startswith(';;', self.i):
                self.i += 2
                if s.startswith('&', self.i):
                    self.i += 1
                fl()
                if case_stack:
                    case_stack[-1] = 'pattern'
                continue
            if c == '(' and words and re.match(r'^[A-Za-z_][A-Za-z0-9_]*\+?=$', words[-1]):   # an array assignment: name=( ... )
                self.i += 1
                while self.i < self.n:
                    while self.i < self.n and s[self.i] in ' \t\n':
                        self.i += 1
                    if self.i < self.n and s[self.i] == ')':
                        self.i += 1
                        break
                    if not self.parse_word():
                        self.i += 1
                words[-1] = words[-1] + '(...)'
                continue
            if c == '(' and s.startswith('()', self.i) and len(words) == 1:   # a function definition: name() {
                self.i += 2
                words = []
                continue
            if c == '(' and s.startswith('((', self.i) and not words:
                self.i = self.skip_arith(self.i + 2)
                continue
            if c == '(':
                self.i += 1
                depth += 1
                fl()
                continue
            if c == ')':
                self.i += 1
                if depth > 0:
                    depth -= 1
                    fl()
                    continue
                if term == ')':
                    fl()
                    return
                fl()
                continue
            if c in ';&|':
                if s.startswith('&>', self.i):
                    pass   # a redirection, handled below
                else:
                    self.i += 1
                    if s.startswith(c, self.i) and c in '&|':
                        self.i += 1
                    elif c == '|' and s.startswith('&', self.i):
                        self.i += 1
                    fl()
                    continue
            m = REDIR_RE.match(s[self.i:]) if (c in '<>&' or c.isdigit()) else None
            if m:
                op = m.group(0)
                if op[-1] in '<>' and s.startswith('(', self.i + len(op)) and not op[0].isdigit():
                    self.i += len(op) + 1
                    self.parse(term=')')
                    continue
                self.i += len(op)
                if op.endswith('&'):
                    m2 = re.match(r'[0-9]+-?|-', s[self.i:])
                    if m2:
                        self.i += len(m2.group(0))
                        redirs.append((op, m2.group(0)))
                        continue
                while self.i < self.n and s[self.i] in ' \t':
                    self.i += 1
                if s.startswith('(', self.i) and op.endswith(('<', '>')):
                    self.i += 1
                    self.parse(term=')')
                    continue
                target = self.parse_word()
                redirs.append((op, target))
                op_clean = op.lstrip('0123456789')
                if op_clean in ('<<', '<<-'):
                    pending.append((strip_quotes(target), op_clean == '<<-'))
                continue
            w = self.parse_word()
            if not w:
                self.i += 1
                continue
            words.append(w)
            eff = [x for x in words]
            if w == '[[' and len(words) == 1:
                dbl = True
            elif w == 'in' and words[0] == 'case':
                words, redirs = [], []
                case_stack.append('pattern')
        fl()


def functions_of(src):
    """line number -> function name, from definitions that start in column 0."""
    lines = src.split('\n')
    func_at, cur = {}, ''
    for no, text in enumerate(lines, 1):
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{', text)
        if m:
            cur = m.group(1)
            func_at[no] = cur
            if re.search(r'\(\) \{ .*\}[ \t]*(#.*)?$', text):
                cur = ''
            continue
        func_at[no] = cur
        if text == '}':
            cur = ''
    return func_at


def scan(path):
    src = open(path).read()
    p = Parser(src)
    p.parse()
    fa = functions_of(src)
    lines = src.split('\n')
    out = []
    for line, words, redirs in p.cmds:
        out.append((line, fa.get(line, ''), [strip_quotes(w) for w in words], redirs, lines[line - 1] if line - 1 < len(lines) else ''))
    return out


# ---- rules ---------------------------------------------------------------------------------------------------------
BUILTINS_OK = {':', '[', '[[', 'echo', 'printf', 'local', 'read', 'return', 'shift', 'true', 'false', 'break', 'continue', '((', 'test'}
TOOLS_OK = {'stat', 'readlink', 'head', 'tail', 'grep', 'sed', 'cut', 'tr', 'sort', 'find', 'unzip', 'tar', 'sha256sum', 'ls', 'git',
            'command', 'date', 'id', 'dirname', 'basename'}
# functions of other libraries the read-only checks may call: the transitive closure was reviewed once (see REVIEWED below)
FUNCS_OK = {'say', 'log', 'sanitize_stream', 'finish', 'read_line', 'valid_home', 'valid_account_name', 'commit_matches_pin',
            'unit_value', 'unit_home', 'current_release', 'jar_commit', 'service_state', 'proc_owner_exe', 'run_as_repo_owner',
            'check_prepare_src', 'check_finish_run_dir', 'clean_env_exec', 'remove_own_dir', 'now_utc'}
# helper bodies that are scanned with the rules plus these per-function extras (the reviewed seams and helpers)
REVIEWED = {
    'service_state': {'systemctl'},
    'proc_owner_exe': set(),
    'run_as_repo_owner': {'setpriv', 'getent', 'export', 'cd', 'clean_env_exec', 'exit'},
    'check_prepare_src': {'mkdir'},
    'check_finish_run_dir': {'remove_own_dir'},
    'clean_env_exec': {'exec', 'unset', 'compgen', 'export'},
    'remove_own_dir': {'rm'},
    'unit_value': set(), 'unit_home': set(), 'current_release': set(), 'jar_commit': set(),
    'valid_home': set(), 'valid_account_name': set(), 'commit_matches_pin': set(),
    'say': set(), 'log': set(), 'sanitize_stream': set(), 'finish': {'exit'}, 'read_line': set(), 'now_utc': set(),
}
BANNED = {'rm', 'mv', 'cp', 'ln', 'chown', 'chmod', 'chgrp', 'install', 'mkdir', 'touch', 'tee', 'truncate', 'dd', 'mktemp',
          'kill', 'eval', 'exec', 'python3', 'python', 'xargs', 'journalctl', 'logrotate', 'sqlplus', 'sql', 'java', 'curl', 'wget',
          'nc', 'ssh', 'scp', 'rsync', 'cat', 'source', '.', 'flock', 'umask', 'cd'}
CRED_TEXT = re.compile(r'credential|application\.yaml|CRED_DIR|CRED_FILES', re.I)
GIT_SUBCOMMANDS_OK = {'rev-parse', 'archive'}
SYSTEMCTL_VERBS_OK = {'is-active', 'show'}
DYNAMIC_OK_IN = {'run_item'}


def git_sub(args):
    """the git subcommand in an argument list that contains 'git' (skips --git-dir=..., -c k=v, -C dir)"""
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('-c', '-C'):
            i += 2
            continue
        if a.startswith('-'):
            i += 1
            continue
        return a
    return ''


def check_command(path, func, words, redirs, extra, defined):
    cmd = words[0]
    args = words[1:]
    v = []
    if cmd.startswith('$'):
        if func not in DYNAMIC_OK_IN:
            v.append('dynamic command position %s' % cmd)
        return v
    if cmd in extra:
        # reviewed helper use; its verbs are still checked
        if cmd == 'systemctl':
            verb = next((a for a in args if not a.startswith('-')), '')
            if verb not in SYSTEMCTL_VERBS_OK:
                v.append('systemctl %s (only is-active and show)' % verb)
        return v
    if cmd == 'exit' and func == 'validate_ops_run':
        return v
    if cmd in BANNED:
        if cmd == 'umask' or cmd == 'cd':
            if func != 'validate_ops_run':
                v.append('%s outside validate_ops_run' % cmd)
        else:
            v.append('banned command %s' % cmd)
        return v
    if cmd == 'systemctl':
        verb = next((a for a in args if not a.startswith('-')), '')
        v.append('systemctl %s outside the reviewed seam service_state' % verb)
        return v
    if cmd == 'setpriv':
        v.append('setpriv outside run_as_repo_owner')
        return v
    if cmd == 'bash':
        if func != 'validate_ops_run' or '-c' in args:
            v.append('bash %s' % ' '.join(args[:2]))
        return v
    if cmd == 'clean_env_exec':
        if func != 'validate_ops_run':
            v.append('clean_env_exec outside validate_ops_run')
        return v
    if cmd == 'sed':
        for a in args:
            if a == '--in-place' or a.startswith('--in-place=') or re.match(r'^-[A-Za-z]*i[A-Za-z]*$', a) or a.startswith('-i'):
                v.append('sed in place')
    elif cmd == 'find':
        for a in args:
            if a in ('-delete', '-exec', '-execdir', '-ok', '-okdir', '-fprint', '-fprintf', '-fls', '-fprint0'):
                v.append('find %s' % a)
    elif cmd == 'unzip':
        if not any(re.match(r'^-[a-z]*p[a-z]*$', a) for a in args):
            v.append('unzip without -p')
    elif cmd == 'tar':
        flags = ''.join(a.lstrip('-') for a in args[:1] if a.startswith('-')) + ''.join(a for a in args if a in ('--extract', '--create', '--append'))
        if re.search(r'[xcru]', args[0].lstrip('-')) if args else False:
            if not (func == 'validate_stage' and re.search(r'x', args[0])):
                v.append('tar %s outside the staging function validate_stage' % args[0])
        if any(a in ('--extract', '--create', '--append') for a in args) and func != 'validate_stage':
            v.append('tar extract/create outside validate_stage')
    elif cmd == 'git':
        if git_sub(args) not in GIT_SUBCOMMANDS_OK:
            v.append('git %s (only rev-parse and archive)' % git_sub(args))
    elif cmd == 'run_as_repo_owner':
        rest = args[1:]
        if 'git' in rest:
            sub = git_sub(rest[rest.index('git') + 1:])
            if sub not in GIT_SUBCOMMANDS_OK:
                v.append('git %s via run_as_repo_owner (only rev-parse and archive)' % sub)
        else:
            v.append('run_as_repo_owner of something other than git')
    elif cmd in BUILTINS_OK or cmd in TOOLS_OK or cmd in FUNCS_OK or cmd in defined:
        pass
    else:
        v.append('command %s is not on the allowlist' % cmd)
    # credential and configuration files are only ever examined by stat or by a test
    if cmd in TOOLS_OK and cmd not in ('stat', 'command', 'git', 'tar', 'find'):
        for a in args:
            if CRED_TEXT.search(a):
                v.append('%s names a credential or configuration path (%s)' % (cmd, a))
    for op, target in redirs:
        if op.lstrip('0123456789') in ('<', '<<<') and CRED_TEXT.search(target):
            v.append('input redirection from a credential or configuration path (%s)' % target)
    return v


STARTUP_BANNED_CALLS = {'prune_logs', 'ensure_private_dir', 'init_state', 'init_logging', 'chmod', 'chown', 'chgrp', 'ln', 'mv', 'cp',
                        'touch', 'tee', 'truncate', 'dd', 'kill', 'eval', 'python3', 'xargs', 'install', 'journalctl', 'logrotate',
                        'sqlplus', 'java', 'curl', 'wget', 'git', 'systemctl', 'setpriv', 'bash', 'cat'}
STARTUP_ONLY_IN = {'rm': {'prune_check_logs'}, 'mkdir': {'check_dir_strict', 'check_prepare_src'}, 'mktemp': {'check_new_run_dir'},
                   'rmdir': {'check_new_run_dir'}}


def check_startup(path):
    v = []
    for line, func, words, redirs, text in scan(path):
        cmd = words[0]
        if cmd in STARTUP_BANNED_CALLS:
            v.append((line, func, '%s in the command-line start-up' % cmd))
        if cmd in STARTUP_ONLY_IN and func not in STARTUP_ONLY_IN[cmd]:
            v.append((line, func, '%s outside %s' % (cmd, '/'.join(sorted(STARTUP_ONLY_IN[cmd])))))
        if cmd == 'rm' and func == 'prune_check_logs' and not any('oracle-ops-check' in w or '$LOG_DIR/$f' in w for w in words):
            v.append((line, func, 'rm of something other than a check log'))
        if cmd == 'flock' and not (len(words) >= 3 and words[1] == '-s' and words[2] == '-n'):
            v.append((line, func, 'flock other than -s -n'))
        if cmd == 'exec' and any(not re.match(r'^\{[A-Za-z_]+\}$', a) for a in words[1:]):
            v.append((line, func, 'exec of a command'))
    return v


def load_defs(files):
    defs = {}
    for f in files:
        src = open(f).read()
        for m in re.finditer(r'^([A-Za-z_][A-Za-z0-9_]*)\(\) \{', src, re.M):
            defs.setdefault(m.group(1), f)
    return defs


def check_all(root):
    libs = {n: '%s/lib/%s.sh' % (root, n) for n in ('ops-status', 'ops-validate', 'check-startup', 'env', 'common', 'installation', 'menu')}
    violations, allows = [], 0
    guarded = [libs['ops-status'], libs['ops-validate']]
    own_defs = set()
    for f in guarded:
        own_defs |= set(load_defs([f]).keys())
    # 1. the guarded files
    for f in guarded:
        text = open(f).read().split('\n')
        allows += sum(1 for t in text if re.search(r'#\s*guard-allow:\s*\S', t))
        for line, func, words, redirs, src in scan(f):
            if re.search(r'#\s*guard-allow:\s*\S', src):
                continue
            for msg in check_command(f, func, words, redirs, set(), own_defs):
                violations.append('%s:%d (%s) %s' % (f.replace(root + '/', ''), line, func or '-', msg))
    # 2. the reviewed helpers (the transitive closure of what the guarded files call), with their per-function extras
    for name, extra in REVIEWED.items():
        for f in (libs['env'], libs['common'], libs['installation'], libs['check-startup']):
            src = open(f).read()
            if not re.search(r'^%s\(\) \{' % re.escape(name), src, re.M):
                continue
            for line, func, words, redirs, text in scan(f):
                if func != name:
                    continue
                if re.search(r'#\s*guard-allow:\s*\S', text):
                    continue
                for msg in check_command(f, func, words, redirs, extra | {'log', 'say', 'stat', 'sed'}, set(REVIEWED) | set(own_defs)):
                    violations.append('%s:%d (%s) %s' % (f.replace(root + '/', ''), line, func, msg))
    # 3. the command-line start-up
    for line, func, msg in check_startup(libs['check-startup']):
        violations.append('lib/check-startup.sh:%d (%s) %s' % (line, func or '-', msg))
    return violations, allows


def selftest():
    import tempfile, os
    bad = {
        'rm': 'f() {\n  rm -f /x\n}\n',
        'chmod': 'f() {\n  if [ -e x ]; then chmod 0640 "$1"; fi\n}\n',
        'cat': 'f() {\n  x="$(cat "$CRED_DIR/a")"\n}\n',
        'head cred': 'f() {\n  head -c 1 "$CRED_DIR/database.credentials"\n}\n',
        'redirect': 'f() {\n  read -r x < "$CRED_DIR/a.credentials"\n}\n',
        'systemctl': 'f() {\n  systemctl restart x\n}\n',
        'git clone': 'f() {\n  git clone u d\n}\n',
        'git seam': 'f() {\n  run_as_repo_owner "$r" git --git-dir=x ls-remote u\n}\n',
        'sed -i': 'f() {\n  sed -i s/a/b/ x\n}\n',
        'find delete': 'f() {\n  find . -delete\n}\n',
        'unzip': 'f() {\n  unzip x.jar\n}\n',
        'tar -x': 'f() {\n  tar -xf a.tar\n}\n',
        'bash -c': 'f() {\n  bash -c "x"\n}\n',
        'mktemp in subst': 'f() {\n  local t\n  t="$(mktemp -d)"\n}\n',
        'after &&': 'f() {\n  [ -n "$x" ] && kill -0 1\n}\n',
        'in then': 'f() {\n  if true; then touch a; fi\n}\n',
        'pipe': 'f() {\n  echo a | tee b\n}\n',
        'sqlplus': 'f() {\n  sqlplus -v\n}\n',
        'java': 'f() {\n  /x/bin/java -version\n}\n',
        'unknown': 'f() {\n  frobnicate\n}\n',
        'case body': 'f() {\n  case "$1" in\n    a) rm x ;;\n    *) : ;;\n  esac\n}\n',
        'subshell': 'f() {\n  ( rm x )\n}\n',
        'process subst': 'f() {\n  while read -r l; do :; done < <(rm x)\n}\n',
        'setpriv': 'f() {\n  setpriv --reuid 1 x\n}\n',
        'dynamic': 'f() {\n  "$x" a\n}\n',
    }
    good = (
        'f() {\n'
        '  local a b\n'
        '  # rm -rf / in a comment\n'
        '  a="rm -rf x"            # a string, not a command\n'
        '  if ! b="$(stat -c %a -- "$1" 2>/dev/null)"; then return 1; fi\n'
        '  case "$a" in rm*|chmod) printf "%s\\n" "kill -9 1" ;; *) : ;; esac\n'
        '  [[ "$a" =~ ^(rm|kill)$ ]] && echo ok\n'
        '  read -r a <<EOT\nrm -rf /\nEOT\n'
        '  printf "%s" "$(sed -n 1p /x | head -n 1)"\n'
        '  unzip -p x.jar a | head\n'
        '  tar -tvf x.tar\n'
        '  run_as_repo_owner "$r" git --git-dir=x rev-parse --verify y\n'
        '  while IFS= read -r l; do :; done < <(find . -maxdepth 1 -printf "%f\\n")\n'
        '  echo "${#a} ${a%%x} $((1 + 2))"\n'
        '}\n'
    )
    failures = []
    with tempfile.TemporaryDirectory() as d:
        os.makedirs(d + '/lib')
        for name in ('ops-status', 'ops-validate', 'check-startup', 'env', 'common', 'installation', 'menu'):
            open('%s/lib/%s.sh' % (d, name), 'w').write('')
        for label, text in bad.items():
            open(d + '/lib/ops-status.sh', 'w').write(text)
            viol, _ = check_all(d)
            if not viol:
                failures.append('NOT FLAGGED: %s' % label)
        open(d + '/lib/ops-status.sh', 'w').write(good.replace('\\n', '\\n'))
        viol, _ = check_all(d)
        if viol:
            failures.append('CLEAN SNIPPET FLAGGED: %s' % viol)
        open(d + '/lib/ops-status.sh', 'w').write('f() {\n  rm -f x   # guard-allow: reviewed cleanup\n}\n')
        viol, allows = check_all(d)
        if viol or allows != 1:
            failures.append('guard-allow not honoured or not counted: %s %s' % (viol, allows))
    for f in failures:
        print(f)
    print('selftest: %d snippets that must be flagged, 1 that must not, 1 annotation: %s' % (len(bad), 'FAILED' if failures else 'OK'))
    return 1 if failures else 0


def main(argv):
    if len(argv) >= 2 and argv[1] == 'selftest':
        return selftest()
    if len(argv) == 3 and argv[1] == 'check':
        viol, allows = check_all(argv[2].rstrip('/'))
        for x in viol:
            print('VIOLATION ' + x)
        print('guard: %d violation(s), %d guard-allow annotation(s)' % (len(viol), allows))
        return 1 if viol else 0
    if len(argv) >= 3 and argv[1] == 'commands':
        for f in argv[2:]:
            for line, func, words, redirs, text in scan(f):
                print('%s:%d %s %s' % (f, line, func or '-', ' '.join(words)))
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
