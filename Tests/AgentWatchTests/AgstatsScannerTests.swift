import Foundation
import XCTest
@testable import agentwatch

final class AgstatsScannerTests: XCTestCase {
    func testReplacesInstalledAgentAndPreservesLocalOnlyMetrics() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var claude = Daily(agent: .claude, date: date)
        claude.contexts = [42, 58]
        claude.turns = 3
        var codex = Daily(agent: .codex, date: date)
        codex.turns = 7
        let rate = RateWindow(usedPercent: 23, resetsAt: date, observedAt: date)
        let native = Report(daily: [claude, codex], models: [.codex: ["local": 1]],
                            toolNames: [:], sessions: [.codex: 1], warnings: [:],
                            rateWindows: ["Codex primary": rate])
        let fixture: [String: Any] = [
            "installed": ["Claude": true, "Codex": false],
            "daily": [[
                "agent": "Claude", "date": date.timeIntervalSince1970,
                "sessions": 2, "turns": 9, "tools": 20, "failures": 1,
                "inputTokens": 1200, "cachedTokens": 300, "outputTokens": 200,
                "taskDurationSeconds": 3600, "subagentSeconds": 600,
                "longestRunSeconds": 900, "parallelism": 1.2,
                "delegationPercent": 16.7, "hourlyEvents": ["9": 4]
            ]],
            "models": ["Claude": ["Sonnet": 5]],
            "toolNames": ["Claude": ["Read": 12]],
            "sessions": ["Claude": 2]
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let merged = try XCTUnwrap(AgstatsScanner.merge(data, native: native))
        let newClaude = try XCTUnwrap(merged.daily.first { $0.agent == .claude })
        XCTAssertEqual(newClaude.turns, 9)
        XCTAssertEqual(newClaude.taskDurationSeconds, 3600)
        XCTAssertEqual(newClaude.contexts, [42, 58])
        XCTAssertEqual(newClaude.hourlyEvents[9], 4)
        XCTAssertEqual(merged.daily.first { $0.agent == .codex }?.turns, 7)
        XCTAssertEqual(merged.models[.codex]?["local"], 1)
        XCTAssertEqual(merged.models[.claude]?["Sonnet"], 5)
        XCTAssertNotNil(merged.rateWindows["Codex primary"])
        XCTAssertEqual(merged.agstatsAgents, [.claude])
    }

    func testInvalidExportFallsBack() {
        let native = Report(daily: [], models: [:], toolNames: [:], sessions: [:],
                            warnings: [:], rateWindows: [:])
        XCTAssertNil(AgstatsScanner.merge(Data("{}".utf8), native: native))
    }
}
