# Oracle OPS Installer

One interactive command that installs, upgrades, reconfigures and de-installs **Oracle OPS** on an Oracle Linux 7 server,
creates its two REST API keys, and shows its APIs, API keys and configuration. Clone this repository and run the script
as root. You do not need to know Git or run the Oracle OPS deployment scripts yourself.

This repository contains **only the installer**. Oracle OPS itself lives in a private repository
(`Moon2998/oracle-ops`). The installer downloads one pinned, verified Oracle OPS release for the duration of a run, uses
Oracle OPS's own scripts to do the work, and then removes the download again.

> **Oracle APEX is out of scope.** This installer never installs, configures or deploys Oracle APEX, APEX applications
> or workspaces. It only shows what the APEX Web Credentials need (menu 7). Configure APEX separately, by hand.

## What it does

```
Oracle OPS Installer 0.3.2
========================
Oracle OPS release 0.1.11 (commit d5b7ea6). Oracle APEX is not installed or configured by this installer.
Installed: none found on this host

   1) Fresh Installation
   2) Upgrade Existing Installation    (not available: nothing installed)
   3) Reconfigure Installation         (not available: nothing installed)
   4) Validate Environment
   5) View Installation Status
   6) View APIs
   7) View API Keys                    (not available: no keys in /etc/oracle-ops)
   8) View Configuration               (not available: nothing installed)
   9) Uninstall Oracle OPS             (not available: nothing installed)
  10) Exit
```

An item that does not apply to the host stays visible with the reason. Choosing it anyway changes nothing (exit 6).

| # | Action | What happens | Oracle OPS script used (from the pinned release) |
|---|---|---|---|
| 1 | Fresh Installation | Read-only discovery, questions (installation directory, service account, database, REST API bind address/APEX address/port), review and `yes`. Then: the DBA SQL for the schema, download, private JDK, **the Oracle OPS tables and packages created as OPS_OWNER**, **both REST API keys**, the Oracle OPS setup assistant (OPS_RUNTIME password tested and stored), the network listener, a final validation, and **the keys shown** for APEX. See "Fresh Installation". | `provision-java.sh`, the release's `db/` and `docs/12-ddl/` scripts, `deploy-oracle-ops.sh`, `config-migrate.sh validate`, `service-identity.sh check` |
| 2 | Upgrade Existing Installation | Installs the pinned release beside the current one and switches to it. The previous release stays installed. | `install-release.sh` (pre-check, then install), or `activate-release.sh` to finish an interrupted upgrade |
| 3 | Reconfigure Installation | (1) WebLogic administration account: stored for Oracle OPS. (2) Database password: shows the manual procedure; changes nothing. (3) **Regenerate the REST API keys** (read, control or both), then an optional restart. | `manage-app-credentials.sh` for (1); none for (2) and (3) |
| 4 | Validate Environment | Status, then the checks of the pinned release, run from a verified copy taken out of the local Oracle OPS repository (no network). Changes nothing. | `config-migrate.sh validate`, `service-identity.sh check` |
| 5 | View Installation Status | Read-only report on the installed Oracle OPS (13 checks, below). Changes nothing. | none |
| 6 | View APIs | The API catalogue of the pinned release: endpoint, method, purpose, access level, key, status (from what the running service reported), and details per API (headers, parameters, example body and response). Never shows a key. | none |
| 7 | View API Keys | Shows the read key, the control key or both from `/etc/oracle-ops` with the APEX Web Credential settings, **after you type `SHOW`**, then clears the screen. Never logged. | none |
| 8 | View Configuration | Shows `config/application.yaml` (values of secret-looking keys masked) and the owner/mode of the credential files (their contents are never shown). | none |
| 9 | Uninstall Oracle OPS | Stops and disables the service, removes its systemd unit and log-rotation file, and **renames** the installation directory to `<dir>.retired-<time>`. Nothing is deleted; `/etc/oracle-ops` (including the API keys) stays. | `service-identity.sh retire --apply` |
| 10 | Exit | Nothing is changed. | – |

Each run does one action, then exits.

### Fresh Installation

Built for an **application server** (Oracle OPS) and a separate **database server** (the repository PDB, Oracle APEX),
or both on one host.

