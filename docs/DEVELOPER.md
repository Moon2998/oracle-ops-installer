# Developer guide

## Repository layout

```
oracle-ops-installer.sh   entry: INSTALLER_VERSION, the pinned Oracle OPS release (OPS_COMMIT, OPS_VERSION), the Oracle OPS file
                          manifest (OPS_FILE_MANIFEST, used by "validate"), the library manifest (LIB_MANIFEST), the library
                          loader (ldr_*) and main()
lib/env.sh                host locations and limits (plain globals), the seams (is_root, stdin_is_tty, host_arch, is_tmpfs,
                          service_active, root_home, service_state, proc_owner_exe, run_as_repo_owner, account_uid, group_gid,
                          port_in_use, memory_total_mb, restart_service, clear_screen)
lib/common.sh             output and logging, child processes, ending a run, prompts, validation helpers
lib/state.sh              the protected log, lock and staging directory (the menu start-up)
lib/prereq.sh             prerequisites
lib/installation.sh       the existing installation and its verification
lib/source.sh             token, access check, download, verification
lib/discover.sh           read-only environment discovery for Fresh Installation (0.3.0)
lib/api-keys.sh           the two REST API keys: generate, write (never replace), replace (Reconfigure), strict read, menu 7
lib/api-catalogue.sh      the API catalogue of the pinned release and menu 6 View APIs (status from the service log)
lib/db-tool.sh            the database tool's Java source (OpsSchemaDeploy: split / check / deploy), written into the run dir
lib/db-deploy.sh          the DBA SQL, the verified copy of the release's database scripts, the OPS_OWNER step
lib/ops-install.sh        Fresh Installation (menu 1): questions, review, DBA SQL, JDK, database objects, keys, setup
                          assistant, network listener, final validation, key display
lib/ops-upgrade.sh, ops-deinstall.sh   Upgrade (menu 2), Uninstall (menu 9)
lib/ops-credentials.sh    Reconfigure (menu 3): WebLogic credential, DB password guidance, regenerate the API keys
lib/ops-views.sh          menu 8 View Configuration (read-only)
lib/check-startup.sh      the strict command-line start-up and exit of status/validate; prune_check_logs for the menu start-up
lib/ops-status.sh         the status items, the item runner, op_status (menu 5)
lib/ops-validate.sh       the pinned-source checks, validate_run, op_validate (menu 4)
lib/menu.sh               usage, parse_args, parse_check_args, menu
README.md                 operator documentation
SECURITY.md               protections and known limitations
docs/DEVELOPER.md         this file
tests/run-tests.sh        runs everything: bash -n, ShellCheck (if installed), the manifest check, the hermetic suite, the
                          comparison with the single-file baseline, the mutation tests
tests/installer-test.sh   the install/upgrade/de-install/credential tests and the integrity (loader) tests
tests/check-tests.sh      the status/validate tests, the security-boundary tests, the static guard tests (sourced by the above)
tests/lib.sh              sandbox, fixture repository, test doubles, assertions
tests/update-lib-digests.sh   regenerates (or --check) the library manifest in the entry script
tests/compare-command-sequences.sh   proved the 0.2.0 split behaved like the single-file installer 96c8b73 (tests/baseline/);
                          RETIRED from run-tests.sh in 0.3.0 (the menu and the install flow changed on purpose)
tests/db-check.py         OPS_DB_SCRIPTS digests, the DBA view list and the SQL splitter against the pinned source (needs a JDK;
                          NOT RUN without one or without the pinned commit)
tests/api-catalogue-check.py   the API catalogue, key file names, minimum key length and start-up log lines against the
                          source of the pinned Oracle OPS commit (local repository; NOT RUN if the commit is not there)
tests/mutation-tests.sh, tests/mutations.py   injects harmful changes into copies; each must be detected
tests/guard-scan.py       the static guard: command-position scanner and its rules
tests/online-check.sh     optional: real git + github.com with a deliberately invalid token
```

