# Oracle OPS Installer

One interactive command that installs, upgrades or de-installs **Oracle OPS** on an Oracle Linux 7 server, and updates
the WebLogic credential Oracle OPS stores. You do not need to know Git, clone anything or run the Oracle OPS deployment
scripts yourself.

This repository contains **only the installer**. Oracle OPS itself lives in a private repository
(`Moon2998/oracle-ops`). The installer downloads one pinned, verified Oracle OPS release for the duration of a run, uses
Oracle OPS's own scripts to do the work, and then removes the download again.

> **Oracle APEX is out of scope.** This installer never installs, configures or deploys Oracle APEX, APEX applications
> or workspaces. Install and configure APEX separately, by hand.

## What it does

```
Oracle OPS Installer
====================
Oracle OPS release 0.1.5. Oracle APEX is not installed or configured by this installer.

  1) Install Oracle OPS
  2) Update credentials
  3) Upgrade Oracle OPS
  4) De-install Oracle OPS
  5) Status
  6) Validate
  7) Exit
```

| Action | What happens | Oracle OPS script used (from the pinned release) |
|---|---|---|
| Install Oracle OPS | Fresh installation. The Oracle OPS setup assistant asks for the service account, database connection and options, proves the database login, writes the configuration and installs. | `deploy-oracle-ops.sh --home <dir>` |
| Update credentials | (1) WebLogic administration account: stored for Oracle OPS. (2) Database password: shows the manual procedure; changes nothing. | `manage-app-credentials.sh` |
| Upgrade Oracle OPS | Installs the pinned release beside the current one and switches to it. The previous release stays installed. | `install-release.sh` (pre-check, then install), or `activate-release.sh` to finish an interrupted upgrade |
| De-install Oracle OPS | Stops and disables the service, removes its systemd unit and log-rotation file, and **renames** the installation directory to `<dir>.retired-<time>`. Nothing is deleted. | `service-identity.sh retire --apply` |
| Status | Read-only report on the installed Oracle OPS (13 checks, below). Changes nothing. | none |
| Validate | Status, then the checks of the pinned release, run from a verified copy taken out of the local Oracle OPS repository (no network). Changes nothing. | `config-migrate.sh validate`, `service-identity.sh check` |
| Exit | Nothing is changed. | – |

Each run does one action, then exits. Install, Update credentials, Upgrade and De-install go through the same stages
(Status and Validate print a list of checks instead, see "Status and validate"):

```
[1/5] Checking system prerequisites...
[2/5] Configuring Oracle OPS...            (or: Checking the current installation...)
[3/5] Configuring source...
[4/5] Installing Oracle OPS...             (or: Upgrading / De-installing / Updating ...)
[5/5] Finalizing installation...

Oracle OPS installation completed successfully.
```

The installer prints only these high-level messages and its questions. Git commands, download details and build
output go to a protected log. **One exception:** the Oracle OPS setup assistant (Install) and credential manager
(Update credentials) talk to you directly. Their questions and messages are shown between two dashed lines, and also
recorded in the log.

## Supported systems

| | |
|---|---|
| Operating system | **Oracle Linux 7** (`/etc/os-release` `ID=ol`, `VERSION_ID=7.x`). The pinned Oracle OPS release supports only this platform: its Java runtime pin is `jdk.platforms=ol:7`. |
| Architecture | x86_64 |
| Init system | systemd (Oracle OPS runs as `oracle-ops.service`) |
| Shell | bash 4.2 or later (Oracle Linux 7 ships 4.2) |

Any other system is refused before anything is changed. Development and automated tests ran on Oracle Linux 7.9. A
real root installation has **not yet** been run with this installer (see `docs/DEVELOPER.md`, "Verification status").

## Before you start

You need:

- **root** (`sudo`) and an interactive terminal (`status` and `validate` need no terminal).
- **A GitHub access token** that can read the private Oracle OPS repository (see below).
- **Outbound HTTPS** to `github.com`, and to `download.oracle.com` for Oracle OPS's private Java runtime. For a host
  without internet access to Oracle, pass a pre-staged copy of the pinned JDK archive with `--java-archive FILE`.
