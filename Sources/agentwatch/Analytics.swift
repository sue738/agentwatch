import Foundation

enum Agent: String, CaseIterable, Identifiable, Sendable, Codable {
    case codex = "Codex"
    case claude = "Claude"
    var id: String { rawValue }
}

struct Activity: Sendable {
    let agent: Agent
    let session: String
    let date: Date
    let kind: Kind
    let amount: Double
    let name: String
    enum Kind: Sendable, Equatable { case turn, tool, toolFailure, inputTokens, cachedTokens, outputTokens, context, model, taskDuration, skill }
}

struct Daily: Identifiable, Codable {
    let agent: Agent
    let date: Date
    var sessions = 0
    var turns = 0
    var tools = 0
    var failures = 0
    var inputTokens = 0.0
    var cachedTokens = 0.0
    var outputTokens = 0.0
    var taskDurationSeconds = 0.0
    var subagentSeconds = 0.0
    var parallelism: Double?
    var delegationPercent: Double?
    var skills = 0
    var activeSeconds = 0.0
    var longestRunSeconds = 0.0
    var contexts: [Double] = []
    var hours: Set<Int> = []
    var hourlyEvents: [Int: Int] = [:]
    var id: String { "\(agent.rawValue)-\(Int(date.timeIntervalSince1970))" }
    var contextMedian: Double? {
        let values = contexts.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }
    var contextQuartiles: (Double, Double, Double)? {
        let values = contexts.sorted()
        guard !values.isEmpty else { return nil }
        return (values[(values.count - 1) / 4], values[(values.count - 1) / 2], values[(values.count - 1) * 3 / 4])
    }
}

struct RateWindow: Codable {
    let usedPercent: Double
    let resetsAt: Date
    let observedAt: Date
}

struct TaskInterval: Codable {
    let start: Date
    let end: Date
    let subagent: Bool
}

struct Report {
    let daily: [Daily]
    let models: [Agent: [String: Int]]
    let toolNames: [Agent: [String: Int]]
    let sessions: [Agent: Int]
    let warnings: [Agent: String]
    let rateWindows: [String: RateWindow]
}

private struct FileSummary: Codable {
    var days: [Date: Daily] = [:]
    var models: [String: Int] = [:]
    var tools: [String: Int] = [:]
    var rateWindows: [String: RateWindow] = [:]
    var intervals: [TaskInterval] = []
}

private final class ScanCache {
    static let shared = ScanCache()
    private struct Entry: Codable {
        let path: String
        let modified: Date
        let size: Int
        let startDay: Date
        let summary: FileSummary
    }
    private let location = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AgentWatch/scan-cache-v5.json")
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    private init() {
        guard let data = try? Data(contentsOf: location), let loaded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(uniqueKeysWithValues: loaded.map { ($0.path, $0) })
    }

    func read(_ url: URL, modified: Date, size: Int, startDay: Date) -> FileSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url.path], entry.modified == modified, entry.size == size, entry.startDay == startDay else { return nil }
        return entry.summary
    }

    func store(_ summary: FileSummary, for url: URL, modified: Date, size: Int, startDay: Date) {
        lock.lock(); defer { lock.unlock() }
        entries[url.path] = Entry(path: url.path, modified: modified, size: size, startDay: startDay, summary: summary)
    }

    func persist(startDay: Date) {
        lock.lock()
        let values = entries.values.filter { $0.startDay == startDay }
        lock.unlock()
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: location, options: .atomic)
    }
}