The installer is an entry script and libraries, **verified by the entry script** (SHA-256 per library, ownership of the
whole path when run as root; `SECURITY.md`, "Installer integrity"). It can be sourced: every action runs from `main()`.
Functions marked *seam* (`lib/env.sh`) wrap host-specific actions so tests can replace them, and the "Host locations"
globals are plain variables that tests reassign after sourcing. They are deliberately not read from the environment, so
nobody can redirect a root run through an environment variable. Libraries contain only function definitions and constant
assignments: nothing runs at load time (a test checks this statically).

### Changing a library: regenerate the digests

Every change to a `lib/*.sh` file must be followed by

```bash
tests/update-lib-digests.sh            # rewrites the LIB_MANIFEST block of oracle-ops-installer.sh
tests/update-lib-digests.sh --check    # what tests/run-tests.sh does: fails while the block is stale or a lib file is not listed
```

A new library is added by putting a line with a digest of 64 zeros and the library path (`lib/<name>.sh`) into the
block, in loading order, and running the script. An edited library with a stale digest is refused by the loader (exit 2)
before anything runs. `--root DIR` works on a copy (the mutation tests use it).

## Running the tests

```bash
tests/run-tests.sh                                   # everything
bash tests/installer-test.sh test_upgrade_success    # one test
bash tests/online-check.sh                           # optional, needs HTTPS to github.com
```

The tests need bash 4.2+, git, python3 (only to write the small test jar files), unzip and the usual coreutils. They
need **no root, no network and no access to the private Oracle OPS repository**. Everything happens in a temporary
directory, which is removed when all tests pass and kept (its path is printed) when one fails.

Further scripts, all run by `tests/run-tests.sh`:

```bash
bash tests/update-lib-digests.sh --check            # is the library manifest current?
bash tests/compare-command-sequences.sh             # 58 baseline tests, baseline vs this code: must be 58/58 equal
bash tests/mutation-tests.sh                        # 21 injected mutations + one without digest regeneration
python3 -I tests/guard-scan.py check .              # the static guard; "selftest" checks the scanner itself
```

To run a group of tests, pass names or prefixes that end in `_`: `bash tests/installer-test.sh test_status_ test_validate_`.

### The comparison harness (single-file baseline vs this code)

**Retired in 0.3.0** (no longer run by `tests/run-tests.sh`): 0.3.0 changes the menu and the Fresh Installation flow on
purpose, so the comparison with the 0.1.0 single-file installer no longer applies. The description below is the 0.2.0
record.

`tests/baseline/oracle-ops-installer-96c8b73.sh` is the single-file installer at commit 96c8b73 (SHA-256 pinned in the
comparison script). For each of the 58 baseline tests, every `run_installer` call is run against the baseline (menu
"Exit" is 5) and against this code (Exit is 7) in record mode, and these are compared after normalising sandbox paths,
random names and time stamps: exit status, terminal output, the Oracle OPS script trace, the git, local-git, yum,
systemctl and forbidden-tool traces, the sandbox tree and the installer log lines. **The only accepted differences**:
the menu lines "5) Status" and "6) Validate" and the number of "Exit", the prompt range `[1-5]`/`[1-7]` and the choice list
after an invalid answer, the version string, the `--help` text, and the log line `menu choice: N` of the Exit entry. A
source-identity phase also requires that every other baseline function is byte-identical (`main`: three added lines;
`parse_args`: a prelude; `menu`: items 5-7; `usage`: the text). `init_logging`, `init_state`, `prune_logs` and all four
actions are unchanged. The list is in the script (`allowed_sed`, `CHANGED_FUNCTIONS`, `LOST_CODE_ALLOWED`); extend it only
together with a reviewed change of those functions.

### Tests of the read-only checks

