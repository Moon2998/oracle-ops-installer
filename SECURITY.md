# Security

The Oracle OPS Installer runs as root, holds a GitHub access token for a few seconds, downloads private source code
and runs the Oracle OPS deployment scripts from it. This document describes how each of those is protected, and what
is **not** protected.

## Token handling

- **Input:** read with `read -s`, so it is not echoed. It must look like a GitHub token (20–255 letters, digits or `_`)
  before it is used, which also keeps quotes and line breaks out of every place it is written. Up to three attempts.
- **In memory:** one non-exported shell variable. It is never exported, so no child process inherits it. It is
  cleared as soon as the download finishes, and again at exit.
- **Handing it to git:** git runs with `GIT_ASKPASS` pointing to a small helper script. The helper contains **no
  secret**. It answers exactly two prompts, `Username for 'https://github.com'` with `x-access-token`, and `Password
  for 'https://x-access-token@github.com'` by reading the token file. It refuses every other prompt, so the token
  cannot be handed to another host (for example after a redirect). The prompt wording was verified against the real
  git 1.8.3.1 of Oracle Linux 7 and github.com (`tests/online-check.sh`, using an invalid token).
- **Never in:** a command-line argument (process listings), an environment variable, the clone URL (the remote stays
  `https://github.com/Moon2998/oracle-ops.git`), the terminal, or the log.
- **No storage by git:** git runs with an empty `HOME` and `GIT_CONFIG_NOSYSTEM=1`. No user or system git
  configuration is read, so no credential helper (for example `store`) can save the token. The operator's git
  configuration and credentials are neither read nor changed.
- **Least privilege:** use a fine-grained token limited to the `oracle-ops` repository with **Contents: Read-only**,
  and a short expiry (README). The installer only reads: it never pushes or changes anything on GitHub.

## Temporary authentication storage

- The token file is `token` (mode 0600, root) beside the helper (mode 0700) in a directory created by `mktemp -d`
  (mode 0700, root).
- That directory goes in `/run` only if `/run` is a **tmpfs** (RAM-backed) owned by root and not writable by group or
  other. Otherwise it goes inside the root-only staging directory (see below), which is on disk.
- Lifetime: created just before the access check, deleted right after the download finishes, and **before any code
  from the download runs**. The Oracle OPS scripts therefore cannot read it. The tests check this from inside the
  Oracle OPS script stand-ins. It is deleted again at exit on every path.
- If the installer is killed with `SIGKILL` or the host loses power, the directory remains until the next run removes
  it (it carries a marker), or until reboot (`/run` is emptied at boot).

## Directory permissions and ownership

- `/var/lib/oracle-ops-installer` (staging) and `/var/log/oracle-ops-installer` (logs) must be real directories owned
  by root, whose parent is owned by root and not writable by group or other. They are created as mode 0700, and an
  existing one has its mode tightened to 0700. A symbolic link, a non-directory, or a directory or parent owned by
  someone else stops the run before anything is written. Nothing is followed through a link.
- Each run gets its own `run.XXXXXXXX` directory (`mktemp -d`, mode 0700) carrying a marker file. The download, git's
  empty home directory and captured command output live only there, readable by root only (the installer's umask is
  077).
- A lock (`flock` on `/var/lib/oracle-ops-installer/.lock`) allows one installer run at a time. It does not prevent
  someone from running Oracle OPS scripts by hand at the same time.
- `/etc/oracle-ops`, Oracle OPS's credential directory, is never written by the installer. It only checks that it
  exists and, after a credential update, checks the file's owner, group, mode and link count, without reading its
  content.
- No recursive `chown`/`chmod`, and no permission change outside the installer's own two directories.

## Source cleanup

- On every exit path (success, failure, cancellation, `SIGINT`/`SIGTERM`/`SIGHUP`), an exit handler removes the token
  directory and then the run directory. It removes a directory only if it is exactly the path this run recorded, is a
  real directory (not a link) and contains the run's marker. It uses `rm -rf --one-file-system`.
- An incomplete download is removed immediately.
- At start-up, `run.*` directories with the marker are leftovers of an interrupted run (the lock proves no other run is
  active) and are removed. Any other entry in the staging directory stops the run and is left alone.
- A cleanup failure is reported (path only) and logged separately. It never replaces the result of the action.
- Ordinary file deletion does **not** securely erase data from disk.

## Log protection

- One file per run, `/var/log/oracle-ops-installer/oracle-ops-installer-<UTC>-<pid>.log`, mode 0600, in a mode-0700
  root directory. The newest 20 are kept, and only files matching the installer's own name pattern are ever deleted. A
  log's size is bounded by the output of one run.
- Everything written to the log passes a sanitizer that:
  - replaces the literal token (done in bash, so the token never becomes an argument of `sed`);
  - redacts `ghp_…`, `gho_…`, `ghu_…`, `ghs_…`, `ghr_…` and `github_pat_…` tokens and the user-info part of any URL
    (`https://user:secret@host` becomes `https://[REDACTED]@host`), including proxy URLs;
  - strips ANSI escape sequences and control characters (log injection).
