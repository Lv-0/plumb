import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChromiumWindowIdentifierTests
//
// 验证从 Chromium 内核浏览器（Chrome / Edge / Brave / Arc / Vivaldi / Opera /
// ChatGPT Atlas）窗口的 AXIdentifier 结构化 JSON 中识别「主窗口」的纯逻辑。
//
// 背景：这些浏览器的主窗口与二级窗口（设置页、扩展详情页、PWA、弹窗等）的
// AXSubrole / AXModal 完全相同，kAXMainWindowAttribute 在二级窗口聚焦时不可靠
// （要么追踪聚焦窗、要么读不到），无法区分。唯一稳定的硬特征是 AXIdentifier JSON：
//   - 主窗口：    {"type":"main", ...}
//   - 二级窗口：  {"type":"secondary", ...}
//
// 本测试覆盖：主窗口被判为主、各类二级窗口被判为非主、非 JSON / 无 type 标记时
// 返回 nil（让调用方回退到 kAXMainWindowAttribute 判据，保守不误伤）。
// ─────────────────────────────────────────────────────────────────────────────

@Test
func chromiumIdentifier_mainBrowserWindow_isMain() {
    // 实测（2026-06）ChatGPT Atlas 主窗口 AXIdentifier：
    let id = #"{"main":{"type":"browser","profileID":{"index":0}},"type":"main"}"#
    #expect(ChromiumWindowIdentifier.classify(axIdentifier: id) == .main)
}

@Test
func chromiumIdentifier_settingsWindow_isSecondary() {
    // 实测（2026-06）设置窗口 AXIdentifier：
    let id = #"{"secondary":{"type":"settings"},"type":"secondary"}"#
    #expect(ChromiumWindowIdentifier.classify(axIdentifier: id) == .secondary)
}

@Test
func chromiumIdentifier_extensionPage_isSecondary() {
    // 扩展详情页 / 扩展设置页（用户报告的误居中场景）：同样走 "type":"secondary"。
    // 这里用不含 "settings" 的标识符，确保判定靠的是 type 字段而非 settings 子串。
    let id = #"{"secondary":{"type":"popup","tab":{"id":42}},"type":"secondary"}"#
    #expect(ChromiumWindowIdentifier.classify(axIdentifier: id) == .secondary)
}

@Test
func chromiumIdentifier_nonJsonIdentifier_returnsNil() {
    // 非 Chromium 的 AXIdentifier（或无 JSON 结构）：返回 nil，调用方回退到 kAXMainWindowAttribute。
    #expect(ChromiumWindowIdentifier.classify(axIdentifier: "some-window-id") == nil)
    #expect(ChromiumWindowIdentifier.classify(axIdentifier: "") == nil)
}

@Test
func chromiumIdentifier_missingTypeField_returnsNil() {
    // JSON 但无 "type" 字段：无法判定，返回 nil 让调用方保守回退。
    let id = #"{"foo":"bar"}"#
    #expect(ChromiumWindowIdentifier.classify(axIdentifier: id) == nil)
}

@Test
func chromiumIdentifier_knownChromiumBrowserBundleIDs_useIdentifierPath() {
    #expect(ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "com.google.Chrome"))
    #expect(ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "com.microsoft.edgemac"))
    #expect(ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "com.brave.Browser"))
    #expect(ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "company.thebrowser.Browser"))
    #expect(ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "com.openai.atlas"))
}

@Test
func chromiumIdentifier_nonChromiumBrowserBundleIDs_doNotUseIdentifierPath() {
    #expect(!ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "com.apple.Safari"))
    #expect(!ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "org.mozilla.firefox"))
    #expect(!ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: "com.apple.finder"))
    #expect(!ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: nil))
}
