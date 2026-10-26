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
  5) Exit
```

| Action | What happens | Oracle OPS script used (from the pinned release) |
|---|---|---|
| Install Oracle OPS | Fresh installation. The Oracle OPS setup assistant asks for the service account, database connection and options, proves the database login, writes the configuration and installs. | `deploy-oracle-ops.sh --home <dir>` |
| Update credentials | (1) WebLogic administration account: stored for Oracle OPS. (2) Database password: shows the manual procedure; changes nothing. | `manage-app-credentials.sh` |
| Upgrade Oracle OPS | Installs the pinned release beside the current one and switches to it. The previous release stays installed. | `install-release.sh` (pre-check, then install), or `activate-release.sh` to finish an interrupted upgrade |
| De-install Oracle OPS | Stops and disables the service, removes its systemd unit and log-rotation file, and **renames** the installation directory to `<dir>.retired-<time>`. Nothing is deleted. | `service-identity.sh retire --apply` |
| Exit | Nothing is changed. | – |

Each run does one action, then exits. Every action goes through the same stages:

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

- **root** (`sudo`) and an interactive terminal.
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

```bash
curl -fLO https://raw.githubusercontent.com/Moon2998/oracle-ops-installer/<release-tag>/oracle-ops-installer.sh
sha256sum oracle-ops-installer.sh        # compare with the checksum published in the release notes
sudo bash oracle-ops-installer.sh
```

(Replace `<release-tag>` with a released tag, and adjust the address if the repository is published under a different
name. Do not pipe the download straight into `sudo bash`: check it first.)

Options: `--java-archive FILE` (air-gapped Java runtime, see above), `--help`, `--version`.

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

The installer is pinned to **one** Oracle OPS release: commit `5a13cf4456c4ed3361c74aaa39e5d36b257af894`, version
`0.1.5`. It never installs whatever happens to be the newest code on a branch. After downloading, it checks out exactly
that commit and checks that:

- the checked-out tree is that commit with no differences;
- `service/VERSION` is `0.1.5`;
- the release supports this operating system.

After installing, it checks that the deployed build carries that commit id. A new Oracle OPS release needs a new
installer release (`docs/DEVELOPER.md`).

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
| `release 0.1.5 is already installed … built from different source` | The host runs a build with the same version number but different code. Oracle OPS cannot install a second build under one version, so a new Oracle OPS version (and installer release) is needed. |
| `an upgrade needs both in place` | Upgrade needs the existing `config/application.yaml` and `/etc/oracle-ops/database.credentials`. |
| `the Oracle OPS setup assistant did not complete` | Read the assistant's messages (shown on screen and in the log), fix the cause and run Install again. An incomplete installation is detected and completed. |
| `did not report a healthy database connection` | The new release started but could not log in to the database. Check the database and `<dir>/logs/oracle-ops.log`. See "Rolling back". |
| `another run of the Oracle OPS Installer is in progress` | Only one run at a time. Wait for it to finish. |
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

`0` done (or nothing to do) · `1` the action failed · `2` cannot run as invoked · `3` prerequisites missing · `4`
source access or verification failed · `5` cancelled by you · `6` the action does not apply to this host (nothing
changed) · `129`/`130`/`143` interrupted

## More

- `SECURITY.md`: how secrets, files and privileges are protected, and the known limitations.
- `docs/DEVELOPER.md`: repository layout, tests, the Oracle OPS interface the installer depends on, and how to release.
