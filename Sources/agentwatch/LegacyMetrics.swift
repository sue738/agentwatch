import Foundation
import Darwin

// Claude-only companion metrics retain ccwatch's source definitions. The
// scanner never substitutes Codex counts for metrics with different semantics.
struct LegacyDay {
    var cost: Double?
    var costByModel: [String: Double] = [:]
    var inputTokens: Double?
    var outputTokens: Double?
    var hours: Double?
    var longestHours: Double?
    var parallelism: Double?
    var delegationPercent: Double?
    var context: (Double, Double, Double)?
    var selfCorrectionPercent: Double?
    var bounces: Double?
    var turnsPerSession: Double?
    var toolFailurePercent: Double?
}

struct LegacyReport {
    var days: [Date: LegacyDay] = [:]
    var topSkills: [(String, Int)] = []
    var topFailures: [(String, Int, Double)] = []
    var skillsFired: Int?
    var skillsTotal: Int?
    var available: Set<String> = []
    var rateWindows: [String: RateWindow] = [:]
}

enum LegacyScanner {
    private static func cli(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func stopAndReap(_ task: Process) {
        guard task.isRunning else { return }
        task.terminate()
        let deadline = Date().addingTimeInterval(2)
        while task.isRunning && Date() < deadline { usleep(20_000) }
        if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
        if task.isRunning { task.waitUntilExit() }
    }

    private static func json(_ name: String, _ args: [String]) -> [String: Any]? {
        guard let executable = cli(name) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        let lock = NSLock()
        var bytes = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); bytes.append(chunk); lock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        do { try task.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(120)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        let timedOut = task.isRunning
        if timedOut { stopAndReap(task) }
        usleep(50_000)
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let result = bytes; lock.unlock()
        guard !timedOut, task.terminationStatus == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: result) as? [String: Any]
    }

