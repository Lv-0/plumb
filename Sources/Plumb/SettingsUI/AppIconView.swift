import AppKit
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AppIconView (SettingsUI)
//
// 模块角色：应用列表行的图标视图。
//
// 职责：取 InstalledAppInfo.path，经 NSWorkspace.shared.icon(forFile:) 得到系统级
// 应用图标（含系统提供的占位图），24×24、圆角 5（与设计一致）。
// ─────────────────────────────────────────────────────────────────────────────

/// 应用图标：InstalledAppInfo.path → NSWorkspace.shared.icon(forFile:) → SwiftUI Image。
/// 24×24，圆角 5（与设计图一致）。
struct AppIconView: View {
    let path: String

    var body: some View {
        let nsImage = NSWorkspace.shared.icon(forFile: path)
        Image(nsImage: nsImage)
            .resizable()
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
