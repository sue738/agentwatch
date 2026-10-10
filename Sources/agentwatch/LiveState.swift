import SwiftUI

// いま動いているエージェント・サブエージェント・ターミナルのコマンド。
// 検知は runawake (https://github.com/sue738/runawake) が行い、~/.runawake/state.json に書く。ここでは読んで見せるだけ。

struct LiveItem: Decodable, Hashable {
    let kind: String      // "agent" / "subagent" / "terminal"
    let name: String      // 例: "Claude Code", "Codex", "rsync"
    let place: String     // 作業フォルダ(~ 始まり)。無ければ空
}

struct LiveState: Decodable {
    let updated: Date
    let holding: Bool
    let paused: Bool
    let count: Int
    let items: [LiveItem]

    static func parse(_ data: Data) -> LiveState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LiveState.self, from: data)
    }

    var agents: [LiveItem] { items.filter { $0.kind == "agent" } }
    var subagents: [LiveItem] { items.filter { $0.kind == "subagent" } }
    var terminals: [LiveItem] { items.filter { $0.kind == "terminal" } }

    /// 同じ名前・同じ場所のものをまとめる。サブエージェントは親と同じ名前・場所にぶら下げる。
    struct Group: Hashable {
        let name: String
        let place: String
        let kind: String
        var sessions: Int
        var subagents: Int
    }
    var groups: [Group] {
        var order: [String] = [], map: [String: Group] = [:]
        for item in items where item.kind != "subagent" {
            let key = item.kind + "\u{1}" + item.name + "\u{1}" + item.place
            if map[key] == nil { order.append(key); map[key] = Group(name: item.name, place: item.place, kind: item.kind, sessions: 0, subagents: 0) }
            map[key]!.sessions += 1
        }
        for item in subagents {
            let key = "agent\u{1}" + item.name + "\u{1}" + item.place
            if map[key] == nil { order.append(key); map[key] = Group(name: item.name, place: item.place, kind: "agent", sessions: 0, subagents: 0) }
            map[key]!.subagents += 1
        }
        return order.compactMap { map[$0] }
    }
}

@MainActor
final class LiveStateModel: ObservableObject {
    static let shared = LiveStateModel()
    static let path = NSHomeDirectory() + "/.runawake/state.json"
    /// runawake が最後に書いてからこれ以上たっていたら、runawake は止まっているとみなす
    static let staleAfter: TimeInterval = 90

    @Published private(set) var state: LiveState?
    @Published private(set) var fileExists = false
    private var lastRaw: Data?
    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        timer.map { RunLoop.main.add($0, forMode: .common) }
    }

    /// ファイルが変わったときだけ publish する(メニューバーの再描画を増やさない)
    func reload() {
        let data = FileManager.default.contents(atPath: Self.path)
        let exists = data != nil
        if exists != fileExists { fileExists = exists }
        guard let data else { if state != nil { state = nil }; return }
        if data == lastRaw { return }
        lastRaw = data
        state = LiveState.parse(data)
    }

    /// runawake が動いていて、state が新しいか
    var fresh: Bool {
        guard let state else { return false }
        return Date().timeIntervalSince(state.updated) < Self.staleAfter
    }
    var liveCount: Int { fresh ? (state?.count ?? 0) : 0 }
}

/// メニューバー用の小さな「いま動いている数」。CC/CO の枠表示と同じ作りで並ぶ。
struct LiveCountLabel: View {
    let count: Int
    let subagents: Int
    var body: some View {
        HStack(spacing: 3) {
            VStack(spacing: -2) {
                Text("NOW").font(.system(size: 7.5, weight: .heavy, design: .rounded))
                Text("RUN").font(.system(size: 7.5, weight: .heavy, design: .rounded))
            }
            .frame(height: 19)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
            if subagents > 0 {
                Text("+\(subagents)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.8)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("いま動いているもの \(count)件" + (subagents > 0 ? "、サブエージェント \(subagents)" : ""))
    }
}

/// ダッシュボードのカード本文。
struct LiveNowContent: View {
    @ObservedObject var live: LiveStateModel

    private func label(_ g: LiveState.Group) -> String {
        var s = g.name
        if g.kind == "terminal" { s = "ターミナル: " + s }
        if g.sessions > 1 { s += " ×\(g.sessions)" }
        if g.subagents > 0 { s += "（サブエージェント \(g.subagents)）" }
        return s
    }

    var body: some View {
        if !live.fresh {
            Text(live.fileExists ? "runawake が止まっています（state.json が更新されていません）" : "runawake が入っていないため、いま動いているものは見えません")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        } else if let state = live.state, !state.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(state.count)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("セッション \(state.agents.count)・サブエージェント \(state.subagents.count)・ターミナル \(state.terminals.count)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(state.paused ? "runawake オフ" : (state.holding ? "Mac を起こしています" : "")).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                ForEach(state.groups, id: \.self) { g in
                    HStack(spacing: 6) {
                        Circle().fill(g.kind == "terminal" ? Color.secondary : Color.green).frame(width: 6, height: 6)
                        Text(label(g)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if !g.place.isEmpty {
                            Text(g.place).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            Text("いまは何も動いていません").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
