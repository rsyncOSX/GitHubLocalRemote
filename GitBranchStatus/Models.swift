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
            branch.needsAttention
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
    /// The configured upstream branch on the scanned remote, if any.
    var upstreamName: String? = nil
    /// True when the configured upstream no longer exists on the remote.
    var upstreamIsMissing = false

    /// A branch that exists only on the remote is someone else's work, not
    /// something to act on locally, so it does not need attention.
    var isRemoteOnly: Bool {
        localOID == nil && remoteOID != nil
    }

    var needsAttention: Bool {
        status != .inSync && !isRemoteOnly
    }

    /// True when the branch is compared with a remote branch of another name.
    var tracksDifferentlyNamedBranch: Bool {
        guard let upstreamName else { return false }
        return upstreamName != name
    }

    var localShortOID: String {
        localOID.map { String($0.prefix(8)) } ?? "—"
    }

    var remoteShortOID: String {
        remoteOID.map { String($0.prefix(8)) } ?? "—"
    }

    var statusDetail: String {
        switch (localOID, remoteOID, status) {
        case (.some, nil, _) where upstreamIsMissing:
            "Tracked remote branch no longer exists"
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
        branches.count(where: \.needsAttention)
    }

    var localBranchCount: Int {
        branches.count { !$0.isRemoteOnly }
    }

    var remoteOnlyCount: Int {
        branches.count(where: \.isRemoteOnly)
    }
}

/// A Git repository whose remotes could not be read, for example because Git
/// refuses a repository with "dubious ownership".
struct SkippedRepository: Identifiable, Equatable, Sendable {
    let directoryURL: URL
    let reason: String

    var id: String {
        directoryURL.standardizedFileURL.path
    }
}

struct CatalogScan: Equatable, Sendable {
    let folderURL: URL
    let candidateDirectoryCount: Int
    let gitRepositoryCount: Int
    let githubRepositoryCount: Int
    let projects: [ProjectScan]
    let scannedAt: Date
    var skippedRepositories: [SkippedRepository] = []

    /// Applies a partial result from a rescan of the same folder to the
    /// previous catalog, so projects not yet rescanned stay visible (and
    /// selectable) until the scan finishes.
    static func merging(_ partial: CatalogScan, into previous: CatalogScan?) -> CatalogScan {
        guard let previous, previous.folderURL == partial.folderURL else {
            return partial
        }

        let rescanned = Dictionary(
            partial.projects.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let previousIDs = Set(previous.projects.map(\.id))
        let projects = previous.projects.map { rescanned[$0.id] ?? $0 }
            + partial.projects.filter { !previousIDs.contains($0.id) }

        return CatalogScan(
            folderURL: partial.folderURL,
            candidateDirectoryCount: partial.candidateDirectoryCount,
            gitRepositoryCount: partial.gitRepositoryCount,
            githubRepositoryCount: partial.githubRepositoryCount,
            projects: projects,
            scannedAt: partial.scannedAt,
            skippedRepositories: partial.skippedRepositories
        )
    }
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

    static func isGitHubHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "github.com" || host == "www.github.com"
    }

    /// The host an SSH remote connects to, as written in the URL; it may be an
    /// alias defined in the user's SSH configuration. `nil` for other URLs.
    static func sshHost(of rawValue: String) -> String? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("://") {
            guard let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "ssh" || scheme == "git+ssh",
                  let host = components.host,
                  !host.isEmpty
            else {
                return nil
            }
            return host
        }

        // SCP-style: [user@]host:path, where the host part contains no slash.
        guard let separatorIndex = raw.firstIndex(of: ":") else { return nil }
        let prefix = raw[..<separatorIndex]
        guard !prefix.contains("/") else { return nil }
        let host = prefix.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).last
        guard let host, !host.isEmpty else { return nil }
        return String(host)
    }

    /// Parses a GitHub remote URL. `resolveSSHHost` maps an SSH host alias to
    /// the host name it stands for, so `git@github.com-work:owner/repo` is
    /// recognized when the user's SSH configuration points it at github.com.
    static func parse(
        _ rawValue: String,
        resolveSSHHost: (String) -> String? = { _ in nil }
    ) -> GitHubRemote? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let isSSH = sshHost(of: raw) != nil
        func isGitHub(_ host: String) -> Bool {
            isGitHubHost(host) || (isSSH && resolveSSHHost(host).map(isGitHubHost) == true)
        }

        if raw.contains("://") {
            guard let components = URLComponents(string: raw),
                  let host = components.host,
                  isGitHub(host)
            else {
                return nil
            }
            return remote(fromPath: components.path, rawValue: raw)
        }

        // Git commonly stores SSH remotes in SCP-style form:
        // git@github.com:owner/repository.git
        guard let host = sshHost(of: raw), isGitHub(host),
              let separatorIndex = raw.firstIndex(of: ":")
        else {
            return nil
        }

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
