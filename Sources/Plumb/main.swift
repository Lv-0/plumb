import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - main (入口)
//
// 模块角色：程序入口，负责"正常启动"与"自测模式"的分流。
//
// 职责：
//   - 创建 NSApplication，设为 .accessory（仅菜单栏、无 Dock 图标）。
//   - 检查 UserDefaults 中的 selftest* 标志：命中则进入对应的自测 harness（通过
//     Launch Services 触发，使 AX 桥接处于激活状态），运行后 exit(0)。
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

let app = NSApplication.shared

if selfTestMulti {
    UserDefaults.standard.set(false, forKey: "selftestMulti")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestMultiScreenDelegate()
    app.run()
    exit(0)
}

if selfTestMultiPhysical {
    // Physical 2-screen test: place a real TextEdit window on the built-in screen,
    // center+tile via the real engine, verify it stays on the built-in screen.
    UserDefaults.standard.set(false, forKey: "selftestMultiPhysical")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestMultiScreenPhysicalDelegate()
    app.run()
    exit(0)
}

if selfTestGeo {
    UserDefaults.standard.set(false, forKey: "selftestGeo")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestGeometryDelegate()
    app.run()
    exit(0)
}

if selfTest {
    UserDefaults.standard.set(false, forKey: "selftestTile")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestTileDelegate()
    app.run()
    exit(0)
}

if selfTestSecondary {
    // Verifies processedPIDs suppression (需求 3) via real observer: tile main window,
    // open a secondary window (File→Open dialog), confirm secondary is NOT moved.
    UserDefaults.standard.set(false, forKey: "selftestSecondary")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestSecondaryWindowDelegate()
    app.run()
    exit(0)
}

if selfTestTileApp {
    // Drives the REAL tiling engine against a real third-party app window (Apifox),
    // where kAXSize writes actually apply (unlike bare test NSWindows on macOS 26).
    UserDefaults.standard.set(false, forKey: "selftestTileApp")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestTileAppDelegate()
    app.run()
    exit(0)
}

if selfTestCenterMulti {
    // Tests centering on EACH physical screen via the real engine.
    UserDefaults.standard.set(false, forKey: "selftestCenterMulti")
    app.setActivationPolicy(.accessory)
    app.delegate = SelfTestCenterMultiDelegate()
    app.run()
    exit(0)
}

if selfTestSwitchAbort {
    // Reproduces the false "user moved window" abort that kills auto-centering right after
    // an app is activated (需求: "平铺 Safari → 切换 Music → Music 不居中").
    UserDefaults.standard.set(false, forKey: "selftestSwitchAbort")
    app.setActivationPolicy(.accessory)
    app.delegate = SelfTestSwitchAbortDelegate()
    app.run()
    exit(0)
}

if selfTestUI {
    // UI self-test: renders the real SettingsWindowController in-process and verifies
    // the PillToggle + search TextField fixes work. The settings window is the app's
    // own window, so NO cross-process AX trust is required to test UI rendering/focus.
    UserDefaults.standard.set(false, forKey: "selftestUI")
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.delegate = SelfTestUIDelegate()
    app.run()
    exit(0)
}

// Installer mode: triggered when the normal-mode app writes installerMode=true and
// relaunches itself. Runs a minimal privileged installer that replaces
// /Applications/Plumb.app, then relaunches the new version.
if UserDefaults.standard.bool(forKey: UpdateConfig.installerModeKey) {
    UserDefaults.standard.set(false, forKey: UpdateConfig.installerModeKey)  // cleared here too for safety
    app.setActivationPolicy(.regular)
    app.delegate = UpdateInstallerDelegate()
    app.run()
    exit(0)
}

let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
