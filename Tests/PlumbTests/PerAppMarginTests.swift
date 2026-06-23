import CoreGraphics
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Per-App Tiling Margin 数据模型测试
//
// 验证：每个被平铺 app 可单独设置边距；未单独设置的回退全局默认边距。
// ─────────────────────────────────────────────────────────────────────────────

/// 构造一份可平铺设置的工具函数（平铺总开关开、含指定白名单）。
private func tilingSettings(
    enabled: Bool = true,
    globalMargin: CGFloat = 16,
    tiled: Set<String> = ["com.example.app"],
    perApp: [String: CGFloat] = [:]
) -> AppTilingSettings {
    AppTilingSettings(
        isEnabled: enabled,
        edgeMargin: globalMargin,
        tiledBundleIDs: tiled,
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppMargins: perApp
    )
}

// MARK: - effectiveMargin（默认回退语义）

@Test
func effectiveMargin_fallsBackToGlobalWhenAppNotInMap() async throws {
    // app 不在 perAppMargins → 回退全局 edgeMargin。
    let s = tilingSettings(globalMargin: 16, perApp: [:])
    #expect(s.effectiveMargin(for: "com.example.app") == 16)
}

@Test
func effectiveMargin_fallsBackToGlobalWhenBundleIdIsNil() async throws {
    let s = tilingSettings(globalMargin: 20, perApp: ["com.example.app": 40])
    // bundle id 为 nil（无 bundle id 的进程）→ 回退全局。
    #expect(s.effectiveMargin(for: nil) == 20)
}

@Test
func effectiveMargin_returnsCustomWhenAppInMap() async throws {
    let s = tilingSettings(globalMargin: 16, perApp: ["com.example.app": 40])
    #expect(s.effectiveMargin(for: "com.example.app") == 40)
}

@Test
func effectiveMargin_normalizesBundleIdOnLookup() async throws {
    // 存储与查询都用归一化（trim+小写），大小写/空格差异应命中同一 app。
    let s = tilingSettings(globalMargin: 16, perApp: ["com.example.app": 40])
    #expect(s.effectiveMargin(for: "COM.EXAMPLE.APP") == 40)
    #expect(s.effectiveMargin(for: "  com.example.app  ") == 40)
}

@Test
func effectiveMargin_independentPerApp() async throws {
    // 不同 app 各自的边距互不影响，未设置的回退默认。
    let s = tilingSettings(
        globalMargin: 16,
        tiled: ["com.a", "com.b", "com.c"],
        perApp: ["com.a": 10, "com.b": 30]
    )
    #expect(s.effectiveMargin(for: "com.a") == 10)
    #expect(s.effectiveMargin(for: "com.b") == 30)
    #expect(s.effectiveMargin(for: "com.c") == 16) // 未设置 → 全局默认
}

// MARK: - normalized()（钳制 + key 归一化）

@Test
func normalized_clampsPerAppMarginsToValidRange() async throws {
    let s = tilingSettings(
        globalMargin: 16,
        perApp: [
            "com.low": -5,    // 低于下限 → 钳到 minimumEdgeMargin(0)
            "com.high": 9999  // 高于上限 → 钳到 maximumEdgeMargin(400)
        ]
    )
    let n = s.normalized()
    #expect(n.perAppMargins["com.low"] == AppTilingSettings.minimumEdgeMargin)
    #expect(n.perAppMargins["com.high"] == AppTilingSettings.maximumEdgeMargin)
}

@Test
func normalized_normalizesPerAppMarginKeys() async throws {
    // key 归一化为小写、去空格。
    let s = tilingSettings(
        globalMargin: 16,
        perApp: ["  COM.Example.App  ": 40]
    )
    let n = s.normalized()
    #expect(n.perAppMargins["com.example.app"] == 40)
    #expect(n.perAppMargins["  COM.Example.App  "] == nil)
}

@Test
func defaultSettings_hasEmptyPerAppMargins() async throws {
    // 默认配置无任何 per-app 边距 → 全部走默认。
    #expect(AppTilingSettings.default.perAppMargins.isEmpty)
    #expect(AppTilingSettings.default.effectiveMargin(for: "com.anything") == AppTilingSettings.defaultEdgeMargin)
}
