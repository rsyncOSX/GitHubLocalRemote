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
