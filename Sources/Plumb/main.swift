import AppKit

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

let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
