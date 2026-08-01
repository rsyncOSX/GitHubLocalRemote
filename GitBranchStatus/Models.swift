import Foundation

enum ScanPhase: Equatable {
    case idle
    case scanning
    case loaded
}

enum RepositoryScanProgress: Equatable, Sendable {
    case discoveringRepositories
    case foundRepositories(
        githubRepositoryCount: Int,
        gitRepositoryCount: Int,
        candidateDirectoryCount: Int
    )
    case checking(repositoryName: String, number: Int, total: Int)
    case finished(repositoryName: String, number: Int, total: Int)

    var message: String {
        switch self {
        case .discoveringRepositories:
            "Finding Git repositories…"
        case let .foundRepositories(githubCount, gitCount, directoryCount):
            "Found \(githubCount) GitHub \(Self.repositoryLabel(for: githubCount)) among \(gitCount) Git \(Self.repositoryLabel(for: gitCount)) in \(directoryCount) \(Self.folderLabel(for: directoryCount))."
        case let .checking(repositoryName, number, total):
            "Checking \(repositoryName) (\(number) of \(total))…"
        case let .finished(repositoryName, number, total):
            "Finished \(repositoryName) (\(number) of \(total))"
        }
    }

    var isFinished: Bool {
        if case .finished = self {
            return true
        }
        return false
    }

    private static func repositoryLabel(for count: Int) -> String {
        count == 1 ? "repository" : "repositories"
    }

    private static func folderLabel(for count: Int) -> String {
        count == 1 ? "folder" : "folders"
    }
}

enum BranchSyncStatus: String, CaseIterable, Sendable {
    case localAhead
    case inSync
    case remoteAhead
    case diverged
    case unknown

    var title: String {
        switch self {
        case .localAhead: "Local ahead"
        case .inSync: "In sync"
        case .remoteAhead: "Remote ahead"
        case .diverged: "Diverged"
        case .unknown: "Unknown"
        }
    }
}

enum BranchFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case localAhead
    case inSync
    case remoteAhead
    case diverged
    case unknown

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .all: "All branches"
        case .attention: "Needs attention"
        case .localAhead: "Local ahead"
        case .inSync: "In sync"
        case .remoteAhead: "Remote ahead"
        case .diverged: "Diverged"
        case .unknown: "Could not compare"
        }
    }

    func includes(_ branch: BranchRecord) -> Bool {
        switch self {
        case .all:
            true
        case .attention:
            branch.status != .inSync
        case .localAhead:
            branch.status == .localAhead
        case .inSync:
            branch.status == .inSync
        case .remoteAhead:
            branch.status == .remoteAhead
        case .diverged:
            branch.status == .diverged
        case .unknown:
            branch.status == .unknown
        }
    }
}

struct BranchRecord: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let status: BranchSyncStatus
    let localOID: String?
    let remoteOID: String?
    let aheadCount: Int?
    let behindCount: Int?

    var localShortOID: String {
        localOID.map { String($0.prefix(8)) } ?? "—"
    }

    var remoteShortOID: String {
        remoteOID.map { String($0.prefix(8)) } ?? "—"
    }

    var statusDetail: String {
        switch (localOID, remoteOID, status) {
        case (.some, nil, _):
            "Local only — not published"
        case (nil, .some, _):
            "Remote only — not available locally"
        case (_, _, .localAhead):
            "\(aheadCount ?? 0) commit\(aheadCount == 1 ? "" : "s") ahead"
        case (_, _, .remoteAhead):
            "\(behindCount ?? 0) commit\(behindCount == 1 ? "" : "s") behind"
        case (_, _, .inSync):
            "Same commit"
        case (_, _, .diverged):
            "\(aheadCount ?? 0) ahead, \(behindCount ?? 0) behind"
        case (_, _, .unknown):
            "Could not compare commits"
        }
    }
}

struct ProjectScan: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let directoryURL: URL
    let remoteName: String
    let remoteWebURL: URL
    let branches: [BranchRecord]
    let fetchedAt: Date
    let warning: String?

    /// A normalized warning suitable for presentation. Keeping this check at
    /// the model boundary prevents an empty diagnostic from being rendered as
    /// an orange warning banner or unhealthy sidebar status.
    var warningMessage: String? {
        guard let warning else { return nil }
        let message = warning.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    func count(for status: BranchSyncStatus) -> Int {
        branches.count { $0.status == status }
    }

    var attentionCount: Int {
        branches.count { $0.status != .inSync }
    }
}

struct CatalogScan: Equatable, Sendable {
    let folderURL: URL
    let candidateDirectoryCount: Int
    let gitRepositoryCount: Int
    let githubRepositoryCount: Int
    let projects: [ProjectScan]
    let scannedAt: Date
}

struct GitHubRemote: Equatable, Sendable {
    let remoteURL: String
    let owner: String
    let repository: String

    var webURL: URL {
        // Owner and repository originate from a parsed GitHub path. Encoding them
        // again keeps the displayed URL free of any credentials in the Git URL.
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner)/\(repository)"
        return components.url ?? URL(string: "https://github.com")!
    }

    static func parse(_ rawValue: String) -> GitHubRemote? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        if let components = URLComponents(string: raw),
           components.host?.lowercased() == "github.com"
        {
            return remote(fromPath: components.path, rawValue: raw)
        }

        // Git commonly stores SSH remotes in SCP-style form:
        // git@github.com:owner/repository.git
        guard let separatorIndex = raw.firstIndex(of: ":") else {
            return nil
        }

        let host = raw[..<separatorIndex]
            .split(separator: "@", maxSplits: 1)
            .last?
            .lowercased()
        guard host == "github.com" else { return nil }

        let path = String(raw[raw.index(after: separatorIndex)...])
        return remote(fromPath: path, rawValue: raw)
    }

    private static func remote(fromPath path: String, rawValue: String) -> GitHubRemote? {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard components.count == 2 else { return nil }

        let owner = components[0].removingPercentEncoding ?? components[0]
        var repository = components[1].removingPercentEncoding ?? components[1]
        if repository.lowercased().hasSuffix(".git") {
            repository.removeLast(4)
        }

        guard !owner.isEmpty, !repository.isEmpty else { return nil }
        return GitHubRemote(remoteURL: rawValue, owner: owner, repository: repository)
    }
}

enum BranchComparison {
    static func classify(ahead: Int, behind: Int) -> BranchSyncStatus {
        switch (ahead, behind) {
        case (0, 0): .inSync
        case let (ahead, 0) where ahead > 0: .localAhead
        case let (0, behind) where behind > 0: .remoteAhead
        default: .diverged
        }
    }
}
