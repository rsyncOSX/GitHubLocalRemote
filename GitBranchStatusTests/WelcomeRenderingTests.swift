import AppKit
@testable import GitBranchStatus
import SwiftUI
import XCTest

final class WelcomeRenderingTests: XCTestCase {
    @MainActor
    func testWelcomeScreenRendersAtExpectedSize() throws {
        let renderer = ImageRenderer(
            content: ZStack {
                Color(nsColor: .windowBackgroundColor)
                ContentView()
            }
            .environment(\.colorScheme, .light)
            .frame(width: 960, height: 620)
        )
        renderer.scale = 2

        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 1920)
        XCTAssertEqual(image.height, 1240)

        let imageData = try XCTUnwrap(image.dataProvider?.data as? Data)
        XCTAssertGreaterThan(Set(imageData).count, 10, "The rendered screen should not be blank")

        let representation = NSBitmapImageRep(cgImage: image)
        let pngData = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        let outputPath = ProcessInfo.processInfo.environment["GIT_BRANCH_STATUS_SNAPSHOT_PATH"]
            ?? "/private/tmp/GitBranchStatusWelcome.png"
        try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
