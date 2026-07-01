import CoreGraphics
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Per-App Tiling Insets 数据模型测试
//
// 验证：每个被平铺 app 可单独设置上/下/左/右四向间距；未单独设置的回退全局默认边距
//（全局标量 edgeMargin 铺满 4 向）。
// ─────────────────────────────────────────────────────────────────────────────

/// 构造一份可平铺设置的工具函数（平铺总开关开、含指定白名单）。
private func tilingSettings(
    enabled: Bool = true,
    globalMargin: CGFloat = 16,
    tiled: Set<String> = ["com.example.app"],
    perApp: [String: TileInsets] = [:]
) -> AppTilingSettings {
    AppTilingSettings(
        isEnabled: enabled,
        edgeInsets: TileInsets(all: globalMargin),
        tiledBundleIDs: tiled,
        hideSystemAppsInPicker: true,
        centerEnabled: true,
        centeredBundleIDs: [],
        documentChooserBundleIDs: [],
        perAppInsets: perApp
    )
}

// MARK: - effectiveInsets（默认回退语义）

@Test
func effectiveInsets_fallsBackToGlobalWhenAppNotInMap() async throws {
    // app 不在 perAppInsets → 回退全局 edgeInsets。
    let s = tilingSettings(globalMargin: 16, perApp: [:])
    #expect(s.effectiveInsets(for: "com.example.app") == TileInsets(all: 16))
}

@Test
func effectiveInsets_fallsBackToGlobalWhenBundleIdIsNil() async throws {
    let s = tilingSettings(globalMargin: 20, perApp: ["com.example.app": TileInsets(all: 40)])
    // bundle id 为 nil（无 bundle id 的进程）→ 回退全局。
    #expect(s.effectiveInsets(for: nil) == TileInsets(all: 20))
}

@Test
func effectiveInsets_returnsCustomWhenAppInMap() async throws {
    let custom = TileInsets(top: 10, bottom: 20, left: 30, right: 40)
    let s = tilingSettings(globalMargin: 16, perApp: ["com.example.app": custom])
    #expect(s.effectiveInsets(for: "com.example.app") == custom)
}

@Test
func effectiveInsets_normalizesBundleIdOnLookup() async throws {
    // 存储与查询都用归一化（trim+小写），大小写/空格差异应命中同一 app。
    let custom = TileInsets(top: 10, bottom: 20, left: 30, right: 40)
    let s = tilingSettings(globalMargin: 16, perApp: ["com.example.app": custom])
    #expect(s.effectiveInsets(for: "COM.EXAMPLE.APP") == custom)
    #expect(s.effectiveInsets(for: "  com.example.app  ") == custom)
}

@Test
func effectiveInsets_independentPerApp() async throws {
    // 不同 app 各自的四向间距互不影响，未设置的回退默认。
    let s = tilingSettings(
        globalMargin: 16,
        tiled: ["com.a", "com.b", "com.c"],
        perApp: ["com.a": TileInsets(all: 10), "com.b": TileInsets(all: 30)]
    )
    #expect(s.effectiveInsets(for: "com.a") == TileInsets(all: 10))
    #expect(s.effectiveInsets(for: "com.b") == TileInsets(all: 30))
    #expect(s.effectiveInsets(for: "com.c") == TileInsets(all: 16)) // 未设置 → 全局默认
}

@Test
func effectiveInsets_eachDirectionIndependent() async throws {
    // 四个方向可各自不同；默认回退时四向统一。
    let asym = TileInsets(top: 8, bottom: 40, left: 16, right: 24)
    let s = tilingSettings(globalMargin: 16, perApp: ["com.example.app": asym])
    let eff = s.effectiveInsets(for: "com.example.app")
    #expect(eff.top == 8)
    #expect(eff.bottom == 40)
    #expect(eff.left == 16)
    #expect(eff.right == 24)
}

// MARK: - normalized()（钳制 + key 归一化）

@Test
func normalized_clampsPerAppInsetsToValidRange() async throws {
    let s = tilingSettings(
        globalMargin: 16,
        perApp: [
            "com.low": TileInsets(top: -5, bottom: -5, left: -5, right: -5),     // 低于下限 → 钳到 0
            "com.high": TileInsets(top: 9999, bottom: 9999, left: 9999, right: 9999) // 高于上限 → 钳到 400
        ]
    )
    let n = s.normalized()
    #expect(n.perAppInsets["com.low"] == TileInsets(all: AppTilingSettings.minimumEdgeMargin))
    #expect(n.perAppInsets["com.high"] == TileInsets(all: AppTilingSettings.maximumEdgeMargin))
}

@Test
func normalized_clampsEachDirectionIndependently() async throws {
    // 每个方向独立钳制，互不影响。
    let s = tilingSettings(
        globalMargin: 16,
        perApp: ["com.x": TileInsets(top: -5, bottom: 9999, left: 200, right: 50)]
    )
    let n = s.normalized()
    let insets = try #require(n.perAppInsets["com.x"])
    #expect(insets.top == 0)         // -5 → 钳到 0
    #expect(insets.bottom == 400)    // 9999 → 钳到 400
    #expect(insets.left == 200)      // 合法
    #expect(insets.right == 50)      // 合法
}

@Test
func normalized_normalizesPerAppInsetKeys() async throws {
    // key 归一化为小写、去空格。
    let s = tilingSettings(
        globalMargin: 16,
        perApp: ["  COM.Example.App  ": TileInsets(all: 40)]
    )
    let n = s.normalized()
    #expect(n.perAppInsets["com.example.app"] == TileInsets(all: 40))
    #expect(n.perAppInsets["  COM.Example.App  "] == nil)
}

@Test
func defaultSettings_hasEmptyPerAppInsets() async throws {
    // 默认配置无任何 per-app 间距 → 全部走默认（四向统一）。
    #expect(AppTilingSettings.default.perAppInsets.isEmpty)
    #expect(AppTilingSettings.default.effectiveInsets(for: "com.anything") == TileInsets(all: AppTilingSettings.defaultEdgeMargin))
}
