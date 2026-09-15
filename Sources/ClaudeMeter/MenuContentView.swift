import SwiftUI

struct GaugeBar: View {
    var used: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(Severity(used: used).color)
                    .frame(width: max(2, geo.size.width * min(used, 100) / 100))
            }
        }
        .frame(height: height)
    }
}

struct WindowSection: View {
    var kind: LimitKind
    var state: WindowState
    var now: Date
    var resetFormatter: DateFormatter

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(kind.label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(state.used.map { Fmt.percent($0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state.used.map { Severity(used: $0).color } ?? .secondary)
            }
            GaugeBar(used: state.used ?? 0)
            Text(caption)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var caption: String {
        switch state {
        case .missing:
            return "未取得"
        case .rolledOver:
            return "窓がリセットされました (次の送信で再開)"
        case .live(let window):
            guard let resets = window.resetsAt, let remaining = window.remaining(at: now) else {
                return "リセット時刻なし"
            }
            return "リセットまで \(Fmt.duration(remaining))  (\(resetFormatter.string(from: resets)))"
        }
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var tint: Color = .secondary

    var body: some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 10).monospacedDigit()).foregroundStyle(tint)
        }
    }
}

struct MenuContentView: View {
    @ObservedObject var model: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.collectorInstalled {
                setupNotice
            } else {
                WindowSection(kind: .fiveHour, state: model.state(.fiveHour), now: model.now,
                              resetFormatter: Fmt.timeOnly)
                WindowSection(kind: .sevenDay, state: model.state(.sevenDay), now: model.now,
                              resetFormatter: Fmt.dateTime)
                if model.state(.spendLimit) != .missing {
                    WindowSection(kind: .spendLimit, state: model.state(.spendLimit), now: model.now,
                                  resetFormatter: Fmt.dateTime)
                }
                Divider()
                stats
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 272)
    }

    private var header: some View {
        HStack {
            Text("claudeMeter").font(.system(size: 12, weight: .bold))
            Spacer()
            Text(Fmt.dateTimeShort.string(from: model.now))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("収集が未設定です").font(.system(size: 11, weight: .semibold))
            Text("statusLine スクリプトに収集フックを入れると\nここに 5時間／週間の残量が出ます。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(Paths.samplesFile.path)
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var stats: some View {
        if let rate = model.burnRate(.fiveHour) {
            StatRow(label: "バーンレート", value: String(format: "%.1f %%/h", rate))
        } else {
            StatRow(label: "バーンレート", value: "計測中")
        }

        if let projected = model.projection(.fiveHour) {
            StatRow(label: "予測枯渇 (5h窓)",
                    value: Fmt.timeOnly.string(from: projected),
                    tint: .red)
        } else if model.window(.fiveHour) != nil {
            StatRow(label: "予測枯渇 (5h窓)", value: "このペースなら到達せず", tint: .green)
        }

        if let hit = model.lastHit() {
            StatRow(label: "直近の到達 (\(hit.kind == .fiveHour ? "5h" : "週"))",
                    value: Fmt.dateTimeShort.string(from: hit.at))
        }
    }

    private var footer: some View {
        HStack {
            if model.isStale {
                Label("待機中 (Claude 未実行)", systemImage: "moon.zzz")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else if let last = model.engine.lastSampleAt {
                Text("最終更新 \(Fmt.timeOnly.string(from: last))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("終了") { NSApplication.shared.terminate(nil) }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}
