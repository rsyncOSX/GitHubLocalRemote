@testable import GitBranchStatus
import XCTest

final class GitCommandRunner2Tests: XCTestCase {
    private let originalRunner = GitCommandRunner()
    private let processCommandRunner = GitCommandRunner2()

    @MainActor
    func testSuccessfulCommandMatchesOriginalRunner() async throws {
        let arguments = ["rev-parse", "--show-toplevel"]

        let expected = try originalRunner.run(arguments, in: repositoryURL)
        let actual = try await processCommandRunner.run(arguments, in: repositoryURL)

        assertEqual(actual, expected)
    }

    @MainActor
    func testWorkingDirectoryContainingSpacesMatchesOriginalRunner() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Git Command Runner 2 \(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try originalRunner.run(["init", "--quiet"], in: directory)
        let arguments = ["rev-parse", "--show-toplevel"]

        let expected = try originalRunner.run(arguments, in: directory)
        let actual = try await processCommandRunner.run(arguments, in: directory)

        assertEqual(actual, expected)
    }

    @MainActor
    func testEmptyArgumentsMatchOriginalRunnerWhenFailureIsAllowed() async throws {
        let expected = try originalRunner.run(
            [],
            in: repositoryURL,
            allowFailure: true
        )
        let actual = try await processCommandRunner.run(
            [],
            in: repositoryURL,
            allowFailure: true
        )

        assertEqual(actual, expected)
    }

    @MainActor
    func testAllowedFailureMatchesOriginalRunner() async throws {
        let arguments = [
            "rev-parse",
            "--verify",
            "refs/heads/__GitCommandRunner2_missing_branch__",
        ]

        let expected = try originalRunner.run(
            arguments,
            in: repositoryURL,
            allowFailure: true
        )
        let actual = try await processCommandRunner.run(
            arguments,
            in: repositoryURL,
            allowFailure: true
        )

        assertEqual(actual, expected)
        XCTAssertNotEqual(actual.exitCode, 0)
        XCTAssertFalse(actual.errorOutput.isEmpty)
    }

    @MainActor
    func testSeparateOutputStreamsMatchOriginalRunner() async throws {
        let arguments = [
            "-c",
            "alias.runner2-parity=!f() { echo stdout-data; echo stderr-data >&2; return 7; }; f",
            "runner2-parity",
        ]

        let expected = try originalRunner.run(
            arguments,
            in: repositoryURL,
            allowFailure: true
        )
        let actual = try await processCommandRunner.run(
            arguments,
            in: repositoryURL,
            allowFailure: true
        )

        assertEqual(actual, expected)
        XCTAssertEqual(actual.output, "stdout-data")
        XCTAssertEqual(actual.errorOutput, "stderr-data")
        XCTAssertEqual(actual.exitCode, 7)
    }

    @MainActor
    func testDisallowedFailureThrowsEquivalentCommandError() async throws {
        let arguments = [
            "rev-parse",
            "--verify",
            "refs/heads/__GitCommandRunner2_missing_branch__",
        ]
        let expectedResult = try originalRunner.run(
            arguments,
            in: repositoryURL,
            allowFailure: true
        )

        do {
            _ = try await processCommandRunner.run(arguments, in: repositoryURL)
            XCTFail("Expected GitCommandError.commandFailed")
        } catch let GitCommandError.commandFailed(
            actualArguments,
            actualExitCode,
            actualMessage
        ) {
            XCTAssertEqual(actualArguments, arguments)
            XCTAssertEqual(actualExitCode, expectedResult.exitCode)
            XCTAssertEqual(actualMessage, expectedResult.errorOutput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertEqual(
        _ actual: GitCommandResult,
        _ expected: GitCommandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.output, expected.output, file: file, line: line)
        XCTAssertEqual(actual.errorOutput, expected.errorOutput, file: file, line: line)
        XCTAssertEqual(actual.exitCode, expected.exitCode, file: file, line: line)
    }
}
