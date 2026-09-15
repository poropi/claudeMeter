import Foundation

/// `~/.claude/projects/**/*.jsonl` に残る 429 の記録から「実際に上限に当たった時刻」を拾う。
/// JSONL は追記専用なので、ファイルごとに走査済みオフセットを覚えて差分だけ読む。
/// (全体は 800MB を超えるため、毎回の全走査はしない)
final class LimitHitScanner: @unchecked Sendable {
    private struct Cache: Codable {
        var offsets: [String: UInt64] = [:]
        var hits: [StoredHit] = []
    }

    private struct StoredHit: Codable {
        var at: Double
        var kind: String
        var resetsAt: Double?
    }

    private static let marker = Data("\"rateLimitType\"".utf8)
    private static let maxHits = 200

    private let lock = NSLock()
    private var cache = Cache()
    private var loaded = false

    func scan() -> [LimitHit] {
        lock.lock()
        defer { lock.unlock() }
        loadCacheIfNeeded()

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: Paths.projectsDir,
                                         includingPropertiesForKeys: [.fileSizeKey],
                                         options: [.skipsHiddenFiles]) else { return storedHits() }

        var newHits: [StoredHit] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let path = url.path
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { UInt64($0) } ?? 0
            var offset = cache.offsets[path] ?? 0
            if offset > size { offset = 0 }          // ローテート/再作成されたファイル
            guard size > offset else { continue }

            newHits.append(contentsOf: extractHits(url: url, from: offset))
            cache.offsets[path] = size
        }

        if !newHits.isEmpty {
            cache.hits.append(contentsOf: newHits)
            cache.hits.sort { $0.at < $1.at }
            if cache.hits.count > Self.maxHits {
                cache.hits.removeFirst(cache.hits.count - Self.maxHits)
            }
        }
        saveCache()
        return storedHits()
    }

    private func extractHits(url: URL, from offset: UInt64) -> [StoredHit] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let start = data.index(data.startIndex, offsetBy: Int(min(offset, UInt64(data.count))))
        guard start < data.endIndex else { return [] }

        var hits: [StoredHit] = []
        var cursor = start
        while let found = data.range(of: Self.marker, in: cursor..<data.endIndex) {
            let lineStart = data[start..<found.lowerBound].lastIndex(of: 0x0A).map { data.index(after: $0) } ?? start
            let lineEnd = data[found.upperBound...].firstIndex(of: 0x0A) ?? data.endIndex
            if let hit = parseHit(Data(data[lineStart..<lineEnd])) { hits.append(hit) }
            cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : data.endIndex
            if cursor >= data.endIndex { break }
        }
        return hits
    }

    private func parseHit(_ line: Data) -> StoredHit? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let quota = obj["quotaLimits"] as? [String: Any],
              (quota["status"] as? String) == "rejected",
              let kind = quota["rateLimitType"] as? String,
              LimitKind(rawValue: kind) != nil,
              let stamp = obj["timestamp"] as? String,
              let at = ISO8601DateFormatter.parse(stamp)
        else { return nil }
        return StoredHit(at: at.timeIntervalSince1970, kind: kind, resetsAt: quota["resetsAt"] as? Double)
    }

    private func storedHits() -> [LimitHit] {
        cache.hits.compactMap { stored in
            guard let kind = LimitKind(rawValue: stored.kind) else { return nil }
            return LimitHit(at: Date(timeIntervalSince1970: stored.at),
                            kind: kind,
                            resetsAt: stored.resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
    }

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Paths.hitsCache),
           let decoded = try? JSONDecoder().decode(Cache.self, from: data) {
            cache = decoded
        }
    }

    private func saveCache() {
        Paths.ensureMeterDir()
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: Paths.hitsCache, options: .atomic)
        }
    }
}

extension ISO8601DateFormatter {
    /// Claude Code のタイムスタンプは小数秒つき ("2026-09-14T06:54:16.550Z")。
    static func parse(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
