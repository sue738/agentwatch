import SwiftUI
import Charts
import AppKit

enum Scope: String, CaseIterable, Identifiable {
    case all = "すべて", codex = "Codex", claude = "Claude"
    var id: String { rawValue }
    func includes(_ agent: Agent) -> Bool {
        self == .all || (self == .codex && agent == .codex) || (self == .claude && agent == .claude)
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var selectedScope: Scope = Scope(rawValue: UserDefaults.standard.string(forKey: "AgentWatch.selectedScope") ?? "") ?? .all {
        didSet { UserDefaults.standard.set(selectedScope.rawValue, forKey: "AgentWatch.selectedScope") }
    }
    @Published var report: Report?
    @Published var legacy: LegacyReport?
    @Published var loading = false
    @Published var legacyLoading = false
    @Published var refreshedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var legacyFetchedAt = Date.distantPast

    private func mergeClaudeRateWindows(_ incoming: [String: RateWindow]) {
        guard !incoming.isEmpty else { return }
        var current = legacy ?? LegacyReport()
        for (name, window) in incoming where window.resetsAt > Date()
            && Date().timeIntervalSince(window.observedAt) <= 12 * 60 * 60 {
            if window.observedAt > (current.rateWindows[name]?.observedAt ?? .distantPast) {
                current.rateWindows[name] = window
            }
        }
        legacy = current
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        refreshTask = Task {
            let value = await Task.detached(priority: .utility) { TranscriptScanner.scan() }.value
            report = value
            refreshedAt = Date()
            loading = false
        }
        if !legacyLoading && Date().timeIntervalSince(legacyFetchedAt) > 900 {
            legacyLoading = true
            Task {
                // Show the last known Claude quotas immediately, and refresh them
                // independently so a slow ccusage run cannot leave Codex alone.
                let cachedRates = await Task.detached(priority: .utility) {
                    LegacyScanner.cachedClaudeRateWindows()
                }.value
                mergeClaudeRateWindows(cachedRates)
                let ratesTask = Task.detached(priority: .utility) { LegacyScanner.claudeRateWindows() }
                var value = await Task.detached(priority: .utility) {
                    LegacyScanner.scan(includeRateWindows: false)
                }.value
                value.rateWindows = legacy?.rateWindows ?? [:]
                legacy = value
                legacyFetchedAt = Date()
                legacyLoading = false
                mergeClaudeRateWindows(await ratesTask.value)
            }
        }
    }
}

// Stable agent colors; categorical accents are reserved for real sub-series.
private let codexColor = Color(red: 0.16, green: 0.47, blue: 0.84)
private let claudeColor = Color(red: 0.92, green: 0.41, blue: 0.20)
private let accentCyan = Color(red: 0.10, green: 0.63, blue: 0.68)
private let accentPurple = Color(red: 0.48, green: 0.38, blue: 0.78)
private let accentRed = Color(red: 0.82, green: 0.23, blue: 0.25)
private let accentOrange = Color(red: 0.88, green: 0.48, blue: 0.12)
private let accentGreen = Color(red: 0.20, green: 0.62, blue: 0.40)
private let modelPalette: [Color] = [
    Color(red: 0.16, green: 0.47, blue: 0.84), Color(red: 0.92, green: 0.41, blue: 0.20),
    Color(red: 0.10, green: 0.63, blue: 0.68), Color(red: 0.48, green: 0.38, blue: 0.78),
    Color(red: 0.20, green: 0.62, blue: 0.40), Color(red: 0.82, green: 0.23, blue: 0.25),
    Color(red: 0.76, green: 0.30, blue: 0.59), Color(red: 0.69, green: 0.56, blue: 0.13)
]

private func compact(_ value: Double) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
    if value > 0 && value < 10 { return String(format: "%.1f", value) }
    return String(format: "%.0f", value)
}

private func compactTokens(_ value: Double) -> String {
    if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", value / 1_000) }
    return String(format: "%.0f", value)
}

private func dollars(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencySymbol = "$"
    formatter.maximumFractionDigits = 0
    formatter.minimumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "$\(Int(value.rounded()))"
}

private struct Card<Content: View>: View {
    let title: String
    var minHeight: CGFloat = 0
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 3)
    }
}

private struct OverviewMetric: View {
    let icon: String
    let color: Color
    let title: String
    let today: String
    let range: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
                Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(today).font(.system(size: 19, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
            Text("30日 \(range)").font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RateDonut: View {
    let name: String
    let window: RateWindow
    let elapsed: Double
    let color: Color
    let label: String

    private var used: Double { min(100, max(0, window.usedPercent)) / 100 }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: used)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: 36)
                Circle().stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    .frame(width: 42, height: 42)
                Circle().fill(Color.primary.opacity(0.75))
                    .frame(width: 3, height: 3)
                    .offset(y: -21)
                    .rotationEffect(.degrees(elapsed * 3.6))
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            .frame(width: 44, height: 44)
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 20)
        }
        .frame(maxWidth: .infinity)
        .help("\(name) · 使用 \(Int(window.usedPercent.rounded()))% · 外周の点は時間経過 \(Int(elapsed.rounded()))% · 次回リセット \(window.resetsAt.formatted(date: .omitted, time: .shortened))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) 使用率 \(Int(window.usedPercent.rounded()))パーセント")
    }
}

private struct MetricPoint: Identifiable {
    let agent: Agent
    let date: Date
    let value: Double
    var id: String { "\(agent.rawValue)-\(date.timeIntervalSince1970)" }
}

