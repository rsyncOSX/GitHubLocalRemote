//
//  GitCommandRunner2.swift
//  GitBranchStatus
//
//  Created by Thomas Evensen on 26/07/2026.
//

import Foundation
import ProcessCommand

struct GitCommandRunner2: Sendable {
    func run(
        _ arguments: [String],
        in directory: URL,
        allowFailure: Bool = false
    ) async throws -> GitCommandResult {
        try await Self.runOnMainActor(
            arguments,
            in: directory,
            allowFailure: allowFailure
        )
    }

    @MainActor
    private static func runOnMainActor(
        _ arguments: [String],
        in directory: URL,
        allowFailure: Bool
    ) async throws -> GitCommandResult {
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              FileManager.default.fileExists(
                  atPath: directory.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue
        else {
            throw GitCommandError.launchFailed(
                "The working directory does not exist: \(directory.path)"
            )
        }

        let execution = GitCommandExecution()
        let handlers = CreateCommandHandlers().createCommandHandlers(
            processTermination: { output, _ in
                execution.processDidTerminate(output: output)
            },
            updateProcess: { process in
                execution.updateProcess(process)
            },
            propagateError: { error in
                execution.processDidFail(error)
            }
        )

        let process = ProcessCommand(
            command: "/bin/sh",
            arguments: [
                "-c",
                Self.commandTransport,
                "GitCommandRunner2",
                directory.standardizedFileURL.path,
            ] + arguments,
            handlers: handlers
        )

        do {
            try process.executeProcess()
        } catch {
            throw GitCommandError.launchFailed(error.localizedDescription)
        }

        let output = try await execution.waitForCompletion()
        let result = try Self.decodeResult(from: output)

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

    /// `ProcessCommand` combines stdout and stderr and does not expose the child
    /// process's exit status or working directory. The shell keeps both streams
    /// separate, serializes them after Git exits, and writes one base64 payload
    /// for `ProcessCommand` to transport safely.
    private static let commandTransport = """
    stdout_file=$(/usr/bin/mktemp -t GitCommandRunner2.stdout) || exit 125
    stderr_file=$(/usr/bin/mktemp -t GitCommandRunner2.stderr) || exit 125
    cleanup() {
        /bin/rm -f "$stdout_file" "$stderr_file"
    }
    trap cleanup EXIT HUP INT TERM

    directory=$1
    shift
    /usr/bin/git -C "$directory" "$@" >"$stdout_file" 2>"$stderr_file"
    git_exit_code=$?

    {
        /usr/bin/printf '%s\\n' "$git_exit_code"
        /usr/bin/base64 <"$stdout_file" | /usr/bin/tr -d '\\n'
        /usr/bin/printf '\\n'
        /usr/bin/base64 <"$stderr_file" | /usr/bin/tr -d '\\n'
        /usr/bin/printf '\\n'
    } | /usr/bin/base64
    """

    private static func decodeResult(from output: [String]) throws -> GitCommandResult {
        let encodedEnvelope = output
            .joined()
            .filter { !$0.isWhitespace }

        guard let envelopeData = Data(base64Encoded: encodedEnvelope) else {
            throw GitCommandError.launchFailed(
                "ProcessCommand returned an invalid Git result."
            )
        }

        let envelope = String(decoding: envelopeData, as: UTF8.self)
        let fields = envelope.components(separatedBy: "\n")
        guard fields.count >= 3,
              let exitCode = Int32(fields[0]),
              let outputData = Data(base64Encoded: fields[1]),
              let errorData = Data(base64Encoded: fields[2])
        else {
            throw GitCommandError.launchFailed(
                "ProcessCommand returned an incomplete Git result."
            )
        }

        return GitCommandResult(
            output: String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            exitCode: exitCode
        )
    }
}

@MainActor
private final class GitCommandExecution {
    private var continuation: CheckedContinuation<[String], any Error>?
    private var pendingResult: Result<[String], GitCommandError>?
    // Retain the child process until ProcessCommand reports termination.
    private var process: Process?
    private var isComplete = false

    func updateProcess(_ process: Process?) {
        if let process {
            self.process = process
        }
    }

    func processDidTerminate(output: [String]?) {
        resolve(.success(output ?? []))
    }

    func processDidFail(_ error: Error) {
        resolve(.failure(.launchFailed(error.localizedDescription)))
    }

    func waitForCompletion() async throws -> [String] {
        if let pendingResult {
            return try pendingResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func resolve(_ result: Result<[String], GitCommandError>) {
        guard !isComplete else { return }
        isComplete = true

        guard let continuation else {
            pendingResult = result
            return
        }

        switch result {
        case let .success(output):
            continuation.resume(returning: output)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

