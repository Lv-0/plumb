import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - main (入口)
//
// 模块角色：程序入口，负责"正常启动"与"自测模式"的分流。
//
// 职责：
//   - 创建 NSApplication，设为 .accessory（仅菜单栏、无 Dock 图标）。
//   - 检查 UserDefaults 中的 selftest* 标志：命中则进入对应的自测 harness（通过
//     Launch Services 触发，使 AX 桥接处于激活状态），按断言结果 exit(0/1)。
//     标志会在进入前被清零，保证每次只运行一次。
//   - 无自测标志时：构造 AppDelegate，交给 runloop。
//
// 设计说明：自测 harness（SelfTest*.swift）只在标志命中时被实例化；正常用户运行
// 不会触碰它们。它们存在的目的是在没有 CI/真实窗口自动化的前提下，用真实引擎验证
// 居中/平铺/多屏/动画中止等行为。
// ─────────────────────────────────────────────────────────────────────────────

// Self-test mode: verifies the tiling engine produces a near-fullscreen rect on a
// real NSWindow that we fully control. Trigger via Launch Services so the AX bridge
// is active: set `defaults write com.comet.plumb selftestTile -bool true`
// then `open dist/Plumb.app`. The flag is cleared after one run.
let selfTest = UserDefaults.standard.bool(forKey: "selftestTile")
let selfTestGeo = UserDefaults.standard.bool(forKey: "selftestGeo")
let selfTestMulti = UserDefaults.standard.bool(forKey: "selftestMulti")
let selfTestUI = UserDefaults.standard.bool(forKey: "selftestUI")
let selfTestTileApp = UserDefaults.standard.bool(forKey: "selftestTileApp")
let selfTestSecondary = UserDefaults.standard.bool(forKey: "selftestSecondary")
let selfTestMultiPhysical = UserDefaults.standard.bool(forKey: "selftestMultiPhysical")
let selfTestCenterMulti = UserDefaults.standard.bool(forKey: "selftestCenterMulti")
let selfTestSwitchAbort = UserDefaults.standard.bool(forKey: "selftestSwitchAbort")
let selfTestDocumentChooser = UserDefaults.standard.bool(forKey: "selftestDocumentChooser")

let app = NSApplication.shared

/// `NSApplication.delegate` is weak. Keep every launch-mode delegate alive for the
/// complete run-loop lifetime instead of assigning a temporary instance that is
/// released before `applicationDidFinishLaunching` can run.
@MainActor
private func runApplication(_ app: NSApplication, delegate: NSApplicationDelegate) -> Never {
    SelfTestOutcome.reset()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
    exit(SelfTestOutcome.exitCode)
}

// Installer argv has precedence over every UserDefaults-driven self-test mode. Self-test
// flags can legitimately remain set after a crashed/manual harness; allowing one of them to
// intercept a verified update handoff would make `/usr/bin/open` return success while the
// installer never runs and the old app exits.
//
// Legacy UserDefaults are accepted only when their recorded path resolves exactly to the
// currently running Bundle.main and Bundle.main is not /Applications/Plumb.app. A writable
// defaults path can therefore no longer make the trusted installed app copy an arbitrary app.
let legacyInstallerMode = UserDefaults.standard.bool(forKey: UpdateConfig.installerModeKey)
let legacyInstallerPath = UserDefaults.standard.string(forKey: UpdateConfig.installerAppPathKey)
let runningBundleVersion = Bundle.main.object(
    forInfoDictionaryKey: "CFBundleShortVersionString") as? String
let installerHandoff = UpdateInstallerHandoff.resolveLaunch(
    arguments: CommandLine.arguments,
    legacyMode: legacyInstallerMode,
    legacyPath: legacyInstallerPath,
    bundlePath: Bundle.main.bundlePath,
    bundleVersion: runningBundleVersion)

