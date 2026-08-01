import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = AppModel()
    @State private var isChoosingFolder = false

    var body: some View {
        Group {
            switch model.phase {
            case .idle:
                WelcomeView {
                    isChoosingFolder = true
                }
/*
            case .scanning where model.catalogScan == nil:
                ScanningView(progress: model.scanProgress)
*/
            case .scanning, .loaded:
                CatalogView(
                    model: model,
                    chooseFolder: { isChoosingFolder = true }
                )
            }
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let folderURL = urls.first {
                    model.selectFolder(folderURL)
                }
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .fileDialogMessage("Choose the folder that contains your local Git projects.")
        .fileDialogConfirmationLabel("Scan Folder")
        .alert(
            "Scan failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }
}

private struct WelcomeView: View {
    let chooseFolder: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Git Branch Status")
                    .font(.largeTitle.weight(.semibold))
                Text("Compare every local branch with its GitHub remote.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Button("Choose Projects Folder…", systemImage: "folder") {
                chooseFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityHint("Opens a folder picker and scans its project folders")
        }
        .padding(48)
    }
}

private struct ScanningView: View {
    let progress: RepositoryScanProgress?

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Scanning projects and fetching GitHub remotes…")
                .font(.headline)
            ScanStatusLine(progress: progress)
                .frame(minWidth: 360)
        }
        .padding(48)
        .accessibilityElement(children: .combine)
    }
}

private struct CatalogView: View {
    @Bindable var model: AppModel
    let chooseFolder: () -> Void

    var body: some View {
        NavigationSplitView {
            ProjectSidebar(
                scan: model.catalogScan,
                selectedProjectID: $model.selectedProjectID
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let project = model.selectedProject {
                ProjectDetailView(project: project)
            } else if let scan = model.catalogScan, scan.projects.isEmpty {
                NoProjectsView(scan: scan)
            } else {
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Choose a GitHub project in the sidebar.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            if model.isScanning {
                ScanStatusLine(progress: model.scanProgress)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Choose Folder", systemImage: "folder") {
                    chooseFolder()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Rescan", systemImage: "arrow.clockwise") {
                    model.rescan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.isScanning)
            }
        }
    }
}

private struct ScanStatusLine: View {
    let progress: RepositoryScanProgress?

    private var displayedProgress: RepositoryScanProgress {
        progress ?? .discoveringRepositories
    }

    var body: some View {
        HStack(spacing: 8) {
            if displayedProgress.isFinished {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }

            Text(displayedProgress.message)
                .font(.callout)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayedProgress.message)
    }
}

private struct ProjectSidebar: View {
    let scan: CatalogScan?
    @Binding var selectedProjectID: ProjectScan.ID?

