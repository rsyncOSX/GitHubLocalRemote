# GitHub scan robustness review

Date: 2026-08-15
Reviewed branch: `version-1.0.3`
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
- limits a repository fetch to 45 seconds and falls back to cached references;
- publishes each GitHub project as soon as that repository has been scanned;
- uses the local ProcessGit 1.1.0 package for hardened process execution.

The GitBranchStatus suite currently passes 29 tests with no failures. The local
ProcessGit 1.1.0 package adds 10 passing package-level contract tests.

## Failure analysis

The original ProcessGit 1.0.0 execution path was implicated when the reported
scan stopped after the first repository, but the package itself was not isolated
as the sole cause. The application waited for a process result that never
arrived, leaving the progress display at the current repository and withholding
the catalog result.

ProcessGit 1.1.0 avoids that failure mode by explicitly managing pipe ownership,
waiting for the spawned process directly, and terminating the complete process
group on timeout or cancellation. Repeated sequential commands, timeout
cancellation, and incremental scan updates are covered by package and app tests.

Compared with `main`, the current implementation also addresses two independent
ways a scan could appear frozen:

1. A fetch could wait indefinitely for credentials or an unreachable transport.
2. Successfully scanned projects were not exposed to the UI until every
   repository had finished.

## Resolution status

### P1 — Scan cancellation does not propagate through `Task.detached` — resolved

`RepositoryScanner.scan` now runs as structured child work. `AppModel` cancels
the previous task and uses a scan generation to reject progress, partial catalog,
completion, or error updates from an older scan.

Coverage now starts scan A with an active, deliberately slow Git subprocess,
starts scan B, and verifies that:

- scan B becomes and remains the displayed catalog;
- scan A publishes no finished progress or project update;
- scan A's Git process and child process both terminate promptly.

### P2 — The 15-second fetch timeout is a fixed policy — resolved

The fetch deadline is centralized in `RepositoryScanPolicy`, with a 45-second
application default and constructor injection for deterministic tests. A fetch
timeout is reported explicitly and cached references remain visible.

Coverage verifies the default policy, a short injected deadline, explicit
timeout reporting, and cached-reference fallback.

### P2 — Cancellation terminates only the direct Git process — resolved

ProcessGit 1.1.0 launches each command in a dedicated POSIX process group.
Timeout and user cancellation send `SIGTERM` to the group, then escalate to
`SIGKILL` after a short grace period if any group member remains. Readers stay
active until every group member closes its inherited output descriptors.

Coverage uses a command that spawns a child, ignores `SIGTERM` in the parent,
and verifies that timeout and user cancellation leave neither process running.

### P2 — Existing parity tests compare the runner with itself — resolved

`GitCommandRunner2Tests` has been replaced by `GitCommandRunnerTests`. Tests now
assert contract values directly: output, error output, exit status, working
directory, allowed and disallowed failures, timeout, cancellation, environment
policy, process-tree cleanup, and high-volume concurrent stdout/stderr.

### P3 — Non-interactive SSH policy overrides `GIT_SSH_COMMAND` — remains open

The runner sets `GIT_SSH_COMMAND` for every Git invocation. SSH still reads the
user's SSH configuration, but an existing environment-provided wrapper or
custom command is replaced.

Future work should scope network-specific overrides to fetch and explicitly
decide whether a pre-existing `GIT_SSH_COMMAND` is preserved or intentionally
replaced. Fetch must remain noninteractive.

## Current conclusion

All P1 and P2 items recorded by this review are resolved on `version-1.0.3`.
The scanner now has structured cancellation, stale-update isolation, bounded
fetches, ProcessGit 1.1.0 process-tree termination, and contract-based runner
tests. The P3 SSH environment-policy item remains open.
