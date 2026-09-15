import Foundation
import SwiftUI

@MainActor
final class MeterModel: ObservableObject {
    /// サーバーへ残量を引きに行く間隔。CLAUDEMETER_POLL_SECONDS で変えられる。
    static var pollInterval: TimeInterval {
        let raw = ProcessInfo.processInfo.environment["CLAUDEMETER_POLL_SECONDS"]
        return raw.flatMap(Double.init).map { max(10, $0) } ?? 30
    }

    @Published private(set) var engine = LimitEngine(samples: [])
    @Published private(set) var hits: [LimitHit] = []
    @Published private(set) var now = Date()
    @Published private(set) var collectorInstalled = false
    @Published private(set) var probeStatus: UsageProbe.Status = .starting

    private let scanner = LimitHitScanner()
    private var lastSamplesMtime: Date?
    private var tick: Timer?
    private var scanTick: Timer?
    private var probe: UsageProbe?

    /// 直近の値がいつのものか。ライブ取得が生きている間は古びない。
    var isStale: Bool {
        if case .live(let at) = probeStatus, now.timeIntervalSince(at) < 180 { return false }
        guard let last = engine.lastSampleAt else { return true }
        return now.timeIntervalSince(last) > 120
    }

    func start() {
        // MenuBarExtra の label は作り直されることがある。二重にタイマーを張らない。
        guard tick == nil else { return }

        reloadSamples(force: true)
        Task { await refreshHits() }
        startProbe()

        // .common モードで回す。メニューを開いている間も秒針とゲージを止めない。
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                self.reloadSamples(force: false)
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        self.tick = tick

        let scanTick = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refreshHits() }
        }
        RunLoop.main.add(scanTick, forMode: .common)
        self.scanTick = scanTick
    }

    /// `claude` に `get_usage` を投げて残量を直接引く。statusLine が走らない
    /// UI（VSCode 拡張・デスクトップ）でも、Claude Code が動いていなくても取れる。
    private func startProbe() {
        let probe = UsageProbe(
            interval: Self.pollInterval,
            onReading: { [weak self] reading in
                Task { @MainActor in self?.apply(reading) }
            },
            onStatus: { [weak self] status in
                Task { @MainActor in self?.probeStatus = status }
            }
        )
        probe.start()
        self.probe = probe
    }

    private func apply(_ reading: UsageReading) {
        guard SampleWriter.append(reading, to: Paths.samplesFile, previous: engine.samples.last) else { return }
        reloadSamples(force: true)
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