private struct ComparedPoint: Identifiable {
    let date: Date
    let series: String
    let kind: String
    let value: Double
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

private struct ComparedSeries: Identifiable {
    let name: String
    let kind: String
    let color: Color
    var id: String { name }
}

private struct ComparedTrend: View {
    let points: [ComparedPoint]
    let series: [ComparedSeries]
    let height: CGFloat
    var axisLabel: (Double) -> String = { compact($0) }

    var body: some View {
        if points.isEmpty {
            Text("データなし").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 34)
        } else {
            Chart(points) { point in
                LineMark(x: .value("日", point.date, unit: .day), y: .value("値", point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .lineStyle(by: .value("指標", point.kind))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("日", point.date, unit: .day), y: .value("値", point.value))
                    .foregroundStyle(by: .value("系列", point.series))
                    .symbolSize(8)
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartLineStyleScale(domain: Array(Set(series.map(\.kind))).sorted(), range: Array(Set(series.map(\.kind))).sorted().map {
                $0 == series.first?.kind ? StrokeStyle(lineWidth: 1.8) : StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            })
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine().foregroundStyle(.tertiary)
                    AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    if let number = value.as(Double.self) { AxisValueLabel(axisLabel(number)).font(.system(size: 8)) }
                }
            }
            .frame(height: height)
            HStack(spacing: 8) {
                ForEach(series) { item in
                    HStack(spacing: 3) {
                        Capsule().fill(item.color).frame(width: 10, height: 2)
                        Text(item.name).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct DualAxisPoint: Identifiable {
    let date: Date
    let agent: Agent
    let kind: String
    let normalizedValue: Double
    var series: String { "\(agent.rawValue) \(kind)" }
    var id: String { "\(series)-\(date.timeIntervalSince1970)" }
}

private struct DualAxisTrend: View {
    let primary: [MetricPoint]
    let secondary: [MetricPoint]
    let primaryName: String
    let secondaryName: String
    let primaryFormat: (Double) -> String
    let secondaryFormat: (Double) -> String

    private func bounds(_ values: [MetricPoint]) -> (Double, Double) {
        guard let minimum = values.map(\.value).min(), let maximum = values.map(\.value).max() else { return (0, 1) }
        if maximum - minimum < 0.001 { return (max(0, minimum - 0.5), maximum + 0.5) }
        return (minimum, maximum)
    }

    private var primaryBounds: (Double, Double) { bounds(primary) }
    private var secondaryBounds: (Double, Double) { bounds(secondary) }

    private func normalize(_ value: Double, using range: (Double, Double)) -> Double {
        (value - range.0) / max(range.1 - range.0, 0.001) * 100
    }

    private func value(at position: Double, using range: (Double, Double)) -> Double {
        range.0 + position / 100 * (range.1 - range.0)
    }

    private var points: [DualAxisPoint] {
        primary.map { DualAxisPoint(date: $0.date, agent: $0.agent, kind: primaryName, normalizedValue: normalize($0.value, using: primaryBounds)) }
        + secondary.map { DualAxisPoint(date: $0.date, agent: $0.agent, kind: secondaryName, normalizedValue: normalize($0.value, using: secondaryBounds)) }
    }

    var body: some View {
        if points.isEmpty {
            Text("データなし").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 34)
        } else {
            Chart(points) { point in
                LineMark(x: .value("日", point.date, unit: .day), y: .value("相対位置", point.normalizedValue))
                    .foregroundStyle(by: .value("系列", point.series))
                    .lineStyle(by: .value("指標", point.kind))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("日", point.date, unit: .day), y: .value("相対位置", point.normalizedValue))
                    .foregroundStyle(by: .value("系列", point.series))
                    .symbolSize(8)
            }
            .chartYScale(domain: 0...100)
            .chartForegroundStyleScale(
                domain: ["Codex \(primaryName)", "Codex \(secondaryName)", "Claude \(primaryName)", "Claude \(secondaryName)"],
                range: [codexColor, codexColor, claudeColor, claudeColor]
            )
            .chartLineStyleScale(
                domain: [primaryName, secondaryName],
                range: [StrokeStyle(lineWidth: 1.8), StrokeStyle(lineWidth: 1.5, dash: [4, 3])]
            )
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine().foregroundStyle(.tertiary)
                    AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.0, 50.0, 100.0]) { tick in
                    AxisGridLine().foregroundStyle(.quaternary)
                    if let position = tick.as(Double.self) {
                        AxisValueLabel(primaryFormat(value(at: position, using: primaryBounds))).font(.system(size: 8))
                    }
                }
                AxisMarks(position: .trailing, values: [0.0, 50.0, 100.0]) { tick in
                    if let position = tick.as(Double.self) {
                        AxisValueLabel(secondaryFormat(value(at: position, using: secondaryBounds))).font(.system(size: 8))
                    }
                }
            }
            .frame(height: 68)
            HStack(spacing: 10) {
                HStack(spacing: 3) { Circle().fill(codexColor).frame(width: 6, height: 6); Text("Codex").font(.system(size: 8)).foregroundStyle(.secondary) }
                HStack(spacing: 3) { Circle().fill(claudeColor).frame(width: 6, height: 6); Text("Claude").font(.system(size: 8)).foregroundStyle(.secondary) }
                Text("実線 \(primaryName) · 破線 \(secondaryName)").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct ContextBand: Identifiable {
    let agent: Agent
    let date: Date
    let low: Double
    let median: Double
    let high: Double
    var id: String { "\(agent.rawValue)-\(date.timeIntervalSince1970)" }
}

private struct ModelCostPoint: Identifiable {
    let date: Date
    let model: String
    let cost: Double
    var id: String { "\(date.timeIntervalSince1970)-\(model)" }
}

private struct ModelCostBand: Identifiable {
    let date: Date
    let model: String
    let lower: Double
    let upper: Double
    var id: String { "\(date.timeIntervalSince1970)-\(model)" }
}

private struct RankedItem: Identifiable {
    let name: String
    let agent: Agent
    let count: Int
    var id: String { "\(agent.rawValue)-\(name)" }
}

private struct RankedBars: View {
    let items: [RankedItem]

    private func maximum(for agent: Agent) -> Double {
        Double(max(items.filter { $0.agent == agent }.map(\.count).max() ?? 1, 1))
    }

    var body: some View {
        if items.isEmpty {
            Text("履歴なし").font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 40)
        } else {
            VStack(spacing: 5) {
                ForEach(items) { item in
                    HStack(spacing: 5) {
                        Text(item.agent == .codex ? "C" : "A")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(item.agent == .codex ? codexColor : claudeColor)
                            .frame(width: 10)
                        Text(item.name)
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 112, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule()
                                    .fill(item.agent == .codex ? codexColor : claudeColor)
                                                        .frame(width: max(2, proxy.size.width * CGFloat(Double(item.count) / maximum(for: item.agent))))
                            }
                        }
                        .frame(height: 7)
                        Text(compact(Double(item.count)))
                            .font(.system(size: 8, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            }
            .frame(height: CGFloat(items.count * 15))
        }
    }
}

private struct CostTrend: View {
    let points: [ModelCostPoint]
    private let familyOrder = ["fable", "opus", "sonnet", "haiku"]
    private var models: [String] {
        Array(Set(points.map(\.model))).sorted { lhs, rhs in
            let leftFamily = lhs.split(separator: "-").first.map(String.init) ?? lhs
            let rightFamily = rhs.split(separator: "-").first.map(String.init) ?? rhs
            let leftRank = familyOrder.firstIndex(of: leftFamily) ?? familyOrder.count
            let rightRank = familyOrder.firstIndex(of: rightFamily) ?? familyOrder.count
            if leftRank != rightRank { return leftRank < rightRank }
            if leftFamily != rightFamily { return leftFamily < rightFamily }
            let leftVersion = lhs.split(separator: "-").dropFirst().compactMap { Int($0) }
            let rightVersion = rhs.split(separator: "-").dropFirst().compactMap { Int($0) }
            return leftVersion.lexicographicallyPrecedes(rightVersion) == false
        }
    }

    private func shortName(_ model: String) -> String {
        let parts = model.split(separator: "-")
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().prefix(2).filter { $0.count < 5 }.joined(separator: ".")
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }

    private var maxTotal: Double {
        let totals = Dictionary(grouping: points, by: \.date).values.map { $0.reduce(0) { $0 + $1.cost } }
        return max(totals.max() ?? 1, 1)
    }

    // Keep ccwatch's stacked model areas, but compress the y values with log1p:
    // a single $600+ day was forcing ordinary $10–$80 days onto the baseline.
    private var bands: [ModelCostBand] {
        let grouped = Dictionary(grouping: points, by: \.date)
        return grouped.keys.sorted().flatMap { date -> [ModelCostBand] in
            let values = Dictionary(uniqueKeysWithValues: (grouped[date] ?? []).map { ($0.model, $0.cost) })
            var cumulative = 0.0
            return models.map { model in
                let lower = log1p(cumulative)
                cumulative += values[model] ?? 0
                return ModelCostBand(date: date, model: model, lower: lower, upper: log1p(cumulative))
            }
        }
    }

    private var yTicks: [Double] {
        let middle = maxTotal >= 200 ? 100.0 : maxTotal / 2
        return [0, middle, maxTotal].map(log1p)
    }

    private func axisDollars(_ transformed: Double) -> String {
        dollars(expm1(transformed))
    }

    var body: some View {
        if points.isEmpty {
            Text("データなし").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 34)
        } else {
            Chart(bands) { band in
                AreaMark(x: .value("日", band.date, unit: .day),
                         yStart: .value("下限", band.lower), yEnd: .value("上限", band.upper))
                    .foregroundStyle(by: .value("モデル", band.model))
                    .interpolationMethod(.monotone)
            }
            .chartForegroundStyleScale(domain: models, range: models.enumerated().map { modelPalette[$0.offset % modelPalette.count] })
            .chartLegend(.hidden)
            .chartYScale(domain: 0...log1p(maxTotal))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                    AxisGridLine().foregroundStyle(.tertiary)
                    AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: yTicks) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    if let amount = value.as(Double.self) {
                        AxisValueLabel(axisDollars(amount)).font(.system(size: 8))
                    }
                }
            }
            .frame(height: 52)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(models.enumerated()), id: \.element) { index, model in
                        HStack(spacing: 4) {
                            Circle().fill(modelPalette[index % modelPalette.count]).frame(width: 6, height: 6)
                            Text(shortName(model)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(stride(from: 0, to: models.count, by: 2)), id: \.self) { start in
                        HStack(spacing: 8) {
                            ForEach(start..<min(start + 2, models.count), id: \.self) { index in
                                HStack(spacing: 4) {
                                    Circle().fill(modelPalette[index % modelPalette.count]).frame(width: 6, height: 6)
                                    Text(shortName(models[index])).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ContextTrend: View {
    let bands: [ContextBand]
    let failures: [MetricPoint]
    var body: some View {
        if bands.isEmpty && failures.isEmpty {
            Text("データなし").font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 34)
        } else {
            Chart {
                ForEach(bands) { point in
                    AreaMark(x: .value("日", point.date, unit: .day), yStart: .value("p25", point.low), yEnd: .value("p75", point.high))
                        .foregroundStyle(point.agent == .codex ? codexColor.opacity(0.14) : claudeColor.opacity(0.14))
                    LineMark(x: .value("日", point.date, unit: .day), y: .value("中央値", point.median))
                        .foregroundStyle(by: .value("エージェント", point.agent.rawValue))
                        .lineStyle(by: .value("指標", "コンテキスト"))
                        .interpolationMethod(.monotone)
                }
                ForEach(failures) { point in
                    LineMark(x: .value("日", point.date, unit: .day), y: .value("失敗率", point.value))
                        .foregroundStyle(by: .value("エージェント", point.agent.rawValue))
                        .lineStyle(by: .value("指標", "失敗率"))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("日", point.date, unit: .day), y: .value("失敗率", point.value))
                        .foregroundStyle(point.agent == .codex ? codexColor : claudeColor)
                        .symbolSize(7)
                }
            }
            .chartForegroundStyleScale(domain: [Agent.codex.rawValue, Agent.claude.rawValue], range: [codexColor, claudeColor])
            .chartLineStyleScale(domain: ["コンテキスト", "失敗率"], range: [StrokeStyle(lineWidth: 1.8), StrokeStyle(lineWidth: 1.5, dash: [4, 3])])
            .chartLegend(.hidden)
            .chartYScale(domain: 0...100)
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.day()).font(.system(size: 8)) } }
            .chartYAxis { AxisMarks(values: [0.0, 50.0, 100.0]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                if let number = value.as(Double.self) { AxisValueLabel(String(format: "%.0f%%", number)).font(.system(size: 8)) }
            } }
            .frame(height: 74)
            HStack(spacing: 10) {
                HStack(spacing: 3) { Capsule().fill(codexColor).frame(width: 9, height: 2); Text("Codex").font(.system(size: 8)).foregroundStyle(.secondary) }
                HStack(spacing: 3) { Capsule().fill(claudeColor).frame(width: 9, height: 2); Text("Claude").font(.system(size: 8)).foregroundStyle(.secondary) }
                Text("実線 コンテキスト · 破線 失敗率").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct MetricTrend: View {
    let points: [MetricPoint]
    let label: String
    var accent: Color = accentCyan
    var showsXAxis = true
    var body: some View {
        if points.isEmpty {
            Text("データなし")
                .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 34)
        } else {
            Chart(points) { point in
                BarMark(x: .value("日", point.date, unit: .day), y: .value(label, point.value))
                    .foregroundStyle(by: .value("エージェント", point.agent.rawValue))
            }
            .chartForegroundStyleScale(
                domain: [Agent.codex.rawValue, Agent.claude.rawValue],
                range: Set(points.map(\.agent)).count > 1 ? [codexColor, claudeColor] : [accent, accent]
            )
            .chartLegend(.hidden)
            .chartXAxis {
                if showsXAxis {
                    AxisMarks(values: .stride(by: .day, count: 3)) { _ in AxisValueLabel(format: .dateTime.day()).font(.system(size: 8)) }
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                if let number = value.as(Double.self) { AxisValueLabel(compact(number)).font(.system(size: 9)) }
            } }
            .frame(height: 64)
        }
    }
}

private struct HeatCell: Identifiable {
    let day: Date
    let hour: Int
    let count: Int
    var id: String { "\(day.timeIntervalSince1970)-\(hour)" }
}

private struct ActivityHeatmap: View {
    let cells: [HeatCell]
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .trailing) {
                Text("0"); Spacer(); Text("12"); Spacer(); Text("23")
            }
            .font(.system(size: 8)).foregroundStyle(.tertiary)
            .frame(width: 18, height: 124)
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    ForEach(0..<30, id: \.self) { day in
                        VStack(spacing: 1) {
                            ForEach(0..<24, id: \.self) { hour in
                                let count = cells[day * 24 + hour].count
                                Rectangle()
                                    .fill(count == 0 ? Color.gray.opacity(0.10) : color.opacity(min(0.95, 0.22 + log(Double(count) + 1) / 5)))
                                    .frame(height: (124 - 23) / 24)
                            }
                        }
                        .frame(width: max(2, (geometry.size.width - 29) / 30))
                    }
                }
            }.frame(height: 124)
        }
        HStack { Text("30日前"); Spacer(); Text("今日") }
            .font(.system(size: 8)).foregroundStyle(.tertiary)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var model: DashboardModel
    private let previewScope: Scope?

    init(model: DashboardModel, previewScope: Scope? = nil) {
        self.model = model
        self.previewScope = previewScope
    }

    private var scope: Scope { previewScope ?? model.selectedScope }

    private func current(_ window: RateWindow?) -> RateWindow? {
        guard let window, window.resetsAt > Date(),
              Date().timeIntervalSince(window.observedAt) < 24 * 60 * 60 else { return nil }
        return window
    }

    private var statusContent: some View {
        HStack(spacing: 3) {
            if scope != .codex {
                MenuQuotaGroup(name: "CC", fiveHour: current(model.legacy?.rateWindows["Claude 5時間"]),
                               weekly: current(model.legacy?.rateWindows["Claude 週間"]))
            }
            if scope == .all {
                Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 1, height: 17)
            }
            if scope != .claude {
                MenuQuotaGroup(name: "CO", fiveHour: current(model.report?.rateWindows["Codex primary"]),
                               weekly: current(model.report?.rateWindows["Codex secondary"]))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 0.7)
    }

    private var statusImage: NSImage? {
        let renderer = ImageRenderer(content: statusContent)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        return image
    }

    var body: some View {
        Group {
            if let statusImage {
                Image(nsImage: statusImage)
            } else {
                Text("AgentWatch")
            }
        }
        .accessibilityLabel("AgentWatch。Claude CodeとCodexの5時間・週間利用枠")
        .help("Claude Code / Codex の利用枠。バーの色 = 使用率、縦線 = 時間進捗。使用率が時間進捗を超えると赤")
    }
}

private struct MenuQuotaGroup: View {
    let name: String
    let fiveHour: RateWindow?
    let weekly: RateWindow?

    var body: some View {
        HStack(spacing: 3) {
            VStack(spacing: -2) {
                Text(name == "CC" ? "CLAUDE" : "CO")
                    .font(.system(size: name == "CC" ? 7.5 : 9, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: true, vertical: false)
                Text(name == "CC" ? "CODE" : "DEX")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 19)
            MenuQuotaBar(title: "5h", window: fiveHour)
            MenuQuotaBar(title: "週", window: weekly)
        }
    }
}

enum RateWindowPace {
    static func elapsed(_ window: RateWindow, duration: TimeInterval, now: Date = Date()) -> Double {
        let start = window.resetsAt.addingTimeInterval(-duration)
        return min(1, max(0, now.timeIntervalSince(start) / duration))
    }

    static func isAhead(_ window: RateWindow, duration: TimeInterval, now: Date = Date()) -> Bool {
        window.usedPercent / 100 > elapsed(window, duration: duration, now: now)
    }
}

private struct MenuQuotaBar: View {
    let title: String
    let window: RateWindow?

    private var used: Double { min(100, max(0, window?.usedPercent ?? 0)) / 100 }
    private var elapsed: Double {
        guard let window else { return 0 }
        let duration: TimeInterval = title == "5h" ? 5 * 3600 : 7 * 24 * 3600
        return RateWindowPace.elapsed(window, duration: duration)
    }
    private var color: Color {
        guard let window else { return .clear }
        let duration: TimeInterval = title == "5h" ? 5 * 3600 : 7 * 24 * 3600
        return RateWindowPace.isAhead(window, duration: duration) ? accentRed : accentGreen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .semibold, design: .rounded))
                Text(window.map { "\(Int($0.usedPercent.rounded()))%" } ?? "—")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.27)).frame(width: 34, height: 2)
                Capsule().fill(color).frame(width: 34 * used, height: 2)
                if window != nil {
                    Rectangle().fill(Color.white).frame(width: 1.5, height: 6)
                        .offset(x: min(32.5, max(0, 34 * elapsed - 0.75)))
                }
            }
            .frame(width: 34, height: 6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct Dashboard: View {
    @ObservedObject var model: DashboardModel
    private let previewScope: Scope?

    init(model: DashboardModel, initialScope: Scope? = nil) {
        self.model = model
        self.previewScope = initialScope
    }

    private var scope: Scope { previewScope ?? model.selectedScope }

    private var points: [Daily] {
        model.report?.daily.filter { scope.includes($0.agent) } ?? []
    }
    private var today: [Daily] {
        points.filter { Calendar.current.isDateInToday($0.date) }
    }
    private var heatCells: [HeatCell] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let byDay = Dictionary(grouping: points, by: \.date)
        return (0..<30).flatMap { offset -> [HeatCell] in
            let day = calendar.date(byAdding: .day, value: offset - 29, to: today) ?? today
            return (0..<24).map { hour in
                HeatCell(day: day, hour: hour, count: (byDay[day] ?? []).reduce(0) { $0 + ($1.hourlyEvents[hour] ?? 0) })
            }
        }
    }
    private var contextPoints: [Daily] { points.filter { $0.contextMedian != nil } }
    private func metrics(_ codex: (Daily) -> Double?, _ claude: (Daily, LegacyDay?) -> Double?) -> [MetricPoint] {
        points.compactMap { point in
            let value = point.agent == .codex ? codex(point) : claude(point, model.legacy?.days[point.date])
            guard let value else { return nil }
            return MetricPoint(agent: point.agent, date: point.date, value: value)
        }
    }
    private var hoursPoints: [MetricPoint] {
        metrics({ $0.taskDurationSeconds / 3600 }, { _, legacy in legacy?.hours })
    }
    private var longestPoints: [MetricPoint] {
        metrics({ $0.longestRunSeconds / 3600 }, { _, legacy in legacy?.longestHours })
    }
    private var parallelismPoints: [MetricPoint] {
        metrics({ $0.parallelism }, { _, legacy in legacy?.parallelism })
    }
    private var delegationPoints: [MetricPoint] {
        metrics({ $0.delegationPercent }, { _, legacy in legacy?.delegationPercent })
    }
    private var correctionPoints: [MetricPoint] {
        metrics({ _ in nil }, { _, legacy in legacy?.selfCorrectionPercent })
    }
    private var bouncePoints: [MetricPoint] {
        metrics({ _ in nil }, { _, legacy in legacy?.bounces })
    }
    private var hoursComparePoints: [ComparedPoint] {
        let hours = hoursPoints.map { ComparedPoint(date: $0.date, series: $0.agent == .codex ? "C 稼働" : "A 稼働", kind: "稼働", value: $0.value) }
        let longest = longestPoints.map { ComparedPoint(date: $0.date, series: $0.agent == .codex ? "C 最長" : "A 最長", kind: "最長", value: $0.value) }
        return hours + longest
    }
    private var hoursCompareSeries: [ComparedSeries] { [
        ComparedSeries(name: "C 稼働", kind: "稼働", color: codexColor),
        ComparedSeries(name: "A 稼働", kind: "稼働", color: claudeColor),
        ComparedSeries(name: "C 最長", kind: "最長", color: accentCyan),
        ComparedSeries(name: "A 最長", kind: "最長", color: accentPurple)
    ] }
    private var costPoints: [MetricPoint] {
        metrics({ _ in nil }, { _, legacy in legacy?.cost })
    }
    private func total(_ points: [MetricPoint], todayOnly: Bool = false) -> Double {
        points.filter { !todayOnly || Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.value }
    }
    private var tokenMetricPoints: [MetricPoint] { inputPoints + outputPoints }
    private var todayHours: Double { total(hoursPoints, todayOnly: true) }
    private var rangeHours: Double { total(hoursPoints) }
    private var todayTokens: Double { total(tokenMetricPoints, todayOnly: true) }
    private var rangeTokens: Double { total(tokenMetricPoints) }
    private var todayCost: Double { total(costPoints, todayOnly: true) }
    private var rangeCost: Double { total(costPoints) }
    private var modelCostPoints: [ModelCostPoint] {
        guard scope != .codex, let legacy = model.legacy else { return [] }
        let dates = Set(points.filter { $0.agent == .claude }.map(\.date))
        return legacy.days.flatMap { date, value in
            guard dates.contains(date) else { return [ModelCostPoint]() }
            return value.costByModel.map { ModelCostPoint(date: date, model: $0.key, cost: $0.value) }
        }.sorted { $0.date < $1.date }
    }
    private var inputPoints: [MetricPoint] {
        metrics({ $0.inputTokens }, { point, legacy in legacy?.inputTokens ?? point.inputTokens })
    }
    private var outputPoints: [MetricPoint] {
        metrics({ $0.outputTokens }, { point, legacy in legacy?.outputTokens ?? point.outputTokens })
    }
    private var toolFailurePoints: [MetricPoint] {
        metrics({ $0.tools == 0 ? nil : Double($0.failures) / Double($0.tools) * 100 }, { point, legacy in
            legacy?.toolFailurePercent ?? (point.tools == 0 ? nil : Double(point.failures) / Double(point.tools) * 100)
        })
    }
    private var contextMetricPoints: [MetricPoint] {
        metrics({ $0.contextQuartiles?.1 }, { _, legacy in legacy?.context?.1 })
    }
    private var contextBands: [ContextBand] {
        points.compactMap { point in
            let band = point.agent == .codex ? point.contextQuartiles : model.legacy?.days[point.date]?.context
            guard let band else { return nil }
            return ContextBand(agent: point.agent, date: point.date, low: band.0, median: band.1, high: band.2)
        }
    }
    private var rateWindows: [(String, RateWindow)] {
        var limits: [String: RateWindow] = [:]
        if scope != .claude { limits.merge(model.report?.rateWindows ?? [:]) { _, new in new } }
        if scope != .codex { limits.merge(model.legacy?.rateWindows ?? [:]) { _, new in new } }
        return limits.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    private func rateWindowHours(_ name: String) -> Double {
        name.contains("5時間") || name == "Codex primary" ? 5 : 24 * 7
    }
    private func elapsedPercent(_ window: RateWindow, hours: Double) -> Double {
        let start = window.resetsAt.addingTimeInterval(-hours * 3600)
        return min(100, max(0.1, Date().timeIntervalSince(start) / (hours * 3600) * 100))
    }
    private func rateColor(_ name: String, _ window: RateWindow) -> Color {
        let elapsed = elapsedPercent(window, hours: rateWindowHours(name))
        guard elapsed >= 10 else { return name.hasPrefix("Codex") ? codexColor : claudeColor }
        let pace = window.usedPercent / elapsed
        if pace <= 1 { return accentGreen }
        if pace <= 1.15 { return accentOrange }
        return accentRed
    }
    private func rateLabel(_ name: String) -> String {
        if name == "Codex primary" { return "Codex\n5時間" }
        if name == "Codex secondary" { return "Codex\n週間" }
        if name == "Claude 5時間" { return "Claude\n5時間" }
        if name == "Claude 週間" { return "Claude\n週間" }
        if name.hasPrefix("Claude ") { return "\(name.dropFirst("Claude ".count))\n週間" }
        return name
    }
    private var namedTools: [RankedItem] {
        guard let report = model.report else { return [] }
        var result: [RankedItem] = []
        for agent in Agent.allCases where scope.includes(agent) {
            result += (report.toolNames[agent] ?? [:])
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(5)
                .map { RankedItem(name: $0.key, agent: agent, count: $0.value) }
        }
        return result
    }
    private var namedModels: [RankedItem] {
        guard let report = model.report else { return [] }
        var result: [RankedItem] = []
        for agent in Agent.allCases where scope.includes(agent) {
            result += (report.models[agent] ?? [:])
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(5)
                .map { RankedItem(name: $0.key, agent: agent, count: $0.value) }
        }
        return result
    }
    private var weekInsight: String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let currentStart = calendar.date(byAdding: .day, value: -7, to: today),
              let previousStart = calendar.date(byAdding: .day, value: -14, to: today) else { return "" }
        let current = points.filter { $0.date >= currentStart && $0.date < today }
        let previous = points.filter { $0.date >= previousStart && $0.date < currentStart }
        let currentTurns = current.reduce(0) { $0 + $1.turns }
        let previousTurns = previous.reduce(0) { $0 + $1.turns }
        let trend: String
        if previousTurns > 0 {
            let delta = Int((Double(currentTurns - previousTurns) / Double(previousTurns) * 100).rounded())
            trend = "前週比 \(delta > 0 ? "+" : "")\(delta)%"
        } else {
            trend = currentTurns > 0 ? "前週は記録なし" : "—"
        }
        let currentHours = hoursPoints.filter { $0.date >= currentStart && $0.date < today }.reduce(0) { $0 + $1.value }
        return "直近7日 \(currentTurns)ターン（\(trend)） · 稼働 \(String(format: "%.1f", currentHours))h"
    }

    var dashboardContent: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(codexColor)
                    Text("AgentWatch").font(.system(size: 15, weight: .bold))
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        ForEach(Scope.allCases) { value in
                            Text(value.rawValue)
                                .font(.system(size: 11, weight: scope == value ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(scope == value ? Color.primary : Color.secondary)
                                .background(scope == value ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedScope = value }
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    .padding(3)
                    .frame(width: 310)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    if model.loading { ProgressView().controlSize(.small) }
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                        .contentShape(Rectangle())
                        .onTapGesture { model.refresh() }
                        .accessibilityLabel("履歴を再集計")
                        .accessibilityAddTraits(.isButton)
                }
                if let report = model.report {
                    if scope == .codex {
                        Text("コスト・自己修正は、Codex 履歴に比較可能な記録がないため非表示")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Card(title: "今日の活動", minHeight: 116) {
                            HStack(alignment: .top, spacing: 4) {
                                OverviewMetric(icon: "clock.fill", color: codexColor, title: "稼働時間",
                                               today: String(format: "%.1fh", todayHours), range: String(format: "%.0fh", rangeHours))
                                OverviewMetric(icon: "dollarsign.circle.fill", color: accentOrange, title: "コスト",
                                               today: costPoints.isEmpty ? "—" : dollars(todayCost), range: costPoints.isEmpty ? "—" : dollars(rangeCost))
                                OverviewMetric(icon: "circle.hexagongrid.fill", color: accentPurple, title: "トークン",
                                               today: compactTokens(todayTokens), range: compactTokens(rangeTokens))
                            }
                            Text(weekInsight)
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Card(title: "利用枠", minHeight: 116) {
                            if rateWindows.isEmpty {
                                Text("取得できる利用枠なし").font(.system(size: 10)).foregroundStyle(.secondary)
                            } else {
                                HStack(alignment: .top, spacing: 0) {
                                    ForEach(rateWindows, id: \.0) { name, window in
                                        RateDonut(name: name, window: window,
                                                  elapsed: elapsedPercent(window, hours: rateWindowHours(name)),
                                                  color: rateColor(name, window), label: rateLabel(name))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeading(title: "稼働パターン", subtitle: "実行時間と活動時間帯")
                            Card(title: "稼働時間・最長連続 / 日") {
                                ComparedTrend(points: hoursComparePoints, series: hoursCompareSeries, height: 68,
                                              axisLabel: { String(format: "%.0fh", $0) })
                            }
                            Card(title: "並列実行・委譲率 / 日") {
                                DualAxisTrend(
                                    primary: parallelismPoints, secondary: delegationPoints,
                                    primaryName: "並列", secondaryName: "委譲率",
                                    primaryFormat: { String(format: "×%.1f", $0) },
                                    secondaryFormat: { String(format: "%.0f%%", $0) }
                                )
                                Text("左軸 = 同時実行数 / 右軸 = サブエージェント時間比")
                                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                            Card(title: "活動時間帯") {
                                ActivityHeatmap(cells: heatCells, color: scope == .claude ? claudeColor : codexColor)
                                Text("色の濃さ = その時間帯のターン＋ツール数").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeading(title: costPoints.isEmpty ? "利用品質" : "コスト・品質", subtitle: "利用効率とコンテキストの状態")
                            if scope != .codex {
                                if !modelCostPoints.isEmpty {
                                    Card(title: "コスト推移 / 日") {
                                        CostTrend(points: modelCostPoints)
                                        Text("Claude: ccusage。Codex の実請求額はローカル履歴から取得不可")
                                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                                    }
                                }
                                if !model.legacyLoading && modelCostPoints.isEmpty && costPoints.isEmpty {
                                    Text("Claudeのコストデータなし")
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                        .padding(.horizontal, 2)
                                }
                            }
                            Card(title: "コンテキスト・ツール失敗率 / 日") {
                                ContextTrend(bands: contextBands, failures: toolFailurePoints)
                                Text("帯 = コンテキスト p25–p75 / 実線 = 中央値 / 破線 = ツール失敗率")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            if scope != .codex {
                                Card(title: "自己修正・差し戻し / 日 · Claude") {
                                    DualAxisTrend(
                                        primary: correctionPoints, secondary: bouncePoints,
                                        primaryName: "自己修正", secondaryName: "差し戻し",
                                        primaryFormat: { String(format: "%.0f%%", $0) },
                                        secondaryFormat: { String(format: "%.0f", $0) }
                                    )
                                    Text("左軸 = 自己修正率 / 右軸 = 差し戻し回数")
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    SectionHeading(title: "使い方の内訳", subtitle: "ツールとモデルはエージェントごとに上位5件")
                    HStack(alignment: .top, spacing: 10) {
                        Card(title: "よく使うツール · 上位") {
                            RankedBars(items: namedTools)
                            Text("C = Codex / A = Claude · 件数は別スケール")
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                        Card(title: "利用モデル · 上位") {
                            RankedBars(items: namedModels)
                            Text("記録されたモデルイベント数 · C = Codex / A = Claude")
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    if scope != .codex, let legacy = model.legacy,
                       !legacy.topSkills.isEmpty || !legacy.topFailures.isEmpty {
                        SectionHeading(title: "Claude Code固有の指標", subtitle: "Codex履歴とは測定方法が異なるため、比較グラフから分離")
                        HStack(alignment: .top, spacing: 10) {
                            if !legacy.topSkills.isEmpty {
                                Card(title: "よく使うスキル · Claude") {
                                    ForEach(legacy.topSkills, id: \.0) { name, count in
                                        HStack { Text(name).lineLimit(1); Spacer(); Text("\(count)").monospacedDigit() }
                                            .font(.system(size: 10))
                                    }
                                }
                            }
                            if !legacy.topFailures.isEmpty {
                                Card(title: "失敗しやすいツール · Claude") {
                                    ForEach(legacy.topFailures, id: \.0) { name, calls, rate in
                                        HStack {
                                            Text(name).lineLimit(1)
                                            Spacer()
                                            Text("\(calls)回 / " + String(format: "%.0f%%", rate)).monospacedDigit()
                                        }.font(.system(size: 10))
                                    }
                                }
                            }
                        }
                    }
                    if model.legacyLoading && scope != .codex {
                        HStack { ProgressView().controlSize(.small); Text("Claude の追加指標を集計中…") }
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    let filteredWarnings = Agent.allCases.filter { scope.includes($0) }.compactMap { agent in report.warnings[agent].map { "\(agent.rawValue): \($0)" } }
                    if !filteredWarnings.isEmpty {
                        Text(filteredWarnings.joined(separator: " / ")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("過去30日・ローカル履歴 / 最終更新 \(model.refreshedAt?.formatted(date: .omitted, time: .shortened) ?? "—")")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                } else {
                    Text("履歴を集計しています…").font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
            }.padding(12).frame(width: 660)
    }

    private var maxPanelHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 80
    }

    var body: some View {
        ScrollView(.vertical) {
            dashboardContent
        }
        .frame(width: 660, height: maxPanelHeight, alignment: .top)
        .scrollIndicators(.visible)
        .onAppear { if model.report == nil { model.refresh() } }
    }
}

@main
struct AgentWatchApp: App {
    @StateObject private var model = DashboardModel()
    private let timer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    init() {
        let previewFlag = CommandLine.arguments.firstIndex(of: "--render-preview")
        let menuBarFlag = CommandLine.arguments.firstIndex(of: "--render-menubar")
        if let index = previewFlag ?? menuBarFlag, index + 1 < CommandLine.arguments.count {
            let destination = CommandLine.arguments[index + 1]
            let scope = CommandLine.arguments.count > index + 2
                ? Scope.allCases.first { $0.rawValue == CommandLine.arguments[index + 2] } ?? .all
                : .all
            Task { @MainActor in
                let model = DashboardModel()
                model.report = await Task.detached(priority: .utility) { TranscriptScanner.scan() }.value
                model.legacy = await Task.detached(priority: .utility) { LegacyScanner.scan() }.value
                model.refreshedAt = Date()
                let background = menuBarFlag != nil
                    ? Color(red: 0.20, green: 0.22, blue: 0.23)
                    : Color(NSColor.windowBackgroundColor)
                let content: AnyView
                if menuBarFlag != nil {
                    content = AnyView(MenuBarStatusLabel(model: model, previewScope: scope)
                        .padding(6).background(background))
                } else {
                    content = AnyView(Dashboard(model: model, initialScope: scope)
                        .dashboardContent.background(background))
                }
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let image = renderer.nsImage
                if let image,
                   let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: destination), options: .atomic)
                }
                exit(0)
            }
            while true { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
        }
        if CommandLine.arguments.contains("--legacy-summary") {
            let legacy = LegacyScanner.scan()
            print("Claude companion metrics: \(legacy.available.sorted().joined(separator: ", ")); days=\(legacy.days.count); skills=\(legacy.topSkills.count); rateWindows=\(legacy.rateWindows.count)")
            exit(0)
        }
        if CommandLine.arguments.contains("--rate-summary") {
            print("Claude rate windows: \(LegacyScanner.claudeRateWindows().count)")
            exit(0)
        }
        if CommandLine.arguments.contains("--summary") {
            let report = TranscriptScanner.scan()
            for agent in Agent.allCases {
                let points = report.daily.filter { $0.agent == agent }
                print("\(agent.rawValue): sessions=\(report.sessions[agent] ?? 0) turns=\(points.reduce(0) { $0 + $1.turns }) tools=\(points.reduce(0) { $0 + $1.tools }) hours=\(String(format: "%.1f", points.reduce(0) { $0 + $1.taskDurationSeconds } / 3600)) input=\(compact(points.reduce(0) { $0 + $1.inputTokens })) output=\(compact(points.reduce(0) { $0 + $1.outputTokens }))")
            }
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra {
            Dashboard(model: model)
        } label: {
            MenuBarStatusLabel(model: model)
                .onAppear { model.refresh() }
                .onReceive(timer) { _ in model.refresh() }
        }.menuBarExtraStyle(.window)
    }
}
