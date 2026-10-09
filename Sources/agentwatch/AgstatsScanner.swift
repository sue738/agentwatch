import Foundation
import Darwin

// agstats owns the cross-agent transcript interpretation. The local scanner
// remains the fallback and supplies context bands and Codex rate windows,
// which agstats does not currently expose.
enum AgstatsScanner {
    private struct Export: Decodable {
        struct Day: Decodable {
            let agent: Agent
            let date: Double
            let sessions: Int
            let turns: Int
            let tools: Int
            let failures: Int
            let inputTokens: Double
            let cachedTokens: Double
            let outputTokens: Double
            let taskDurationSeconds: Double
            let subagentSeconds: Double
            let longestRunSeconds: Double
            let parallelism: Double?
            let delegationPercent: Double?
            let hourlyEvents: [String: Int]
        }
        let installed: [String: Bool]
        let daily: [Day]
        let models: [String: [String: Int]]
        let toolNames: [String: [String: Int]]
        let sessions: [String: Int]
    }

    private static let cacheURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/AgentWatch/agstats-cache-v1.json")
    private static let cacheLifetime: TimeInterval = 15 * 60

    private static func binary(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)",
                          "/usr/local/bin/\(name)", "\(home)/.npm-global/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var bridge: String? {
        if let bundled = Bundle.main.path(forResource: "agstats-bridge", ofType: "js") { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts/agstats-bridge.js").path
        return FileManager.default.fileExists(atPath: development) ? development : nil
    }

    static var isAvailable: Bool { binary("agstats") != nil && binary("node") != nil && bridge != nil }

    static var cachedAt: Date? {
        try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func cached(native: Report) -> Report? {
        guard isAvailable,
              let modified = cachedAt,
              Date().timeIntervalSince(modified) < cacheLifetime,
              let data = try? Data(contentsOf: cacheURL) else { return nil }
        return merge(data, native: native)
    }

    static func fresh(native: Report) -> Report? {
        guard let node = binary("node"), let cli = binary("agstats"), let bridge else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = [bridge, cli]
        task.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        task.standardOutput = stdout
        let lock = NSLock()
        var bytes = Data()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); bytes.append(chunk); lock.unlock()
        }
        do { try task.run() } catch { stdout.fileHandleForReading.readabilityHandler = nil; return nil }
        let deadline = Date().addingTimeInterval(90)
        while task.isRunning && Date() < deadline { usleep(50_000) }
        if task.isRunning {
            task.terminate()
            let grace = Date().addingTimeInterval(2)
            while task.isRunning && Date() < grace { usleep(20_000) }
            if task.isRunning { _ = Darwin.kill(task.processIdentifier, SIGKILL) }
        }
        task.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        let tail = stdout.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); bytes.append(tail); let data = bytes; lock.unlock()
        guard task.terminationStatus == 0, let report = merge(data, native: native) else { return nil }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if (try? data.write(to: cacheURL, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
        return report
    }

    static func merge(_ data: Data, native: Report) -> Report? {
        guard let export = try? JSONDecoder().decode(Export.self, from: data) else { return nil }
        let replacement = Set(Agent.allCases.filter { export.installed[$0.rawValue] == true })
        guard !replacement.isEmpty else { return nil }
        let nativeDays = Dictionary(uniqueKeysWithValues: native.daily.map {
            ("\($0.agent.rawValue)|\($0.date.timeIntervalSince1970)", $0)
        })
        var daily = native.daily.filter { !replacement.contains($0.agent) }
        for source in export.daily where replacement.contains(source.agent) {
            let date = Date(timeIntervalSince1970: source.date)
            var day = Daily(agent: source.agent, date: date)
            day.sessions = source.sessions
            day.turns = source.turns
            day.tools = source.tools
            day.failures = source.failures
            day.inputTokens = source.inputTokens
            day.cachedTokens = source.cachedTokens
            day.outputTokens = source.outputTokens
            day.taskDurationSeconds = source.taskDurationSeconds
            day.subagentSeconds = source.subagentSeconds
            day.longestRunSeconds = source.longestRunSeconds
            day.parallelism = source.parallelism
            day.delegationPercent = source.delegationPercent
            day.hourlyEvents = Dictionary(uniqueKeysWithValues: source.hourlyEvents.compactMap {
                guard let hour = Int($0.key) else { return nil }
                return (hour, $0.value)
            })
            if let local = nativeDays["\(source.agent.rawValue)|\(date.timeIntervalSince1970)"] {
                day.contexts = local.contexts
                day.skills = local.skills
            }
            daily.append(day)
        }
        var models = native.models
        var toolNames = native.toolNames
        var sessions = native.sessions
        var warnings = native.warnings
        for agent in replacement {
            models[agent] = export.models[agent.rawValue] ?? [:]
            toolNames[agent] = export.toolNames[agent.rawValue] ?? [:]
            sessions[agent] = export.sessions[agent.rawValue] ?? 0
            warnings.removeValue(forKey: agent)
        }
        return Report(daily: daily.sorted { $0.date == $1.date ? $0.agent.rawValue < $1.agent.rawValue : $0.date < $1.date },
                      models: models, toolNames: toolNames, sessions: sessions,
                      warnings: warnings, rateWindows: native.rateWindows, agstatsAgents: replacement)
    }
}
