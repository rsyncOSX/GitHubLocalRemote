@testable import GitBranchStatus
import XCTest

final class ModelsTests: XCTestCase {
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
