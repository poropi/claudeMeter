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