- No environment variables are logged. The database and WebLogic passwords are typed into the Oracle OPS tools at
  hidden prompts and never pass through the installer.
- The installer is quiet, not silent: every command's output and exit status is logged, and a failed mandatory step
  ends the run with a short reason and the log's path.

## Release-reference validation

- The Oracle OPS release is pinned in the installer itself: a full 40-character commit id (`OPS_COMMIT`), the
  version it carries (`OPS_VERSION`) and the supported platform. No branch, tag or user-supplied reference is accepted.
- The download is a full clone with `transfer.fsckObjects=true` (git checks every received object). Then the installer
  requires that the pinned commit exists, checks it out detached, and confirms `HEAD` is the pinned id with a clean
  tree. It also requires `service/VERSION` to be the pinned version, the release's Java pin to support this OS, and
  every Oracle OPS script it may run to be a regular file. Only then does any downloaded code run.
- After an install or upgrade, it confirms the deployed build is stamped with the pinned commit, so a same-numbered
  build from other code is never mistaken for the pinned release.

## Privilege requirements

- The installer must run as root because the Oracle OPS scripts it runs need root (systemd unit, ownership under the
  installation directory and `/etc/oracle-ops`). There is one privilege boundary: `sudo bash oracle-ops-installer.sh`.
  There is no nested `sudo`.
- Oracle OPS scripts run as child processes with root's usual umask 022, `LC_ALL=C`, a fixed `PATH`
  (`/usr/sbin:/usr/bin:/sbin:/bin`) and a **scrubbed environment**. Only `TERM` and the proxy variables pass; variables
  such as `BASH_ENV`, `LD_*`, `GIT_*`, `JAVA_*` and `TMPDIR` are removed. The installer scrubs its own environment the
  same way at start-up.
- Arguments are passed as separate words, never built into a command string. User input is validated before use: menu
  choices are fixed values, the installation directory must be an absolute path of plain characters outside system
  directories, and the token format is checked.
- Packages are installed only with `yum -y install <names>`, where the names come from a fixed table in the installer,
  never from input.
- The installer never changes SSH, git, firewall, sudo, SELinux or other system settings. Oracle OPS's scripts change
  only what their own documentation lists.

## Installer integrity: the library loader

The installer is an entry script plus libraries (`lib/*.sh`). Before anything from `lib/` runs, the entry script's loader
(which uses only constants of its own and absolute tool paths, never `PATH`) checks:

- **Run as root:** the secure-path check comes first, before anything is hashed. The entry script must not be a link,
  and the entry script, `lib/`, every listed library and every ancestor directory up to `/` must be owned by root and not
  writable by group or other. A sticky directory (like `/tmp`) is accepted only when the next path component is root-owned.
  Run by another user the step is skipped: that user cannot gain privileges (the installer refuses to act unless root), so
  `--help` and `--version` work from a checkout.
- **Every listed library** must exist, be a regular file (not a link) and have the SHA-256 recorded in the entry script;
  only then is any of them sourced. Files in `lib/` that are not listed are never sourced. A failure prints a message and
  exits 2 before any library code ran.
- The digest list is part of the entry script, which is why the entry script's own checksum is what an operator compares
  with the release notes (README, "Download and run"). A copy of the installer in a path another user can write to is
  refused when run as root.

This protects against a changed or replaced library, and against a library directory somebody else can write. It does not
protect against a root-owned, root-modified installer: root is trusted.

## Read-only checks: status and validate

`status` and `validate` are read-only by design (decisions D3 and D5 in `docs/DEVELOPER.md`; enforced by tests):

- **Scope.** Nothing is installed, changed, started, stopped or restarted. systemd is asked with `systemctl is-active` and
  `systemctl show` only. There is no database access, no SQL and no network. `java` is never executed by the installer.
- **Credential and configuration files are never opened.** `config/application.yaml` and the credential files are examined
  with `stat` (type, owner, group, mode, link count). The tests replace them by FIFOs (any open would hang), check access
  times, and check that marker text in them never reaches the output or the log.
- **Their own files only.** A command-line check may create the installer's own directories when missing (mode 0700), its
  own `oracle-ops-check-*.log` and the lock file when missing; `validate` also a marked staging directory in the state
  directory, removed again on every exit path. It never prunes, never changes a mode, never removes a leftover (it reports
  it). The lock is **shared**: it runs beside another check, and refuses while an install, upgrade or de-install holds the
  exclusive lock. Directories that are links, not root-owned or writable by group or other are refused; other modes than
  0700 are a warning. The menu path keeps the installer's normal start-up (its housekeeping, including chmod of its own
  directories) and additionally prunes `oracle-ops-check-*.log` to the newest 20.