enum TranscriptScanner {
    static func timestamp(_ value: Any?, fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> Date? {
        guard let value = value as? String else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }

    static func events(from data: Data, agent: Agent, session: String) -> [Activity] {
        var events: [Activity] = []
        var seenClaudeModels: Set<String> = []
        var seenClaudeTools: Set<String> = []
        var claudeUsageByMessage: [String: (input: Double, cached: Double, output: Double)] = [:]
        var seenCodexResponses: Set<String> = []
        var codexCumulative = 0.0
        var codexOutputCumulative = 0.0
        var codexCachedCumulative = 0.0
        var recordedInput = 0.0, recordedOutput = 0.0, recordedCached = 0.0
        var lastCountDate: Date?
        let hasUsageRecords = data.range(of: Data("\"type\":\"token_usage_record\"".utf8)) != nil
        var codexContextWindow = 0.0
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let claudeAssistant = Data("\"type\":\"assistant\"".utf8)
        let claudeUser = Data("\"type\":\"user\"".utf8)
        for line in data.split(separator: 10) {
            let header = String(decoding: line.prefix(900), as: UTF8.self)
            // Claude writes the outer `type` after message content, which can
            // be megabytes long. Search bytes throughout the line, then parse
            // only plausible user and assistant records.
            if agent == .claude && line.range(of: claudeAssistant) == nil && line.range(of: claudeUser) == nil { continue }
            if agent == .codex && !header.contains("\"type\":\"event_msg\"") && !header.contains("\"type\":\"response_item\"") && !header.contains("\"type\":\"turn_context\"") && !header.contains("\"type\":\"token_usage_record\"") { continue }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let date = timestamp(row["timestamp"], fractional: fractional, plain: plain), let type = row["type"] as? String else { continue }
            func emit(_ kind: Activity.Kind, _ amount: Double = 1, _ name: String = "") {
                events.append(Activity(agent: agent, session: session, date: date, kind: kind, amount: amount, name: name))
            }
            if agent == .codex {
                let payload = row["payload"] as? [String: Any] ?? [:]
                let subtype = payload["type"] as? String ?? ""
                if type == "event_msg" && subtype == "task_started" { emit(.turn) }
                if type == "turn_context" {
                    if let model = payload["model"] as? String, !model.isEmpty { emit(.model, 1, model) }
                }
                if type == "event_msg" && subtype == "task_complete", let milliseconds = payload["duration_ms"] as? NSNumber {
                    emit(.taskDuration, max(0, milliseconds.doubleValue / 1_000))
                }
                if type == "response_item" && ["function_call", "custom_tool_call"].contains(subtype) {
                    let name = payload["name"] as? String ?? "tool"
                    emit(.tool, 1, name)
                    if name == "Skill" || name == "functions.skill" { emit(.skill, 1, name) }
                }
                if type == "response_item" && ["function_call_output", "custom_tool_call_output"].contains(subtype) {
                    if payload["is_error"] as? Bool == true { emit(.toolFailure) }
                }
                if type == "token_usage_record" {
                    let response = payload["response_id"] as? String ?? ""
                    guard !response.isEmpty, seenCodexResponses.insert(response).inserted,
                          let usage = payload["usage"] as? [String: Any] else { continue }
                    let input = number(usage["input_tokens"])
                    let cached = number(usage["cached_input_tokens"])
                    let output = number(usage["output_tokens"])
                    emit(.inputTokens, input)
                    emit(.cachedTokens, cached)
                    emit(.outputTokens, output)
                    recordedInput += input
                    recordedCached += cached
                    recordedOutput += output
                }
                if type == "event_msg" && subtype == "token_count" {
                    let info = payload["info"] as? [String: Any] ?? [:]
                    codexContextWindow = number(info["model_context_window"])
                    if codexContextWindow > 0, let last = info["last_token_usage"] as? [String: Any] {
                        emit(.context, min(100, number(last["input_tokens"]) / codexContextWindow * 100))
                    }
                    if !hasUsageRecords, let usage = info["total_token_usage"] as? [String: Any] {
                        let input = number(usage["input_tokens"])
                        let cached = number(usage["cached_input_tokens"])
                        let output = number(usage["output_tokens"])
                        emit(.inputTokens, max(0, input - codexCumulative))
                        emit(.cachedTokens, max(0, cached - codexCachedCumulative))
                        emit(.outputTokens, max(0, output - codexOutputCumulative))
                        codexCumulative = input
                        codexCachedCumulative = cached
                        codexOutputCumulative = output
                    }
                    if hasUsageRecords, let usage = info["total_token_usage"] as? [String: Any] {
                        codexCumulative = max(codexCumulative, number(usage["input_tokens"]))
                        codexCachedCumulative = max(codexCachedCumulative, number(usage["cached_input_tokens"]))
                        codexOutputCumulative = max(codexOutputCumulative, number(usage["output_tokens"]))
                        lastCountDate = date
                    }
                }
            } else {
                if type == "user", let message = row["message"] as? [String: Any] {
                    if message["content"] is String { emit(.turn) }
                    if let blocks = message["content"] as? [[String: Any]] {
                        for block in blocks where block["type"] as? String == "tool_result" {
                            if block["is_error"] as? Bool == true { emit(.toolFailure) }
                        }
                    }
                }
                if type == "assistant", let message = row["message"] as? [String: Any] {
                    let id = message["id"] as? String ?? row["uuid"] as? String ?? ""
                    guard !id.isEmpty else { continue }
                    if let model = message["model"] as? String, !model.isEmpty, seenClaudeModels.insert(id).inserted { emit(.model, 1, model) }
                    if let blocks = message["content"] as? [[String: Any]] {
                        for block in blocks where block["type"] as? String == "tool_use" {
                            let toolID = block["id"] as? String ?? "\(id)-\(block["name"] as? String ?? "tool")"
                            if seenClaudeTools.insert(toolID).inserted { emit(.tool, 1, block["name"] as? String ?? "tool") }
                        }
                    }
                    if let usage = message["usage"] as? [String: Any] {
                        let cached = number(usage["cache_read_input_tokens"])
                        let input = number(usage["input_tokens"]) + cached + number(usage["cache_creation_input_tokens"])
                        let output = number(usage["output_tokens"])
                        let previous = claudeUsageByMessage[id] ?? (0, 0, 0)
                        if input > previous.input { emit(.inputTokens, input - previous.input) }
                        if cached > previous.cached { emit(.cachedTokens, cached - previous.cached) }
                        if output > previous.output { emit(.outputTokens, output - previous.output) }
                        claudeUsageByMessage[id] = (max(input, previous.input), max(cached, previous.cached), max(output, previous.output))
                        // Claude's local transcript does not record a reliable
                        // model context window across models; leave it unavailable.
                    }
                }
            }
        }
        // Some mixed-version transcripts contain usage records for only part
        // of a session. Reconcile against the provider's cumulative total once,
        // instead of discarding the older part or counting both formats twice.
        if hasUsageRecords, let date = lastCountDate {
            if codexCumulative > recordedInput {
                events.append(Activity(agent: agent, session: session, date: date, kind: .inputTokens, amount: codexCumulative - recordedInput, name: ""))
            }
            if codexCachedCumulative > recordedCached {
                events.append(Activity(agent: agent, session: session, date: date, kind: .cachedTokens, amount: codexCachedCumulative - recordedCached, name: ""))
            }
            if codexOutputCumulative > recordedOutput {
                events.append(Activity(agent: agent, session: session, date: date, kind: .outputTokens, amount: codexOutputCumulative - recordedOutput, name: ""))
            }
        }
        return events
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    static func rateWindows(from data: Data) -> [String: RateWindow] {
        var latest: [String: RateWindow] = [:]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for line in data.split(separator: 10) where line.range(of: Data("\"rate_limits\"".utf8)) != nil {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let observed = timestamp(row["timestamp"], fractional: fractional, plain: plain),
                  let payload = row["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any],
                      let used = window["used_percent"] as? NSNumber,
                      let reset = window["resets_at"] as? NSNumber else { continue }
                let name = "Codex \(key)"
                if observed > (latest[name]?.observedAt ?? .distantPast) {
                    latest[name] = RateWindow(usedPercent: used.doubleValue, resetsAt: Date(timeIntervalSince1970: reset.doubleValue), observedAt: observed)
                }
            }
        }
        return latest
    }

    static func codexIntervals(from data: Data) -> [TaskInterval] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var subagent = false
        var intervals: [TaskInterval] = []
        for line in data.split(separator: 10) {
            let head = String(decoding: line.prefix(300), as: UTF8.self)
            guard head.contains("\"type\":\"session_meta\"") || head.contains("\"type\":\"event_msg\"") && head.contains("\"task_complete\"") else { continue }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = row["payload"] as? [String: Any] else { continue }
            if row["type"] as? String == "session_meta" {
                if let source = payload["thread_source"] as? [String: Any] { subagent = source["subagent"] != nil }
                else { subagent = payload["thread_source"] as? String == "subagent" }
            } else if payload["type"] as? String == "task_complete",
                      let end = timestamp(row["timestamp"], fractional: fractional, plain: plain),
                      let milliseconds = payload["duration_ms"] as? NSNumber, milliseconds.doubleValue > 0 {
                intervals.append(TaskInterval(start: end.addingTimeInterval(-milliseconds.doubleValue / 1_000), end: end, subagent: subagent))
            }
        }
        return intervals
    }

    static func intervalMetrics(_ intervals: [TaskInterval]) -> (parallelism: Double?, delegation: Double?, longest: Double) {
        guard !intervals.isEmpty else { return (nil, nil, 0) }
        var boundaries: [(Date, Int)] = []
        var total = 0.0, delegated = 0.0
        for interval in intervals {
            let duration = max(0, interval.end.timeIntervalSince(interval.start))
            total += duration
            if interval.subagent { delegated += duration }
            boundaries.append((interval.start, 1))
            boundaries.append((interval.end, -1))
        }
        boundaries.sort { $0.0 == $1.0 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var active = 0, union = 0.0, longest = 0.0, current = 0.0
        var previous: Date?
        for (time, change) in boundaries {
            if let previous, active > 0 {
                let span = max(0, time.timeIntervalSince(previous))
                union += span
                current += span
                longest = max(longest, current)
            }
            active += change
            if active == 0 { current = 0 }
            previous = time
        }
        return (union > 0 ? total / union : nil, total > 0 ? delegated / total * 100 : nil, longest)
    }

    static func scan(now: Date = Date(), roots: [Agent: URL]? = nil) -> Report {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        let folders = roots ?? [
            .codex: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions"),
            .claude: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        ]
        var daily: [String: Daily] = [:]
        var models: [Agent: [String: Int]] = [:]
        var tools: [Agent: [String: Int]] = [:]
        var sessions: [Agent: Int] = [:]
        var warnings: [Agent: String] = [:]
        var rateWindows: [String: RateWindow] = [:]
        var intervalsByDay: [String: [TaskInterval]] = [:]
        let fm = FileManager.default
        for agent in Agent.allCases {
            guard let root = folders[agent], fm.fileExists(atPath: root.path) else {
                warnings[agent] = "履歴フォルダが見つかりません"
                continue
            }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                warnings[agent] = "履歴を開けません"
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" && !url.path.contains("/subagents/") {
                let properties = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = properties?.contentModificationDate ?? .distantPast
                let size = properties?.fileSize ?? 0
                guard modified >= since else { continue }
                let summary: FileSummary
                if let cached = ScanCache.shared.read(url, modified: modified, size: size, startDay: since) {
                    summary = cached
                } else {
                    guard let computed = autoreleasepool(invoking: { () -> FileSummary? in
                        guard let data = try? Data(contentsOf: url) else { return nil }
                        let session = url.deletingPathExtension().lastPathComponent
                        let events = events(from: data, agent: agent, session: session).filter { $0.date >= since && $0.date <= now }
                        var result = summarize(events, agent: agent, calendar: calendar)
                        if agent == .codex { result.rateWindows = Self.rateWindows(from: data) }
                        if agent == .codex { result.intervals = Self.codexIntervals(from: data) }
                        return result
                    }) else { continue }
                    summary = computed
                    ScanCache.shared.store(summary, for: url, modified: modified, size: size, startDay: since)
                }
                guard !summary.days.isEmpty else { continue }
                sessions[agent, default: 0] += 1
                for (day, source) in summary.days {
                    let key = "\(agent.rawValue)|\(day.timeIntervalSince1970)"
                    var point = daily[key] ?? Daily(agent: agent, date: day)
                    point.sessions += source.sessions
                    point.turns += source.turns
                    point.tools += source.tools
                    point.failures += source.failures
                    point.inputTokens += source.inputTokens
                    point.cachedTokens += source.cachedTokens
                    point.outputTokens += source.outputTokens
                    point.taskDurationSeconds += source.taskDurationSeconds
                    point.skills += source.skills
                    point.activeSeconds += source.activeSeconds
                    point.longestRunSeconds = max(point.longestRunSeconds, source.longestRunSeconds)
                    point.contexts.append(contentsOf: source.contexts)
                    point.hours.formUnion(source.hours)
                    for (hour, count) in source.hourlyEvents { point.hourlyEvents[hour, default: 0] += count }
                    daily[key] = point
                }
                for (name, count) in summary.models { models[agent, default: [:]][name, default: 0] += count }
                for (name, count) in summary.tools { tools[agent, default: [:]][name, default: 0] += count }
                for (name, window) in summary.rateWindows where window.observedAt > (rateWindows[name]?.observedAt ?? .distantPast) {
                    rateWindows[name] = window
                }
                if agent == .codex {
                    for interval in summary.intervals where interval.end >= since && interval.start <= now {
                        let day = calendar.startOfDay(for: interval.end)
                        let key = "\(agent.rawValue)|\(day.timeIntervalSince1970)"
                        intervalsByDay[key, default: []].append(interval)
                    }
                }
            }
        }
        for (key, intervals) in intervalsByDay {
            guard var point = daily[key] else { continue }
            let metrics = intervalMetrics(intervals)
            point.parallelism = metrics.parallelism
            point.delegationPercent = metrics.delegation
            point.longestRunSeconds = metrics.longest
            daily[key] = point
        }
        ScanCache.shared.persist(startDay: since)
        return Report(daily: daily.values.sorted { $0.date == $1.date ? $0.agent.rawValue < $1.agent.rawValue : $0.date < $1.date }, models: models, toolNames: tools, sessions: sessions, warnings: warnings, rateWindows: rateWindows)
    }

    private static func summarize(_ events: [Activity], agent: Agent, calendar: Calendar) -> FileSummary {
        var summary = FileSummary()
        var previous: Date?
        var runSeconds = 0.0
        for event in events.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: event.date)
            var point = summary.days[day] ?? Daily(agent: agent, date: day)
            point.sessions = 1
            if let previous {
                let gap = event.date.timeIntervalSince(previous)
                if gap >= 0 && gap <= 300 {
                    point.activeSeconds += gap
                    runSeconds += gap
                    point.longestRunSeconds = max(point.longestRunSeconds, runSeconds)
                } else { runSeconds = 0 }
            }
            previous = event.date
            point.hours.insert(calendar.component(.hour, from: event.date))
            if event.kind == .turn || event.kind == .tool {
                point.hourlyEvents[calendar.component(.hour, from: event.date), default: 0] += 1
            }
            switch event.kind {
            case .turn: point.turns += 1
            case .tool:
                point.tools += 1
                summary.tools[event.name, default: 0] += 1
            case .toolFailure: point.failures += 1
            case .inputTokens: point.inputTokens += event.amount
            case .cachedTokens: point.cachedTokens += event.amount
            case .outputTokens: point.outputTokens += event.amount
            case .taskDuration: point.taskDurationSeconds += event.amount
            case .skill: point.skills += 1
            case .context: point.contexts.append(event.amount)
            case .model: summary.models[event.name, default: 0] += 1
            }
            summary.days[day] = point
        }
        return summary
    }
}
