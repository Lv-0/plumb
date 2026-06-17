import AppKit
import SwiftUI

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
