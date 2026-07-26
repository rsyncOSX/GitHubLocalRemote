//
//  GitCommandRunner2.swift
//  GitBranchStatus
//
//  Created by Thomas Evensen on 26/07/2026.
//

import Foundation
import ProcessGit

struct GitCommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
}

enum GitCommandError: LocalizedError, Sendable {
    case launchFailed(String)
    case commandFailed(arguments: [String], exitCode: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            "Could not launch Git: \(message)"
        case let .commandFailed(arguments, exitCode, message):
            "git \(arguments.joined(separator: " ")) failed (\(exitCode)): \(message)"
        }
    }
}

struct GitCommandRunner: Sendable {
    func run(
        _ arguments: [String],
        in directory: URL,
        allowFailure: Bool = false
    ) async throws -> GitCommandResult {
        let process = ProcessGit(
            command: "/usr/bin/git",
            arguments: arguments,
            currentDirectoryURL: directory
        )

        let processResult: ProcessGitResult
        do {
            processResult = try await process.run()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitCommandError.launchFailed(error.localizedDescription)
        }

        let result = GitCommandResult(
            output: String(decoding: processResult.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: String(decoding: processResult.standardError, as: UTF8.self)
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
}
