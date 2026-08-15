import Darwin
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
                processResult = try await execute(
                    arguments,
                    in: directory
                )
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
                .completed(
                    try await execute(
                        arguments,
                        in: directory
                    )
                )
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
        let standardOutput = Pipe()
        let standardError = Pipe()
        let cancellation = ProcessCancellation()

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()

            let processID: pid_t
            do {
                processID = try spawn(
                    arguments,
                    in: directory,
                    environment: nonInteractiveEnvironment,
                    standardOutput: standardOutput,
                    standardError: standardError
                )
            } catch {
                try? standardOutput.fileHandleForWriting.close()
                try? standardError.fileHandleForWriting.close()
                try? standardOutput.fileHandleForReading.close()
                try? standardError.fileHandleForReading.close()
                throw error
            }

            // The parent must close its copies. Otherwise readers do not receive
            // EOF after every process in the child process group exits.
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()

            if cancellation.register(processGroupID: processID) {
                cancellation.terminateRegisteredProcessGroup()
            }
            defer { cancellation.finished() }

            do {
                async let output = Self.read(standardOutput.fileHandleForReading)
                async let errorOutput = Self.read(standardError.fileHandleForReading)
                async let exitCode = Self.waitForProcess(processID)

                let (outputData, errorData, status) = try await (
                    output,
                    errorOutput,
                    exitCode
                )
                try Task.checkCancellation()

                return ProcessResult(
                    output: outputData,
                    errorOutput: errorData,
                    exitCode: status
                )
            } catch {
                cancellation.cancel()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private var nonInteractiveEnvironment: [String: String] {
        baseEnvironment.merging(
            [
                "GIT_TERMINAL_PROMPT": "0",
                "GCM_INTERACTIVE": "Never",
                "GIT_ASKPASS": "/usr/bin/false",
                "SSH_ASKPASS": "/usr/bin/false",
                "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=10",
            ],
            uniquingKeysWith: { _, nonInteractiveValue in nonInteractiveValue }
        )
    }

    private func spawn(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String],
        standardOutput: Pipe,
        standardError: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?

        guard posix_spawn_file_actions_init(&fileActions) == 0,
              posix_spawnattr_init(&attributes) == 0
        else {
            throw GitCommandError.launchFailed("Could not initialize process attributes.")
        }
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        let outputReadDescriptor = standardOutput.fileHandleForReading.fileDescriptor
        let outputWriteDescriptor = standardOutput.fileHandleForWriting.fileDescriptor
        let errorReadDescriptor = standardError.fileHandleForReading.fileDescriptor
        let errorWriteDescriptor = standardError.fileHandleForWriting.fileDescriptor

        try checkSpawnAction(posix_spawn_file_actions_adddup2(
            &fileActions,
            outputWriteDescriptor,
            STDOUT_FILENO
        ))
        try checkSpawnAction(posix_spawn_file_actions_adddup2(
            &fileActions,
            errorWriteDescriptor,
            STDERR_FILENO
        ))
        try checkSpawnAction(posix_spawn_file_actions_addclose(&fileActions, outputReadDescriptor))
        try checkSpawnAction(posix_spawn_file_actions_addclose(&fileActions, errorReadDescriptor))
        if outputWriteDescriptor != STDOUT_FILENO {
            try checkSpawnAction(posix_spawn_file_actions_addclose(&fileActions, outputWriteDescriptor))
        }
        if errorWriteDescriptor != STDERR_FILENO {
            try checkSpawnAction(posix_spawn_file_actions_addclose(&fileActions, errorWriteDescriptor))
        }
        try directory.path.withCString { path in
            try checkSpawnAction(posix_spawn_file_actions_addchdir(&fileActions, path))
        }

        try checkSpawnAction(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        ))
        try checkSpawnAction(posix_spawnattr_setpgroup(&attributes, 0))

        let argumentStrings = [executableURL.path] + arguments
        let environmentStrings = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var processID: pid_t = 0

        let result = executableURL.path.withCString { executablePath in
            Self.withCStringArray(argumentStrings) { argumentPointers in
                Self.withCStringArray(environmentStrings) { environmentPointers in
                    posix_spawn(
                        &processID,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        try checkSpawnAction(result)
        return processID
    }

    private func checkSpawnAction(_ result: Int32) throws {
        guard result == 0 else {
            throw GitCommandError.launchFailed(String(cString: strerror(result)))
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }

        var optionalPointers: [UnsafeMutablePointer<CChar>?] = pointers
        optionalPointers.append(nil)
        return try optionalPointers.withUnsafeMutableBufferPointer { buffer in
            try operation(buffer.baseAddress!)
        }
    }

    private static func read(_ handle: FileHandle) async throws -> Data {
        // FileHandle has no native async read-to-EOF API. The detached task is
        // limited to this blocking syscall; process lifetime remains structured.
        try await Task.detached {
            try handle.readToEnd() ?? Data()
        }.value
    }

    private static func waitForProcess(_ processID: pid_t) async throws -> Int32 {
        // waitpid is blocking. Cancellation is made cooperative by the parent's
        // cancellation handler terminating the registered process group.
        try await Task.detached {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1 {
                if errno != EINTR {
                    throw GitCommandError.launchFailed(String(cString: strerror(errno)))
                }
            }

            if status & 0x7f == 0 {
                return (status >> 8) & 0xff
            }
            return 128 + (status & 0x7f)
        }.value
    }
}

private struct ProcessResult: Sendable {
    let output: Data
    let errorOutput: Data
    let exitCode: Int32
}

private final class ProcessCancellation: Sendable {
    private struct State {
        var processGroupID: pid_t?
        var cancellationRequested = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(processGroupID: pid_t) -> Bool {
        state.withLock { state in
            state.processGroupID = processGroupID
            return state.cancellationRequested
        }
    }

    func cancel() {
        let processGroupID = state.withLock { state in
            state.cancellationRequested = true
            return state.processGroupID
        }
        terminate(processGroupID)
    }

    func terminateRegisteredProcessGroup() {
        terminate(state.withLock { $0.processGroupID })
    }

    func finished() {
        state.withLock { $0.processGroupID = nil }
    }

    private func terminate(_ processGroupID: pid_t?) {
        guard let processGroupID else { return }

        _ = kill(-processGroupID, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
            let isStillRegistered = self.state.withLock {
                $0.processGroupID == processGroupID
            }
            if isStillRegistered, kill(-processGroupID, 0) == 0 {
                _ = kill(-processGroupID, SIGKILL)
            }
        }
    }
}
