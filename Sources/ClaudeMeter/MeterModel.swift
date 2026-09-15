import Foundation
import SwiftUI

@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var engine = LimitEngine(samples: [])
    @Published private(set) var hits: [LimitHit] = []
    @Published private(set) var now = Date()
    @Published private(set) var collectorInstalled = false

    private let scanner = LimitHitScanner()
    private var lastSamplesMtime: Date?
    private var tick: Timer?
    private var scanTick: Timer?

    /// このリセット時刻を過ぎたら Claude Code 側もカウンタを畳む。
    /// サンプルが古くても「窓が変わった」ことだけは時計から判断できる。
    var isStale: Bool {
        guard let last = engine.lastSampleAt else { return true }
        return now.timeIntervalSince(last) > 120
    }

    func start() {
        reloadSamples(force: true)
        Task { await refreshHits() }

        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.reloadSamples(force: false)
            }
        }
        scanTick = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refreshHits() }
        }
    }

    func refreshHits() async {
        let scanner = self.scanner
        let found = await Task.detached(priority: .utility) { scanner.scan() }.value
        self.hits = found
    }

    /// samples.jsonl の mtime が変わったときだけ読み直す。
    private func reloadSamples(force: Bool) {
        let url = Paths.samplesFile
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        collectorInstalled = attrs != nil

        if !force, mtime == lastSamplesMtime { return }
        lastSamplesMtime = mtime
        engine = LimitEngine(samples: SampleReader.loadTail(from: url))
    }

    func state(_ kind: LimitKind) -> WindowState { engine.state(kind, now: now) }

    func window(_ kind: LimitKind) -> LimitWindow? { state(kind).window }

    func burnRate(_ kind: LimitKind) -> Double? { engine.burnRate(kind, now: now) }
    func projection(_ kind: LimitKind) -> Date? { engine.projectedExhaustion(kind, now: now) }

    func lastHit(_ kind: LimitKind? = nil) -> LimitHit? {
        hits.last { kind == nil || $0.kind == kind }
    }

    var barTitle: String { engine.barTitle(now: now) }

    var barSeverity: Severity { Severity(used: engine.worstUsed(now: now)) }
}
