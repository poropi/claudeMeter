import Foundation
import SwiftUI

enum Severity {
    case calm, warn, danger

    init(used: Double) {
        switch used {
        case ..<50: self = .calm
        case ..<80: self = .warn
        default: self = .danger
        }
    }

    var color: Color {
        switch self {
        case .calm: return .green
        case .warn: return .orange
        case .danger: return .red
        }
    }
}

enum Fmt {
    /// 残り時間を "2:41" / "3日 4:05" の形にする。
    static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return String(format: "%d日 %d:%02d", days, hours, minutes) }
        return String(format: "%d:%02d", hours, minutes)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = format
        return f
    }

    static let timeOnly = formatter("H:mm")
    static let dateTime = formatter("M/d(E) H:mm")
    static let dateTimeShort = formatter("M/d H:mm")

    /// 消費率に応じた円グリフ。メニューバーは幅が限られるので 1 文字で量を伝える。
    static func glyph(_ used: Double) -> String {
        switch used {
        case ..<12.5: return "○"
        case ..<37.5: return "◔"
        case ..<62.5: return "◑"
        case ..<87.5: return "◕"
        default: return "●"
        }
    }

    /// サーバーが返す値は概ね整数だが、小数が来る場合もあるので 10% 未満だけ 1 桁出す。
    static func percent(_ value: Double) -> String {
        if value == 0 || value >= 10 { return String(format: "%.0f%%", value) }
        return String(format: "%.1f%%", value)
    }
}