- **Static and dynamic proof.** A syntactic guard (`tests/guard-scan.py`) lists every command by command position in
  `lib/ops-status.sh` and `lib/ops-validate.sh` and refuses everything off an allowlist (no `rm`, `mv`, `cp`, `ln`,
  `chmod`, `mkdir`, `touch`, `tee`, `mktemp`, `kill`, `eval`, `exec`, `cat` or `sed -i`; `unzip` only with `-p`; `tar` extraction only in
  the staging function; `systemctl` only `is-active`/`show`; `git` only `rev-parse` and `archive`; `setpriv` only inside the repository-owner seam).
  Snapshots of the protected trees (path, type, mode, owner, size, mtime, ctime, link target, SHA-256) taken before and after a
  run, and a list of 21 mutations (each injected into a copy of the installer) show that a harmful change is detected.

### What `validate` trusts (R1)

`validate` runs two Oracle OPS scripts. They come from the **local** Oracle OPS repository, which a non-root account may
own, so they are not trusted by where they came from. The trust anchor is the entry script (root-held, verified like the
libraries): a list of the SHA-256 of exactly six files at the pinned commit (`OPS_FILE_MANIFEST`). Before anything runs:

1. git runs with the privileges of the account that owns `<repo>/.git` (its uid and passwd primary group, no
   supplementary groups; `setpriv`), in `/`, in a scrubbed environment with `HOME=/nonexistent`, `GIT_CONFIG_NOSYSTEM=1`
   and `GIT_NO_REPLACE_OBJECTS=1`, so a repository somebody else can write is never read with root's privileges. Only a repository
   owned by root is read as root.
2. `git rev-parse --verify <pin>` and `git archive <pin> -- <the six paths>` produce a tar archive written by root.
3. The archive may hold only regular files and directories with relative names without `..`; it is extracted by root with
   `--no-same-owner --no-same-permissions`; the extracted files must be exactly the six, each with its recorded SHA-256, and
   `service/VERSION` must equal the pinned version. Otherwise: exit 4, nothing is run, the staging directory is removed.
4. A repository with `.git/info/attributes`, `.git/info/grafts` or replace refs is refused outright (an attributes filter could
   rewrite or drop what `git archive` writes; replace refs and grafts change what objects mean). `GIT_NO_REPLACE_OBJECTS=1` already makes
   `git` ignore replace refs, the refusal makes the tampering visible.

### Documented side effects of validate (R3 and others)

- `config-migrate.sh validate`'s Java tool opens `api.credentials` and the control token to check them (it prints no value). The
  installer's own code never opens a credential file; this is the Oracle OPS tool's behaviour, run as root.
- The JVM of that tool may create `hsperfdata` files in `/tmp`. Everything else the OPS scripts write is outside the protected
  scopes only in this respect.
- The Oracle OPS scripts run with root's umask 022, root's `HOME`, a scrubbed environment and the staging directory as
  working directory.

### Limits of the read-only checks

- A leftover directory whose marker pid is alive is reported "in use"; pid reuse can make a dead leftover look alive.
- `/proc/<pid>` is owned by root for a process that is not dumpable; status then reports the owner mismatch as a FAIL.
- The `git archive` smudge/export filters of a repository run as the repository's owner (unprivileged) while the archive is written
  if somebody planted one in `.git/config`; an attributes file is refused first, but a filter named by the committed
  `.gitattributes` of the pinned commit is part of the pinned commit (and the digest check detects a changed result).
- A non-root account that owns the repository can make `validate` fail (denial of service), never run its code as root.

## Known limitations and residual risks

- **Code from the pinned commit runs as root.** Oracle OPS's installation builds the service as root. The protection
  is the pin: only the exact reviewed commit runs. Commits are not signed, and git 1.8.3 identifies objects by SHA-1,
  so the pin is only as strong as SHA-1 collision resistance and the integrity of the `Moon2998/oracle-ops` repository.
- **Root can read the token** while it exists (the file, or the helper's process). Any root process on the host is
  trusted.
- **On-disk fallback:** if `/run` is not a safe tmpfs, the token file is briefly on disk. The private source is always
  on disk under `/var/lib/oracle-ops-installer` during a run. Deletion does not securely erase either.
- **Interrupted cleanup:** `SIGKILL` or power loss leaves the run directory (and possibly the token file) until the
  next run or, for `/run`, the next reboot.
- **Installer integrity:** a checksum downloaded from the same place as the script proves integrity, not authenticity.
  Compare it with a value obtained out of band. The libraries are checked against the entry script, so the entry script's
  checksum is the one to compare; install the tagged release into a root-owned path (README, "Download and run").
- **Proxy credentials** in `https_proxy` are passed to git and the Oracle OPS scripts, because they need them. They are
  redacted from the log, but are visible to root in the processes' environment.
- **Information in this public repository:** the private repository's name, the pinned commit id and the names of the
  Oracle OPS scripts the installer calls. It contains no Oracle OPS code and no secrets.
- **Interactive tools' output** (setup assistant, credential manager) is shown on the terminal. By Oracle OPS's design
  those tools never print a password. The installer also sanitizes the copy it logs.
- **No rollback action:** rolling back an upgrade uses Oracle OPS's `activate-release.sh` (README, "Rolling back").

## Reporting a vulnerability

Do not open a public issue. Contact the repository owner privately (for example through GitHub's private vulnerability
reporting, if it is enabled for this repository).