// Always consume stale legacy flags; the new handoff is argv-owned and one-shot by process life.
if legacyInstallerMode || legacyInstallerPath != nil {
    UserDefaults.standard.set(false, forKey: UpdateConfig.installerModeKey)
    UserDefaults.standard.removeObject(forKey: UpdateConfig.installerAppPathKey)
}
if let installerHandoff {
    app.setActivationPolicy(.regular)
    runApplication(
        app,
        delegate: UpdateInstallerDelegate(expectedVersion: installerHandoff.expectedVersion))
}

if selfTestMulti {
    UserDefaults.standard.set(false, forKey: "selftestMulti")
    app.setActivationPolicy(.regular)
    runApplication(app, delegate: SelfTestMultiScreenDelegate())
}

if selfTestMultiPhysical {
    // Physical multi-screen test: place a real TextEdit standard window on every screen,
    // tile via the real engine, and verify exact per-screen CG bounds.
    UserDefaults.standard.set(false, forKey: "selftestMultiPhysical")
    app.setActivationPolicy(.regular)
    runApplication(app, delegate: SelfTestMultiScreenPhysicalDelegate())
}

if selfTestGeo {
    UserDefaults.standard.set(false, forKey: "selftestGeo")
    app.setActivationPolicy(.regular)
    runApplication(app, delegate: SelfTestGeometryDelegate())
}

if selfTest {
    UserDefaults.standard.set(false, forKey: "selftestTile")
    app.setActivationPolicy(.regular)
    runApplication(app, delegate: SelfTestTileDelegate())
}

if selfTestSecondary {
    // Verifies processedPIDs suppression (需求 3) via real observer: tile main window,
    // open a secondary window (File→Open dialog), confirm secondary is NOT moved.
    UserDefaults.standard.set(false, forKey: "selftestSecondary")
    app.setActivationPolicy(.regular)
    runApplication(app, delegate: SelfTestSecondaryWindowDelegate())
}

if selfTestTileApp {
    // Drives the REAL tiling engine against a real third-party app window (Apifox),
    // where kAXSize writes actually apply (unlike bare test NSWindows on macOS 26).
    UserDefaults.standard.set(false, forKey: "selftestTileApp")
    app.setActivationPolicy(.regular)
    runApplication(app, delegate: SelfTestTileAppDelegate())
}

if selfTestCenterMulti {
    // Tests centering on EACH physical screen via the real engine.
    UserDefaults.standard.set(false, forKey: "selftestCenterMulti")
    app.setActivationPolicy(.accessory)
    runApplication(app, delegate: SelfTestCenterMultiDelegate())
}

if selfTestSwitchAbort {
    // Reproduces the false "user moved window" abort that kills auto-centering right after
    // an app is activated (需求: "平铺 Safari → 切换 Music → Music 不居中").
    UserDefaults.standard.set(false, forKey: "selftestSwitchAbort")
    app.setActivationPolicy(.accessory)
    runApplication(app, delegate: SelfTestSwitchAbortDelegate())
}

if selfTestDocumentChooser {
    // Verifies document-chooser awareness (文档类 App 选择器感知): a gallery/template picker
    // window (kAXDocument empty) is centered but NOT tiled, while a real document gets tiled.
    // Requires the user to first open Word/Excel/Pages/Numbers to its gallery state.
    UserDefaults.standard.set(false, forKey: "selftestDocumentChooser")
    app.setActivationPolicy(.accessory)
    runApplication(app, delegate: SelfTestDocumentChooserDelegate())
}

if selfTestUI {
    // UI self-test: renders the real SettingsWindowController in-process and verifies
    // the PillToggle + search TextField fixes work. The settings window is the app's
    // own window, so NO cross-process AX trust is required to test UI rendering/focus.
    UserDefaults.standard.set(false, forKey: "selftestUI")
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    runApplication(app, delegate: SelfTestUIDelegate())
}

app.setActivationPolicy(.accessory)
runApplication(app, delegate: AppDelegate())
