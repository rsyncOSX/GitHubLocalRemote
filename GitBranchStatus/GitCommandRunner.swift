import Foundation
import ProcessCommand

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
    ) throws -> GitCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw GitCommandError.launchFailed(error.localizedDescription)
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = GitCommandResult(
            output: output,
            errorOutput: errorOutput,
            exitCode: process.terminationStatus
        )

        if result.exitCode != 0, !allowFailure {
            throw GitCommandError.commandFailed(
                arguments: arguments,
                exitCode: result.exitCode,
                message: errorOutput.isEmpty ? "Unknown Git error" : errorOutput
            )
        }

        return result
    }
}

