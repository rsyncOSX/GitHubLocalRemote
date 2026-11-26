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

/// Applies Git-specific policy around the reusable ProcessGit executor.
struct GitCommandRunner: Sendable {
    /// The SSH command used for network operations when the user has not
    /// configured one: batch mode never prompts, and a dead host fails fast.
    static let nonInteractiveSSHCommand = "ssh -oBatchMode=yes -oConnectTimeout=10"

    private let executableURL: URL
    private let baseEnvironment: [String: String]

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        self.baseEnvironment = baseEnvironment
    }

    func run(
        _ arguments: [String],
        in directory: URL,
        allowFailure: Bool = false,
        timeout: Duration? = nil,
        environment overrides: [String: String] = [:]
    ) async throws -> GitCommandResult {
        let processResult: ProcessGitResult
        do {
            processResult = try await ProcessGit(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: directory,
                environment: nonInteractiveEnvironment.merging(
                    overrides,
                    uniquingKeysWith: { _, override in override }
                )
            ).run(timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessGitError {
            if case .timedOut = error {
                throw GitCommandError.timedOut(arguments: arguments)
            }
            throw GitCommandError.launchFailed(error.localizedDescription)
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

    /// True when the environment already chooses the SSH program, which Git
    /// then prefers over `core.sshCommand`.
    var usesCustomSSHCommand: Bool {
        ["GIT_SSH_COMMAND", "GIT_SSH"].contains { !(baseEnvironment[$0] ?? "").isEmpty }
    }

    /// Prompts are refused for every command. The SSH program itself is left
    /// alone here: a user's `GIT_SSH_COMMAND` or `core.sshCommand` (for example
    /// a per-repository key) must keep working, so network commands add
    /// ``nonInteractiveSSHCommand`` only when neither is configured.
    private var nonInteractiveEnvironment: [String: String] {
        baseEnvironment.merging(
            [
                "GIT_TERMINAL_PROMPT": "0",
                "GCM_INTERACTIVE": "Never",
                "GIT_ASKPASS": "/usr/bin/false",
                "SSH_ASKPASS": "/usr/bin/false",
                // Makes ssh use the failing askpass instead of a terminal, so
                // a custom SSH command cannot wait on a passphrase prompt.
                "SSH_ASKPASS_REQUIRE": "force",
            ],
            uniquingKeysWith: { _, nonInteractiveValue in nonInteractiveValue }
        )
    }
}
