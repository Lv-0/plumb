import SwiftUI

/// 居中/平铺段共用的“应用列表”：搜索框 + 药丸开关行，选中的应用排在前面。
struct AppListSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    @State private var query: String = ""

    /// 过滤 + 排序：选中的排前面，再按名称字母序；叠加搜索过滤。
    private var sortedFilteredApps: [InstalledAppInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return apps
            .filter { app in
                if q.isEmpty { return true }
                return app.name.lowercased().contains(q) || app.bundleID.contains(q)
            }
            .sorted { a, b in
                let aOn = selected.contains(a.bundleID)
                let bOn = selected.contains(b.bundleID)
                if aOn != bOn { return aOn && !bOn }
                return a.name.localizedLowercase < b.name.localizedLowercase
            }
    }

    var body: some View {
        contentView
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 内容（不含 ScrollView）—— 供居中段直接使用；平铺段会放进它自己的 ScrollView。
    var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            // 搜索框：Liquid Glass 容器
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索应用", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // 应用列表：选中在前
            LazyVStack(spacing: 2) {
                ForEach(sortedFilteredApps, id: \.bundleID) { app in
                    AppListRow(app: app, isOn: Binding(
                        get: { selected.contains(app.bundleID) },
                        set: { on in
                            if on { selected.insert(app.bundleID) }
                            else { selected.remove(app.bundleID) }
                        }
                    ))
                }
            }
            .padding(8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

/// 居中段的滚动容器包装。
struct CenteringSection: View {
    let footnote: String
    @Binding var selected: Set<String>
    let apps: [InstalledAppInfo]

    var body: some View {
        ScrollView {
            AppListSection(footnote: footnote, selected: $selected, apps: apps).contentView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }
}
