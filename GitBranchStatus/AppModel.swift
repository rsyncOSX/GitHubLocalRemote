import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var phase: ScanPhase = .idle
    var catalogScan: CatalogScan?
    var selectedProjectID: ProjectScan.ID?
    var errorMessage: String?
    var scanProgress: RepositoryScanProgress?

    @ObservationIgnored private let scanner: RepositoryScanner
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0

    init(scanner: RepositoryScanner = RepositoryScanner(policy: .standard)) {
        self.scanner = scanner
    }

    var selectedProject: ProjectScan? {
        guard let selectedProjectID else { return nil }
        return catalogScan?.projects.first { $0.id == selectedProjectID }
    }

    var isScanning: Bool {
        phase == .scanning
    }

    func selectFolder(_ folderURL: URL) {
        catalogScan = nil
        selectedProjectID = nil
        scan(folderURL: folderURL)
    }

    func rescan() {
        guard let folderURL = catalogScan?.folderURL else { return }
        scan(folderURL: folderURL)
    }

    private func scan(folderURL: URL) {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning
        errorMessage = nil
        scanProgress = .discoveringRepositories

        scanTask = Task {
            do {
                let result = try await scanner.scan(
                    folderURL: folderURL,
                    progress: { progress in
                        guard !Task.isCancelled,
                              self.scanGeneration == generation
                        else { return }
                        self.scanProgress = progress
                    },
                    update: { partialResult in
                        guard !Task.isCancelled,
                              self.scanGeneration == generation
                        else { return }
                        self.catalogScan = partialResult
                        if self.selectedProjectID == nil {
                            self.selectedProjectID = partialResult.projects.first?.id
                        }
                    }
                )
                guard !Task.isCancelled, scanGeneration == generation else { return }

                catalogScan = result
                if let selectedProjectID,
                   result.projects.contains(where: { $0.id == selectedProjectID })
                {
                    self.selectedProjectID = selectedProjectID
                } else {
                    selectedProjectID = result.projects.first?.id
                }
                phase = .loaded
                scanProgress = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, scanGeneration == generation else { return }
                phase = catalogScan == nil ? .idle : .loaded
                scanProgress = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
