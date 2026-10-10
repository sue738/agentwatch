import XCTest
@testable import agentwatch

final class LiveStateTests: XCTestCase {
    func testParsesRunawakeStateAndGroupsSubagentsUnderTheirSession() {
        let json = """
        {"count":4,"holding":true,"paused":false,"updated":"2026-10-10T13:09:00Z","items":[
          {"kind":"agent","name":"Claude Code","place":"~/private/akcheck"},
          {"kind":"agent","name":"Claude Code","place":"~/private/akcheck"},
          {"kind":"subagent","name":"Claude Code","place":"~/private/akcheck"},
          {"kind":"terminal","name":"rsync","place":"~/backup"}]}
        """
        let state = LiveState.parse(Data(json.utf8))
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.count, 4)
        XCTAssertEqual(state?.agents.count, 2)
        XCTAssertEqual(state?.subagents.count, 1)
        XCTAssertEqual(state?.terminals.count, 1)
        let groups = state?.groups ?? []
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].name, "Claude Code")
        XCTAssertEqual(groups[0].sessions, 2)
        XCTAssertEqual(groups[0].subagents, 1)
        XCTAssertEqual(groups[1].kind, "terminal")
    }

    func testRejectsMalformedJSON() {
        XCTAssertNil(LiveState.parse(Data("{not json".utf8)))
    }
}
