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

    @ObservationIgnored private let scanner = RepositoryScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

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
        phase = .scanning
        errorMessage = nil
        scanProgress = .discoveringRepositories

        scanTask = Task {
            do {
                let result = try await scanner.scan(folderURL: folderURL) { [weak self] progress in
                    guard !Task.isCancelled else { return }
                    self?.scanProgress = progress
                }
                guard !Task.isCancelled else { return }

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
                guard !Task.isCancelled else { return }
                phase = catalogScan == nil ? .idle : .loaded
                scanProgress = nil
                errorMessage = error.localizedDescription
            }
        }
    }
}