- **For Install:** an existing OS user and group for the service. Oracle OPS creates no accounts and has no default
  one. You also need the database listener host, port, service name, runtime account and its password. The database
  account and its grants are prepared by your DBA; the installer creates none.
- These tools (normally present): `git curl unzip tar gzip sha256sum flock setpriv find readlink stat mktemp timeout df
  awk sed grep install cmp cp chmod chown chgrp mkdir rm mv ln tee env getent systemctl tr cut sort head tail date id
  uname stty`, plus `logrotate`. If some are missing, the installer lists them and offers two choices:
  1. **install them now** with `yum` (fixed package names only), after which it checks again; or
  2. **install them yourself**: it prints the exact `yum install -y …` command and stops.

  It continues only when every prerequisite is present.
- About 200 MB free under `/var/lib` for the temporary download. Oracle OPS itself needs about 800 MB in the
  installation directory while it provisions its Java runtime.

If you use an HTTP proxy, `sudo` drops proxy variables. Pass them explicitly:
`sudo env https_proxy=http://proxy:3128 bash oracle-ops-installer.sh`.

## Download and run

The installer is the entry script `oracle-ops-installer.sh` plus the libraries in `lib/`. Before it sources any library,
the entry script checks the library's SHA-256 against a list that is part of the entry script, and (run as root) that the
whole path to it is root-owned and not writable by group or other. **Install it as a unit, as root, into a root-owned
path** (for example `/opt/oracle-ops-installer`, whose parent directories are root-owned too), and compare the checksum of
the entry script with the one published in the release notes. This is the procedure (nothing in the installer does it
for you):

```bash
# on a host with a clone of the installer repository, as root, for a tagged release
cd /path/to/oracle-ops-installer
git archive --format=tar --prefix=oracle-ops-installer/ v<release-tag> | tar -x -C /opt --no-same-owner
chown -R root:root /opt/oracle-ops-installer && chmod -R go-w /opt/oracle-ops-installer
sha256sum /opt/oracle-ops-installer/oracle-ops-installer.sh    # compare with the checksum in the release notes
bash /opt/oracle-ops-installer/oracle-ops-installer.sh
```

