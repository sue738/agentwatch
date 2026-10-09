import XCTest
@testable import agentwatch

final class TranscriptScannerTests: XCTestCase {
    func testCodexCountsEventsAndDoesNotDoubleCountTokenFormats() {
        let text = """
        {"timestamp":"2026-10-06T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-10-06T01:00:01.000Z","type":"response_item","payload":{"type":"function_call","name":"exec"}}
        {"timestamp":"2026-10-06T01:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10},"model_context_window":1000}}}
        {"timestamp":"2026-10-06T01:00:02.000Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":100,"output_tokens":10}}}
        """
        let events = TranscriptScanner.events(from: Data(text.utf8), agent: .codex, session: "test")
        XCTAssertEqual(events.filter { $0.kind == .turn }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .inputTokens }.reduce(0) { $0 + $1.amount }, 100)
    }

    func testClaudeSkipsDuplicateAssistantMessage() {
        let text = """
        {"timestamp":"2026-10-06T01:00:00Z","type":"user","message":{"content":"hello"}}
        {"timestamp":"2026-10-06T01:00:01Z","type":"assistant","message":{"id":"m1","model":"claude-test","content":[{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":10,"cache_read_input_tokens":20,"output_tokens":5}}}
        {"timestamp":"2026-10-06T01:00:02Z","type":"assistant","message":{"id":"m1","model":"claude-test","content":[{"type":"tool_use","name":"Bash"}],"usage":{"input_tokens":10,"cache_read_input_tokens":20,"output_tokens":5}}}
        """
        let events = TranscriptScanner.events(from: Data(text.utf8), agent: .claude, session: "test")
        XCTAssertEqual(events.filter { $0.kind == .turn }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .tool }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .inputTokens }.reduce(0) { $0 + $1.amount }, 30)
        XCTAssertEqual(events.filter { $0.kind == .cachedTokens }.reduce(0) { $0 + $1.amount }, 20)
    }

    func testClaudeOuterTypeAfterLongMessageBody() {
        let body = String(repeating: "x", count: 2_000)
        let line = """
        {"timestamp":"2026-10-06T01:00:01Z","message":{"id":"m2","content":[{"type":"tool_use","id":"tool-2","name":"Bash","input":"\(body)"}],"usage":{"input_tokens":10,"output_tokens":5}},"type":"assistant"}
        """
        let events = TranscriptScanner.events(from: Data(line.utf8), agent: .claude, session: "test")
        XCTAssertEqual(events.filter { $0.kind == .tool }.count, 1)
    }

    func testClaudeUserWithLongTailStillCounts() {
        let body = String(repeating: "x", count: 2_000)
        let line = """
        {"message":{"content":"\(body)"},"type":"user","timestamp":"2026-10-06T01:00:01Z","other":"\(body)"}
        """
        let events = TranscriptScanner.events(from: Data(line.utf8), agent: .claude, session: "test")
        XCTAssertEqual(events.filter { $0.kind == .turn }.count, 1)
    }

    func testCodexRateLimitAndDurationIntervals() {
        let text = """
        {"timestamp":"2026-10-06T01:00:00.000Z","type":"session_meta","payload":{"thread_source":{"subagent":{"parent":"redacted"}}}}
        {"timestamp":"2026-10-06T01:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","duration_ms":2000}}
        {"timestamp":"2026-10-06T01:00:03.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":35,"resets_at":1791262656}}}}
        """
        let data = Data(text.utf8)
        let intervals = TranscriptScanner.codexIntervals(from: data)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertTrue(intervals[0].subagent)
        XCTAssertEqual(intervals[0].end.timeIntervalSince(intervals[0].start), 2, accuracy: 0.001)
        XCTAssertEqual(TranscriptScanner.rateWindows(from: data)["Codex primary"]?.usedPercent, 35)
    }

    func testParallelismUsesUnionAndDelegatedTime() {
        let start = Date(timeIntervalSince1970: 0)
        let intervals = [
            TaskInterval(start: start, end: start.addingTimeInterval(10), subagent: false),
            TaskInterval(start: start.addingTimeInterval(5), end: start.addingTimeInterval(15), subagent: true)
        ]
        let metrics = TranscriptScanner.intervalMetrics(intervals)
        XCTAssertEqual(metrics.parallelism ?? 0, 20.0 / 15.0, accuracy: 0.001)
        XCTAssertEqual(metrics.delegation ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(metrics.longest, 15, accuracy: 0.001)
    }

    func testMixedCodexUsageRecordsReconcileCumulativeTotals() {
        let text = """
        {"timestamp":"2026-10-06T01:00:00.000Z","type":"token_usage_record","payload":{"response_id":"r1","usage":{"input_tokens":60,"cached_input_tokens":20,"output_tokens":10}}}
        {"timestamp":"2026-10-06T01:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":30,"output_tokens":15}}}}
        """
        let events = TranscriptScanner.events(from: Data(text.utf8), agent: .codex, session: "test")
        XCTAssertEqual(events.filter { $0.kind == .inputTokens }.reduce(0) { $0 + $1.amount }, 100)
        XCTAssertEqual(events.filter { $0.kind == .cachedTokens }.reduce(0) { $0 + $1.amount }, 30)
        XCTAssertEqual(events.filter { $0.kind == .outputTokens }.reduce(0) { $0 + $1.amount }, 15)
    }
}