```
[1/9] Checking the system (read-only)...      prerequisites, OS, CPU, memory, disk, systemd, existing installation
[2/9] Installation settings (nothing is changed yet)...
      Installation directory [/u01/oracle_ops_runtime]:
      Service account user / group:           must exist, never root, never created
      Database host / listener port [1521]:   the listener is probed from this host
      Database service name:                  the PDB's service (not a SID)
      REST API bind address [127.0.0.1]:      127.0.0.1 if APEX/ORDS is on this host, else this host's IP
      IP address(es) of the APEX/ORDS server: only when the bind address is not loopback (at most 8)
      REST API port (1024-65535):             must be free
[3/9] Review...                               every setting and the planned changes; type yes
[4/9] Database prerequisites (DBA)...         1 = write and show the DBA SQL, wait for the DBA; 2 = already done
[5/9] Configuring source...                   GitHub access token (hidden), download of the pinned release, token removed
[6/9] Creating the Oracle OPS database objects...
                                              private JDK installed; OPS_OWNER password (hidden); read-only check;
                                              type yes; the release's own scripts run as OPS_OWNER
[7/9] Creating the REST API keys...           api.credentials (read, GET) and api-control.credentials (control, POST)
[8/9] Installing Oracle OPS...                the Oracle OPS setup assistant: OPS_RUNTIME password (tested, then stored in
                                              /etc/oracle-ops/database.credentials), node name, optional EBS; then the
                                              REST API is moved to the bind address if it is not loopback
[9/9] Final validation...                     [PASS]/[FAIL] per check, then both API keys are shown for APEX
```

**Database (fixed names):** tablespace `OPS_DATA`, users `OPS_OWNER` (owns the Oracle OPS objects) and `OPS_RUNTIME`
(the service's login).

- The **DBA SQL** (step 4, saved by default as `/root/oracle-ops-schema-<release>.sql` and shown on screen) creates the
  tablespace if missing (a datafile path, or Oracle Managed Files), both users, `CREATE SESSION/TABLE/SEQUENCE/PROCEDURE`
  for `OPS_OWNER`, `CREATE SESSION` for `OPS_RUNTIME`, and `SELECT` on the ten `DBA_*` views that the Oracle OPS scripts
  check. SQL*Plus asks the DBA for both passwords (hidden); they are not in the file. Run it in the PDB, not in
  `CDB$ROOT`: `sqlplus system@//<db-host>:<port>/<service> @oracle-ops-schema-<release>.sql`. It refuses to run twice.
- The **tables and packages** (step 6) are created by the installer itself, logged in as `OPS_OWNER`: it runs the pinned
  release's own scripts unchanged (V4_001, V4_002, the `EXECUTE` grant on `OPS_RUN_API` to `OPS_RUNTIME`, V5_001,
  V8_001), each checked against the SHA-256 recorded in the installer. No Oracle client is needed on the application
  server: the installer's own Java tool uses the release's private JDK and JDBC driver. A complete, valid schema is left
  as it is; a partly built one stops the run (the installer never drops or replaces database objects).
- The `OPS_OWNER` password is typed once, hidden, used for the check and the creation, then cleared. It is never stored,
  never in a log, never in a command line or environment. A wrong password gets one more try only (a loop could lock
  the account); a locked or expired account stops the run.

**REST API:** GET and POST are part of the release; both keys are created automatically.

- **APEX/ORDS on this host:** keep `127.0.0.1`. Every API is reachable.
- **APEX/ORDS on the database server:** enter this host's IP and the APEX/ORDS server's IP. The installer sets
  `api.bind-address` and `api.plain-http.client-addresses` (backup first, validated by Oracle OPS's `config-migrate.sh`,
  restarted and checked; restored if Oracle OPS refuses it). Plain HTTP: keys and data cross the network unencrypted
  until HTTPS is switched on. Since Oracle OPS 0.1.10 (decision A7) the allowed APEX/ORDS server gets **every** API: Managed
  Servers, host monitoring, node identity and, once `ebs.control.enabled` is true, start/stop. Limit the API port to that
  server in the firewall. Since Oracle OPS 0.1.11 the API can be switched to **HTTPS** after installation
  (`api.tls.enabled`; certificate, password file and the DB wallet steps: Oracle OPS `docs/14-Oracle-OPS-HTTPS.md`).
  Regenerate both API keys once HTTPS is on.
- Start/stop (POST) stays off (`ebs.control.enabled: false`).

**Keys at the end:** after every check passed, both keys are printed with their APEX Web Credential settings (`Valid for
URLs` = the real listener), then the screen is cleared when you press Enter. Menu 7 shows them again later. They are in
no log.

- **Nothing changes before the `yes` on the review screen**, and nothing on the host changes while the installer waits for
  the DBA.
- **Final validation:** service active, pinned release and build commit, a healthy database connection, the API routes the
  service reported (must include `/api/v1/ops/status`), the network listener (if set), both key files `root:<group>` 0640,
  and Oracle OPS's `service-identity.sh check`.

