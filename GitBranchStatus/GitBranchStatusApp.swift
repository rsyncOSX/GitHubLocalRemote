import SwiftUI

@main
struct GitBranchStatusApp: App {
    var body: some Scene {
        Window("Git Branch Status", id: "main") {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1120, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
    }
}