    var body: some View {
        List(selection: $selectedProjectID) {
            if let scan {
                Section("GitHub Projects") {
                    ForEach(scan.projects) { project in
                        ProjectSidebarRow(project: project)
                            .tag(project.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let scan {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(scan.projects.count) GitHub project\(scan.projects.count == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                    Text(
                        "Found \(scan.githubRepositoryCount) GitHub repos among \(scan.gitRepositoryCount) Git repos in \(scan.candidateDirectoryCount) folders"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(scan.folderURL.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(scan.folderURL.path)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.bar)
            }
        }
        .navigationTitle("Projects")
    }
}

private struct ProjectSidebarRow: View {
    let project: ProjectScan

    private var isHealthy: Bool {
        project.warningMessage == nil && !project.branches.isEmpty && project.attentionCount == 0
    }

    private var summary: String {
        if project.warningMessage != nil, project.branches.isEmpty {
            return "Could not read branches"
        }
        if project.branches.isEmpty {
            return "No branches found"
        }
        if project.attentionCount == 0 {
            return "All \(project.branches.count) branches in sync"
        }
        return "\(project.attentionCount) of \(project.branches.count) need attention"
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isHealthy ? .green : .orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .lineLimit(1)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectDetailView: View {
    let project: ProjectScan
    @State private var filter: BranchFilter = .all
    @State private var searchText = ""

    private var visibleBranches: [BranchRecord] {
        project.branches.filter { branch in
            filter.includes(branch)
                && (searchText.isEmpty || branch.name.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ProjectHeader(project: project, filter: $filter)

            if let warning = project.warningMessage {
                WarningBanner(message: warning)
            }

            if visibleBranches.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                BranchTable(branches: visibleBranches)
            }
        }
        .navigationTitle(project.name)
        .searchable(text: $searchText, prompt: "Filter branches")
    }
}

private struct ProjectHeader: View {
    let project: ProjectScan
    @Binding var filter: BranchFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.title.bold())
                    Label(project.directoryURL.path, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.directoryURL.path)
                        .textSelection(.enabled)
                        .accessibilityLabel("Local repository path: \(project.directoryURL.path)")
                    Link(destination: project.remoteWebURL) {
                        Label(
                            "\(project.remoteWebURL.path.dropFirst()) · \(project.remoteName)",
                            systemImage: "link"
                        )
                    }
                    .font(.callout)
                }

                Spacer()

                Picker("Branch status", selection: $filter) {
                    ForEach(BranchFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .frame(width: 170)
            }

            HStack(spacing: 10) {
                SummaryCard(
                    title: "Local ahead",
                    count: project.count(for: .localAhead),
                    systemImage: "arrow.up.circle.fill",
                    color: .blue
                )
                SummaryCard(
                    title: "In sync",
                    count: project.count(for: .inSync),
                    systemImage: "checkmark.circle.fill",
                    color: .green
                )
                SummaryCard(
                    title: "Remote ahead",
                    count: project.count(for: .remoteAhead),
                    systemImage: "arrow.down.circle.fill",
                    color: .orange
                )
                SummaryCard(
                    title: "Diverged",
                    count: project.count(for: .diverged),
                    systemImage: "arrow.triangle.branch",
                    color: .red
                )
                SummaryCard(
                    title: "Unknown",
                    count: project.count(for: .unknown),
                    systemImage: "questionmark.circle.fill",
                    color: .gray
                )
            }
        }
        .padding(20)
    }
}

private struct SummaryCard: View {
    let title: String
    let count: Int
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(count, format: .number)
                    .font(.title3.bold())
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(count)")
    }
}

private struct WarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1))
        .accessibilityElement(children: .combine)
    }
}

private struct BranchTable: View {
    let branches: [BranchRecord]

    var body: some View {
        Table(branches) {
            TableColumn("Branch") { branch in
                Text(branch.name)
                    .lineLimit(1)
                    .help(branch.name)
            }
            .width(min: 160, ideal: 230)

            TableColumn("Status") { branch in
                BranchStatusLabel(branch: branch)
            }
            .width(min: 150, ideal: 190)

            TableColumn("Local") { branch in
                CommitLabel(value: branch.localShortOID)
            }
            .width(78)

            TableColumn("Remote") { branch in
                CommitLabel(value: branch.remoteShortOID)
            }
            .width(78)

            TableColumn("Ahead") { branch in
                CountLabel(value: branch.aheadCount)
            }
            .width(55)

            TableColumn("Behind") { branch in
                CountLabel(value: branch.behindCount)
            }
            .width(55)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
    }
}

private struct BranchStatusLabel: View {
    let branch: BranchRecord

    private var color: Color {
        switch branch.status {
        case .localAhead: .blue
        case .inSync: .green
        case .remoteAhead: .orange
        case .diverged: .red
        case .unknown: .gray
        }
    }

    private var systemImage: String {
        switch branch.status {
        case .localAhead: "arrow.up.circle.fill"
        case .inSync: "checkmark.circle.fill"
        case .remoteAhead: "arrow.down.circle.fill"
        case .diverged: "arrow.triangle.branch"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(branch.status.title)
                Text(branch.statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(branch.status.title), \(branch.statusDetail)")
    }
}

private struct CommitLabel: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(value == "—" ? .tertiary : .secondary)
            .textSelection(.enabled)
    }
}

private struct CountLabel: View {
    let value: Int?

    var body: some View {
        Text(value.map(String.init) ?? "—")
            .monospacedDigit()
            .foregroundStyle(value == nil ? .tertiary : .primary)
    }
}

private struct NoProjectsView: View {
    let scan: CatalogScan

    var body: some View {
        ContentUnavailableView {
            Label("No GitHub Projects Found", systemImage: "questionmark.folder")
        } description: {
            Text(
                "Found \(scan.gitRepositoryCount) Git repositories in \(scan.candidateDirectoryCount) folders, but none has a remote hosted on github.com."
            )
        }
    }
}

#Preview("Welcome") {
    ContentView()
        .frame(width: 960, height: 620)
}
