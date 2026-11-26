import Foundation

enum RepositoryScannerError: LocalizedError, Sendable {
    case cannotReadFolder(String)
    case gitUnavailable(String)
    case malformedReferenceOutput(String)

    var errorDescription: String? {
        switch self {
        case let .cannotReadFolder(path):
            "The folder could not be read: \(path)"
        case let .gitUnavailable(message):
            "Git could not be run, so no repositories were checked. \(message)"
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

struct RepositoryScanPolicy: Sendable {
    static let standard = RepositoryScanPolicy(fetchTimeout: .seconds(45))

    let fetchTimeout: Duration
}

struct RepositoryScanner: Sendable {
    private struct QualifiedRepository {
        let url: URL
        let remoteName: String
        let remote: GitHubRemote
    }

    private enum RemoteLookup {
        case github(name: String, remote: GitHubRemote)
        case notGitHub
        case failed(String)
    }

    private struct LocalBranch {
        let oid: String
        /// The upstream branch name on the scanned remote, when one is configured.
        let upstreamBranch: String?
    }

    /// Bounds the one-time `git --version` check that precedes a scan.
    private static let gitAvailabilityTimeout: Duration = .seconds(20)

    private let git: GitCommandRunner
    private let policy: RepositoryScanPolicy

    init(
        policy: RepositoryScanPolicy = .standard,
        git: GitCommandRunner = GitCommandRunner()
    ) {
        self.policy = policy
        self.git = git
    }

    init(fetchTimeout: Duration, git: GitCommandRunner = GitCommandRunner()) {
        self.init(
            policy: RepositoryScanPolicy(fetchTimeout: fetchTimeout),
            git: git
        )
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

        try await verifyGitIsAvailable(in: folderURL)

        var candidateDirectoryCount = 0
        var gitRepositories: [URL] = []
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

            candidateDirectoryCount += 1

            var isDirectory: ObjCBool = false
            let gitPath = descendant.appendingPathComponent(".git").path
            if fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                gitRepositories.append(descendant)
                // A repository's working tree (build output, dependencies,
                // vendored checkouts) is not searched for further projects.
                descendants.skipDescendants()
            }
        }
        gitRepositories.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        var qualifiedRepositories: [QualifiedRepository] = []
        var skippedRepositories: [SkippedRepository] = []
        for repositoryURL in gitRepositories {
            try Task.checkCancellation()

            switch try await githubRemote(in: repositoryURL) {
            case let .github(name, remote):
                qualifiedRepositories.append(
                    QualifiedRepository(url: repositoryURL, remoteName: name, remote: remote)
                )
            case .notGitHub:
                continue
            case let .failed(reason):
                skippedRepositories.append(
                    SkippedRepository(directoryURL: repositoryURL, reason: reason)
                )
            }
        }

        await progress(
            .foundRepositories(
                githubRepositoryCount: qualifiedRepositories.count,
                gitRepositoryCount: gitRepositories.count,
                candidateDirectoryCount: candidateDirectoryCount
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
                    candidateDirectoryCount: candidateDirectoryCount,
                    gitRepositoryCount: gitRepositories.count,
                    githubRepositoryCount: qualifiedRepositories.count,
                    projects: projects,
                    skippedRepositories: skippedRepositories
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
            candidateDirectoryCount: candidateDirectoryCount,
            gitRepositoryCount: gitRepositories.count,
            githubRepositoryCount: qualifiedRepositories.count,
            projects: projects,
            skippedRepositories: skippedRepositories
        )
    }

    private func catalogScan(
        folderURL: URL,
        candidateDirectoryCount: Int,
        gitRepositoryCount: Int,
        githubRepositoryCount: Int,
        projects: [ProjectScan],
        skippedRepositories: [SkippedRepository]
    ) -> CatalogScan {
        CatalogScan(
            folderURL: folderURL,
            candidateDirectoryCount: candidateDirectoryCount,
            gitRepositoryCount: gitRepositoryCount,
            githubRepositoryCount: githubRepositoryCount,
            projects: projects,
            scannedAt: Date(),
            skippedRepositories: skippedRepositories
        )
    }

    /// Fails the scan up front when Git itself cannot run (for example when
    /// the Command Line Tools are not installed), instead of silently
    /// reporting that no GitHub projects exist.
    private func verifyGitIsAvailable(in folderURL: URL) async throws {
        do {
            _ = try await git.run(
                ["--version"],
                in: folderURL,
                timeout: Self.gitAvailabilityTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RepositoryScannerError.gitUnavailable(error.localizedDescription)
        }
    }

    private func githubRemote(in repositoryURL: URL) async throws -> RemoteLookup {
        let namesOutput: String
        do {
            namesOutput = try await git.run(["remote"], in: repositoryURL).output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // For example Git's "dubious ownership" check on external drives.
            return .failed(error.localizedDescription)
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
            return .github(name: name, remote: githubRemote)
        }

        return .notGitHub
    }

    private func scanRepository(
        at repositoryURL: URL,
        remoteName: String,
        remote: GitHubRemote
    ) async throws -> ProjectScan {
        let warning: String?
        do {
            let fetchResult = try await git.run(
                // Automatic gc/maintenance is disabled so that a fetch killed at
                // its deadline cannot leave lock files in the user's repository.
                ["fetch", "--prune", "--quiet", "--no-auto-maintenance", remoteName],
                in: repositoryURL,
                allowFailure: true,
                timeout: policy.fetchTimeout
            )
            warning = if fetchResult.exitCode != 0 {
                fetchResult.errorOutput.isEmpty
                    ? "Could not refresh \(remoteName); cached remote references are shown."
                    : "Could not refresh \(remoteName): \(fetchResult.errorOutput)"
            } else {
                nil
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GitCommandError {
            if case .timedOut = error {
                warning = "Refreshing \(remoteName) timed out; cached remote references are shown."
            } else {
                warning = "Could not refresh \(remoteName); cached remote references are shown."
            }
        } catch {
            warning = "Could not refresh \(remoteName); cached remote references are shown."
        }

        do {
            let remotePrefix = "refs/remotes/\(remoteName)/"
            let localBranches = try await references(
                arguments: [
                    "for-each-ref",
                    // The full refname is used: the short form becomes
                    // "heads/<name>" when a tag shares the branch name.
                    "--format=%(refname)%09%(upstream)%09%(objectname)",
                    "refs/heads/",
                ],
                fieldCount: 3,
                in: repositoryURL
            )
            .reduce(into: [String: LocalBranch]()) { branches, fields in
                let upstream = fields[1]
                branches[Self.removing("refs/heads/", from: fields[0])] = LocalBranch(
                    oid: fields[2],
                    upstreamBranch: upstream.hasPrefix(remotePrefix)
                        ? Self.removing(remotePrefix, from: upstream)
                        : nil
                )
            }
            let remoteReferences = try await references(
                arguments: [
                    "for-each-ref",
                    "--format=%(refname)%09%(objectname)",
                    remotePrefix,
                ],
                fieldCount: 2,
                in: repositoryURL
            )
            .reduce(into: [String: String]()) { references, fields in
                let name = Self.removing(remotePrefix, from: fields[0])
                if name != "HEAD" {
                    references[name] = fields[1]
                }
            }

            var branches: [BranchRecord] = []
            var comparisonWarnings: [String] = []
            var pairedRemoteBranches = Set<String>()

            let localNames = localBranches.keys
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for name in localNames {
                let local = localBranches[name]!
                // A configured upstream on this remote wins; otherwise the
                // remote branch with the same name is the counterpart.
                let remoteBranch = local.upstreamBranch ?? name
                let remoteOID = remoteReferences[remoteBranch]
                if remoteOID != nil {
                    pairedRemoteBranches.insert(remoteBranch)
                }
                let comparison = try await compare(
                    id: "\(repositoryURL.standardizedFileURL.path)#\(name)",
                    branchName: name,
                    upstreamName: local.upstreamBranch,
                    upstreamIsMissing: local.upstreamBranch != nil && remoteOID == nil,
                    localOID: local.oid,
                    remoteOID: remoteOID,
                    repositoryURL: repositoryURL
                )
                branches.append(comparison.branch)
                if let warning = comparison.warning {
                    comparisonWarnings.append(warning)
                }
            }

            for (name, remoteOID) in remoteReferences where !pairedRemoteBranches.contains(name) {
                let comparison = try await compare(
                    id: "\(repositoryURL.standardizedFileURL.path)#\(remoteName)/\(name)",
                    branchName: name,
                    upstreamName: nil,
                    upstreamIsMissing: false,
                    localOID: nil,
                    remoteOID: remoteOID,
                    repositoryURL: repositoryURL
                )
                branches.append(comparison.branch)
            }
            branches.sort { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
                // Local branches precede a remote-only branch of the same name.
                return lhs.localOID != nil && rhs.localOID == nil
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
        fieldCount: Int,
        in repositoryURL: URL
    ) async throws -> [[String]] {
        let output = try await git.run(arguments, in: repositoryURL).output
        guard !output.isEmpty else { return [] }

        return try output
            .split(whereSeparator: \.isNewline)
            .map { rawLine in
                // Empty fields (an unset upstream) are significant.
                let fields = rawLine
                    .split(separator: "\t", omittingEmptySubsequences: false)
                    .map(String.init)
                guard fields.count == fieldCount, !fields[0].isEmpty, !fields[fieldCount - 1].isEmpty else {
                    throw RepositoryScannerError.malformedReferenceOutput(String(rawLine))
                }
                return fields
            }
    }

    private static func removing(_ prefix: String, from value: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    private func compare(
        id: String,
        branchName: String,
        upstreamName: String?,
        upstreamIsMissing: Bool,
        localOID: String?,
        remoteOID: String?,
        repositoryURL: URL
    ) async throws -> (branch: BranchRecord, warning: String?) {
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
                        behindCount: counts.behind,
                        upstreamName: upstreamName
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
                        behindCount: nil,
                        upstreamName: upstreamName
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
                    behindCount: nil,
                    upstreamName: upstreamName,
                    upstreamIsMissing: upstreamIsMissing
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
