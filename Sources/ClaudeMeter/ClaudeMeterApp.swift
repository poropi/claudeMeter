import SwiftUI

@main
struct ClaudeMeterApp: App {
    @StateObject private var model = MeterModel()

    init() {
        // GUI を立ち上げずに現在値を確認する経路。Scene を作る前に抜ける。
        if CommandLine.arguments.contains("--dump") {
            DumpMode.run()
            exit(0)
        }
        // 取得経路の切り分け用。どの claude を選んだか、何が返ったかを出す。
        if CommandLine.arguments.contains("--probe") {
            for (key, value) in ClaudeCLI.diagnose() { print("  \(key): \(value)") }
            print("binary: \(ClaudeCLI.resolveBinary() ?? "(見つかりません)")")
            if let reading = UsageProbe.fetchOnce() {
                print("available: \(reading.available)")
                print("five_hour: \(String(describing: reading.fiveHour))")
                print("seven_day: \(String(describing: reading.sevenDay))")
            } else {
                print("応答なし")
            }
            exit(0)
        }
        // ログイン項目の登録／解除も GUI なしで扱えるようにしておく。
        if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
            let sub = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            exit(LoginItem.runCLI(sub))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Text(model.barTitle)
                .monospacedDigit()
                .foregroundStyle(model.barSeverity.color)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}
