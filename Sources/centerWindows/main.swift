import AppKit

// Self-test mode: verifies the tiling engine produces a near-fullscreen rect on a
// real NSWindow that we fully control. Trigger via Launch Services so the AX bridge
// is active: set `defaults write com.comet.centerwindows selftestTile -bool true`
// then `open dist/centerWindows.app`. The flag is cleared after one run.
let selfTest = UserDefaults.standard.bool(forKey: "selftestTile")
let selfTestGeo = UserDefaults.standard.bool(forKey: "selftestGeo")
let selfTestMulti = UserDefaults.standard.bool(forKey: "selftestMulti")

let app = NSApplication.shared

if selfTestMulti {
    UserDefaults.standard.set(false, forKey: "selftestMulti")
    app.setActivationPolicy(.regular)
    app.delegate = SelfTestMultiScreenDelegate()
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

let delegate = AppDelegate()

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
