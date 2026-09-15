import Foundation

/// `ClaudeMeter --dump` でメニューのパネルと同じ内容を標準出力に出す。
/// GUI を開かずに収集が効いているか確かめるための確認口。
enum DumpMode {
    static func run() {
        let now = Date()
        let engine = LimitEngine(samples: SampleReader.loadTail(from: Paths.samplesFile))
        let hits = LimitHitScanner().scan()

        print("claudeMeter  \(Fmt.dateTimeShort.string(from: now))")
        print("")

        guard FileManager.default.fileExists(atPath: Paths.samplesFile.path) else {
            print("収集が未設定です: \(Paths.samplesFile.path) がありません")
            print("scripts/install-collector.py を実行してください")
            return
        }

        for kind in [LimitKind.fiveHour, .sevenDay, .spendLimit] {
            guard let latest = engine.latest(kind) else {
                if kind != .spendLimit { print("\(kind.label): 未取得") ; print("") }
                continue
            }
            let live = latest.effective(at: now)
            let used = live?.used ?? 0
            print("\(kind.label)  \(bar(used))  \(Fmt.percent(used))")
            if let live, let resets = live.resetsAt, let remaining = live.remaining(at: now) {
                let f = kind == .fiveHour ? Fmt.timeOnly : Fmt.dateTime
                print("  リセットまで \(Fmt.duration(remaining))  (\(f.string(from: resets)))")
            } else if live == nil {
                print("  窓がリセットされました (次の送信で再開)")
            }
            print("")
        }

        if let rate = engine.burnRate(.fiveHour, now: now) {
            print(String(format: "バーンレート  %.1f %%/h", rate))
            if let projected = engine.projectedExhaustion(.fiveHour, now: now) {
                print("予測枯渇      \(Fmt.timeOnly.string(from: projected))  (5h窓)")
            } else {
                print("予測枯渇      このペースなら到達せず")
            }
        } else {
            print("バーンレート  計測中 (サンプル不足)")
        }

        if let hit = hits.last {
            print("直近の到達    \(Fmt.dateTimeShort.string(from: hit.at))  (\(hit.kind.label))")
        }

        if let last = engine.lastSampleAt {
            let age = now.timeIntervalSince(last)
            print("最終更新      \(Fmt.timeOnly.string(from: last))" + (age > 120 ? "  ※ Claude 未実行" : ""))
        }
        print("サンプル数    \(engine.samples.count)")
        print("")
        print("メニューバー表示:  \(engine.barTitle(now: now))")
    }

    private static func bar(_ used: Double, width: Int = 20) -> String {
        let filled = Int((min(max(used, 0), 100) / 100 * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }
}
