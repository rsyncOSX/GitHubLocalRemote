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

struct RepositoryScanner: Sendable {
    private let git = GitCommandRunner()

    func scan(folderURL: URL) async throws -> CatalogScan {
        try await Task.detached(priority: .userInitiated) {
            try scanSynchronously(folderURL: folderURL)
        }.value
    }

    private func scanSynchronously(folderURL: URL) throws -> CatalogScan {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw RepositoryScannerError.cannotReadFolder(folderURL.path)
        }

        let candidateDirectories = children
            .filter { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]) else {
                    return false
                }
                return values.isDirectory == true && values.isHidden != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let gitRepositories = candidateDirectories.filter { directory in
            var isDirectory: ObjCBool = false
            let gitPath = directory.appendingPathComponent(".git").path
            return fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) && isDirectory.boolValue
        }

        var projects: [ProjectScan] = []
        for repositoryURL in gitRepositories {
            guard let remote = githubRemote(in: repositoryURL) else {
                continue
            }
            projects.append(scanRepository(at: repositoryURL, remoteName: remote.name, remote: remote.remote))
        }

        return CatalogScan(
            folderURL: folderURL,
            candidateDirectoryCount: candidateDirectories.count,
            gitRepositoryCount: gitRepositories.count,
            projects: projects,
            scannedAt: Date()
        )
    }

    private func githubRemote(in repositoryURL: URL) -> (name: String, remote: GitHubRemote)? {
        guard let namesOutput = try? git.run(["remote"], in: repositoryURL).output else {
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
            guard let remoteURL = try? git.run(["remote", "get-url", name], in: repositoryURL).output,
                  let githubRemote = GitHubRemote.parse(remoteURL)
            else {
                continue
            }
            return (name, githubRemote)
        }

        return nil
    }

    private func scanRepository(
        at repositoryURL: URL,
        remoteName: String,
        remote: GitHubRemote
    ) -> ProjectScan {
        let fetchResult = try? git.run(
            ["fetch", "--prune", "--quiet", remoteName],
            in: repositoryURL,
            allowFailure: true
        )

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
            let localReferences = try references(
                arguments: ["for-each-ref", "--format=%(refname:short)%09%(objectname)", "refs/heads/"],
                in: repositoryURL
            )
            let remoteReferences = try references(
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

            let branches = branchNames.map { branchName in
                compare(
                    branchName: branchName,
                    localOID: localReferences[branchName],
                    remoteOID: remoteReferences[branchName],
                    repositoryURL: repositoryURL
                )
            }

            return ProjectScan(
                id: repositoryURL.standardizedFileURL.path,
                name: repositoryURL.lastPathComponent,
                directoryURL: repositoryURL,
                remoteName: remoteName,
                remoteWebURL: remote.webURL,
                branches: branches,
                fetchedAt: Date(),
                warning: warning
            )
        } catch {
            let combinedWarning = [warning, error.localizedDescription]
                .compactMap(\.self)
                .joined(separator: "\n")

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
    ) throws -> [String: String] {
        let output = try git.run(arguments, in: repositoryURL).output
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
    ) -> BranchRecord {
        let id = "\(repositoryURL.standardizedFileURL.path)#\(branchName)"

        switch (localOID, remoteOID) {
        case let (.some(local), .some(remote)):
            let counts = divergenceCounts(localOID: local, remoteOID: remote, repositoryURL: repositoryURL)
            return BranchRecord(
                id: id,
                name: branchName,
                status: BranchComparison.classify(ahead: counts.ahead, behind: counts.behind),
                localOID: local,
                remoteOID: remote,
                aheadCount: counts.ahead,
                behindCount: counts.behind
            )
        case let (.some(local), nil):
            return BranchRecord(
                id: id,
                name: branchName,
                status: .localAhead,
                localOID: local,
                remoteOID: nil,
                aheadCount: nil,
                behindCount: nil
            )
        case let (nil, .some(remote)):
            return BranchRecord(
                id: id,
                name: branchName,
                status: .remoteAhead,
                localOID: nil,
                remoteOID: remote,
                aheadCount: nil,
                behindCount: nil
            )
        case (nil, nil):
            preconditionFailure("A branch must exist locally, remotely, or both")
        }
    }

    private func divergenceCounts(
        localOID: String,
        remoteOID: String,
        repositoryURL: URL
    ) -> (ahead: Int, behind: Int) {
        guard let output = try? git.run(
            ["rev-list", "--left-right", "--count", "\(localOID)...\(remoteOID)"],
            in: repositoryURL
        ).output else {
            return (0, 0)
        }

        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 2,
              let ahead = Int(fields[0]),
              let behind = Int(fields[1])
        else {
            return (0, 0)
        }
        return (ahead, behind)
    }
}
