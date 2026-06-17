import SwiftUI

/// 居中/平铺段共用的“应用列表”：每应用一行 Toggle，绑定到 settings 的某个 Set<String>。
/// 按设计图：无总开关、无搜索框；顶部脚注说明“空列表 = 全部居中”的隐含语义。
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        List {
            Section {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowSeparator(.hidden)
            }
            Section {
                ForEach(apps, id: \.bundleID) { app in
                    AppListRow(app: app, isOn: Binding(
                        get: { selected.contains(app.bundleID) },
                        set: { on in
                            if on { selected.insert(app.bundleID) }
                            else { selected.remove(app.bundleID) }
                        }
                    ))
                    .listRowBackground(Color.clear)
                }
            }
        }
        // 隐藏 List 自带的不透明内容背景，否则会盖住下面的玻璃材质。
        .scrollContentBackground(.hidden)
        // Liquid Glass 卡片层：折射背景内容，自适应活力度让文字保持清晰。
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
