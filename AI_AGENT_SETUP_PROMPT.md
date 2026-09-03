# AI agent setup prompt

Copy the prompt below into a local AI coding agent running on the Mac that will
become an opt-in GitHub Actions burst runner.

---

You are configuring the checked-out **Mac CI Burst Runner** project on this Mac.
Read `README.md`, `SECURITY.md`, `Scripts/config.env.example`, and the scripts
before taking action.

Your objective is to install the local menu-bar controller, prepare a correct
private configuration, register one GitHub Actions self-hosted runner, and prove
that it finishes **Off and unschedulable**. Do not make the runner Available until
I explicitly approve the workflow audit and ask you to run the availability test.

Safety constraints:

1. Never print, copy, store, or commit a GitHub token. Use the existing `gh`
   keychain login and show only `gh auth status` metadata.
2. Never add credentials to `config.env`, shell history, logs, issues, commits, or
   chat output.
3. Do not reboot, shut down, or change sleep, firewall, FileVault, login, sharing,
   network, or unrelated service settings.
4. Do not stop unrelated processes or delete caches, projects, user files, runner
   workspaces, or existing runner registrations. The tiered disk guard may delete
   only the directories I explicitly configure through `CACHE_DIRS` and
   `ARTIFACT_DIR`. Do not set `CLEAN_RM=1` without asking me first; it lets the
   guard remove a configured cache tree outright.
5. Do not expose the runner to public repositories, forked pull requests, all
   organization repositories, or unreviewed workflows.
6. Do not guess the GitHub owner, scope, repository access, runner group, runner
   name, scheduling label, runner directory, or disk floor. Ask me for missing
   values as one concise group.
7. The unique burst label must be required by every eligible workflow. Do not
   treat `self-hosted`, `macOS`, or an architecture label as the availability
   switch.
8. Do not alter repository workflows without showing me the exact proposed diff
   and receiving approval.
9. Stop without registering anything if the existing runner directory conflicts,
   the package checksum cannot be verified, GitHub permissions are insufficient,
   or the selected runner group is not restricted as intended.

Procedure:

1. Run read-only preflights: confirm macOS version and architecture, available
   disk, Swift, `gh`, `jq`, GitHub authentication status, and whether the proposed
   runner directory or runner name already exists. Redact any sensitive output.
2. Ask me for and confirm:
   - organization or repository scope;
   - GitHub owner and repository only when repository-scoped;
   - a unique runner name;
   - a unique burst label;
   - runner directory;
   - minimum free GiB, and the soft threshold if it should not be twice that;
   - disk guard cache directories, artifact directory and retention count, and
     any sweep or clean command templates, if this Mac should reclaim space
     instead of only refusing jobs;
   - organization runner group, if applicable;
   - optional repositories used only for current-job links.
3. For organization scope, have me confirm that the runner group allows only the
   intended trusted private repositories and, if supported, trusted workflows.
4. Inspect intended workflow `runs-on` selectors. Confirm every job meant for this
   Mac requires the exact burst label. Report mismatches; do not edit them without
   approval.
5. Run `./Scripts/install-controller.sh`. Edit only the generated private
   `~/Library/Application Support/MacCIBurst/config.env`; never edit the checked-in
   example with real values.
6. Run the project tests. If they fail, diagnose within this project only and do
   not proceed to registration.
7. Run the installed `setup-runner.sh`. It must verify the official archive digest
   and finish by removing the burst label and stopping the runner service.
8. Verify with both the local JSON status and GitHub API that:
   - the runner is registered;
   - desired state is `off`;
   - the runner is not busy;
   - the service is stopped/offline;
   - the burst label is absent;
   - the disk floor and soft threshold are correctly reported;
   - no credentials or personal paths were written inside this Git repository.
9. Report the configuration using redacted/generic descriptions. Do not make the
   runner Available until I explicitly request the harmless lifecycle test.
10. When approved, run one harmless workflow and demonstrate Available → Busy →
    Drain → Off. Drain must remove eligibility before waiting for the active job,
    and Off must refuse while GitHub reports the runner busy.

At completion, provide a short operator handoff: menu colors/states, CLI commands,
disk threshold, safe workflow selector, how to drain, and the exact evidence that
the runner is currently Off.

---
