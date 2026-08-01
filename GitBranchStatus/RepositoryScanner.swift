import Foundation

enum RepositoryScannerError: LocalizedError, Sendable {
    case cannotReadFolder(String)
    case malformedReferenceOutput(String)

    var errorDescription: String? {
        switch self {
        case let .cannotReadFolder(path):
            "The folder could not be read: \(path)"
        case let .malformedReferenceOutput(line):
            "Git returned an unexpected branch record: \(line)"
        }
    }
}

enum RepositoryWarnings {
    static func combine(_ warnings: [String?]) -> String? {
        let messages = warnings.compactMap { warning -> String? in
            guard let warning else { return nil }
            let message = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? nil : message
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

struct RepositoryScanner: Sendable {
    private struct QualifiedRepository {
        let url: URL
        let remoteName: String
        let remote: GitHubRemote
    }

    private let git = GitCommandRunner()
    private let fetchTimeout: Duration

    init(fetchTimeout: Duration = .seconds(15)) {
        self.fetchTimeout = fetchTimeout
    }

    func scan(
        folderURL: URL,
        progress: @escaping @MainActor @Sendable (RepositoryScanProgress) -> Void,
        update: @escaping @MainActor @Sendable (CatalogScan) -> Void = { _ in }
    ) async throws -> CatalogScan {
        try await scanSynchronously(
            folderURL: folderURL,
            progress: progress,
            update: update
        )
    }

    private func scanSynchronously(
        folderURL: URL,
        progress: @escaping @MainActor @Sendable (RepositoryScanProgress) -> Void,
        update: @escaping @MainActor @Sendable (CatalogScan) -> Void
    ) async throws -> CatalogScan {
        await progress(.discoveringRepositories)

        let fileManager = FileManager.default
        guard (try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        )) != nil else {
            throw RepositoryScannerError.cannotReadFolder(folderURL.path)
        }

        guard let descendants = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw RepositoryScannerError.cannotReadFolder(folderURL.path)
        }

        var candidateDirectories: [URL] = []
        while let descendant = descendants.nextObject() as? URL {
            try Task.checkCancellation()

            guard let values = try? descendant.resourceValues(
                forKeys: [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey]
            ), values.isDirectory == true,
                values.isHidden != true,
                values.isSymbolicLink != true
            else {
                continue
            }

            candidateDirectories.append(descendant)
        }
        candidateDirectories.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        let gitRepositories = candidateDirectories.filter { directory in
            var isDirectory: ObjCBool = false
            let gitPath = directory.appendingPathComponent(".git").path
            return fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        var qualifiedRepositories: [QualifiedRepository] = []
        for repositoryURL in gitRepositories {
            try Task.checkCancellation()

            guard let remote = try await githubRemote(in: repositoryURL) else {
                continue
            }
            qualifiedRepositories.append(
                QualifiedRepository(
                    url: repositoryURL,
                    remoteName: remote.name,
                    remote: remote.remote
                )
            )
        }

        await progress(
            .foundRepositories(
                githubRepositoryCount: qualifiedRepositories.count,
                gitRepositoryCount: gitRepositories.count,
                candidateDirectoryCount: candidateDirectories.count
            )
        )
        await Task.yield()

        var projects: [ProjectScan] = []
        for (offset, repository) in qualifiedRepositories.enumerated() {
            try Task.checkCancellation()

            let repositoryNumber = offset + 1
            await progress(
                .checking(
                    repositoryName: repository.url.lastPathComponent,
                    number: repositoryNumber,
                    total: qualifiedRepositories.count
                )
            )

            let project = try await scanRepository(
                at: repository.url,
                remoteName: repository.remoteName,
                remote: repository.remote
            )
            projects.append(project)
            await update(
                catalogScan(
                    folderURL: folderURL,
                    candidateDirectoryCount: candidateDirectories.count,
                    gitRepositoryCount: gitRepositories.count,
                    githubRepositoryCount: qualifiedRepositories.count,
                    projects: projects
                )
            )

            await progress(
                .finished(
                    repositoryName: repository.url.lastPathComponent,
                    number: repositoryNumber,
                    total: qualifiedRepositories.count
                )
            )
            await Task.yield()
        }

        return catalogScan(
            folderURL: folderURL,
            candidateDirectoryCount: candidateDirectories.count,
            gitRepositoryCount: gitRepositories.count,
            githubRepositoryCount: qualifiedRepositories.count,
            projects: projects
        )
    }

    private func catalogScan(
        folderURL: URL,
        candidateDirectoryCount: Int,
        gitRepositoryCount: Int,
        githubRepositoryCount: Int,
        projects: [ProjectScan]
    ) -> CatalogScan {
        CatalogScan(
            folderURL: folderURL,
            candidateDirectoryCount: candidateDirectoryCount,
            gitRepositoryCount: gitRepositoryCount,
            githubRepositoryCount: githubRepositoryCount,
            projects: projects,
            scannedAt: Date()
        )
    }

    private func githubRemote(in repositoryURL: URL) async throws -> (name: String, remote: GitHubRemote)? {
        let namesOutput: String
        do {
            namesOutput = try await git.run(["remote"], in: repositoryURL).output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }

        let names = namesOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .sorted { lhs, rhs in
                if lhs == "origin" {
                    return true
                }
                if rhs == "origin" {
                    return false
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }

        for name in names {
                let remoteURL: String
                do {
                    remoteURL = try await git.run(["remote", "get-url", name], in: repositoryURL).output
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    continue
                }
                guard let githubRemote = GitHubRemote.parse(remoteURL) else { continue }
                return (name, githubRemote)
            }

        return nil
    }

    private func scanRepository(
        at repositoryURL: URL,
        remoteName: String,
        remote: GitHubRemote
    ) async throws -> ProjectScan {
        let fetchResult: GitCommandResult?
        do {
            fetchResult = try await git.run(
                ["fetch", "--prune", "--quiet", remoteName],
                in: repositoryURL,
                allowFailure: true,
                timeout: fetchTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            fetchResult = nil
        }

        let warning: String? = if let fetchResult, fetchResult.exitCode != 0 {
            fetchResult.errorOutput.isEmpty
                ? "Could not refresh \(remoteName); cached remote references are shown."
                : "Could not refresh \(remoteName): \(fetchResult.errorOutput)"
        } else if fetchResult == nil {
            "Could not refresh \(remoteName); cached remote references are shown."
        } else {
            nil
        }

        do {
            let localReferences = try await references(
                arguments: ["for-each-ref", "--format=%(refname:short)%09%(objectname)", "refs/heads/"],
                in: repositoryURL
            )
            let remoteReferences = try await references(
                arguments: [
                    "for-each-ref",
                    "--format=%(refname)%09%(objectname)",
                    "refs/remotes/\(remoteName)/",
                ],
                in: repositoryURL,
                removingPrefix: "refs/remotes/\(remoteName)/"
            )
            .filter { $0.key != "HEAD" }

            let branchNames = Set(localReferences.keys)
                .union(remoteReferences.keys)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            var branches: [BranchRecord] = []
            var comparisonWarnings: [String] = []
            for branchName in branchNames {
                let comparison = try await compare(
                    branchName: branchName,
                    localOID: localReferences[branchName],
                    remoteOID: remoteReferences[branchName],
                    repositoryURL: repositoryURL
                )
                branches.append(comparison.branch)
                if let warning = comparison.warning {
                    comparisonWarnings.append(warning)
                }
            }

            return ProjectScan(
                id: repositoryURL.standardizedFileURL.path,
                name: repositoryURL.lastPathComponent,
                directoryURL: repositoryURL,
                remoteName: remoteName,
                remoteWebURL: remote.webURL,
                branches: branches,
                fetchedAt: Date(),
                warning: RepositoryWarnings.combine([
                    warning,
                    comparisonWarnings.isEmpty
                        ? nil
                        : comparisonWarnings.joined(separator: "\n"),
                ])
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let combinedWarning = RepositoryWarnings.combine([
                warning,
                error.localizedDescription,
            ])

            return ProjectScan(
                id: repositoryURL.standardizedFileURL.path,
                name: repositoryURL.lastPathComponent,
                directoryURL: repositoryURL,
                remoteName: remoteName,
                remoteWebURL: remote.webURL,
                branches: [],
                fetchedAt: Date(),
                warning: combinedWarning
            )
        }
    }

    private func references(
        arguments: [String],
        in repositoryURL: URL,
        removingPrefix prefix: String? = nil
    ) async throws -> [String: String] {
        let output = try await git.run(arguments, in: repositoryURL).output
        guard !output.isEmpty else { return [:] }

        return try output
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { references, rawLine in
                let fields = rawLine.split(separator: "\t", maxSplits: 1).map(String.init)
                guard fields.count == 2 else {
                    throw RepositoryScannerError.malformedReferenceOutput(String(rawLine))
                }

                var name = fields[0]
                if let prefix, name.hasPrefix(prefix) {
                    name.removeFirst(prefix.count)
                }
                references[name] = fields[1]
            }
    }

    private func compare(
        branchName: String,
        localOID: String?,
        remoteOID: String?,
        repositoryURL: URL
    ) async throws -> (branch: BranchRecord, warning: String?) {
        let id = "\(repositoryURL.standardizedFileURL.path)#\(branchName)"

        switch (localOID, remoteOID) {
        case let (.some(local), .some(remote)):
            do {
                let counts = try await divergenceCounts(
                    localOID: local,
                    remoteOID: remote,
                    repositoryURL: repositoryURL
                )
                return (
                    BranchRecord(
                        id: id,
                        name: branchName,
                        status: BranchComparison.classify(ahead: counts.ahead, behind: counts.behind),
                        localOID: local,
                        remoteOID: remote,
                        aheadCount: counts.ahead,
                        behindCount: counts.behind
                    ),
                    nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (
                    BranchRecord(
                        id: id,
                        name: branchName,
                        status: .unknown,
                        localOID: local,
                        remoteOID: remote,
                        aheadCount: nil,
                        behindCount: nil
                    ),
                    "Could not compare \(branchName): \(error.localizedDescription)"
                )
            }
        case let (.some(local), nil):
            return (
                BranchRecord(
                    id: id,
                    name: branchName,
                    status: .localAhead,
                    localOID: local,
                    remoteOID: nil,
                    aheadCount: nil,
                    behindCount: nil
                ),
                nil
            )
        case let (nil, .some(remote)):
            return (
                BranchRecord(
                    id: id,
                    name: branchName,
                    status: .remoteAhead,
                    localOID: nil,
                    remoteOID: remote,
                    aheadCount: nil,
                    behindCount: nil
                ),
                nil
            )
        case (nil, nil):
            preconditionFailure("A branch must exist locally, remotely, or both")
        }
    }

    private func divergenceCounts(
        localOID: String,
        remoteOID: String,
        repositoryURL: URL
    ) async throws -> (ahead: Int, behind: Int) {
        let output = try await git.run(
            ["rev-list", "--left-right", "--count", "\(localOID)...\(remoteOID)"],
            in: repositoryURL
        ).output

        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let ahead = Int(fields[0]),
              let behind = Int(fields[1])
        else {
            throw RepositoryScannerError.malformedReferenceOutput(output)
        }
        return (ahead, behind)
    }
}