`tests/check-tests.sh` (hermetic, non-root; the fake service process, `systemctl show` output and repository owner are
test doubles/seams): healthy status (13 OK, exit 0), pin differences (WARN only), not installed (6), `--home` mismatch,
every kind of service/metadata/undeterminable deviation (FAIL), usage errors and non-root (2), no terminal needed; the
strict start-up (refused links, foreign owners, group/other-writable directories; other modes warn; missing directories and
lock created; leftovers reported, never removed; no pruning); the shared/exclusive lock; the **read trap** (FIFOs in place
of the configuration and credential files under a watchdog, mode-000 files, unchanged access times, marker text never in
the output or log); validate (the archive of the pinned commit only, a missing commit, repositories with attributes,
filters, replace refs or grafts, an R1 digest mismatch, a version mismatch, symlink/hardlink/`..`/absolute/extra/missing
archive entries, failing OPS checks, git only `rev-parse`/`archive` through the seam with the owner's privileges, the OPS
scripts only `config-migrate.sh validate` and `service-identity.sh check` with the staging directory as working
directory); the **security boundary** for the CLI and the menu (snapshots of `u01`, `etc`, `run`, the fixture repository
with `.git` and the installer tree before and after, with `LOG_DIR`/`STATE_DIR` at 0750, more than `LOG_KEEP` old logs, a
marked leftover and a marked token directory in place; no new file under `/tmp`); the static guard.

### Mutation tests

`tests/mutation-tests.sh` copies the installer tree, injects ONE change from `tests/mutations.py` (`systemctl restart`,
`systemctl stop`, `touch` in the home, a same-mode `chmod` and a `cat` of a credential file, `rm` of a release, `ln -sfn`
on `current`, `git clone`, `git ls-remote`, `sqlplus`, `java`, `kill`, `mktemp`, `flock -x`, `config-migrate.sh apply`,
`service-identity.sh retire`, `prune_logs` in the CLI path, leftover removal, a staging directory not removed, reading the
working tree instead of `git archive`, skipping the R1 digest check), regenerates the digests in the copy, runs the
status/validate/boundary/guard tests against it and prints which tests failed; every mutation must fail at least one. One more
mutation is made without regenerating the digests and must be refused by the loader. The unmutated copy is the control.

### Testing without the private repository

- `tests/lib.sh` builds a **fixture repository** with two commits. The first, `service/VERSION` 0.1.5, is what the
  tests pin. The second, 0.1.6, sits on the default branch and must never be installed. It contains stand-ins for the
  Oracle OPS scripts the installer calls. They record their arguments, environment variable names, umask, `TMPDIR`,
  the checked-out commit, and whether any token material is reachable while they run. Then they simulate success or a
  chosen failure. `config-migrate.sh` and `service-identity.sh` also run standalone (without the shared stub library),
  because `validate` runs them from a copy of exactly six files. The harness computes the fixture's
  `OPS_FILE_MANIFEST` (SHA-256 of the six blobs at the pinned fixture commit); tests assign it like `OPS_COMMIT`.
- A **git test double** passes local commands to the real git. For `ls-remote`/`clone` of the private repository URL,
  it authenticates through the installer's **real** askpass helper and token file. It can simulate a rejected token,
  denied access, a network failure, a partial clone or a tool that prints the token. Then it clones the fixture with
  the real git.
- **systemctl** and **yum** test doubles record calls (`$SB/systemctl-trace`). yum can "install" a removed tool, fail, or do
  nothing. systemctl answers `is-active` and `show` (configurable through `$SB/systemctl-show`, `systemctl-show-fail`,
  `mainpid`). Forbidden-tool sentinels (`sqlplus sql java curl wget nc ssh scp rsync journalctl logrotate`) record any call
  in `$SB/forbidden-trace`; a sentinel `java` sits in the fake runtime directory.
- Each test gets a sandbox with its own `/var/lib`, `/var/log`, `/run`, `/etc`, installation directory and a curated
  `PATH` (so a missing tool can be simulated). `run_installer` sources the installer, points every host location into
  the sandbox and runs `main` with scripted input.

### Test coverage (scenarios of the installer requirements)

