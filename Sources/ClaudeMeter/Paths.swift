import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    /// 既定は ~/.claude/claudemeter。CLAUDEMETER_DIR で差し替えられる（検証用）。
    static var meterDir: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDEMETER_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return claudeDir.appendingPathComponent("claudemeter", isDirectory: true)
    }
    static var samplesFile: URL { meterDir.appendingPathComponent("samples.jsonl") }
    static var hitsCache: URL { meterDir.appendingPathComponent("hits-cache.json") }
    static var projectsDir: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }

    static func ensureMeterDir() {
        try? FileManager.default.createDirectory(at: meterDir, withIntermediateDirectories: true)
    }
}
