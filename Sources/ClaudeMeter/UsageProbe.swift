import Foundation

/// サーバーから引いた残量。`rate_limits` の 1 スナップショット。
struct UsageReading: Equatable {
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    /// API キー / Bedrock / Vertex のセッションでは false（プラン制限が存在しない）。
    var available: Bool

    var isEmpty: Bool { fiveHour == nil && sevenDay == nil }
}

/// `claude` の在処と、それを動かすための PATH。
///
/// GUI から起動したアプリの PATH は `/usr/bin:/bin:/usr/sbin:/sbin` しかないので、
/// nvm・homebrew・mise のいずれに入れていても届かない。ログインシェルと
/// 対話シェルの両方に PATH を聞き、見つかった `claude` をバージョンで選ぶ。
/// `get_usage` に応えるのは 2.0 以降で、1.x が homebrew に残っていることがある。
enum ClaudeCLI {
    private static var cachedBinary: String??
    private static var cachedPath: String?

    static func resolveBinary() -> String? {
        if let cachedBinary { return cachedBinary }
        let resolved = findBinary()
        cachedBinary = .some(resolved)
        return resolved
    }

    /// 子プロセスに渡す環境。PATH だけシェルのものに差し替える。
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shellPath()
        return env
    }

    private static func shellPath() -> String {
        if let cachedPath { return cachedPath }
        let fallback = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // 対話シェル (-i) を先に見る。nvm や mise は .zshrc で PATH に入るため。
        for flags in ["-ic", "-lc"] {
            guard let out = run(shell, [flags, #"printf %s "$PATH""#], environment: nil, timeout: 20) else { continue }
            if let line = out.split(separator: "\n").last(where: { $0.contains("/") }) {
                let path = String(line).trimmingCharacters(in: .whitespaces)
                cachedPath = path
                return path
            }
        }
        cachedPath = fallback
        return fallback
    }

    private static func findBinary() -> String? {
        if let override = ProcessInfo.processInfo.environment["CLAUDEMETER_CLAUDE_BIN"], !override.isEmpty {
            return override
        }
        var best: (path: String, version: [Int])?
        var seen = Set<String>()
        for path in candidates() where seen.insert(path).inserted {
            guard FileManager.default.isExecutableFile(atPath: path), let version = version(of: path) else { continue }
            if best == nil || isNewer(version, than: best!.version) { best = (path, version) }
        }
        return best?.path
    }

    static func candidates() -> [String] {
        var found = shellPath().split(separator: ":").map { "\($0)/claude" }
        found += nvmInstalls()
        found += [
            Paths.home.appendingPathComponent(".claude/local/claude").path,
            Paths.home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return found
    }

    /// nvm はバージョンごとに bin を持つ。シェルの PATH に出ていないこともある。
    private static func nvmInstalls() -> [String] {
        let root = Paths.home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return versions.map { root.appendingPathComponent("\($0)/bin/claude").path }
    }

    private static func isNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        for (l, r) in zip(lhs, rhs) where l != r { return l > r }
        return lhs.count > rhs.count
    }

    /// "2.1.270 (Claude Code)" → [2, 1, 270]
    private static func version(of path: String) -> [Int]? {
        guard let out = run(path, ["--version"], environment: environment, timeout: 20) else { return nil }
        let token = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        let parts = token.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 ? parts : nil
    }

    private static func run(_ path: String, _ arguments: [String],
                            environment: [String: String]?, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// --probe 用。候補と判定結果をそのまま見せる。
    static func diagnose() -> [(String, String)] {
        var rows = [("PATH", shellPath())]
        var seen = Set<String>()
        for path in candidates() where seen.insert(path).inserted {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            rows.append((path, version(of: path).map { $0.map(String.init).joined(separator: ".") } ?? "バージョン取得失敗"))
        }
        return rows
    }

    /// stream-json で 1 プロセス立て、control_request を流し込むための引数。
    /// `disableAllHooks` はユーザーのフック（ワークログ等）を毎回起こさないため。
    static let arguments = [
        "-p",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--settings", #"{"disableAllHooks":true}"#,
    ]

    static func requestLine(id: String) -> String {
        #"{"type":"control_request","request_id":"\#(id)","request":{"subtype":"get_usage","skip_behaviors":true}}"# + "\n"
    }
}

/// control_response の中身を `LimitWindow` に落とす。
enum UsageResponse {
    static func parse(_ object: [String: Any]) -> UsageReading? {
        guard object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["subtype"] as? String == "success",
              let payload = response["response"] as? [String: Any]
        else { return nil }

        let limits = payload["rate_limits"] as? [String: Any]
        func window(_ key: String) -> LimitWindow? {
            guard let w = limits?[key] as? [String: Any],
                  let used = w["utilization"] as? Double
            else { return nil }
            return LimitWindow(used: used, resetsAt: (w["resets_at"] as? String).flatMap(timestamp))
        }

        return UsageReading(
            fiveHour: window(LimitKind.fiveHour.rawValue),
            sevenDay: window(LimitKind.sevenDay.rawValue),
            available: payload["rate_limits_available"] as? Bool ?? false
        )
    }

    /// "2026-09-15T05:40:00.289197+00:00" 形式。ISO8601DateFormatter は
    /// マイクロ秒を受け付けないので、小数部を落としてから渡す。
    static func timestamp(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: "."),
           let tz = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text.removeSubrange(dot..<tz)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// `claude` を 1 プロセスだけ常駐させ、一定間隔で `get_usage` を投げて残量を引く。
///
/// statusLine はターミナル UI でしか走らないため、VSCode 拡張やデスクトップで
/// 作業している間は収集が止まる。こちらはセッションの有無に依存せず、
/// プロンプトを送らないのでクォータも消費しない。
final class UsageProbe {
    enum Status: Equatable {
        case starting
        case live(Date)
        case unavailable(String)
    }

    private let interval: TimeInterval
    private let onReading: (UsageReading) -> Void
    private let onStatus: (Status) -> Void

    private let queue = DispatchQueue(label: "io.github.poropi.claudemeter.probe")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var restartDelay: TimeInterval = 5
    private var stopped = false
    private var counter = 0

    init(interval: TimeInterval,
         onReading: @escaping (UsageReading) -> Void,
         onStatus: @escaping (Status) -> Void) {
        self.interval = interval
        self.onReading = onReading
        self.onStatus = onStatus
    }

    func start() { queue.async { self.launch() } }

    func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
        }
    }

    // MARK: - プロセス

    private func launch() {
        guard !stopped else { return }
        guard let binary = ClaudeCLI.resolveBinary() else {
            onStatus(.unavailable("claude コマンドが見つかりません"))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ClaudeCLI.arguments
        process.environment = ClaudeCLI.environment
        Paths.ensureMeterDir()
        process.currentDirectoryURL = Paths.meterDir

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.consume(chunk) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.scheduleRestart() }
        }

        do {
            try process.run()
        } catch {
            onStatus(.unavailable("claude を起動できません: \(error.localizedDescription)"))
            scheduleRestart()
            return
        }

        self.process = process
        self.input = inPipe.fileHandleForWriting
        self.buffer = Data()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.request() }
        timer.resume()
        self.timer?.cancel()
        self.timer = timer

        request()
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        input = nil
        buffer = Data()
    }

    private func scheduleRestart() {
        guard !stopped, process != nil || input != nil || timer != nil else { return }
        teardown()
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 60)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch() }
    }

    // MARK: - やり取り

    private func request() {
        guard let input else { return }
        counter += 1
        let line = ClaudeCLI.requestLine(id: "meter_\(counter)")
        guard let data = line.data(using: .utf8) else { return }
        do {
            try input.write(contentsOf: data)
        } catch {
            scheduleRestart()
        }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line)
        }
        // 改行が来ないまま肥大したら捨てる（壊れた出力で溜め込まないように）
        if buffer.count > 1 << 20 { buffer.removeAll() }
    }

    private func handle(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let reading = UsageResponse.parse(object)
        else { return }

        guard reading.available, !reading.isEmpty else {
            onStatus(.unavailable("このセッションではプラン残量が出ません"))
            return
        }
        restartDelay = 5
        onStatus(.live(Date()))
        onReading(reading)
    }

    // MARK: - 単発

    /// `--dump` 用に 1 回だけ引く。常駐せず、取れたら即終了する。
    static func fetchOnce(timeout: TimeInterval = 30) -> UsageReading? {
        guard let binary = ClaudeCLI.resolveBinary() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ClaudeCLI.arguments
        process.environment = ClaudeCLI.environment
        Paths.ensureMeterDir()
        process.currentDirectoryURL = Paths.meterDir

        let inPipe = Pipe()
        let outPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var result: UsageReading?
        var buffer = Data()
        let done = DispatchSemaphore(value: 0)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard result == nil,
                      let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let reading = UsageResponse.parse(object)
                else { continue }
                result = reading
                done.signal()
            }
        }

        guard (try? process.run()) != nil else { return nil }
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(ClaudeCLI.requestLine(id: "meter_dump").utf8))

        _ = done.wait(timeout: .now() + timeout)
        outPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }

        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
