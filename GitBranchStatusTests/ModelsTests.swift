@testable import GitBranchStatus
import Darwin
import Foundation
import Testing

@Suite("Models and repository scanning", .serialized)
struct ModelsTests {
    @MainActor
    @Test
    func testScannerHonorsCallerCancellation() async throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitBranchStatusCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folderURL.appendingPathComponent("Child"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folderURL) }

        let task = Task {
            try await RepositoryScanner().scan(
                folderURL: folderURL,
                progress: { _ in }
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the scan to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @MainActor
    @Test
    func testStartingScanBCancelsActiveScanAAndRejectsItsUpdates() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusScanIsolation-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let slowFolderURL = rootURL.appendingPathComponent("Slow")
        let fastFolderURL = rootURL.appendingPathComponent("Fast")
        try createSyntheticRepository(in: slowFolderURL)
        try createSyntheticRepository(in: fastFolderURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        let parentPIDURL = rootURL.appendingPathComponent("parent.pid")
        let childPIDURL = rootURL.appendingPathComponent("child.pid")
        try writeScannerFixture(
            to: scriptURL,
            slowParentPIDURL: parentPIDURL,
            slowChildPIDURL: childPIDURL
        )

        let scanner = RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .seconds(10)),
            git: GitCommandRunner(executableURL: scriptURL)
        )
        let model = AppModel(scanner: scanner)

        model.selectFolder(slowFolderURL)
        try await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: childPIDURL.path)
        }

        model.selectFolder(fastFolderURL)
        try await waitUntil(timeout: .seconds(2)) {
            model.phase == .loaded && model.catalogScan?.folderURL == fastFolderURL
        }

        let parentPID = try processID(in: parentPIDURL)
        let childPID = try processID(in: childPIDURL)
        try await waitUntil(timeout: .seconds(2)) {
            !self.processExists(parentPID) && !self.processExists(childPID)
        }

        #expect(model.catalogScan?.folderURL == fastFolderURL)
        #expect(model.catalogScan?.projects.map(\.name) == ["Repository"])
        #expect(model.phase == .loaded)
        #expect(model.errorMessage == nil)
    }

    @MainActor
    @Test
    func testScannerCancellationDuringFetchEndsGitAndPublishesNoProject() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusActiveCancellation-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try createSyntheticRepository(in: rootURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        let parentPIDURL = rootURL.appendingPathComponent("parent.pid")
        let childPIDURL = rootURL.appendingPathComponent("child.pid")
        try writeScannerFixture(
            to: scriptURL,
            slowParentPIDURL: parentPIDURL,
            slowChildPIDURL: childPIDURL,
            slowPathPattern: "*"
        )

        let scanner = RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .seconds(10)),
            git: GitCommandRunner(executableURL: scriptURL)
        )
        var updates: [CatalogScan] = []
        var progress: [RepositoryScanProgress] = []
        let task = Task {
            try await scanner.scan(
                folderURL: rootURL,
                progress: { progress.append($0) },
                update: { updates.append($0) }
            )
        }

        try await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: childPIDURL.path)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the active scan to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let parentPID = try processID(in: parentPIDURL)
        let childPID = try processID(in: childPIDURL)
        try await waitUntil(timeout: .seconds(2)) {
            !self.processExists(parentPID) && !self.processExists(childPID)
        }

        #expect(updates.isEmpty)
        #expect(!(progress.contains { $0.isFinished }))
    }

    @MainActor
    @Test
    func testFetchTimeoutIsExplicitAndKeepsCachedReferencesVisible() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusTimeout-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try createSyntheticRepository(in: rootURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        let parentPIDURL = rootURL.appendingPathComponent("parent.pid")
        let childPIDURL = rootURL.appendingPathComponent("child.pid")
        try writeScannerFixture(
            to: scriptURL,
            slowParentPIDURL: parentPIDURL,
            slowChildPIDURL: childPIDURL,
            slowPathPattern: "*"
        )

        let result = try await RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .milliseconds(100)),
            git: GitCommandRunner(executableURL: scriptURL)
        ).scan(folderURL: rootURL, progress: { _ in })

        let project = try #require(result.projects.first)
        #expect(project.branches.isEmpty)
        #expect(project.warning == "Refreshing origin timed out; cached remote references are shown.")
    }

    @Test
    func testStandardScanPolicyUsesFortyFiveSecondFetchDeadline() {
        #expect(RepositoryScanPolicy.standard.fetchTimeout == .seconds(45))
    }

    @MainActor
    @Test
    func testScannerFinishesEachRepositoryBeforeCheckingTheNext() async throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("GitBranchStatusTests-\(UUID().uuidString)")
        let firstRepositoryURL = folderURL.appendingPathComponent("First")
        let secondRepositoryURL = folderURL.appendingPathComponent("Second")

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folderURL) }

        try await Self.createGitHubRepository(at: firstRepositoryURL)
        try await Self.createGitHubRepository(at: secondRepositoryURL)

        var receivedProgress: [RepositoryScanProgress] = []
        _ = try await RepositoryScanner(fetchTimeout: .milliseconds(10)).scan(
            folderURL: folderURL
        ) { progress in
            receivedProgress.append(progress)
        }

        #expect(receivedProgress == [
                .discoveringRepositories,
                .foundRepositories(
                    githubRepositoryCount: 2,
                    gitRepositoryCount: 2,
                    candidateDirectoryCount: 2
                ),
                .checking(repositoryName: "First", number: 1, total: 2),
                .finished(repositoryName: "First", number: 1, total: 2),
                .checking(repositoryName: "Second", number: 2, total: 2),
                .finished(repositoryName: "Second", number: 2, total: 2),
            ])
    }

    @MainActor
    @Test
    func testScannerPublishesAProjectAsSoonAsItIsScanned() async throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("GitBranchStatusUpdates-\(UUID().uuidString)")
        let repositoryURL = folderURL.appendingPathComponent("First")
        try fileManager.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: folderURL) }

        let git = GitCommandRunner()
        _ = try await git.run(["init", "--quiet"], in: repositoryURL)
        _ = try await git.run(
            [
                "remote",
                "add",
                "origin",
                "https://github.com/example/first.git",
            ],
            in: repositoryURL
        )

        var updates: [CatalogScan] = []
        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10)).scan(
            folderURL: folderURL,
            progress: { _ in },
            update: { updates.append($0) }
        )

        #expect(updates.count == 1)
        #expect(updates.first?.projects.map(\.name) == ["First"])
        #expect(result.projects.map(\.name) == ["First"])
    }

    @MainActor
    @Test
    func testScannerMarksUncomparableBranchesAsUnknown() async throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("GitBranchStatusUncomparable-\(UUID().uuidString)")
        let repositoryURL = folderURL.appendingPathComponent("First")
        try fileManager.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: folderURL) }

        let git = GitCommandRunner()
        _ = try await git.run(["init", "--quiet"], in: repositoryURL)
        _ = try await git.run(["config", "user.email", "tests@example.com"], in: repositoryURL)
        _ = try await git.run(["config", "user.name", "Tests"], in: repositoryURL)
        _ = try await git.run(
            ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "--quiet", "-m", "Initial"],
            in: repositoryURL
        )
        _ = try await git.run(
            ["remote", "add", "origin", "https://github.com/example/first.git"],
            in: repositoryURL
        )

        let branchName = try await git.run(
            ["symbolic-ref", "--short", "HEAD"],
            in: repositoryURL
        ).output
        let treeOID = try await git.run(["write-tree"], in: repositoryURL).output
        _ = try await git.run(
            [
                "update-ref",
                "refs/remotes/origin/\(branchName)",
                treeOID,
            ],
            in: repositoryURL
        )

        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10)).scan(
            folderURL: folderURL,
            progress: { _ in }
        )

        let project = try #require(result.projects.first)
        #expect(project.branches.first?.status == .unknown)
        #expect(project.warning != nil)
        #expect(project.branches.first?.status != .inSync)
    }

    @MainActor
    @Test
    func testScannerFindsRepositoriesInAllVisibleSubdirectories() async throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("GitBranchStatusRecursive-\(UUID().uuidString)")
        let topLevelRepositoryURL = folderURL.appendingPathComponent("TopLevel")
        let nestedRepositoryURL = folderURL
            .appendingPathComponent("Group")
            .appendingPathComponent("Nested")
        let nonGitHubRepositoryURL = folderURL.appendingPathComponent("OtherHost")
        let hiddenRepositoryURL = folderURL
            .appendingPathComponent(".Hidden")
            .appendingPathComponent("Ignored")

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folderURL) }

        try await Self.createGitHubRepository(at: topLevelRepositoryURL)
        try await Self.createGitHubRepository(at: nestedRepositoryURL)
        try await Self.createGitRepository(
            at: nonGitHubRepositoryURL,
            remoteURL: "https://gitlab.com/example/other.git"
        )
        try fileManager.createDirectory(
            at: hiddenRepositoryURL.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        var receivedProgress: [RepositoryScanProgress] = []
        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10)).scan(
            folderURL: folderURL
        ) { progress in
            receivedProgress.append(progress)
        }

        #expect(result.candidateDirectoryCount == 4)
        #expect(result.gitRepositoryCount == 3)
        #expect(result.githubRepositoryCount == 2)
        #expect(result.projects.map(\.name) == ["Nested", "TopLevel"])
        #expect(receivedProgress == [
                .discoveringRepositories,
                .foundRepositories(
                    githubRepositoryCount: 2,
                    gitRepositoryCount: 3,
                    candidateDirectoryCount: 4
                ),
                .checking(repositoryName: "Nested", number: 1, total: 2),
                .finished(repositoryName: "Nested", number: 1, total: 2),
                .checking(repositoryName: "TopLevel", number: 2, total: 2),
                .finished(repositoryName: "TopLevel", number: 2, total: 2),
            ])
    }

    @Test
    func testRepositoryScanProgressDescribesCurrentAndFinishedChecks() {
        let checking = RepositoryScanProgress.checking(
            repositoryName: "GitBranchStatus",
            number: 2,
            total: 5
        )
        let finished = RepositoryScanProgress.finished(
            repositoryName: "GitBranchStatus",
            number: 2,
            total: 5
        )

        #expect(checking.message == "Checking GitBranchStatus (2 of 5)…")
        #expect(!(checking.isFinished))
        #expect(finished.message == "Finished GitBranchStatus (2 of 5)")
        #expect(finished.isFinished)
    }

    @Test
    func testRepositoryScanProgressDescribesQualifiedRepositories() {
        let progress = RepositoryScanProgress.foundRepositories(
            githubRepositoryCount: 2,
            gitRepositoryCount: 3,
            candidateDirectoryCount: 8
        )

        #expect(progress.message == "Found 2 GitHub repositories among 3 Git repositories in 8 folders.")
        #expect(!(progress.isFinished))
    }

    @Test
    func testBranchComparisonClassifiesAllCommitRelationships() {
        #expect(BranchComparison.classify(ahead: 0, behind: 0) == .inSync)
        #expect(BranchComparison.classify(ahead: 3, behind: 0) == .localAhead)
        #expect(BranchComparison.classify(ahead: 0, behind: 2) == .remoteAhead)
        #expect(BranchComparison.classify(ahead: 4, behind: 1) == .diverged)
    }

    @Test
    func testUnknownBranchIsNotShownAsInSync() {
        let branch = BranchRecord(
            id: "unknown",
            name: "main",
            status: .unknown,
            localOID: "1234567890abcdef",
            remoteOID: "fedcba0987654321",
            aheadCount: nil,
            behindCount: nil
        )

        #expect(branch.statusDetail == "Could not compare commits")
        #expect(BranchFilter.attention.includes(branch))
        #expect(!(BranchFilter.inSync.includes(branch)))
    }

    @Test
    func testEmptyWarningsAreNotPresentedAsRepositoryProblems() {
        #expect(RepositoryWarnings.combine([]) == nil)
        #expect(RepositoryWarnings.combine([nil, "", "  \n  "]) == nil)

        let project = ProjectScan(
            id: "project",
            name: "Project",
            directoryURL: URL(fileURLWithPath: "/tmp/Project"),
            remoteName: "origin",
            remoteWebURL: URL(string: "https://github.com/example/project")!,
            branches: [],
            fetchedAt: Date(),
            warning: "\n"
        )

        #expect(project.warningMessage == nil)
    }

    @Test
    func testRepositoryWarningsAreTrimmedAndCombined() {
        #expect(
            RepositoryWarnings.combine(["  Fetch failed.  ", nil, "Compare failed.\n"])
                == "Fetch failed.\nCompare failed."
        )
    }

    @Test
    func testParsesHTTPSGitHubRemote() {
        let remote = GitHubRemote.parse("https://github.com/openai/codex.git")

        #expect(remote?.owner == "openai")
        #expect(remote?.repository == "codex")
        #expect(remote?.webURL.absoluteString == "https://github.com/openai/codex")
    }

    @Test
    func testParsesSCPStyleGitHubRemote() {
        let remote = GitHubRemote.parse("git@github.com:openai/codex.git")

        #expect(remote?.owner == "openai")
        #expect(remote?.repository == "codex")
    }

    @Test
    func testRejectsNonGitHubAndMalformedRemote() {
        #expect(GitHubRemote.parse("https://gitlab.com/openai/codex.git") == nil)
        #expect(GitHubRemote.parse("git@notgithub.com:openai/codex.git") == nil)
        #expect(GitHubRemote.parse("https://github.com/owner") == nil)
        #expect(GitHubRemote.parse("") == nil)
    }

    // MARK: - Review fixes

    @MainActor
    @Test
    func testBranchSharingANameWithATagIsMatchedWithItsRemote() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusTagName-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = rootURL.appendingPathComponent("Repository")
        let git = try await Self.createCommittedGitHubRepository(at: repositoryURL)

        _ = try await git.run(["branch", "release"], in: repositoryURL)
        _ = try await git.run(["update-ref", "refs/tags/release", "HEAD"], in: repositoryURL)
        _ = try await git.run(["update-ref", "refs/remotes/origin/release", "HEAD"], in: repositoryURL)

        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10))
            .scan(folderURL: rootURL, progress: { _ in })

        let branches = try #require(result.projects.first).branches
        let release = branches.filter { $0.name.hasSuffix("release") }
        #expect(release.map(\.name) == ["release"])
        #expect(release.first?.status == .inSync)
    }

    @MainActor
    @Test
    func testBranchIsComparedWithItsConfiguredUpstream() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusUpstream-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = rootURL.appendingPathComponent("Repository")
        let git = try await Self.createCommittedGitHubRepository(at: repositoryURL)

        // "feature" tracks origin/topic; origin/feature does not exist.
        _ = try await git.run(["branch", "feature"], in: repositoryURL)
        _ = try await git.run(["update-ref", "refs/remotes/origin/topic", "HEAD"], in: repositoryURL)
        _ = try await git.run(["config", "branch.feature.remote", "origin"], in: repositoryURL)
        _ = try await git.run(["config", "branch.feature.merge", "refs/heads/topic"], in: repositoryURL)

        // "stale" tracks origin/gone, which has been deleted.
        _ = try await git.run(["branch", "stale"], in: repositoryURL)
        _ = try await git.run(["config", "branch.stale.remote", "origin"], in: repositoryURL)
        _ = try await git.run(["config", "branch.stale.merge", "refs/heads/gone"], in: repositoryURL)

        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10))
            .scan(folderURL: rootURL, progress: { _ in })
        let branches = try #require(result.projects.first).branches

        let feature = try #require(branches.first { $0.name == "feature" })
        #expect(feature.status == .inSync)
        #expect(feature.upstreamName == "topic")
        #expect(feature.tracksDifferentlyNamedBranch)
        #expect(!branches.contains { $0.name == "topic" }, "origin/topic is paired, not remote-only")

        let stale = try #require(branches.first { $0.name == "stale" })
        #expect(stale.remoteOID == nil)
        #expect(stale.upstreamIsMissing)
        #expect(stale.statusDetail == "Tracked remote branch no longer exists")
        #expect(Set(branches.map(\.id)).count == branches.count)
    }

    @MainActor
    @Test
    func testRemoteOnlyBranchWithALocalNameIsKeptSeparate() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusSameName-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = rootURL.appendingPathComponent("Repository")
        let git = try await Self.createCommittedGitHubRepository(at: repositoryURL)

        // Local "work" tracks origin/other, so origin/work is a separate remote-only branch.
        _ = try await git.run(["branch", "work"], in: repositoryURL)
        _ = try await git.run(["update-ref", "refs/remotes/origin/other", "HEAD"], in: repositoryURL)
        _ = try await git.run(["update-ref", "refs/remotes/origin/work", "HEAD"], in: repositoryURL)
        _ = try await git.run(["config", "branch.work.remote", "origin"], in: repositoryURL)
        _ = try await git.run(["config", "branch.work.merge", "refs/heads/other"], in: repositoryURL)

        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10))
            .scan(folderURL: rootURL, progress: { _ in })
        let work = try #require(result.projects.first).branches.filter { $0.name == "work" }

        #expect(work.count == 2)
        #expect(work.first?.localOID != nil)
        #expect(work.last?.localOID == nil)
        #expect(Set(work.map(\.id)).count == 2)
    }

    @Test
    func testRescanKeepsProjectsThatAreNotYetRescanned() {
        let folderURL = URL(fileURLWithPath: "/tmp/Projects")
        let previous = Self.catalog(folderURL, projects: [
            Self.project("A", warning: "old"),
            Self.project("B", warning: "old"),
        ])
        let partial = Self.catalog(folderURL, projects: [Self.project("A", warning: "new")])

        let merged = CatalogScan.merging(partial, into: previous)
        #expect(merged.projects.map(\.name) == ["A", "B"])
        #expect(merged.projects.map(\.warning) == ["new", "old"])

        let otherFolder = Self.catalog(URL(fileURLWithPath: "/tmp/Other"), projects: [Self.project("C")])
        #expect(CatalogScan.merging(otherFolder, into: previous).projects.map(\.name) == ["C"])
        #expect(CatalogScan.merging(partial, into: nil).projects.map(\.name) == ["A"])
    }

    @MainActor
    @Test
    func testRescanDoesNotHideTheSelectedProject() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusRescan-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Self.createSyntheticRepository(named: "First", in: rootURL)
        try Self.createSyntheticRepository(named: "Second", in: rootURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        let releaseURL = rootURL.appendingPathComponent("release")
        // Fetching "Second" waits until the test creates the release file.
        try Self.writeExecutable(to: scriptURL, script: """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
            if [ "$2" = "get-url" ]; then echo "https://github.com/example/repo.git"; else echo "origin"; fi
            exit 0
        fi
        if [ "$1" = "fetch" ]; then
            case "$PWD" in *Second) while [ ! -f "\(releaseURL.path)" ]; do /bin/sleep 0.02; done ;; esac
        fi
        exit 0
        """)
        try "".write(to: releaseURL, atomically: true, encoding: .utf8)

        let model = AppModel(scanner: RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .seconds(10)),
            git: GitCommandRunner(executableURL: scriptURL)
        ))
        model.selectFolder(rootURL)
        try await waitUntil(timeout: .seconds(5)) { model.phase == .loaded }
        let secondID = try #require(model.catalogScan?.projects.last?.id)
        model.selectedProjectID = secondID

        try FileManager.default.removeItem(at: releaseURL)
        model.rescan()
        try await waitUntil(timeout: .seconds(5)) {
            model.scanProgress == .checking(repositoryName: "Second", number: 2, total: 2)
        }

        #expect(model.catalogScan?.projects.map(\.name) == ["First", "Second"])
        #expect(model.selectedProject?.id == secondID)

        try "".write(to: releaseURL, atomically: true, encoding: .utf8)
        try await waitUntil(timeout: .seconds(5)) { model.phase == .loaded }
        #expect(model.selectedProject?.id == secondID)
    }

    @MainActor
    @Test
    func testFetchDisablesAutomaticMaintenance() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusFetchArgs-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Self.createSyntheticRepository(named: "Repository", in: rootURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        let logURL = rootURL.appendingPathComponent("fetch.args")
        try Self.writeExecutable(to: scriptURL, script: """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
            if [ "$2" = "get-url" ]; then echo "https://github.com/example/repo.git"; else echo "origin"; fi
            exit 0
        fi
        if [ "$1" = "fetch" ]; then echo "$@" > "\(logURL.path)"; fi
        exit 0
        """)

        _ = try await RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .seconds(10)),
            git: GitCommandRunner(executableURL: scriptURL)
        ).scan(folderURL: rootURL, progress: { _ in })

        let arguments = try String(contentsOf: logURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(arguments == "fetch --prune --quiet --no-auto-maintenance origin")
    }

    @MainActor
    @Test
    func testMissingGitFailsTheScanInsteadOfFindingNothing() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusNoGit-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Self.createSyntheticRepository(named: "Repository", in: rootURL)

        let scanner = RepositoryScanner(
            policy: .standard,
            git: GitCommandRunner(executableURL: rootURL.appendingPathComponent("missing-git"))
        )
        do {
            _ = try await scanner.scan(folderURL: rootURL, progress: { _ in })
            Issue.record("Expected the scan to fail")
        } catch let error as RepositoryScannerError {
            guard case .gitUnavailable = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @MainActor
    @Test
    func testRepositoryGitRefusesIsReportedAsSkipped() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusSkipped-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Self.createSyntheticRepository(named: "Repository", in: rootURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        try Self.writeExecutable(to: scriptURL, script: """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
            echo "fatal: detected dubious ownership in repository" >&2
            exit 128
        fi
        exit 0
        """)

        let result = try await RepositoryScanner(
            policy: .standard,
            git: GitCommandRunner(executableURL: scriptURL)
        ).scan(folderURL: rootURL, progress: { _ in })

        #expect(result.projects.isEmpty)
        #expect(result.gitRepositoryCount == 1)
        #expect(result.skippedRepositories.map(\.directoryURL.lastPathComponent) == ["Repository"])
        #expect(result.skippedRepositories.first?.reason.contains("dubious ownership") == true)
    }

    @MainActor
    @Test
    func testScannerDoesNotSearchInsideRepositories() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusNoDescend-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = rootURL.appendingPathComponent("Outer")
        try await Self.createGitHubRepository(at: repositoryURL)
        try FileManager.default.createDirectory(
            at: repositoryURL.appendingPathComponent("node_modules/pkg/Inner/.git"),
            withIntermediateDirectories: true
        )

        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10))
            .scan(folderURL: rootURL, progress: { _ in })

        #expect(result.candidateDirectoryCount == 1)
        #expect(result.gitRepositoryCount == 1)
        #expect(result.projects.map(\.name) == ["Outer"])
    }

    // MARK: - Review fixes 7–11

    @MainActor
    @Test
    func testFetchKeepsARepositorySSHCommandAndOtherwiseUsesBatchMode() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusSSH-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Self.createSyntheticRepository(named: "Plain", in: rootURL)
        try Self.createSyntheticRepository(named: "Keyed", in: rootURL)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        try Self.writeExecutable(to: scriptURL, script: """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
            if [ "$2" = "get-url" ]; then echo "git@github.com:example/repo.git"; else echo "origin"; fi
            exit 0
        fi
        if [ "$1" = "config" ]; then
            case "$PWD" in *Keyed) echo "ssh -i ~/.ssh/project_key" ;; *) exit 1 ;; esac
            exit 0
        fi
        if [ "$1" = "fetch" ]; then
            echo "${GIT_SSH_COMMAND-unset}" > "$PWD/ssh-command"
        fi
        exit 0
        """)

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_SSH_COMMAND"] = nil
        environment["GIT_SSH"] = nil
        _ = try await RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .seconds(10)),
            git: GitCommandRunner(executableURL: scriptURL, baseEnvironment: environment)
        ).scan(folderURL: rootURL, progress: { _ in })

        func recordedCommand(_ name: String) throws -> String {
            try String(
                contentsOf: rootURL.appendingPathComponent(name).appendingPathComponent("ssh-command"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try recordedCommand("Plain") == GitCommandRunner.nonInteractiveSSHCommand)
        #expect(try recordedCommand("Keyed") == "unset")
    }

    @MainActor
    @Test
    func testChosenFolderThatIsARepositoryIsScanned() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusRootRepo-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = rootURL.appendingPathComponent("Project")
        try await Self.createGitHubRepository(at: repositoryURL)
        try FileManager.default.createDirectory(
            at: repositoryURL.appendingPathComponent("Sources/Vendored/.git"),
            withIntermediateDirectories: true
        )

        let result = try await RepositoryScanner(fetchTimeout: .milliseconds(10))
            .scan(folderURL: repositoryURL, progress: { _ in })

        #expect(result.projects.map(\.name) == ["Project"])
        #expect(result.gitRepositoryCount == 1)
        #expect(result.candidateDirectoryCount == 1)
    }

    @Test
    func testParsesGitHubSSHHostAliases() {
        let github: (String) -> String? = { $0 == "github.com-work" ? "github.com" : "gitlab.com" }

        let scp = GitHubRemote.parse("git@github.com-work:example/repo.git", resolveSSHHost: github)
        #expect(scp?.owner == "example")
        #expect(scp?.repository == "repo")
        #expect(scp?.webURL.absoluteString == "https://github.com/example/repo")

        let url = GitHubRemote.parse("ssh://git@github.com-work/example/repo.git", resolveSSHHost: github)
        #expect(url?.repository == "repo")

        #expect(GitHubRemote.parse("git@github.com-work:example/repo.git") == nil)
        #expect(GitHubRemote.parse("git@other-alias:example/repo.git", resolveSSHHost: github) == nil)
        // Aliases apply to SSH only, never to an HTTPS host.
        #expect(GitHubRemote.parse("https://github.com-work/example/repo", resolveSSHHost: github) == nil)
        #expect(GitHubRemote.parse("https://www.github.com/example/repo")?.repository == "repo")

        #expect(GitHubRemote.sshHost(of: "git@github.com-work:example/repo.git") == "github.com-work")
        #expect(GitHubRemote.sshHost(of: "ssh://git@host:22/example/repo") == "host")
        #expect(GitHubRemote.sshHost(of: "https://github.com/example/repo") == nil)
        #expect(GitHubRemote.sshHost(of: "/Users/me/repo") == nil)
    }

    @Test
    func testSSHHostResolverReadsTheSSHConfiguration() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusSSHConfig-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let configURL = rootURL.appendingPathComponent("config")
        try "Host github.com-work\n    HostName github.com\n".write(to: configURL, atomically: true, encoding: .utf8)

        let resolver = SSHHostResolver(configFileURL: configURL)
        #expect(try await resolver.hostName(for: "github.com-work") == "github.com")
        #expect(try await resolver.hostName(for: "-oProxyCommand=/usr/bin/false") == nil)
        #expect(try await resolver.hostName(for: "host;rm") == nil)
    }

    @MainActor
    @Test
    func testScannerFindsRepositoriesBehindAnSSHHostAlias() async throws {
        let rootURL = try makeTemporaryDirectory(prefix: "GitBranchStatusAliasScan-")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Self.createSyntheticRepository(named: "Repository", in: rootURL)
        let configURL = rootURL.appendingPathComponent("ssh-config")
        try "Host github.com-work\n    HostName github.com\n".write(to: configURL, atomically: true, encoding: .utf8)

        let scriptURL = rootURL.appendingPathComponent("git-fixture.sh")
        try Self.writeExecutable(to: scriptURL, script: """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
            if [ "$2" = "get-url" ]; then echo "git@github.com-work:example/repo.git"; else echo "origin"; fi
        fi
        exit 0
        """)

        let result = try await RepositoryScanner(
            policy: RepositoryScanPolicy(fetchTimeout: .seconds(10)),
            git: GitCommandRunner(executableURL: scriptURL),
            sshHostResolver: SSHHostResolver(configFileURL: configURL)
        ).scan(folderURL: rootURL, progress: { _ in })

        #expect(result.githubRepositoryCount == 1)
        #expect(result.projects.first?.remoteWebURL.absoluteString == "https://github.com/example/repo")
    }

    @Test
    func testRemoteOnlyBranchesDoNotNeedAttention() {
        let remoteOnly = BranchRecord(
            id: "remote", name: "dependabot/x", status: .remoteAhead,
            localOID: nil, remoteOID: "abc", aheadCount: nil, behindCount: nil
        )
        let behind = BranchRecord(
            id: "behind", name: "main", status: .remoteAhead,
            localOID: "abc", remoteOID: "def", aheadCount: 0, behindCount: 2
        )
        let project = ProjectScan(
            id: "p", name: "P", directoryURL: URL(fileURLWithPath: "/tmp/P"),
            remoteName: "origin", remoteWebURL: URL(string: "https://github.com/e/p")!,
            branches: [remoteOnly, behind], fetchedAt: Date(), warning: nil
        )

        #expect(!remoteOnly.needsAttention)
        #expect(!BranchFilter.attention.includes(remoteOnly))
        #expect(BranchFilter.remoteAhead.includes(remoteOnly))
        #expect(behind.needsAttention)
        #expect(project.attentionCount == 1)
        #expect(project.localBranchCount == 1)
        #expect(project.remoteOnlyCount == 1)
    }

    private static func catalog(_ folderURL: URL, projects: [ProjectScan]) -> CatalogScan {
        CatalogScan(
            folderURL: folderURL,
            candidateDirectoryCount: projects.count,
            gitRepositoryCount: projects.count,
            githubRepositoryCount: projects.count,
            projects: projects,
            scannedAt: Date()
        )
    }

    private static func project(_ name: String, warning: String? = nil) -> ProjectScan {
        ProjectScan(
            id: "/tmp/Projects/\(name)",
            name: name,
            directoryURL: URL(fileURLWithPath: "/tmp/Projects/\(name)"),
            remoteName: "origin",
            remoteWebURL: URL(string: "https://github.com/example/\(name)")!,
            branches: [],
            fetchedAt: Date(),
            warning: warning
        )
    }

    private static func createSyntheticRepository(named name: String, in folderURL: URL) throws {
        try FileManager.default.createDirectory(
            at: folderURL.appendingPathComponent(name).appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
    }

    private static func writeExecutable(to url: URL, script: String) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func createCommittedGitHubRepository(at repositoryURL: URL) async throws -> GitCommandRunner {
        try await createGitHubRepository(at: repositoryURL)
        let git = GitCommandRunner()
        _ = try await git.run(["config", "user.email", "tests@example.com"], in: repositoryURL)
        _ = try await git.run(["config", "user.name", "Tests"], in: repositoryURL)
        _ = try await git.run(
            ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "--quiet", "-m", "Initial"],
            in: repositoryURL
        )
        return git
    }

    private func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func createSyntheticRepository(in folderURL: URL) throws {
        try FileManager.default.createDirectory(
            at: folderURL
                .appendingPathComponent("Repository")
                .appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
    }

    private func writeScannerFixture(
        to scriptURL: URL,
        slowParentPIDURL: URL,
        slowChildPIDURL: URL,
        slowPathPattern: String = "*Slow*"
    ) throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "remote" ]; then
            if [ "$2" = "get-url" ]; then
                echo "https://github.com/example/repository.git"
            else
                echo "origin"
            fi
            exit 0
        fi

        if [ "$1" = "fetch" ]; then
            case "$PWD" in
                \(slowPathPattern))
                    echo $$ > "\(slowParentPIDURL.path)"
                    trap '' TERM
                    /bin/sleep 30 &
                    child=$!
                    echo "$child" > "\(slowChildPIDURL.path)"
                    wait "$child"
                    while :; do /bin/sleep 30; done
                    ;;
            esac
        fi
        exit 0
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
    }

    private func processID(in url: URL) throws -> pid_t {
        let contents = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(contents))
    }

    private func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    @MainActor
    private func waitUntil(
        timeout: Duration,
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Condition was not satisfied before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func createGitHubRepository(at repositoryURL: URL) async throws {
        try await createGitRepository(
            at: repositoryURL,
            remoteURL: "https://github.com/example/\(repositoryURL.lastPathComponent).git"
        )
    }

    private static func createGitRepository(at repositoryURL: URL, remoteURL: String) async throws {
        try FileManager.default.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true
        )

        let git = GitCommandRunner()
        _ = try await git.run(["init", "--quiet"], in: repositoryURL)
        _ = try await git.run(
            ["remote", "add", "origin", remoteURL],
            in: repositoryURL
        )
    }
}
