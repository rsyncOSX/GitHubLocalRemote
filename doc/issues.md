# GitHub scan robustness review

Date: 2026-07-26  
Reviewed branch: `version-1.0.2`  
Baseline: `main`

## Verdict

The implementation on `version-1.0.2` is operationally more robust than the
implementation on `main` and should be the basis for future work.

The `main` implementation is smaller, but it runs Git synchronously, reads
standard output and standard error sequentially, cannot interrupt an active Git
command, has no fetch deadline, may wait for interactive credentials, and does
not publish any projects until the complete folder scan finishes.

The current implementation:

- drains standard output and standard error concurrently;
- installs the process termination handler before launching Git;
- closes the parent copies of the pipe writers so readers receive EOF;
- supports cancellation and command timeouts;
- prevents terminal, credential-manager, and SSH authentication prompts;
- limits a repository fetch to 15 seconds and falls back to cached references;
- publishes each GitHub project as soon as that repository has been scanned;
- no longer depends on the ProcessGit package that introduced the observed
  scan stall.

The full serial test suite currently passes: 16 tests with no failures.

## Failure analysis

The reported scan stopped after the first repository because the ProcessGit
execution path could remain suspended after the Git child had already exited.
The application therefore waited for a process result that would never arrive,
leaving the progress display at the current repository and withholding the
catalog result.

The current runner avoids that failure mode by explicitly managing pipe
ownership and using a termination event registered before process launch.
Repeated sequential Git commands, timeout cancellation, and incremental scan
updates are covered by tests.

Compared with `main`, the current implementation also addresses two independent
ways a scan could appear frozen:

1. A fetch could wait indefinitely for credentials or an unreachable transport.
2. Successfully scanned projects were not exposed to the UI until every
   repository had finished.

## Remaining issues

### P1 — Scan cancellation does not propagate through `Task.detached`

`RepositoryScanner.scan` still wraps the scan in `Task.detached`. A detached task
does not inherit the lifetime or cancellation state of the task awaiting it.
Consequently, selecting another folder or starting another scan may cancel the
`AppModel` task without cancelling the detached scan and its active Git command.
An older scan could continue consuming resources or publish stale updates.

Recommended fix:

- Remove the `Task.detached` wrapper now that Git execution is asynchronous.
- Run the scan as structured child work so cancellation propagates from
  `AppModel` into `RepositoryScanner` and `GitCommandRunner`.
- Add a regression test that starts a deliberately slow scan, cancels it, then
  verifies that its Git process ends and that it cannot publish further updates.

Acceptance criteria:

- Starting scan B cancels scan A.
- No progress or catalog update from scan A is accepted after cancellation.
- The active Git subprocess from scan A terminates promptly.

### P2 — The 15-second fetch timeout is a fixed policy

The deadline prevents an infinite stall, but 15 seconds may be too short for a
large repository or a slow network. A timed-out fetch falls back safely to
cached references, but the displayed comparison may be stale.

Recommended fix:

- Make the fetch deadline configurable in one application-level policy.
- Consider a default between 30 and 60 seconds.
- Preserve the current cached-reference warning when a deadline expires.
- Ideally distinguish a timeout warning from other fetch failures.

Acceptance criteria:

- A slow fetch cannot block the catalog indefinitely.
- The configured deadline is covered by a deterministic test.
- A timeout is reported explicitly and cached references remain visible.

### P2 — Cancellation terminates only the direct Git process

The cancellation handler terminates the `git` process and closes the local pipe
readers. Git may spawn transport children such as SSH or `git-remote-https`.
Those descendants normally exit with Git, but the implementation does not
guarantee that the whole process tree is terminated.

Recommended fix:

- Investigate launching Git in its own process group and terminating the group,
  or otherwise track and terminate transport children.
- Retain the existing SSH batch/connect timeout as defense in depth.
- Add a test command that spawns a child and verify that cancellation leaves no
  descendant running.

Acceptance criteria:

- Timeout and user cancellation leave no Git transport process behind.
- Output readers always unblock during cancellation.

### P2 — Existing parity tests compare the runner with itself

Several tests create both `originalRunner` and `processGitRunner` as
`GitCommandRunner`. Those comparisons can only prove that two executions of the
same implementation returned equivalent results; they do not compare the
current runner with an independent reference implementation.

Recommended fix:

- Replace the parity framing with behavior-based tests.
- Assert exact output, error output, exit status, working-directory behavior,
  large concurrent stdout/stderr handling, cancellation, and timeout behavior.
- Rename `GitCommandRunner2Tests` to `GitCommandRunnerTests`.

Acceptance criteria:

- Every test can fail because of a specific contract violation.
- No expected value is produced by the same code path being tested.
- Include a high-volume stdout/stderr test to guard against pipe deadlocks.

### P3 — Non-interactive SSH policy overrides `GIT_SSH_COMMAND`

The runner sets `GIT_SSH_COMMAND` for every Git invocation. SSH still reads the
user's SSH configuration, but an existing environment-provided wrapper or
custom command is replaced.

Recommended fix:

- Apply network-specific environment overrides only to commands that need them,
  especially `fetch`.
- Decide whether an existing `GIT_SSH_COMMAND` should be preserved or whether
  the application should document that scans always use `/usr/bin/ssh`.
- Add coverage for repositories that rely on standard SSH configuration.

Acceptance criteria:

- Local Git commands are not given unnecessary network policy.
- Fetch remains non-interactive.
- The behavior for a pre-existing `GIT_SSH_COMMAND` is explicit and tested.

## Recommended order

1. Remove `Task.detached` and add cancellation-isolation coverage.
2. Make the fetch deadline configurable and improve timeout reporting.
3. Strengthen process-tree cancellation.
4. Replace the self-parity tests with contract tests.
5. Scope and document the SSH environment policy.

After the P1 item and the timeout-policy decision are complete, the current
implementation can reasonably be considered a hardened replacement for the
scanner on `main`.
