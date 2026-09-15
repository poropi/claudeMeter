import Foundation

/// samples.jsonl の末尾だけを読む。ファイルは追記専用なので全読みは不要。
enum SampleReader {
    static let tailBytes: UInt64 = 512 * 1024

    static func loadTail(from url: URL, maxBytes: UInt64 = tailBytes) -> [Sample] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return [] }
        let offset = end > maxBytes ? end - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        // 途中から読んだ場合、最初の行は壊れている可能性がある
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        return lines.compactMap { parse(line: String($0)) }
    }

    static func parse(line: String) -> Sample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = obj["ts"] as? Double
        else { return nil }

        func window(_ key: String) -> LimitWindow? {
            guard let w = obj[key] as? [String: Any], let used = w["used"] as? Double else { return nil }
            let resets = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return LimitWindow(used: used, resetsAt: resets)
        }

        let sample = Sample(
            ts: Date(timeIntervalSince1970: ts),
            fiveHour: window(LimitKind.fiveHour.rawValue),
            sevenDay: window(LimitKind.sevenDay.rawValue),
            spendLimit: window(LimitKind.spendLimit.rawValue),
            model: obj["model"] as? String
        )
        return sample.isEmpty ? nil : sample
    }
}

/// 観測系列から今の状態と傾きを出す。
struct LimitEngine {
    var samples: [Sample]

    func latest(_ kind: LimitKind) -> LimitWindow? {
        for sample in samples.reversed() {
            if let w = window(sample, kind) { return w }
        }
        return nil
    }

    var lastSampleAt: Date? { samples.last?.ts }

    func window(_ sample: Sample, _ kind: LimitKind) -> LimitWindow? {
        switch kind {
        case .fiveHour: return sample.fiveHour
        case .sevenDay: return sample.sevenDay
        case .spendLimit: return sample.spendLimit
        }
    }

    /// 現在の窓に属するサンプルだけを返す。resets_at が一致するものを同一の窓とみなす。
    func currentWindowSamples(_ kind: LimitKind, now: Date) -> [(Date, Double)] {
        guard let current = latest(kind)?.effective(at: now) else { return [] }
        return samples.compactMap { sample in
            guard let w = window(sample, kind) else { return nil }
            guard w.resetsAt == current.resetsAt else { return nil }
            return (sample.ts, w.used)
        }
    }

    /// 消費速度 (%/時)。まず直近 `span` で見て、サーバーが返す % が整数刻みで
    /// 直近に変化が無いときは窓全体の平均に落とす。どちらも取れなければ nil。
    func burnRate(_ kind: LimitKind, now: Date, span: TimeInterval = 45 * 60) -> Double? {
        let all = currentWindowSamples(kind, now: now)
        let recent = all.filter { now.timeIntervalSince($0.0) <= span }
        return rate(recent, minimumSpan: 5 * 60) ?? rate(all, minimumSpan: 10 * 60)
    }

    private func rate(_ points: [(Date, Double)], minimumSpan: TimeInterval) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        let seconds = last.0.timeIntervalSince(first.0)
        guard seconds >= minimumSpan else { return nil }
        let value = (last.1 - first.1) / (seconds / 3600)
        return value > 0 ? value : nil
    }

    func state(_ kind: LimitKind, now: Date) -> WindowState {
        guard let latest = latest(kind) else { return .missing }
        guard let live = latest.effective(at: now) else { return .rolledOver }
        return .live(live)
    }

    /// メニューバーに出す 1 行。観測していない窓は省く。
    func barTitle(now: Date) -> String {
        let parts = [LimitKind.fiveHour, .sevenDay].compactMap { kind -> String? in
            guard let used = state(kind, now: now).used else { return nil }
            return "\(Fmt.glyph(used))\(Fmt.percent(used))"
        }
        return parts.isEmpty ? "◌" : parts.joined(separator: " ")
    }

    func worstUsed(now: Date) -> Double {
        [state(.fiveHour, now: now).used, state(.sevenDay, now: now).used].compactMap { $0 }.max() ?? 0
    }

    /// このペースで 100% に達する時刻。窓のリセットまでに到達しないなら nil。
    func projectedExhaustion(_ kind: LimitKind, now: Date) -> Date? {
        guard let w = latest(kind)?.effective(at: now), let rate = burnRate(kind, now: now) else { return nil }
        let hoursLeft = (100 - w.used) / rate
        guard hoursLeft > 0 else { return now }
        let at = now.addingTimeInterval(hoursLeft * 3600)
        if let resets = w.resetsAt, at >= resets { return nil }
        return at
    }
}