    private static func day(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: value)
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    private static func claudeAccessToken() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        if (try? task.run()) != nil {
            let deadline = Date().addingTimeInterval(45)
            while task.isRunning && Date() < deadline { usleep(20_000) }
            let timedOut = task.isRunning
            if timedOut { stopAndReap(task) }
            if !timedOut && task.terminationStatus == 0 {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let oauth = root["claudeAiOauth"] as? [String: Any],
                   let token = oauth["accessToken"] as? String { return token }
            }
        }
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }

    private static var claudeRateCacheURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/AgentWatch/claude-rate-cache-v1.json")
    }

    static func cachedClaudeRateWindows() -> [String: RateWindow] {
        guard let data = try? Data(contentsOf: claudeRateCacheURL),
              let cached = try? JSONDecoder().decode([String: RateWindow].self, from: data) else { return [:] }
        let now = Date()
        return cached.filter {
            now.timeIntervalSince($0.value.observedAt) <= 12 * 60 * 60 && $0.value.resetsAt > now
        }
    }

    private static func cacheClaudeRateWindows(_ windows: [String: RateWindow]) {
        guard !windows.isEmpty,
              let data = try? JSONEncoder().encode(windows) else { return }
        try? FileManager.default.createDirectory(at: claudeRateCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: claudeRateCacheURL, options: .atomic)
    }

    static func claudeRateWindows() -> [String: RateWindow] {
        guard let token = claudeAccessToken() else { return cachedClaudeRateWindows() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-cli/2.1.220 (external, cli)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 12) == .success, status == 200,
              let responseData,
              let body = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let limits = body["limits"] as? [[String: Any]] else {
            if CommandLine.arguments.contains("--legacy-summary") { fputs("Claude usage endpoint unavailable (HTTP \(status))\n", stderr) }
            return cachedClaudeRateWindows()
        }
        let observed = Date()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var windows: [String: RateWindow] = [:]
        for item in limits {
            guard let kind = item["kind"] as? String,
                  let percent = item["percent"] as? NSNumber,
                  let resetText = item["resets_at"] as? String,
                  let reset = fractional.date(from: resetText) ?? plain.date(from: resetText) else { continue }
            let name: String
            switch kind {
            case "session": name = "Claude 5時間"
            case "weekly_all": name = "Claude 週間"
            case "weekly_scoped":
                let scope = item["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                name = "Claude \(model?["display_name"] as? String ?? "モデル別週間")"
            default: continue
            }
            windows[name] = RateWindow(usedPercent: percent.doubleValue, resetsAt: reset, observedAt: observed)
        }
        if windows.isEmpty { return cachedClaudeRateWindows() }
        cacheClaudeRateWindows(windows)
        return windows
    }

    static func scan(includeRateWindows: Bool = true) -> LegacyReport {
        var report = LegacyReport()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        let since = formatter.string(from: Calendar.current.date(byAdding: .day, value: -29, to: Date()) ?? Date())
        let jobs: [(String, String, [String])] = [
            ("hours", "cchours", ["--daily", "--days", "30", "--json"]),
            ("cost", "ccusage", ["daily", "--since", since, "--breakdown", "--json"]),
            ("context", "ccsendstats", ["--daily", "--days", "30", "--json"]),
            ("topSkills", "ccskillstats", ["--json", "--days", "30"]),
            ("attention", "ccattention", ["--json", "--days", "30"]),
            ("toolDaily", "ccflaky", ["--daily", "--json", "--days", "30"]),
            ("toolTop", "ccflaky", ["--json", "--days", "30"])
        ]
        let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AgentWatch/legacy-cache-v1.json")
        let renderingPreview = CommandLine.arguments.contains("--render-preview")
            || CommandLine.arguments.contains("--render-menubar")
        var results: [String: [String: Any]] = [:]
        if let modified = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           (renderingPreview || Date().timeIntervalSince(modified) < 900),
           let data = try? Data(contentsOf: cache),
           let stored = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            results = stored
        } else {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 3
            let lock = NSLock()
            for (key, command, arguments) in jobs {
                queue.addOperation {
                    guard let result = json(command, arguments) else { return }
                    lock.lock(); results[key] = result; lock.unlock()
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            if let data = try? JSONSerialization.data(withJSONObject: results) {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
        }
        if let result = results["hours"],
           let rows = result["daily"] as? [[String: Any]] {
            report.available.insert("hours")
            for row in rows {
                guard let date = day(row["date"] as? String) else { continue }
                var metric = report.days[date] ?? LegacyDay()
                metric.hours = number(row["agentHours"])
                metric.longestHours = number(row["longestRunHours"])
                metric.parallelism = number(row["parallelism"])
                if let sub = number(row["subagentHours"]), let hours = metric.hours, hours > 0 { metric.delegationPercent = sub / hours * 100 }
                report.days[date] = metric
            }
        }
        if let result = results["cost"],
           let rows = result["daily"] as? [[String: Any]] {
            report.available.insert("cost")
            for row in rows {
                guard let date = day((row["date"] as? String) ?? (row["period"] as? String)),
                      let models = row["modelBreakdowns"] as? [[String: Any]] else { continue }
                var metric = report.days[date] ?? LegacyDay()
                metric.cost = models.reduce(0) { $0 + (number($1["cost"]) ?? 0) }
                for model in models {
                    guard let name = model["modelName"] as? String else { continue }
                    metric.costByModel[name.replacingOccurrences(of: "claude-", with: ""), default: 0] += number(model["cost"]) ?? 0
                }
                metric.inputTokens = models.reduce(0) { total, model in
                    total + (number(model["inputTokens"]) ?? 0) + (number(model["cacheCreationTokens"]) ?? 0) + (number(model["cacheReadTokens"]) ?? 0)
                }
                metric.outputTokens = models.reduce(0) { $0 + (number($1["outputTokens"]) ?? 0) }
                report.days[date] = metric
            }
        }
        if let result = results["context"],
           let rows = result["daily"] as? [[String: Any]] {
            report.available.insert("context")
            for row in rows {
                guard let date = day(row["date"] as? String),
                      let p25 = number(row["p25Pct"]), let p50 = number(row["p50Pct"]), let p75 = number(row["p75Pct"]) else { continue }
                var metric = report.days[date] ?? LegacyDay()
                metric.context = (p25, p50, p75)
                report.days[date] = metric
            }
        }
        if let result = results["topSkills"],
           let rows = result["skills"] as? [[String: Any]] {
            report.topSkills = rows.compactMap { row in
                guard let name = row["name"] as? String, let total = row["total"] as? Int, total > 0 else { return nil }
                return (name, total)
            }.sorted { $0.1 > $1.1 }.prefix(5).map { $0 }
        }
        if let result = results["attention"] {
            report.available.insert("attention")
            for (key, value) in result {
                guard let date = day(key), let row = value as? [String: Any] else { continue }
                var metric = report.days[date] ?? LegacyDay()
                if let user = number(row["user"]), let threads = number(row["threads"]), threads > 0 {
                    metric.turnsPerSession = user / threads
                }
                if let mine = number(row["mine"]), mine > 0 { metric.selfCorrectionPercent = (number(row["selffix"]) ?? 0) / mine * 100 }
                metric.bounces = number(row["blocks"])
                report.days[date] = metric
            }
        }
        if let result = results["toolDaily"], let rows = result["daily"] as? [[String: Any]] {
            report.available.insert("toolFailures")
            for row in rows {
                guard let date = day(row["date"] as? String) else { continue }
                var metric = report.days[date] ?? LegacyDay()
                metric.toolFailurePercent = number(row["errorRate"])
                report.days[date] = metric
            }
        }
        if let result = results["toolTop"], let rows = result["rows"] as? [[String: Any]] {
            report.topFailures = rows.compactMap { row in
                guard let name = row["name"] as? String,
                      let calls = row["calls"] as? Int,
                      let rate = number(row["errorRate"]), calls >= 5, rate > 0 else { return nil }
                return (name, calls, rate)
            }.sorted { $0.2 > $1.2 }.prefix(5).map { $0 }
        }
        if includeRateWindows { report.rateWindows = claudeRateWindows() }
        return report
    }
}