Run as root from a directory that is not root-owned (for example a checkout under a user's home), the installer refuses
with exit status 2 and says which path is unsafe. Run by a normal user it only answers `--help` and `--version`.

Options: `--java-archive FILE` (air-gapped Java runtime, see above), `--help`, `--version`; and the read-only
subcommands `status` and `validate` (below).

## Private repository access

When the installer reaches **Configuring source**, it asks for a GitHub access token. Typing is not shown.

Create a **fine-grained personal access token** with the least access that works:

- Resource owner: `Moon2998`; Repository access: **Only select repositories → `oracle-ops`**
- Repository permissions: **Contents: Read-only** (GitHub adds Metadata: Read-only automatically)
- A short expiration date

A classic token would need the broad `repo` scope, which gives full control of every private repository you can reach.
Avoid it.

How the token is handled, in brief (details in `SECURITY.md`):

- It is held only in the installer's memory. For the download it is written to a root-only file (mode 0600) in a
  root-only directory on RAM-backed `/run`, or inside the root-only staging directory if `/run` is not a safe tmpfs.
  A small helper hands it to git only when git asks for `github.com`.
- It never appears in a command line, an environment variable, the clone address, the terminal or the log.
- The installer's git commands run with an empty home directory and without the system git configuration, so your
  git configuration and stored credentials are neither used nor changed, and no credential helper can save the token.
- The token file and helper are **deleted as soon as the download finishes**, before any downloaded code runs, and
  again at exit.

The installer first checks access, then downloads. A rejected token, a token without access to the repository, or no
network connection each stop the run with a specific reason. Nothing is installed.

## Which Oracle OPS release is installed

The installer is pinned to **one** Oracle OPS release: commit `63fb7c162c6b7076129b8a1f02b7bdb9b2dd44f5`, version
`0.1.9`. It never installs whatever happens to be the newest code on a branch. After downloading, it checks out exactly
that commit and checks that:

- the checked-out tree is that commit with no differences;
- `service/VERSION` is `0.1.9`;
- the release supports this operating system.

After installing, it checks that the deployed build carries that commit id. A new Oracle OPS release needs a new
installer release (`docs/DEVELOPER.md`).

## Status and validate (read-only)

```bash
sudo bash oracle-ops-installer.sh status   [--home DIR]
sudo bash oracle-ops-installer.sh validate [--home DIR] [--source-repo DIR]
```

Both need root, need **no terminal** and ask nothing, so they can run from a script or a monitoring job. The subcommand
must be the first argument; `--java-archive`, unknown and repeated options are usage errors (exit 2). The menu offers
the same checks as **5 Status** and **6 Validate** (Validate asks for the repository path, default `/u01/oracle_ops`,
three attempts).

`--home` defaults to the installation directory the installed unit names; if both exist they must agree. With no unit
and no `--home` the answer is "not installed" (exit 6).

**status** prints one line per check, `OK`, `WARN` or `FAIL`, then `status: OK n, WARN n, FAIL n`. A check that cannot be
determined (permission denied, missing tool, an unreadable `/proc` entry, a failing `systemctl show`) is a `FAIL`.

| # | Check | OK means |
|---|---|---|
| 1 | `unit` | `oracle-ops.service` is a regular file (not a link), owned by root, not writable by group or other, with a valid `User=`, `Group=` and `ORACLE_OPS_HOME=` |
| 2 | `home` | the installation directory is a real directory with `releases/` |
| 3 | `current-release` | `current` selects `releases/<v>` and `releases/<v>/VERSION` is `<v>` (WARN if `<v>` is not the pinned version) |
| 4 | `build-commit` | the commit stamped in the deployed jar is the pinned commit (WARN if not; FAIL if unreadable) |
| 5 | `other-releases` | information: the other installed releases and their commits |
| 6 | `runtime` | the JDK the release requires (`runtime.properties`) is the one `runtime/java/current` selects. Nothing is executed. |
| 7 | `service` | `systemctl is-active` and `show` report active (running), the main process runs as the unit's `User:Group` and its program is under `<home>/runtime/java/` |
| 8 | `service-log` | the latest lifecycle line, `is RUNNING` line and database-health line of the last 2000 lines of `logs/oracle-ops.log`, quoted (WARN if absent or not healthy) |
| 9 | `configuration` | `config/application.yaml` is a regular file, root:`<Group>`, mode 0640, **by metadata only** |
| 10 | `credential-directory` | `/etc/oracle-ops` is a real directory, root:`<Group>`, mode 0750 |
| 11 | `credential-files` | `database.credentials`, `api.credentials`, `api-control.credentials` (root:`<Group>` 0640) and `apps.credentials` (`<User>:<Group>` 0400) are regular, not links, one link; an absent file is fine. **Metadata only: no credential file is ever opened.** |
| 12 | `installer-state` | no leftover of an interrupted run (WARN lists leftovers and unexpected entries; they are reported, never removed) |
| 13 | `ops-check` | a statement: status runs no Oracle OPS script, no `java` and no database access |

**validate** runs those 13 and then checks the pinned release's own tools against the **local Oracle OPS repository**
(`--source-repo`, default `/u01/oracle_ops`), without network:

| Check | What happens |
|---|---|
| `source-repository` | the path is a real directory with a real `.git`, with no `.git/info/attributes`, grafts or replace refs (they could change what `git archive` produces) |
| `source-commit` | `git rev-parse --verify <pinned commit>` finds the pinned commit |
| `source-archive` | `git archive` of the pinned commit, **only the six files below**, written to a staging directory (never the working tree) |
| `source-verify` | the archive holds only regular files and directories with safe names; it is extracted by root with `--no-same-owner --no-same-permissions`; the extracted files are exactly the six expected ones, each with the SHA-256 recorded in this installer; `service/VERSION` equals the pinned version |
| `config-validate` | `config-migrate.sh validate --home <home>` from the verified copy |
| `service-identity` | `service-identity.sh check --home <home>` from the verified copy |
| `run-directory` | the staging directory is removed again (also on every failure and interrupt) |

The six files: `deploy/scripts/config-migrate.sh`, `service-identity.sh`, `ownership-lib.sh`, `provision-java.sh`,
`deploy/java-runtime.properties`, `service/VERSION`. If the source cannot be verified, validate stops with exit status 4
and **no Oracle OPS script is run**. git runs with the privileges of the account that owns the repository's `.git` (never
root's, unless root owns it), in `/`, in a scrubbed environment.

What status and validate **never** do: connect to a database or run SQL, use the network, start, stop or restart
anything, change a file under the installation directory, `/etc` or systemd, or open a credential or configuration file
themselves. Documented side effects (`SECURITY.md`): the new check log and the lock file in the installer's own
directories; the check's own staging directory during validate; and, in validate, `config-migrate.sh validate`'s Java tool
opens the token files itself to check them (it prints no value) and the JVM may create `hsperfdata` files in `/tmp`.

Exit status of both: `0` no problem found (warnings do not count) · `1` a check failed · `2` not root or a usage error ·
`4` the pinned source could not be verified (validate) · `6` Oracle OPS is not installed. `status` and `validate` may run
beside each other (they share the lock) but not during an install, upgrade or de-installation (exit `1`).

## Where things go

| Path | What | Who manages it |
|---|---|---|
| `/u01/oracle_ops_runtime` (default; you can choose another) | the installed Oracle OPS: `releases/<version>/`, `current`, `config/`, `logs/`, `evidence/`, `runtime/java/` | Oracle OPS scripts |
| `/etc/oracle-ops/` | Oracle OPS credential files (`database.credentials`, optional `api.credentials`, `apps.credentials`) | Oracle OPS scripts; the installer only checks them, never writes them |
| `/etc/systemd/system/oracle-ops.service`, `/etc/logrotate.d/oracle-ops` | service unit and log rotation | Oracle OPS scripts |
| `/var/lib/oracle-ops-installer/` | root-only staging area: a `run.XXXXXXXX` directory per run (the temporary download) and a lock file | installer; emptied at the end of every run |
| `/run/oracle-ops-installer.XXXXXXXX/` (or `run.XXXXXXXX/auth/`) | root-only token file and git helper for the download | installer; removed right after the download |
| `/var/log/oracle-ops-installer/` | **installer logs** (root only) | installer |

## Logs

Every run writes `/var/log/oracle-ops-installer/oracle-ops-installer-<UTC time>-<pid>.log`. The directory is mode
0700 and the file 0600, both owned by root. The newest 20 logs are kept; older installer logs are deleted
automatically, and nothing else in the directory is touched.

`status` and `validate` started from the command line write their own `oracle-ops-check-<UTC time>-<pid>.log` (same
protection) and **never delete anything**. Only the menu start-up prunes check logs, keeping the newest 20 of that name.

The log contains the output of every internal step: prerequisite checks, git, the Oracle OPS scripts, verification and
cleanup. Before it is written, the output is cleaned: the token and anything that looks like a GitHub token or a
password in a URL is replaced with `[REDACTED]`, and terminal control characters are removed.

When something fails, the installer prints a short reason and the log's path. Oracle OPS's own service log is
`<installation directory>/logs/oracle-ops.log`.

## Common problems

| Message | What to do |
|---|---|
| `run the installer as root` / `run it from a terminal` | Use `sudo bash oracle-ops-installer.sh` from an interactive terminal. |
| `operating system … is not supported` | Oracle OPS supports Oracle Linux 7 x86_64 only. |
| `Missing prerequisites` | Choose 1 to let `yum` install them, or install the printed packages yourself and run again. |
| `GitHub rejected the access token` | The token is wrong, expired or revoked. Create a new one. |
| `the access token has no access to the Oracle OPS repository` | Give the token access to `oracle-ops` with Contents: Read-only. |
| `GitHub could not be reached over HTTPS…` | Check DNS, firewall or proxy (see the proxy note above). |
| `the pinned Oracle OPS release … is not available` | The pinned commit is not in the repository (for example, history was rewritten). A corrected installer release is needed. |
| `Oracle OPS is already installed … Choose 'Upgrade Oracle OPS'` | Install never replaces an existing installation. Use Upgrade, or De-install first. |
| `release 0.1.9 is already installed … built from different source` | The host runs a build with the same version number but different code. Oracle OPS cannot install a second build under one version, so a new Oracle OPS version (and installer release) is needed. |
| `an upgrade needs both in place` | Upgrade needs the existing `config/application.yaml` and `/etc/oracle-ops/database.credentials`. |
| `the Oracle OPS setup assistant did not complete` | Read the assistant's messages (shown on screen and in the log), fix the cause and run Install again. An incomplete installation is detected and completed. |
| `did not report a healthy database connection` | The new release started but could not log in to the database. Check the database and `<dir>/logs/oracle-ops.log`. See "Rolling back". |
| `another run of the Oracle OPS Installer is in progress` | Only one install, upgrade or de-install at a time. Wait for it to finish. (`status` and `validate` may run together, but not during one of those.) |
| `lib/… does not match its recorded SHA-256 digest`, `… is missing`, `… is a symbolic link`, `… is writable by group or other users`, `… is not owned by an administrative account` (exit 2) | The installer's files are not the released ones, or the path to them is not root-owned. Install the tagged release again as described in "Download and run". |
| `Oracle OPS is not installed on this host` from `status`/`validate` (exit 6) | No unit is installed and no `--home` was given. |
| `unexpected entry /var/lib/oracle-ops-installer/…` | Something the installer did not create is in its staging area. Review and remove it as root, then run again. |

Commands printed by the Oracle OPS setup assistant name scripts inside the installer's temporary download, which is
removed at the end of the run. Run the installer again instead: Install completes an incomplete installation, and
Upgrade finishes an interrupted upgrade.

## Running it again

Running again is safe:

- **Install** when the pinned release is already installed and running reports that and changes nothing. It refuses
  any other existing installation. It offers to complete an installation directory left by an earlier, failed run.
- **Upgrade** when already on the pinned release changes nothing. It finishes an upgrade whose release was deployed but
  never activated. It refuses an installation that has the same version number built from different code.
- Leftover staging directories of an interrupted run (power loss, `kill -9`) are found and removed at the next start.
  They carry a marker, and the lock proves no other run is active. Anything else in the staging area stops the run
  rather than being deleted.

## What is removed at the end of every run

The installer always tries this, after success, failure, cancellation or an interrupt (Ctrl-C, `SIGTERM`, `SIGHUP`):

- the temporary Oracle OPS download (`/var/lib/oracle-ops-installer/run.XXXXXXXX`);
- the token file and git helper (`/run/oracle-ops-installer.XXXXXXXX`);
- the token in memory.

It never removes the installed runtime, the credential files, your git configuration, or anything it did not create.
If cleanup fails, the installer says so and names the path, separately from the result of the action itself.
Ordinary deletion does not securely erase data on disk.

## What remains after a successful installation

Oracle OPS in the installation directory, running as `oracle-ops.service` (enabled), its credential files in
`/etc/oracle-ops/`, its unit and log-rotation file, and the installer's own logs in `/var/log/oracle-ops-installer/`. No
copy of the Oracle OPS source code remains on the host.

## Rolling back

Oracle OPS keeps the previous release after an upgrade. Rollback is Oracle OPS's `activate-release.sh --home <dir>
--release <previous version>`. That script is part of the Oracle OPS repository, not of this installer: the installer
writes the exact command to the log when an upgrade fails, and the installer itself has no rollback action. A failed
health check after an upgrade is **not** rolled back automatically, in line with Oracle OPS's own deployment design.

## Exit status

`0` done (or nothing to do, or no problem found) · `1` the action failed (a check failed) · `2` cannot run as invoked
(not root, a usage error, an unsafe installer path) · `3` prerequisites missing · `4` source access or verification
failed (including a pinned source that `validate` cannot verify) · `5` cancelled by you · `6` the action does not apply
to this host (nothing changed; for `status`/`validate`: Oracle OPS is not installed) · `129`/`130`/`143` interrupted

## More

- `SECURITY.md`: how secrets, files and privileges are protected, and the known limitations.
- `docs/DEVELOPER.md`: repository layout, tests, the Oracle OPS interface the installer depends on, and how to release.
