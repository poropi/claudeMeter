import Foundation

/// レート制限の 1 窓分。`used` はサーバーが返した実測の消費率 (0-100)。
struct LimitWindow: Equatable {
    var used: Double
    var resetsAt: Date?

    /// 窓のリセット時刻を過ぎていれば消費は 0 に戻っている。
    /// Claude Code 自身もリセット後は当該キーを落とすため、それに合わせる。
    func effective(at now: Date) -> LimitWindow? {
        guard let resetsAt else { return self }
        return now >= resetsAt ? nil : self
    }

    func remaining(at now: Date) -> TimeInterval? {
        guard let resetsAt else { return nil }
        return max(0, resetsAt.timeIntervalSince(now))
    }
}

/// statusLine が 1 回書き出したスナップショット。
struct Sample: Equatable {
    var ts: Date
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    var spendLimit: LimitWindow?
    var model: String?

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil && spendLimit == nil }
}

enum LimitKind: String {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case spendLimit = "spend_limit"

    var label: String {
        switch self {
        case .fiveHour: return "5時間制限"
        case .sevenDay: return "週間制限 (7日)"
        case .spendLimit: return "支出上限"
        }
    }
}

/// 実際に 429 で止められた記録 (`~/.claude/projects/**/*.jsonl` の quotaLimits)。
struct LimitHit: Equatable {
    var at: Date
    var kind: LimitKind
    var resetsAt: Date?
}

/// 窓の観測状態。リセット直後は「消費 0 だがリセット時刻は未定」であり、
/// 未観測 (データなし) とは区別する必要がある。
enum WindowState: Equatable {
    case missing
    case rolledOver
    case live(LimitWindow)

    var used: Double? {
        switch self {
        case .missing: return nil
        case .rolledOver: return 0
        case .live(let w): return w.used
        }
    }

    var window: LimitWindow? {
        if case .live(let w) = self { return w }
        return nil
    }
}