| # | Scenario | Test(s) |
|---|---|---|
| 1 | all prerequisites present | `test_install_success` |
| 2 | a prerequisite is missing | `test_missing_prerequisite_manual`, `…_automatic` |
| 3 | automatic installation chosen | `test_missing_prerequisite_automatic` |
| 4 | manual installation chosen | `test_missing_prerequisite_manual` |
| 5 | installation / revalidation fails | `test_prerequisite_installation_fails`, `test_prerequisite_still_missing_after_installation` |
| 6 | authentication succeeds | `test_install_success`, `test_git_runs_isolated_and_askpass_is_host_bound` |
| 7 | authentication fails | `test_authentication_fails` (+ `online-check.sh` against github.com) |
| 8 | repository access denied | `test_repository_access_denied` |
| 9 | source reference unavailable | `test_pinned_reference_unavailable`, `test_release_version_mismatch` |
| 10 | clone fails partway | `test_partial_clone_is_removed` |
| 11 | temporary directory exists | `test_leftover_staging_directory_of_an_interrupted_run`, `test_unrelated_data_in_staging_directory_stops_the_run` |
| 12 | unsafe symlink / ownership | `test_symlinked_or_foreign_owned_directories_are_refused`, `test_installation_directory_symlink_or_foreign` |
| 13 | invalid configuration | `test_invalid_installation_directory`, `test_invalid_menu_choice`, `test_invalid_token_format_is_rejected_before_use` |
| 14 | Oracle OPS script succeeds | `test_install_success`, `test_upgrade_success` |
| 15 | Oracle OPS script fails | `test_setup_assistant_fails`, `test_upgrade_script_failure`, `test_upgrade_preflight_failure` |
| 16 | verification fails | `test_verification_failure_*`, `test_upgrade_unhealthy_database_is_a_failure`, `test_upgrade_identity_check_failure` |
| 17 | cleanup after success | `assert_clean` in every success test |
| 18 | cleanup after failure | `assert_clean` in every failure test |
| 19 | credential material removed | `authdirs=0` / `tokenfiles=0` recorded by the script stand-ins, `test_token_directory_on_tmpfs_is_used_and_removed` |
| 20 | no token in logs or output | `assert_no_token`, `test_token_is_redacted_if_a_tool_prints_it`, `test_token_without_a_known_prefix_is_redacted` |
| 21 | existing runtime not deleted | `test_existing_installation_is_never_overwritten_by_install`, `test_verification_failure_is_reported_and_runtime_kept`, `test_deinstall_success_renames_and_keeps_credentials` |
| 22 | cancellation / interruption | `test_upgrade_declined_changes_nothing`, `test_deinstall_declined`, `test_end_of_input_at_menu_is_a_cancellation`, `test_interrupt_during_installation_cleans_up` |
| 23 | repeated execution | `test_repeated_install_is_safe`, `test_upgrade_already_current`, `test_upgrade_resumes_a_deployed_but_inactive_release` |
| 24 | APEX never invoked | `test_install_runs_only_the_deploy_script_and_nothing_apex` |

Further tests cover root/terminal checks, the unsupported OS, the lock, log rotation, environment scrubbing (a
hostile `BASH_ENV`), `--java-archive`, the credential manager paths and every upgrade/de-install decision.

### Verification status

