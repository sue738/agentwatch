import AppKit
import SwiftUI
import XCTest
@testable import agentwatch

final class PanelSizingTests: XCTestCase {
    @MainActor
    func testPanelUsesContentHeightWhileLoading() {
        let dashboard = Dashboard(model: DashboardModel())
        let contentHeight = NSHostingView(rootView: dashboard.dashboardContent).fittingSize.height
        let panelHeight = NSHostingView(rootView: dashboard).fittingSize.height

        XCTAssertGreaterThan(contentHeight, 100)
        XCTAssertEqual(panelHeight, contentHeight, accuracy: 2)
    }

    @MainActor
    func testLoadedPanelStopsAtScreenHeight() {
        let model = DashboardModel()
        let (report, legacy) = SampleData.make()
        model.report = report
        model.legacy = legacy
        let dashboard = Dashboard(model: model)
        let contentHeight = NSHostingView(rootView: dashboard.dashboardContent).fittingSize.height
        let panelHeight = NSHostingView(rootView: dashboard).fittingSize.height

        XCTAssertGreaterThan(contentHeight, 500)
        XCTAssertGreaterThan(panelHeight, 500)
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        XCTAssertEqual(panelHeight, min(contentHeight, screenLimit), accuracy: 2)
    }
}
