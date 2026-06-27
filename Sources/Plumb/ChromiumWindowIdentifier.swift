import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChromiumWindowIdentifier
//
// 模块角色：从 Chromium 内核浏览器窗口的 AXIdentifier（结构化 JSON）中判定
// 窗口是「主窗口」还是「二级窗口」的纯逻辑分类器。
//
// 为什么需要它：
//   Chromium 内核浏览器（Chrome / Edge / Brave / Arc / Vivaldi / Opera / ChatGPT Atlas）
//   的主窗口与各类二级窗口（设置页、扩展详情/设置页、PWA 窗口、弹窗）的 AXSubrole、
//   AXModal 完全相同（均为 AXStandardWindow + modal=false），靠这些传统硬特征无法区分。
//   更糟的是 kAXMainWindowAttribute 在二级窗口聚焦时不可靠——它会追踪当前聚焦窗口，
//   导致刚聚焦的扩展设置页被报成「主窗口」，从而绕过 isSecondaryWindowOfApp 的守卫
//   被误居中（正是用户报告「扩展程序设置界面被自动居中」的根因）。
//
//   唯一稳定可靠的硬特征是 AXIdentifier 内嵌的结构化 JSON：
//     - 主窗口：    {"type":"main", ...}
//     - 二级窗口：  {"type":"secondary", ...}
//   这是 Chromium 进程内窗口管理的标识（同一 Chromium 版本下所有窗口遵循此结构，
//   不随网页标题/语言/时序变化）。
//
// 设计为纯函数：只接收 AXIdentifier 字符串、返回枚举/nil，无 AX/macOS 依赖，
// 可直接单元测试。调用方（isSecondaryWindowOfApp）在 kAXMainWindowAttribute 判定
// 失败或不可靠时，对本应用是 Chromium 内核的 bundle 才回退到此分类器。
//
// 保守回退：非 JSON、JSON 无 "type" 字段、或 type 既非 main 也非 secondary → 返回 nil，
// 让调用方回退到 kAXMainWindowAttribute（不会误把主窗口当二级窗口而永远不平铺）。
// ─────────────────────────────────────────────────────────────────────────────

/// Chromium 窗口 AXIdentifier 分类结果。
enum ChromiumWindowClassification: Equatable {
    /// 主浏览器窗口（`"type":"main"`）。
    case main
    /// 二级窗口——设置页/扩展页/PWA/弹窗等（`"type":"secondary"`）。
    case secondary
}

enum ChromiumWindowIdentifier {
    /// 已知会在 AXIdentifier 中暴露 Chromium 窗口分类 JSON 的浏览器 bundle id。
    ///
    /// 仅对这些 bundle 优先使用 `classify(axIdentifier:)`。Safari / Firefox / Finder 等仍
    /// 回退到系统的 `kAXMainWindowAttribute`，避免把任意 JSON-like AXIdentifier 误当
    /// Chromium 内部窗口标识。
    private static let browserBundleIDs: Set<String> = [
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.google.chromefortesting",
        "org.chromium.chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.dev",
        "com.microsoft.edgemac.canary",
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.brave.browser.nightly",
        "company.thebrowser.browser",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "com.openai.atlas"
    ]

    static func isKnownChromiumBrowser(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        let normalized = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return browserBundleIDs.contains(normalized)
    }

    /// 从 AXIdentifier 字符串判定窗口是主还是二级。
    ///
    /// 用 JSONSerialization 解析后读取顶层 `"type"` 字段：
    /// - `"main"` → `.main`
    /// - `"secondary"` → `.secondary`
    /// - 缺失 / 其它 / 非 JSON → `nil`（调用方保守回退）
    ///
    /// 不用子串匹配（如 contains("secondary")）：那样会把 `"secondary"` 出现在任意嵌套层
    /// 的窗口误判；解析后只看顶层 type 字段最精确。JSON 解析失败时返回 nil 而非崩溃。
    static func classify(axIdentifier: String) -> ChromiumWindowClassification? {
        guard let data = axIdentifier.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        guard let type = object["type"] as? String else { return nil }
        switch type {
        case "main": return .main
        case "secondary": return .secondary
        default: return nil
        }
    }
}
