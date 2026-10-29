# Developer guide

## Repository layout

```
oracle-ops-installer.sh   the installer (single file; bash 4.2+; no dependencies beyond base OS tools)
README.md                 operator documentation
SECURITY.md               protections and known limitations
docs/DEVELOPER.md         this file
tests/run-tests.sh        runs everything: bash -n, ShellCheck (if installed), the hermetic suite
tests/installer-test.sh   the test cases
tests/lib.sh              sandbox, fixture repository, test doubles, assertions
tests/online-check.sh     optional: real git + github.com with a deliberately invalid token
```

The installer is one file on purpose: operators download one file and check one checksum. It can be sourced. Every
action runs from `main()`, functions marked *seam* (`is_root`, `stdin_is_tty`, `host_arch`, `is_tmpfs`,
`service_active`, `root_home`) wrap host-specific checks, and the "Host locations" globals are plain variables
that tests reassign after sourcing. They are deliberately not read from the environment, so nobody can redirect a root
run through an environment variable.

## Running the tests

```bash
tests/run-tests.sh                                   # everything
bash tests/installer-test.sh test_upgrade_success    # one test
bash tests/online-check.sh                           # optional, needs HTTPS to github.com
```

The tests need bash 4.2+, git, python3 (only to write the small test jar files), unzip and the usual coreutils. They
need **no root, no network and no access to the private Oracle OPS repository**. Everything happens in a temporary
directory, which is removed when all tests pass and kept (its path is printed) when one fails.

### Testing without the private repository

- `tests/lib.sh` builds a **fixture repository** with two commits. The first, `service/VERSION` 0.1.5, is what the
  tests pin. The second, 0.1.6, sits on the default branch and must never be installed. It contains stand-ins for the
  Oracle OPS scripts the installer calls. They record their arguments, environment variable names, umask, `TMPDIR`,
  the checked-out commit, and whether any token material is reachable while they run. Then they simulate success or a
  chosen failure.
- A **git test double** passes local commands to the real git. For `ls-remote`/`clone` of the private repository URL,
  it authenticates through the installer's **real** askpass helper and token file. It can simulate a rejected token,
  denied access, a network failure, a partial clone or a tool that prints the token. Then it clones the fixture with
  the real git.
- **systemctl** and **yum** test doubles record calls. yum can "install" a removed tool, fail, or do nothing.
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
5. Run `tests/run-tests.sh` and, ideally, ShellCheck and `tests/online-check.sh`. Then do a real installation on a
   non-production host.
6. Release a new installer version (below).

## Releasing a new installer version

1. Update `INSTALLER_VERSION` in `oracle-ops-installer.sh`.
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
