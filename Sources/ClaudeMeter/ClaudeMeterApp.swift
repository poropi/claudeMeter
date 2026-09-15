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
