import Foundation
import Testing
@testable import Plumb

/// 验证设置中应用列表的搜索过滤逻辑（`AppListFilter.filterAndSort`）。
///
/// 过滤策略：仅按显示名匹配（不碰 bundle id）。
///
/// 回归背景（两轮）：
///   1. 早期 `app.bundleID.contains(q)` —— 反向域名前缀（`com.apple.`）几乎总含常见字母，
///      输入 "a" 几乎所有 Apple 应用都命中（bug：搜 a 不过滤）。
///   2. 改成只比 bundle id 最后一段 —— `com.mowglii.ItsycalApp`→`itsycalapp` 仍含 "app"，
///      输入 "app" 会把名字里没有 app 的 Itsycal 带出来（bug：搜 app 出现 Itsycal）。
///
/// 故最终彻底只按显示名过滤。本测试锁定该行为。
struct AppListSectionTests {
    private let sampleApps: [InstalledAppInfo] = [
        // 真实 bundle id：Itsycal 的最后一段是 "ItsycalApp"，历史上会污染 "app" 查询。
        .init(bundleID: "com.mowglii.ItsycalApp", name: "Itsycal", path: "", isSystemApp: false),
        // WhatsApp 的最后一段 "WhatsApp" 也含 "app"，同理会污染。
        .init(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "", isSystemApp: false),
        .init(bundleID: "com.apple.Notes", name: "Notes", path: "", isSystemApp: true),
        .init(bundleID: "com.apple.Maps", name: "地图", path: "", isSystemApp: true),
        .init(bundleID: "com.apple.dt.Xcode", name: "Xcode", path: "", isSystemApp: true),
        .init(bundleID: "com.apple.Safari", name: "Safari", path: "", isSystemApp: true),
        .init(bundleID: "com.raycast.macos", name: "Raycast", path: "", isSystemApp: false),
        .init(bundleID: "com.hegen.Bob", name: "Bob", path: "", isSystemApp: false),
        .init(bundleID: "com.apple.appstore", name: "App Store", path: "", isSystemApp: true),
    ]
    private let emptySelection: Set<String> = []

    private func names(_ result: [InstalledAppInfo]) -> Set<String> {
        Set(result.map(\.name))
    }

    @Test
    func emptyQueryKeepsAllApps() {
        let result = AppListFilter.filterAndSort(
            apps: sampleApps, query: "", selected: emptySelection
        )
        #expect(result.count == sampleApps.count)
    }

    @Test
    func whitespaceOnlyQueryKeepsAllApps() {
        let result = AppListFilter.filterAndSort(
            apps: sampleApps, query: "   ", selected: emptySelection
        )
        #expect(result.count == sampleApps.count)
    }

    @Test
    func singleLetterAFiltersOutAppsWithoutA() {
        // 第一轮回归：输入 "a" 必须过滤掉名称不含 "a" 的应用。
        // 此前因 bundleID 整段含 "apple" 而 Notes/Xcode/地图 被错误保留。
        let result = AppListFilter.filterAndSort(
            apps: sampleApps, query: "a", selected: emptySelection
        )
        let kept = names(result)
        // 名称（小写）含 "a" 的：safari、raycast、whatsapp、itsycal、app store
        #expect(kept == ["Safari", "Raycast", "WhatsApp", "Itsycal", "App Store"])
        // 名称不含 "a" 的必须被过滤掉：
        #expect(!kept.contains("Notes"))
        #expect(!kept.contains("Xcode"))
        #expect(!kept.contains("地图"))
        #expect(!kept.contains("Bob"))
    }

    @Test
    func queryAppDoesNotMatchItsycalByNameOnly() {
        // 第二轮回归（核心）：输入 "app" 不应把名字里没有 "app" 的应用带出来。
        // Itsycal 的 bundle id 最后段是 "ItsycalApp"——历史上因匹配 bundle id 而命中；
        // 现仅按显示名，"itsycal" 不含 "app" → 必须过滤掉。
        let result = AppListFilter.filterAndSort(
            apps: sampleApps, query: "app", selected: emptySelection
        )
        let kept = names(result)
        // 名称（小写）含 "app" 的：whatsapp(whats**app**)、app store
        #expect(kept == ["WhatsApp", "App Store"])
        // 关键断言：Itsycal 必须被过滤掉——尽管其 bundle id 最后段是 "ItsycalApp"。
        #expect(!kept.contains("Itsycal"))
        #expect(!kept.contains("Xcode"))
        #expect(!kept.contains("Notes"))
    }

    @Test
    func queryMatchesByNameCaseInsensitively() {
        let result = AppListFilter.filterAndSort(
            apps: sampleApps, query: "XCODE", selected: emptySelection
        )
        #expect(names(result) == ["Xcode"])
    }

    @Test
    func selectedAppsAreSortedToTop() {
        let selected: Set<String> = ["com.hegen.Bob", "com.apple.Notes"]
        let result = AppListFilter.filterAndSort(
            apps: sampleApps, query: "", selected: selected
        )
        // 选中在前（按字母序），未选中在后字母序。
        let firstTwo = Set(result.prefix(2).map(\.name))
        #expect(firstTwo == ["Bob", "Notes"])
    }
}
