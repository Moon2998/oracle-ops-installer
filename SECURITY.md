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
  Compare it with a value obtained out of band.
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