The installer prints only high-level messages and its questions. Git commands, download details and build output go to
a protected log. **One exception:** the Oracle OPS setup assistant (Fresh Installation) and credential manager
(Reconfigure) talk to you directly. Their questions and messages are shown between two dashed lines, and also recorded
in the log.

### View API Keys and APEX Web Credentials

For each key the installer prints the settings documented by Oracle OPS (`docs/08` section 7.2, `docs/12`):

| Setting | Read key (GET APIs) | Control key (POST APIs) |
|---|---|---|
| Static ID | `OPS_API_TOKEN` | `oracle-ops-api-token-action` |
| Authentication type | HTTP Header | HTTP Header |
| Credential name | `Authorization` | `Authorization` |
| Credential secret | `Bearer <read key>` | `Bearer <control key>` |
| Valid for URLs | `http://<api.bind-address>:<api.port>/` (read from the installed `application.yaml`) | same |

The key is printed only after you type `SHOW`; the screen (and, where the terminal supports it, its scroll-back) is
cleared when you press Enter. The log records that a key was displayed, never the key. After **Reconfigure > Regenerate
the REST API keys**, update the APEX Web Credential and restart Oracle OPS (the installer offers the restart); until both
are done, APEX calls with the old key fail with HTTP 401.

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

Clone this repository wherever you like and run the script as root:

```bash
git clone <installer repository URL> oracle-ops-installer
cd oracle-ops-installer
sudo bash ./oracle-ops-installer.sh
```

Before it sources any library, the entry script checks every library's SHA-256 against a list inside the entry script.
Run as root, it also checks that the whole path to it is root-owned and not writable by group or other.

- **Root-owned path** (for example a copy in `/opt/oracle-ops-installer`): it starts directly.
- **Any other path** (for example a clone in `/u01/master`, owned by `oracle`): it explains that the account owning the
  files could have changed them, asks you to type `yes`, copies the entry script and the listed libraries into a new
  root-only directory `/var/lib/oracle-ops-installer-copy.XXXXXXXX`, runs that copy (which checks every digest again),
  and removes the copy at the end. Without a terminal (scripts, `status`/`validate` from cron) it refuses instead.

The copy protects the run against changes made while it runs. It cannot prove that nobody changed the files before:
compare `sha256sum oracle-ops-installer.sh` with the value published for the release. Run by a normal user the installer
only answers `--help` and `--version`.

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

The installer is pinned to **one** Oracle OPS release: commit `d5b7ea61eb8a0477e0a8c0e9a560ab87b31fd02e`, version
`0.1.11`. It never installs whatever happens to be the newest code on a branch. After downloading, it checks out exactly
that commit and checks that:

- the checked-out tree is that commit with no differences;
- `service/VERSION` is `0.1.11`;
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
the same checks as **5 View Installation Status** and **4 Validate Environment** (Validate asks for the repository path, default `/u01/oracle_ops`,
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
| `/etc/oracle-ops/` | Oracle OPS credential files (`database.credentials`, `api.credentials`, `api-control.credentials`, optional `apps.credentials`) | Oracle OPS scripts; the installer writes only the two API key files (Fresh Installation, Reconfigure) and creates the directory (root:`<group>` 0750) if it is missing |
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
| `Oracle OPS is already installed … Choose 'Upgrade Existing Installation'` | Fresh Installation never replaces an existing installation. Use Upgrade, or Uninstall first. |
| `… is not a valid key file` / `… is a symbolic link` (API key, at the review screen) | An existing `/etc/oracle-ops/api*.credentials` is not exactly one `api.token=` / `api.control.token=` line of at least 32 characters in a single regular file. Fix or remove it (it was not changed), then run again. |
| `Port … is already in use` | Another program listens there. Choose another port. |
| `[FAIL] REST API deployed` | The service did not log `API routes served: [...]` with `/api/v1/ops/status`. Check `<dir>/logs/oracle-ops.log` and `/etc/oracle-ops/api.credentials`. |
| `release 0.1.11 is already installed … built from different source` | The host runs a build with the same version number but different code. Oracle OPS cannot install a second build under one version, so a new Oracle OPS version (and installer release) is needed. |
| `an upgrade needs both in place` | Upgrade needs the existing `config/application.yaml` and `/etc/oracle-ops/database.credentials`. |
| `the Oracle OPS setup assistant did not complete` | Read the assistant's messages (shown on screen and in the log), fix the cause and run Fresh Installation again. An incomplete installation is detected and completed; the API key files already created are kept and reused. |
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

- **Fresh Installation** when the pinned release is already installed and running reports that and changes nothing. It refuses
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
`/etc/oracle-ops/` (including both REST API keys), its unit and log-rotation file, and the installer's own logs in `/var/log/oracle-ops-installer/`. No
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