| Check | Result |
|---|---|
| `bash -n` on all scripts | run, clean |
| Hermetic suite (`tests/installer-test.sh`), Oracle Linux 7.9, bash 4.2.46, git 1.8.3.1 | run: all tests pass (count in the latest `tests/run-tests.sh` output) |
| Mutation checks: token kept too long, no literal redaction, no pinned checkout, no cleanup, askpass answering any host, no commit verification, `TMPDIR` leaked, no environment scrub, success without verification | each one makes the matching test fail |
| `tests/online-check.sh` (real git 1.8.3.1 → github.com, invalid token) | run: PASS. git sent exactly the two prompts the helper answers, and the rejection was classified correctly. |
| Real installer, non-root, on the host | run: refuses with exit 2 and creates nothing |
| ShellCheck | **not run** (not installed on the development host) |
| A real root run with a valid token: download, Oracle OPS scripts, systemd | **not run** |
| 0.3.0 (2026-11-11): `tests/run-tests.sh` on OL7.9 | run: bash -n clean; manifest current; installer tests **137 passed, 0 failed** (116 earlier + 21 new: key creation/keep/refusal, account and listener validation, no change before the review `yes`, missing API routes, no random data, menu hints, View API Keys, View APIs, View Configuration, key regeneration); API catalogue check **PASS** against `63fb7c1` (8 routes); mutation tests PASS (21 detected) |
| 0.3.0 catalogue check mutations (a route removed, POST listed as GET) | each one detected |
| 0.3.0 second build (2026-11-11): `tests/run-tests.sh` | run: installer tests **154 passed, 0 failed** (adds the DBA SQL, the database step's paths - wrong/locked/unreachable login, missing prerequisites, complete/partial schema, failed deploy, digest mismatch, JDK failure - the network listener and its restore, the self-copy); `tests/db-check.py` **PASS** (digests, DBA view list, splitter on the four real scripts: 11/6/6/11 statements, and 6 edge cases); catalogue check PASS; mutation tests PASS |
| Database tool with the real JDBC driver against a closed port | run: exit 5, "The Network Adapter could not establish the connection", password not printed; malformed URL refused (exit 2) |
| Database tool against a real Oracle database (check and deploy as OPS_OWNER) | **not run**: no disposable PDB here, and the UAT schema already exists. First real run = the new application/database server pair |
| 0.3.0 real root run (Fresh Installation end to end, self-copy, key creation in the real `/etc/oracle-ops`, network listener) | **not run** |

## The Oracle OPS interface this installer depends on

Checked against Oracle OPS at the pinned commit. If any of this changes in Oracle OPS, the installer must change with
it.

| What | Used for |
|---|---|
| Paths `service/VERSION`, `service/build.sh`, `deploy/java-runtime.properties` (`jdk.platforms=`), `deploy/scripts/{deploy-oracle-ops,install-release,activate-release,service-identity,manage-app-credentials,ownership-lib,provision-java}.sh` | source verification (all must be regular files) |
| `deploy-oracle-ops.sh --home <dir> [--java-archive <file>]`, interactive on the terminal, exit 0 only after its own health check (service active, identity check, private JDK, `is RUNNING`, database `HEALTHY`) | Install |
| `install-release.sh --preflight --home --user --group [--java-archive] <src>/service` (changes nothing) and the same without `--preflight` (refuses an existing `releases/<VERSION>`; no automatic rollback after a failed health check) | Upgrade |
| `activate-release.sh --home <dir> --release <version>` | finishing an interrupted upgrade |
| `service-identity.sh check --home <dir>` (exit 0 = compliant) | upgrade verification |
| `service-identity.sh retire --home <dir> [--apply]` (renames to `<dir>.retired-<UTC>`, removes unit and logrotate file, leaves `/etc/oracle-ops` and accounts) | De-install |
| `manage-app-credentials.sh` (identity from the installed unit; exit 0 stored, 3 declined, 1/2 failed; `apps.credentials` = service user : group, mode 0400, one link) | Update credentials |
| Unit `/etc/systemd/system/oracle-ops.service` with `User=`, `Group=`, `Environment=ORACLE_OPS_HOME=` | finding an installation |
| `<home>/current` → `<home>/releases/<version>`, `releases/<version>/VERSION`, `releases/<version>/oracle-ops.jar` with `com/oracleops/core/version.properties` (`build.gitCommit=<abbreviated id>`) | verification |
| `<home>/logs/oracle-ops.log` line `Database connectivity startup health check: HEALTHY` | upgrade verification |
| `<home>/config/application.yaml` and `/etc/oracle-ops/database.credentials` must exist for an upgrade | upgrade precondition |
| Default installation directory `/u01/oracle_ops_runtime` | Install default |

Execution assumptions the installer honours:

- Oracle OPS scripts run as root with umask 022.
- `TMPDIR` must stay unset: the database check stages files with `mktemp -d` under `/tmp` and runs them as the
  service account, which cannot enter the installer's 0700 staging directory.
- `install-release.sh` builds inside the download as root and refuses an installation directory inside the checkout.
  The staging directory is never inside an installation directory.

## How the Oracle OPS release is selected, and how to move the pin

The pin is `OPS_COMMIT`, `OPS_VERSION` and `SUPPORTED_PLATFORMS` near the top of `oracle-ops-installer.sh`. To move it:

1. Choose the Oracle OPS release commit (a full 40-character id), normally its `chore(release): prepare Oracle OPS X`
   commit. It must stay reachable from a branch or tag of the repository. A clone does not contain a commit that was
   later amended and force-pushed away, and the installer then stops with "is not available in the repository". This
   happened to the first pin (`5a13cf4`, replaced by `5c34a5e` on 2026-10-26). A protected release tag pointing to the
   pinned commit prevents it.
2. Check that `service/VERSION` there has never been deployed anywhere from different code. Oracle OPS cannot install
   a second build under the same version number, and the installer refuses one.
3. Re-check the interface table above against that commit (script names, options, exit codes, files). Update the
   installer and its stand-ins in `tests/lib.sh` where they changed.
4. Set `OPS_COMMIT`, `OPS_VERSION`, and `SUPPORTED_PLATFORMS` (from `jdk.platforms` in `deploy/java-runtime.properties`).
   **Also update `OPS_FILE_MANIFEST`** (the trust anchor of `validate`, R1): for each of the six paths in it,
   `git show <commit>:<path> | sha256sum`, in the same "digest, two spaces, path" format. If the release adds a file that
   `config-migrate.sh validate` or `service-identity.sh check` sources or reads, add it to the manifest (these two scripts
   source `ownership-lib.sh`; `service-identity.sh` also sources `provision-java.sh`, which reads
   `../java-runtime.properties`), and check that the fixture in `tests/lib.sh` (`MANIFEST_PATHS`) has it too. A wrong digest
   makes `validate` end with exit 4.
5. Run `tests/run-tests.sh` and, ideally, ShellCheck and `tests/online-check.sh`. Then do a real installation on a
   non-production host.
6. Release a new installer version (below).

## Releasing a new installer version

1. Update `INSTALLER_VERSION` in `oracle-ops-installer.sh`. (If a library changed, regenerate the digests first.)
2. Run `tests/run-tests.sh` (and ShellCheck: `shellcheck -x -s bash oracle-ops-installer.sh tests/*.sh`).
3. Commit, tag `v<version>`, and create a GitHub release.
4. Publish `sha256sum oracle-ops-installer.sh` in the release notes, so operators can compare it with the file they
   downloaded (README, "Download and run").

## Design decisions (2026-10-26)

| | Decision | Decided by |
|---|---|---|
| D1 | No AIS (agent instruction / engineering standard) sources were available. The work follows Oracle OPS's own rules and the installer requirements, and makes **no** AIS compliance claim. | repository owner |
| D2 | Temporary download in `/var/lib/oracle-ops-installer/run.XXXXXXXX`, **not** `/etc/oracle-ops`. `/etc/oracle-ops` is Oracle OPS's credential directory (re-owned by its installer), and source code must not be mixed with secrets. | repository owner |
| D3 | Menu: Install, Update credentials, Upgrade, De-install, Exit. Each action maps to the existing Oracle OPS script for it; no Oracle OPS installation logic is re-implemented. | repository owner |
| D4 | Install hands the terminal to Oracle OPS's setup assistant (`deploy-oracle-ops.sh`). `install-release.sh` alone cannot finish a first installation without configuration and database credentials, and the assistant has no quiet mode. Its output is visible during that step and also logged. | repository owner |
| D5 | Update credentials covers the WebLogic credential (the only one with a standalone Oracle OPS tool). The database password gets printed manual guidance only. | repository owner |
| D6 | The release is pinned to commit `5a13cf4456c4ed3361c74aaa39e5d36b257af894` (VERSION 0.1.5). Oracle OPS has no release tags. Moved since: `d080ad0` (0.1.8), then `63fb7c162c6b7076129b8a1f02b7bdb9b2dd44f5` (0.1.9, 2026-10-29; pushed to `main`, still no protected tag). | repository owner |
| D7 | Verification checks the build's stamped commit, not just VERSION, because the reference host runs a 0.1.5 build from different code. | implementation |
| D8 | De-install uses Oracle OPS's non-destructive `retire` (rename, no deletion). Upgrade requires typed confirmation. A failed post-upgrade health check is reported, never rolled back automatically (as in Oracle OPS). | implementation, following Oracle OPS |

## 0.3.0 decisions (2026-11-11): interactive universal menu, REST API keys

| | Decision | Decided by |
|---|---|---|
| U1 | The installer stays a separate repository: the operator clones it and runs `oracle-ops-installer.sh`, which installs Oracle OPS (it supersedes the recommendation to move it into the Oracle OPS repository, D-12 of the Oracle OPS installer design). Built on the 0.2.0 library split (branch `t2-status-validate`), in branch `interactive-installer`. | human (2026-11-11) |
| U2 | Menu: 1 Fresh Installation, 2 Upgrade Existing Installation, 3 Reconfigure Installation, 4 Validate Environment, 5 View Installation Status, 6 View APIs, 7 View API Keys, 8 View Configuration, 9 Uninstall Oracle OPS, 10 Exit. Backup/Recovery was removed from the plan. An item that does not apply stays visible with the reason. | human |
| U3 | Fresh Installation automatically creates **both** API keys (read and control) in `/etc/oracle-ops`. This reverses D2's "never write `/etc/oracle-ops`" for these two files only. | human |
| U4 | Menu 7 View API Keys shows a key from `/etc/oracle-ops` on screen (after typing `SHOW`; never logged; screen cleared). This answers the Oracle OPS design question D-17 (hand-off) with "on screen via a menu option", not a hand-off file. | human |
| U5 | The installer asks the service account and the REST API listener itself (it needs the group for the key files) and passes them, plus `--enable-api`, to Oracle OPS's setup assistant as options; the assistant still asks for the database and EBS settings and keeps its own summary and confirmation. | implementation |
| U6 | ~~Database objects are not deployed by the installer~~ - superseded the same day by U12. | implementation (scope) |
| U7 | The API catalogue is a maintained registry in `lib/api-catalogue.sh`, checked against the pinned source by `tests/api-catalogue-check.py`; status comes only from the service's own start-up line `API routes served: [...]`. | implementation |
| U8 | Start/stop (POST) is created with the release and its key, but stays off (`ebs.control.enabled: false`) after installation, as Oracle OPS's `docs/12` requires a separate, approved step to turn it on. | implementation, following Oracle OPS |
| U9 | Final validation is mandatory: success only if the service, release, commit, database health line, API routes (with `/api/v1/ops/status`), both key files and `service-identity.sh check` all pass. | implementation |
| U10 | Reconfigure > Regenerate the API keys replaces the chosen key(s) atomically, keeps no copy of the old key, and restarts only if the operator says so. | implementation |
| U11 | Clone anywhere: an unprotected installer path is no longer only refused; after a typed `yes` the installer copies itself into a root-only directory and runs the copy (the 0.2.0 refusal stays for runs without a terminal). | human (2026-11-11: "user clone the ops installer wherever they want") |
| U12 | The DBA creates the schema with fixed names (`OPS_DATA`, `OPS_OWNER`, `OPS_RUNTIME`) from SQL the installer writes and shows; the installer creates the tables and packages itself, logged in as `OPS_OWNER` (approved D-01/D-02 of the Oracle OPS design). No change to the private Oracle OPS repository: its scripts run unchanged, because the DBA SQL grants `OPS_OWNER` SELECT on the ten `DBA_*` views they check. | human (2026-11-11) |
| U13 | SQL runner: the installer's own Java tool on the release's private JDK and JDBC driver (no Oracle client on the application server), restricted SQL*Plus subset, every file parsed before the login. | implementation (recommended, not objected to) |
| U14 | The `OPS_OWNER` password is asked once per run (check + creation), one retry on ORA-01017 only. | implementation (simplicity; Oracle OPS design D-33 recommended two prompts) |
| U15 | Separate application and database servers: a non-loopback bind address with the APEX/ORDS client addresses over plain HTTP is set after the setup assistant (which accepts loopback only). With Oracle OPS 0.1.9 only About and Status are served to another host; opening the other GET APIs needs an Oracle OPS runtime change, deferred by the human ("1st will work on installer, don't touch API changes now"). | human (2026-11-11) |
| U16 | Both API keys are shown at the end of a successful installation (and stay available in menu 7). | human (2026-11-11) |
| U17 | Start/stop (POST) is checked later; it stays off. | human (2026-11-11) |

## T2 decisions (2026-11-03): split, status, validate

| | Decision | Decided by |
|---|---|---|
| D1 | Split the installer into libraries; the entry script verifies every library's SHA-256 and, run as root, the ownership of the whole path; unsafe ownership or permissions are refused. | human |
| D2 | `validate` takes the Oracle OPS files from `git archive` of the pinned commit in the local repository; never the working tree; no network. | human |
| D3 | No database access in status or validate. | human |
| D4 | The Oracle OPS side (OpsDbCheck package readiness) reads dictionary views only and never calls API procedures; it is not used by this installer. | human |
| D5 | status and validate write only their own log and lock files (and validate's own staging directory). | human |
| D6 | Root-only command-line subcommands `status` and `validate`, and menu 5 Status, 6 Validate, 7 Exit. | human |
| R1 | The trust anchor for D2 is a root-held per-file SHA-256 manifest of the extracted Oracle OPS files, carried in the entry script next to the pin; every extracted file is checked before anything runs. | review F1 |
| R2 | The menu path keeps today's start-up exactly (log pruning, `init_state` housekeeping, possible chmod of the installer's own directories) and adds only the pruning of check logs; menu 5 and 6 run the same status/validate after that. The command-line subcommands are the strict read-only path (own log name, shared lock, no pruning, no chmod, no leftover removal). | review F3 |
| R3 | `validate` may run `config-migrate.sh validate`, whose Java tool opens the token files to check them (it prints no values). The installer's own code never opens a credential file. | review F6 |
| R4 | Operator procedure: root extracts a tagged installer release (`git archive`) into a root-owned path (for example `/opt/oracle-ops-installer`, root-owned ancestors) and checks the published SHA-256 of the entry script. Documented in the README; nothing installs it. | review F7 |

### Read-only scope and its documented side effects

Inside the protected scopes (`/u01/...` installation, `/etc`, systemd, the service, the installed runtime, the Oracle OPS
repository) nothing changes. Outside them, a command-line `status` writes its check log (and creates the log/state directories
and the lock file when they are missing); `validate` additionally creates and removes one staging directory in the state
directory and runs the two Oracle OPS scripts, whose side effects are the R3 token-file read and the JVM `hsperfdata` files
in `/tmp`. The menu path adds today's housekeeping of the installer's own directories.

### Exit codes of status and validate

`0` no FAIL (warnings allowed) · `1` any FAIL, or the lock is held exclusively by an install/upgrade/de-install · `2` not root,
usage error, unsafe installer path · `3` a start-up tool is missing · `4` (validate) the pinned source could not be
verified, nothing of it was run · `6` not installed (no unit and no `--home`) · `129`/`130`/`143` interrupted.
