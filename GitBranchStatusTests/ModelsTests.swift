@testable import GitBranchStatus
import XCTest

final class ModelsTests: XCTestCase {
    @MainActor
    func testScannerFinishesEachRepositoryBeforeCheckingTheNext() async throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("GitBranchStatusTests-\(UUID().uuidString)")
        let firstRepositoryURL = folderURL.appendingPathComponent("First")
        let secondRepositoryURL = folderURL.appendingPathComponent("Second")

        try fileManager.createDirectory(
            at: firstRepositoryURL.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: secondRepositoryURL.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: folderURL) }

        var receivedProgress: [RepositoryScanProgress] = []
        _ = try await RepositoryScanner().scan(folderURL: folderURL) { progress in
            receivedProgress.append(progress)
        }

        XCTAssertEqual(
            receivedProgress,
            [
                .discoveringRepositories,
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

    func testBranchComparisonClassifiesAllCommitRelationships() {
        XCTAssertEqual(BranchComparison.classify(ahead: 0, behind: 0), .inSync)
        XCTAssertEqual(BranchComparison.classify(ahead: 3, behind: 0), .localAhead)
        XCTAssertEqual(BranchComparison.classify(ahead: 0, behind: 2), .remoteAhead)
        XCTAssertEqual(BranchComparison.classify(ahead: 4, behind: 1), .diverged)
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
        XCTAssertNil(GitHubRemote.parse("https://github.com/owner"))
        XCTAssertNil(GitHubRemote.parse(""))
    }
}
