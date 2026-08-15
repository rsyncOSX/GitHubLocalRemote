@testable import GitBranchStatus
import Darwin
import Foundation
import Testing

@Suite("Git command runner", .serialized)
struct GitCommandRunnerTests {
    private let runner = GitCommandRunner()

    @Test
    func testSuccessfulCommandReturnsExactOutputAndStatus() async throws {
        let result = try await runner.run(
            ["rev-parse", "--show-toplevel"],
            in: repositoryURL
        )

        #expect(result.output == repositoryURL.standardizedFileURL.path)
        #expect(result.errorOutput == "")
        #expect(result.exitCode == 0)
    }

    @Test
    func testWorkingDirectoryContainingSpacesIsPreserved() async throws {
        let directory = try makeTemporaryDirectory(prefix: "Git Command Runner ")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await runner.run(["init", "--quiet"], in: directory)
        let result = try await runner.run(
            ["rev-parse", "--show-toplevel"],
            in: directory
        )

        #expect(result.output == canonicalPath(directory))
        #expect(result.exitCode == 0)
    }

    @Test
    func testAllowedFailureReturnsItsOwnContract() async throws {
        let arguments = [
            "rev-parse",
            "--verify",
            "refs/heads/__GitCommandRunner_missing_branch__",
        ]

        let result = try await runner.run(
            arguments,
            in: repositoryURL,
            allowFailure: true
        )

        #expect(result.exitCode != 0)
        #expect(result.output == "")
        #expect(!(result.errorOutput.isEmpty))
    }

    @Test
    func testDisallowedFailureThrowsCommandError() async throws {
        let arguments = [
            "rev-parse",
            "--verify",
            "refs/heads/__GitCommandRunner_missing_branch__",
        ]

        do {
            _ = try await runner.run(arguments, in: repositoryURL)
            Issue.record("Expected GitCommandError.commandFailed")
        } catch let GitCommandError.commandFailed(
            actualArguments,
            exitCode,
            message
        ) {
            #expect(actualArguments == arguments)
            #expect(exitCode != 0)
            #expect(!(message.isEmpty))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func testStandardOutputAndErrorRemainSeparate() async throws {
        let result = try await runner.run(
            [
                "-c",
                "alias.streams=!f() { echo stdout-data; echo stderr-data >&2; return 7; }; f",
                "streams",
            ],
            in: repositoryURL,
            allowFailure: true
        )

        #expect(result.output == "stdout-data")
        #expect(result.errorOutput == "stderr-data")
        #expect(result.exitCode == 7)
    }

    @Test
    func testLargeConcurrentOutputDoesNotDeadlock() async throws {
        let result = try await runner.run(
            [
                "-c",
                "alias.volume=!i=0; while [ $i -lt 20000 ]; do echo out-$i; echo err-$i >&2; i=$((i + 1)); done",
                "volume",
            ],
            in: repositoryURL
        )

        let outputLines = result.output.split(whereSeparator: \.isNewline)
        let errorLines = result.errorOutput.split(whereSeparator: \.isNewline)
        #expect(outputLines.count == 20_000)
        #expect(errorLines.count == 20_000)
        #expect(outputLines.first == "out-0")
        #expect(outputLines.last == "out-19999")
        #expect(errorLines.first == "err-0")
        #expect(errorLines.last == "err-19999")
    }

    @Test
    func testCommandsUseTheNonInteractiveEnvironment() async throws {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "custom-prompt"
        environment["GCM_INTERACTIVE"] = "custom-interactive"
        environment["GIT_SSH_COMMAND"] = "/custom/ssh-wrapper"
        let configuredRunner = GitCommandRunner(baseEnvironment: environment)
        let arguments = [
            "-c",
            "alias.environment=!printf '%s|%s|%s' \"$GIT_TERMINAL_PROMPT\" \"$GCM_INTERACTIVE\" \"$GIT_SSH_COMMAND\"",
            "environment",
        ]

        let result = try await configuredRunner.run(arguments, in: repositoryURL)
        #expect(result.output == "0|Never|/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=10")
    }

    @Test
    func testConfiguredTimeoutReturnsPromptly() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await runner.run(
                ["-c", "alias.wait=!/bin/sleep 10", "wait"],
                in: repositoryURL,
                timeout: .milliseconds(100)
            )
            Issue.record("Expected GitCommandError.timedOut")
        } catch let GitCommandError.timedOut(arguments) {
            #expect(arguments.last == "wait")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(startedAt.duration(to: clock.now) < .seconds(2))
    }

    @Test
    func testTimeoutTerminatesTheEntireProcessGroup() async throws {
        let directory = try makeTemporaryDirectory(prefix: "GitProcessGroup-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("process-tree.sh")
        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        try writeProcessTreeScript(to: scriptURL)

        let arguments = [
            "-c",
            "alias.tree=!/bin/sh \(scriptURL.path) \(parentPIDURL.path) \(childPIDURL.path)",
            "tree",
        ]

        do {
            _ = try await runner.run(
                arguments,
                in: repositoryURL,
                timeout: .milliseconds(300)
            )
            Issue.record("Expected GitCommandError.timedOut")
        } catch is GitCommandError {
            // Expected timeout.
        }

        let parentPID = try processID(in: parentPIDURL)
        let childPID = try processID(in: childPIDURL)
        try await waitUntil(timeout: .seconds(2)) {
            !self.processExists(parentPID) && !self.processExists(childPID)
        }
    }

    @Test
    func testCallerCancellationTerminatesTheEntireProcessGroup() async throws {
        let directory = try makeTemporaryDirectory(prefix: "GitCancellation-")
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("process-tree.sh")
        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        try writeProcessTreeScript(to: scriptURL)

        let commandRunner = runner
        let workingDirectory = repositoryURL
        let task = Task {
            try await commandRunner.run(
                [
                    "-c",
                    "alias.tree=!/bin/sh \(scriptURL.path) \(parentPIDURL.path) \(childPIDURL.path)",
                    "tree",
                ],
                in: workingDirectory
            )
        }

        try await waitUntil(timeout: .seconds(2)) {
            FileManager.default.fileExists(atPath: childPIDURL.path)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let parentPID = try processID(in: parentPIDURL)
        let childPID = try processID(in: childPIDURL)
        try await waitUntil(timeout: .seconds(2)) {
            !self.processExists(parentPID) && !self.processExists(childPID)
        }
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private func canonicalPath(_ url: URL) -> String {
        let resolvedPath = url.path.withCString { realpath($0, nil) }
        guard let resolvedPath else { return url.standardizedFileURL.path }
        defer { free(resolvedPath) }
        return String(cString: resolvedPath)
    }

    private func writeProcessTreeScript(to url: URL) throws {
        let script = """
        #!/bin/sh
        echo $$ > "$1"
        trap '' TERM
        /bin/sleep 30 &
        child=$!
        echo "$child" > "$2"
        wait "$child"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
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
}
