import Foundation

// Synthetic numbers for the public README screenshot. Never reads local history.
enum SampleData {
    static func make(now: Date = Date()) -> (Report, LegacyReport) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var days: [Daily] = []
        var legacy = LegacyReport()

        for offset in -29...0 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let dayIndex = offset + 29
            for agent in Agent.allCases {
                let isCodex = agent == .codex
                let activity = 0.7 + Double((dayIndex * (isCodex ? 7 : 11)) % 9) / 10
                var day = Daily(agent: agent, date: date)
                day.sessions = Int((isCodex ? 3.0 : 2.0) * activity)
                day.turns = Int((isCodex ? 28.0 : 22.0) * activity)
                day.tools = Int((isCodex ? 96.0 : 72.0) * activity)
                day.failures = dayIndex % 6 == 0 ? 2 : 1
                day.inputTokens = (isCodex ? 620_000 : 440_000) * activity
                day.cachedTokens = day.inputTokens * 0.42
                day.outputTokens = (isCodex ? 95_000 : 72_000) * activity
                day.taskDurationSeconds = (isCodex ? 6_200 : 4_900) * activity
                day.longestRunSeconds = day.taskDurationSeconds * 0.44
                day.parallelism = 1.1 + Double(dayIndex % 5) * 0.17
                day.delegationPercent = 8 + Double(dayIndex % 7) * 4
                day.contexts = [31, 44, 58, 70].map { $0 + Double(dayIndex % 6) }
                day.hourlyEvents = [9: 3, 10: 8, 11: 5, 14: 7, 15: 4, 20: 2]
                days.append(day)

                if !isCodex {
                    var metrics = LegacyDay()
                    metrics.hours = day.taskDurationSeconds / 3600
                    metrics.longestHours = day.longestRunSeconds / 3600
                    metrics.parallelism = day.parallelism
                    metrics.delegationPercent = day.delegationPercent
                    metrics.inputTokens = day.inputTokens
                    metrics.outputTokens = day.outputTokens
                    metrics.cost = 7.5 * activity
                    metrics.costByModel = ["Sonnet": 5.8 * activity, "Opus": 1.7 * activity]
                    metrics.context = (36, 53, 72)
                    metrics.toolFailurePercent = 2 + Double(dayIndex % 4)
                    metrics.selfCorrectionPercent = 12 + Double(dayIndex % 6) * 2
                    metrics.bounces = Double(dayIndex % 3)
                    legacy.days[date] = metrics
                }
            }
        }

        func window(_ used: Double, hoursUntilReset: Double) -> RateWindow {
            RateWindow(usedPercent: used,
                       resetsAt: now.addingTimeInterval(hoursUntilReset * 3600),
                       observedAt: now)
        }
        let report = Report(
            daily: days,
            models: [.codex: ["gpt-5": 130, "gpt-5-mini": 42],
                     .claude: ["Sonnet": 115, "Opus": 34]],
            toolNames: [.codex: ["exec_command": 178, "apply_patch": 73, "web": 22],
                        .claude: ["Bash": 124, "Read": 96, "Edit": 51]],
            sessions: [.codex: 62, .claude: 48],
            warnings: [:],
            rateWindows: ["Codex primary": window(24, hoursUntilReset: 2.5),
                          "Codex secondary": window(38, hoursUntilReset: 72)]
        )
        legacy.rateWindows = ["Claude 5時間": window(32, hoursUntilReset: 2.5),
                              "Claude 週間": window(54, hoursUntilReset: 72)]
        legacy.topSkills = [("review", 18), ("planning", 12)]
        legacy.topFailures = [("Bash", 124, 3), ("Edit", 51, 2)]
        return (report, legacy)
    }
}
