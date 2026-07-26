import Foundation
import os

struct GitCommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

enum GitCommandError: LocalizedError, Sendable {
    case launchFailed(String)
    case commandFailed(arguments: [String], exitCode: Int32, message: String)
    case timedOut(arguments: [String])

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "Could not launch Git: \(message)"
        case let .commandFailed(arguments, exitCode, message):
            "git \(arguments.joined(separator: " ")) failed (\(exitCode)): \(message)"
        case let .timedOut(arguments):
            "git \(arguments.joined(separator: " ")) timed out"
        }
    }
}

struct GitCommandRunner: Sendable {
    func run(
        _ arguments: [String],
        in directory: URL,
        allowFailure: Bool = false,
        timeout: Duration? = nil
    ) async throws -> GitCommandResult {
        let processResult: ProcessResult
        do {
            if let timeout {
                processResult = try await runWithTimeout(
                    arguments: arguments,
                    in: directory,
                    timeout: timeout
                )
            } else {
                processResult = try await execute(arguments, in: directory)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitCommandError {
            throw error
        } catch {
            throw GitCommandError.launchFailed(error.localizedDescription)
        }

        let result = GitCommandResult(
            output: String(decoding: processResult.output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: String(decoding: processResult.errorOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: processResult.exitCode
        )

        if result.exitCode != 0, !allowFailure {
            throw GitCommandError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: result.errorOutput.isEmpty
                    ? "Unknown Git error"
                    : result.errorOutput
            )
        }

        return result
    }

    private func runWithTimeout(
        arguments: [String],
        in directory: URL,
        timeout: Duration
    ) async throws -> ProcessResult {
        enum Outcome: Sendable {
            case completed(ProcessResult)
            case timedOut
        }

        return try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                .completed(try await execute(arguments, in: directory))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw GitCommandError.launchFailed("Git did not return a result.")
            }
            group.cancelAll()

            switch first {
            case let .completed(result):
                return result
            case .timedOut:
                throw GitCommandError.timedOut(arguments: arguments)
            }
        }
    }

    private func execute(
        _ arguments: [String],
        in directory: URL
    ) async throws -> ProcessResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        let cancellation = ProcessCancellation()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.environment = ProcessInfo.processInfo.environment.merging(
            [
                "GIT_TERMINAL_PROMPT": "0",
                "GCM_INTERACTIVE": "Never",
                "GIT_ASKPASS": "/usr/bin/false",
                "SSH_ASKPASS": "/usr/bin/false",
                "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=10",
            ],
            uniquingKeysWith: { _, nonInteractiveValue in nonInteractiveValue }
        )
        let terminationEvents = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield(())
                continuation.finish()
            }
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            do {
                try process.run()
            } catch {
                throw GitCommandError.launchFailed(error.localizedDescription)
            }

            // The parent must close its copies. Otherwise readToEnd() can wait
            // forever for EOF after Git has already exited.
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()

            if cancellation.register(
                process,
                readHandles: [
                    standardOutput.fileHandleForReading,
                    standardError.fileHandleForReading,
                ]
            ) {
                cancellation.terminateRegisteredProcess()
            }
            defer { cancellation.finished() }

            async let output = Self.read(standardOutput.fileHandleForReading)
            async let errorOutput = Self.read(standardError.fileHandleForReading)
            async let termination: Void = Self.waitForTermination(terminationEvents)

            let (outputData, errorData, _) = try await (
                output,
                errorOutput,
                termination
            )
            try Task.checkCancellation()

            return ProcessResult(
                output: outputData,
                errorOutput: errorData,
                exitCode: process.terminationStatus
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func read(_ handle: FileHandle) async throws -> Data {
        try await Task.detached {
            try handle.readToEnd() ?? Data()
        }.value
    }

    private static func waitForTermination(_ events: AsyncStream<Void>) async {
        for await _ in events {
            return
        }
    }
}

private struct ProcessResult: Sendable {
    let output: Data
    let errorOutput: Data
    let exitCode: Int32
}

private final class ProcessCancellation: Sendable {
    private struct State {
        var process: Process?
        var readHandles: [FileHandle] = []
        var cancellationRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(_ process: Process, readHandles: [FileHandle]) -> Bool {
        state.withLock { state in
            state.process = process
            state.readHandles = readHandles
            return state.cancellationRequested
        }
    }

    func cancel() {
        let resources = state.withLock { state in
            state.cancellationRequested = true
            return (state.process, state.readHandles)
        }
        terminate(resources.0)
        resources.1.forEach { try? $0.close() }
    }

    func terminateRegisteredProcess() {
        let resources = state.withLock { ($0.process, $0.readHandles) }
        terminate(resources.0)
        resources.1.forEach { try? $0.close() }
    }

    func finished() {
        state.withLock {
            $0.process = nil
            $0.readHandles = []
        }
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}
