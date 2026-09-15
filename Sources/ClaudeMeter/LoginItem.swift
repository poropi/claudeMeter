import Foundation
import ServiceManagement

/// ログイン時の自動起動。ヘルパーを持たない単体アプリなので SMAppService.mainApp を使う。
/// 登録先は「システム設定 → 一般 → ログイン項目」で、plist を自分で置く必要はない。
enum LoginItem {
    enum State {
        /// 登録済み。ログイン時に起動する。
        case enabled
        /// 未登録。
        case disabled
        /// 登録はされたが、ユーザーがシステム設定で許可していない。
        case requiresApproval
        /// launchd から見えない（.app の外＝ビルド直後のバイナリ単体で動かした等）。
        case unavailable

        var label: String {
            switch self {
            case .enabled: return "登録済み"
            case .disabled: return "未登録"
            case .requiresApproval: return "要承認 (システム設定 → 一般 → ログイン項目)"
            case .unavailable: return "利用不可 (.app として起動していない)"
            }
        }
    }

    /// バイナリ単体で起動していると SMAppService は使えないので、先に弾く。
    static var isBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var state: State {
        guard isBundled else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// 成功したら nil、失敗したら理由を返す。
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isBundled else { return "この起動方法では登録できません (.app から起動してください)" }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return (error as NSError).localizedDescription
        }
    }

    /// システム設定のログイン項目ペインを開く。要承認のときの導線。
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// `--login-item <status|register|unregister>` の処理。
    static func runCLI(_ argument: String?) -> Int32 {
        switch argument {
        case "status", nil:
            print("ログイン時に起動: \(state.label)")
            print("バンドル: \(Bundle.main.bundleURL.path)")
            return 0
        case "register", "unregister":
            let enable = argument == "register"
            if let reason = set(enable) {
                FileHandle.standardError.write(Data("失敗: \(reason)\n".utf8))
                return 1
            }
            print("ログイン時に起動: \(state.label)")
            return 0
        default:
            FileHandle.standardError.write(Data("--login-item は status / register / unregister のいずれか\n".utf8))
            return 2
        }
    }
}
