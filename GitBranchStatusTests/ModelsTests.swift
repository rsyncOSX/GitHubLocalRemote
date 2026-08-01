@testable import GitBranchStatus
import XCTest

final class ModelsTests: XCTestCase {
    @MainActor
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
            XCTFail("Expected the scan to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
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

        XCTAssertEqual(
            receivedProgress,
            [
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
            ]
        )
    }

    @MainActor
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

        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.projects.map(\.name), ["First"])
        XCTAssertEqual(result.projects.map(\.name), ["First"])
    }

    @MainActor
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

        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.branches.first?.status, .unknown)
        XCTAssertNotNil(project.warning)
        XCTAssertNotEqual(project.branches.first?.status, .inSync)
    }

    @MainActor
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

        XCTAssertEqual(result.candidateDirectoryCount, 4)
        XCTAssertEqual(result.gitRepositoryCount, 3)
        XCTAssertEqual(result.githubRepositoryCount, 2)
        XCTAssertEqual(result.projects.map(\.name), ["Nested", "TopLevel"])
        XCTAssertEqual(
            receivedProgress,
            [
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
            ]
        )
    }

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

        XCTAssertEqual(checking.message, "Checking GitBranchStatus (2 of 5)…")
        XCTAssertFalse(checking.isFinished)
        XCTAssertEqual(finished.message, "Finished GitBranchStatus (2 of 5)")
        XCTAssertTrue(finished.isFinished)
    }

    func testRepositoryScanProgressDescribesQualifiedRepositories() {
        let progress = RepositoryScanProgress.foundRepositories(
            githubRepositoryCount: 2,
            gitRepositoryCount: 3,
            candidateDirectoryCount: 8
        )

        XCTAssertEqual(
            progress.message,
            "Found 2 GitHub repositories among 3 Git repositories in 8 folders."
        )
        XCTAssertFalse(progress.isFinished)
    }

    func testBranchComparisonClassifiesAllCommitRelationships() {
        XCTAssertEqual(BranchComparison.classify(ahead: 0, behind: 0), .inSync)
        XCTAssertEqual(BranchComparison.classify(ahead: 3, behind: 0), .localAhead)
        XCTAssertEqual(BranchComparison.classify(ahead: 0, behind: 2), .remoteAhead)
        XCTAssertEqual(BranchComparison.classify(ahead: 4, behind: 1), .diverged)
    }

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

        XCTAssertEqual(branch.statusDetail, "Could not compare commits")
        XCTAssertTrue(BranchFilter.attention.includes(branch))
        XCTAssertFalse(BranchFilter.inSync.includes(branch))
    }

    func testEmptyWarningsAreNotPresentedAsRepositoryProblems() {
        XCTAssertNil(RepositoryWarnings.combine([]))
        XCTAssertNil(RepositoryWarnings.combine([nil, "", "  \n  "]))

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

        XCTAssertNil(project.warningMessage)
    }

    func testRepositoryWarningsAreTrimmedAndCombined() {
        XCTAssertEqual(
            RepositoryWarnings.combine(["  Fetch failed.  ", nil, "Compare failed.\n"]),
            "Fetch failed.\nCompare failed."
        )
    }

    func testParsesHTTPSGitHubRemote() {
        let remote = GitHubRemote.parse("https://github.com/openai/codex.git")

        XCTAssertEqual(remote?.owner, "openai")
        XCTAssertEqual(remote?.repository, "codex")
        XCTAssertEqual(remote?.webURL.absoluteString, "https://github.com/openai/codex")
    }

    func testParsesSCPStyleGitHubRemote() {
        let remote = GitHubRemote.parse("git@github.com:openai/codex.git")

        XCTAssertEqual(remote?.owner, "openai")
        XCTAssertEqual(remote?.repository, "codex")
    }

    func testRejectsNonGitHubAndMalformedRemote() {
        XCTAssertNil(GitHubRemote.parse("https://gitlab.com/openai/codex.git"))
        XCTAssertNil(GitHubRemote.parse("git@notgithub.com:openai/codex.git"))
        XCTAssertNil(GitHubRemote.parse("https://github.com/owner"))
        XCTAssertNil(GitHubRemote.parse(""))
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
