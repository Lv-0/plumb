import AppKit
import ApplicationServices

/// Document-chooser awareness self-test (文档类 App 选择器感知).
///
/// 验证文档类 App（Word/Excel/Pages/Numbers）的"选择器只居中、文档才平铺"行为：
///   1. 用户先把目标 App 打开到模板/文件列表（gallery）状态，再运行本自测。
///   2. 配置 store：平铺开启 + 该 App 在平铺白名单 + 在选择器感知列表。
///   3. observer 启动后应【居中】gallery 窗口（kAXDocument 为空），且【不】铺满全屏。
///   4. 日志打印 gallery 窗口的 subrole / kAXDocument / 平铺前后尺寸，便于人工核对
///      "居中但未平铺"是否成立（尺寸未增长到接近平铺目标）。
///
/// 与 SelfTestSecondaryWindow 的区别：那个验证 processedPIDs 抑制对话框（subrole=AXDialog）；
/// 本测试针对的是 subrole 同为 AXStandardWindow 但 kAXDocument 为空的 gallery 窗口——
/// 必须靠 kAXDocument 属性区分（subrole 区分不出来）。
///
/// 触发：`defaults write com.comet.plumb selftestDocumentChooser -bool true`
/// 然后直接运行 `dist/Plumb.app/Contents/MacOS/Plumb`。
/// 输出：/tmp/cw_selftest_document_chooser.log
///
/// 使用前：先把 Microsoft Word（或 Pages）打开到"打开新的和最近使用的文件"界面（gallery），
/// 不要打开任何文档。自测会把该 App 加入平铺白名单 + 选择器感知列表。

@MainActor
final class SelfTestDocumentChooserDelegate: NSObject, NSApplicationDelegate {
    private static let logPath = "/tmp/cw_selftest_document_chooser.log"
    private var service: WindowCenteringService?
    private var observer: WindowEventObserver?
    private var store: AppTilingSettingsStore?
    private var testedApp: NSRunningApplication?

    /// 目标 App 的 bundle id（运行时从前台 App 解析，要求是已知的文档类 App）。
    private static let knownDocApps: Set<String> = AppTilingSettings.defaultDocumentChooserBundleIDs

    private static func log(_ message: String) {
        print(message)
        if let data = (message + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let h = FileHandle(forWritingAtPath: logPath) {
                    h.seekToEndOfFile(); h.write(data); h.closeFile()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "".write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        // ACCESSORY：不抢前台，让目标 App 保持前台（observer 要求 frontmost == pid）。
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.run()
        }
    }

    private func run() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            Self.log("SELFTEST-DOC: FAIL — no frontmost app")
            finish(); return
        }
        let bundleID = (app.bundleIdentifier ?? "").lowercased()
        guard Self.knownDocApps.contains(bundleID) else {
            Self.log("SELFTEST-DOC: FAIL — frontmost app bundle=\(bundleID) is not a known document app")
            Self.log("SELFTEST-DOC: please open Word/Excel/Pages/Numbers to its gallery first, then run")
            finish(); return
        }
        testedApp = app
        Self.log("SELFTEST-DOC: frontmost app = \(bundleID) pid=\(app.processIdentifier)")

        // 配置：平铺开启 + 该 App 在平铺白名单 + 选择器感知列表。
        let store = AppTilingSettingsStore()
        let settings = AppTilingSettings(
            isEnabled: true,
            edgeInsets: TileInsets(all: 16),
            tiledBundleIDs: [bundleID],
            hideSystemAppsInPicker: true,
            centerEnabled: true,
            centeredBundleIDs: [],
            documentChooserBundleIDs: [bundleID]
        )
        store.save(settings)
        self.store = store

        let service = WindowCenteringService()
        self.service = service
        let observer = WindowEventObserver(service: service, tilingSettingsStore: store)
        self.observer = observer
        observer.start()
        Self.log("SELFTEST-DOC: observer started, tiling+chooser-awareness enabled for \(bundleID)")

        // 给 observer 时间 attach + 居中 gallery（initial retries 起步 0.45s）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.verifyGalleryState(app: app)
        }
    }

    private func verifyGalleryState(app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var winsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &winsRef)
        let wins = (winsRef as? [AXUIElement]) ?? []
        Self.log("SELFTEST-DOC: window count = \(wins.count)")
        for (i, w) in wins.enumerated() {
            Self.log("  win[\(i)] role=\(readRole(w)) subrole=\(readSubrole(w)) " +
                     "document=\(readDocument(w)) frame=\(stringify(readFrame(w)))")
        }

        // gallery = 第一个标准窗口（kAXDocument 为空）。
        guard let gallery = wins.first(where: { readSubrole($0) == kAXStandardWindowSubrole as String }) else {
            Self.log("SELFTEST-DOC: FAIL — no AXStandardWindow found (is the app in gallery state?)")
            finish(); return
        }
        let docAttr = readDocument(gallery)
        let galleryFrame = readFrame(gallery)
        // 平铺目标：visibleFrame 内缩四向 insets（自检用 TileInsets(all:16)）。判定是否"被平铺"看尺寸是否接近铺满。
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let tiledW = screen.width - 32   // 16*2（左右各 16）
        let tiledH = screen.height - 32
        let nearTiled = abs(galleryFrame.width - tiledW) < 40 && abs(galleryFrame.height - tiledH) < 40
        Self.log("SELFTEST-DOC: gallery document attr = '\(docAttr)' (expect empty for chooser)")
        Self.log("SELFTEST-DOC: gallery frame = \(stringify(galleryFrame)) nearTiled=\(nearTiled)")

        if !docAttr.isEmpty {
            Self.log("SELFTEST-DOC: NOTE — gallery window has a document attr; " +
                     "the app may have already opened a document. Re-run from gallery state.")
        }
        // 核心断言：gallery（无文档）不应被平铺（nearTiled=false）。
        if docAttr.isEmpty && nearTiled {
            Self.log("SELFTEST-DOC: RESULT=FAIL — gallery was tiled (should be centered-only)")
        } else if docAttr.isEmpty {
            Self.log("SELFTEST-DOC: RESULT=PASS — gallery not tiled (chooser-awareness works)")
        }

        // 指引人工打开文档后再次核对（不自动操作，避免误触发）。
        Self.log("SELFTEST-DOC: now open a document in \(app.localizedName ?? "?"), " +
                 "then re-run to confirm the document window gets tiled.")
        finish()
    }

    // MARK: - AX helpers

    private func readRole(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func readSubrole(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func readDocument(_ el: AXUIElement) -> String {
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXDocumentAttribute as CFString, &r)
        return (r as? String) ?? ""
    }

    private func readFrame(_ el: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef)
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = posRef { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = sizeRef { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }

    private func stringify(_ r: CGRect) -> String {
        "x=\(Int(r.minX)) y=\(Int(r.minY)) w=\(Int(r.width)) h=\(Int(r.height))"
    }

    private func finish() {
        Self.log("SELFTEST-DOC: DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }
}
