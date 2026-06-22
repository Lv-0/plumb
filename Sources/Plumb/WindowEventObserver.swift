import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WindowEventObserver
//
// 模块角色：自动居中/平铺的"事件入口 + 生命周期编排器"。
//
// 职责：
//   - 监听 NSWorkspace 的 didActivate / didTerminate 通知，跟踪前台 app 切换。
//   - 为前台 app 绑定 AXObserver，订阅 kAXFocusedWindowChanged / kAXWindowCreated
//     通知，在前台 app 出现"新聚焦窗口 / 新建窗口"时决定是否居中或平铺。
//   - 编排居中/平铺的时序：app 刚激活时 macOS 仍在播激活动画、窗口在抖动，
//     故不在 attach 当下立即居中，而是交给 startInitialCenteringRetries 等动画
//     稳定后再触发（与手动"立即居中"走同一条已被验证的路径）。
//   - 维护"本激活周期内每个 PID 只处理一次主窗口"的契约（processedPIDs），
//     满足"软件本体居中即可，二级窗口/对话框/标签页弹层不要居中"的需求。
//
// 不变量 / 关键约定：
//   - 切换 app 前必须调用 service.abortActiveAnimations()，避免 zombie 定时器在
//     非前台 app 上继续移动窗口（"切走后 Safari 跑到另一屏"的根因）。
//   - 缓存按 pid:windowNumber 与 pid 两级记录，app 退出时按 pid 前缀清理；
//     re-attach 到同一 app 时清掉该 pid 的旧缓存，使"切走再回来"能重新居中。
//   - 仅处理前台 app；对后台窗口一律拒绝（handle 内有 frontmost == pid 守卫）。
//
// 与 WindowCenteringService 的边界：
//   Observer 负责"何时、对哪个窗口"做；Service 负责"如何算坐标、如何写 AX"。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class WindowEventObserver {
    private let service: WindowCenteringService
    private let tilingSettingsStore: AppTilingSettingsStore

    private var observer: AXObserver?
    private var observedPID: pid_t?
    /// 已完成居中/平铺的窗口 key（向后兼容 / 防抖）。
    private var centeredWindowKeys: [String] = []
    private var centeredWindowKeySet: Set<String> = []
    /// 已完成本激活周期居中/平铺的 PID 集合（Bug #3 修复）。
    /// 需求："软件本体居中就行，打开的二级标签或页面不要进行居中"。
    /// 旧实现按 pid:windowNumber 记缓存，新窗口（对话框/二级窗口/标签页弹层）
    /// 拥有不同的 windowNumber 而不命中缓存 → 被再次居中。改为按 PID 记：
    /// 一个 app 在其激活周期内只要主窗口已居中/平铺，后续任意窗口事件一律跳过，
    /// 直到切换走再回来（attachToFrontmostApp 会清缓存）。
    private var processedPIDs: Set<pid_t> = []
    private var initialCenterTimer: DispatchSourceTimer?
    private var tileStabilizeTimer: DispatchSourceTimer?

    init(service: WindowCenteringService, tilingSettingsStore: AppTilingSettingsStore) {
        self.service = service
        self.tilingSettingsStore = tilingSettingsStore
    }

    func start() {
        stop()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        if AccessibilityPermission.ensureTrusted(prompt: false) {
            // Already trusted: attach immediately.
            attachToFrontmostApp()
        } else {
            // Accessibility trust may not yet be granted at launch (the system prompt was just shown).
            // macOS offers no "permission granted" notification, so poll until trust is granted and
            // re-attach. A long horizon matters: a user who dismisses the prompt and grants access
            // minutes later (often exactly what happens when "center now" is clicked and re-prompts)
            // must still get the observer attached afterwards — otherwise only manual centering works.
            attachToFrontmostApp()
            AccessibilityPermission.awaitTrusted(timeout: 3 * 3600) { [weak self] in
                self?.attachToFrontmostApp()
            }
        }
    }

    func stop() {
        initialCenterTimer?.cancel()
        initialCenterTimer = nil
        tileStabilizeTimer?.cancel()
        tileStabilizeTimer = nil
        service.abortActiveAnimations()
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        centeredWindowKeys.removeAll()
        centeredWindowKeySet.removeAll()
        processedPIDs.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeAppChanged() {
        attachToFrontmostApp()
    }

    /// Re-evaluate trust and re-attach if needed. Called when a manual action (e.g. "center now")
    /// may have just caused the user to grant Accessibility access — so auto-centering can pick up
    /// immediately instead of waiting for the next app switch / poll.
    func refreshAfterPossibleTrustChange() {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else { return }
        // If we already have an observer bound to the current frontmost app, nothing to do.
        if let observedPID, observedPID == NSWorkspace.shared.frontmostApplication?.processIdentifier, observer != nil {
            return
        }
        attachToFrontmostApp()
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        // When an app quits, purge its "already centered" cache entries so that if the OS later
        // recycles the same PID (or the same app is relaunched), windows are centered again.
        guard
            let userInfo = notification.userInfo,
            let app = userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return
        }
        let pid = app.processIdentifier
        // If the terminated app is the one we were observing, drop the observer too so a stale
        // source does not fire for a recycled PID.
        if observedPID == pid {
            initialCenterTimer?.cancel()
            initialCenterTimer = nil
            tileStabilizeTimer?.cancel()
            tileStabilizeTimer = nil
            // 被观察的 app 退出时，其进行中的平铺/居中动画也必须停止，否则 Phase-B 定时器
            // 会在已退出的 pid 上继续尝试写 AX（必然失败，但仍占用 activeAnimationKey 锁）。
            service.abortActiveAnimations()
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            observedPID = nil
        }

        let prefix = "\(pid):"
        centeredWindowKeySet = centeredWindowKeySet.filter { !$0.hasPrefix(prefix) }
        centeredWindowKeys = centeredWindowKeys.filter { !$0.hasPrefix(prefix) }
        processedPIDs.remove(pid)
    }

    private func attachToFrontmostApp() {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else {
            DiagnosticLog.debug("attach: accessibility NOT trusted — skipping")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            DiagnosticLog.debug("attach: no frontmost app")
            return
        }

        if observedPID == app.processIdentifier {
            DiagnosticLog.debug("attach: already observing pid=\(app.processIdentifier) (\(app.bundleIdentifier ?? "?"))")
            return
        }

        DiagnosticLog.debug("attach: switching to pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "?")")

        // 切换到新 app 前：立即中止上一个 app 进行中的平铺/居中动画，窗口停在最后一帧
        //（不回弹、不再写）。这消除"平铺动画进行中切走 → zombie Phase-B 定时器在后台继续
        // 移动已非前台 app 的窗口 → 切回来时它跳到另一个屏幕"的根因。
        service.abortActiveAnimations()

        initialCenterTimer?.cancel()
        initialCenterTimer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil

        let pid = app.processIdentifier

        // When (re)attaching to an app, clear any prior "already centered" entries for THIS app's pid.
        // This is what makes a window re-center when the user switches away from an app and comes back:
        // without this, the cache from the first centering suppresses re-centering on reactivation.
        // (Entries for other apps are left untouched and are also purged on app termination.)
        let reactivatedPrefix = "\(pid):"
        let removedCount = centeredWindowKeySet.filter { $0.hasPrefix(reactivatedPrefix) }.count
        if removedCount > 0 {
            DiagnosticLog.debug("attach: cleared \(removedCount) stale cache entries for reactivated pid=\(pid)")
            centeredWindowKeySet = centeredWindowKeySet.filter { !$0.hasPrefix(reactivatedPrefix) }
            centeredWindowKeys = centeredWindowKeys.filter { !$0.hasPrefix(reactivatedPrefix) }
        }
        // Bug #3: 同步清除 per-PID 标记，让 app 重新激活后能重新居中其主窗口。
        processedPIDs.remove(pid)
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let unmanaged = Unmanaged<WindowEventObserver>.fromOpaque(refcon)
            let obj = unmanaged.takeUnretainedValue()
            Task { @MainActor in
                obj.handle(notification: notification as String, element: element)
            }
        }, &newObserver)

        guard result == .success, let newObserver else {
            DiagnosticLog.debug("attach: AXObserverCreate failed result=\(result.rawValue)")
            return
        }

        observer = newObserver
        observedPID = pid

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(newObserver), .defaultMode)

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let r1 = AXObserverAddNotification(newObserver, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        let r2 = AXObserverAddNotification(newObserver, appElement, kAXWindowCreatedNotification as CFString, refcon)
        DiagnosticLog.debug("attach: observer added; focusedChanged=\(r1.rawValue) windowCreated=\(r2.rawValue)")

        // 不在 attach 当下立即居中：app 刚被激活时 macOS 还在做激活动画，窗口位置/尺寸在抖动，
        // 此时探测坐标空间与读取 visibleFrame 都不稳定，会导致居中位置算错（"切换后居中没考虑
        // Dock 栏"的根因之一）。改为完全交给 startInitialCenteringRetries：它在短延迟后首次触发，
        // 等同于用户"等动画结束再点立即居中"的效果——此时窗口已稳定，走的是与手动按钮完全相同、
        // 已被验证正确的居中路径。
        // （这里刻意不再调用 handle("initial")。立即居中会抢在动画完成前写入，反而出错。）

        // Some apps only create their focused window after a short delay (splash screens, permission prompts, etc.).
        // Retry briefly without showing alerts; stop once we successfully process a window or after a timeout.
        startInitialCenteringRetries(
            pid: pid,
            appElement: appElement,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    @discardableResult
    private func handle(notification: String, element: AXUIElement, forcedPID: pid_t? = nil) -> Bool {
        // For focused-window-changed, element is usually the app; for window-created it can be the window.
        // We always process the current focused window once per strategy.
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            DiagnosticLog.debug("handle[\(notification)]: no frontmost app")
            return false
        }

        let pid: pid_t
        if let forcedPID {
            pid = forcedPID
        } else {
            pid = frontmostApp.processIdentifier
        }

        // Only act on the frontmost app to avoid moving background windows.
        guard frontmostApp.processIdentifier == pid else {
            DiagnosticLog.debug("handle[\(notification)]: frontmost \(frontmostApp.processIdentifier) != pid \(pid), skip")
            return false
        }

        // Reject stale notifications delivered from a previously-observed app after the observer has
        // already been rebound to a different app.
        if let observedPID, observedPID != pid {
            DiagnosticLog.debug("handle[\(notification)]: stale — observedPID=\(observedPID) pid=\(pid), skip")
            return false
        }

        // Bug #3: 本激活周期内此 PID 的主窗口已完成居中/平铺 → 跳过任何后续窗口事件
        //（二级窗口、对话框、标签页弹层等），满足"软件本体居中就行，二级页面不要居中"。
        if processedPIDs.contains(pid) {
            DiagnosticLog.debug("handle[\(notification)]: PID \(pid) already processed this cycle, skip (suppress secondary window)")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        guard let windowElement = centerCandidateWindow(for: appElement, hintedElement: element) else {
            DiagnosticLog.debug("handle[\(notification)]: no centerable candidate window")
            return false
        }

        let tilingSettings = tilingSettingsStore.load()
        let shouldTile = tilingSettings.shouldTile(bundleIdentifier: frontmostApp.bundleIdentifier)
        if shouldTile {
            // 每个"激活周期"内同一窗口只平铺一次：首次平铺后若再收到聚焦/创建通知，
            // 直接跳过，避免重试与重复事件反复触发"先居中再放大"动画，导致窗口被来回
            // 拉扯、最终回弹到小尺寸（这是"指定 App 不会自动平铺放大"的根因）。
            if hasCentered(windowElement: windowElement, pid: pid) {
                DiagnosticLog.debug("handle[\(notification)]: already tiled pid=\(pid)")
                return false
            }

            // 文档类 App 选择器感知（Pages/Word/Excel/Numbers 等）。
            // 这些 App 启动时常先弹出模板/文件列表窗口（kAXDocument 为空），再打开真正文档窗口
            // （kAXDocument 为 file:// URL）。两者 subrole 都是 AXStandardWindow，仅凭 subrole 无法区分。
            //
            // 判据：只看 kAXDocument（弃用「标题匹配」方案，见 windowHasDocument 注释）。
            //   - 无 kAXDocument（选择器 / 未保存新文档）→ 只居中、不平铺。
            //   - 有 kAXDocument（已保存文档）→ 落到下方正常平铺逻辑。
            //
            // 关键：本分支【不】锁 processedPIDs、也【不】markCentered —— 否则后续真正文档窗口
            // （含同一窗口保存后获得 kAXDocument）会被第 270 行或 hasCentered 永久挡住，无法平铺
            // （这正是此前「打开文稿后不平铺」的根因）。重复居中由 service 的动画去重防抖
            //（activeAnimationKey），居中不涉及 resize，无「来回拉扯」风险。
            //
            // 设计决策：选择器居中不受 shouldCenter 白名单约束——只要该 App 在平铺白名单 +
            // 选择器感知列表内，选择器一律居中（符合"选择器不平铺但整理到屏幕中央"的预期）。
            if tilingSettings.isDocumentChooserApp(bundleIdentifier: frontmostApp.bundleIdentifier),
               !windowHasDocument(windowElement)
            {
                DiagnosticLog.debug("handle[\(notification)]: chooser/no-doc window — center only, keep PID unlocked, not marked pid=\(pid)")
                do {
                    try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
                    // 不 markCentered：允许窗口后续获得 kAXDocument 时被平铺。
                    // 不 insert processedPIDs：允许后续窗口事件继续处理。
                    return true
                } catch {
                    DiagnosticLog.debug("handle[\(notification)]: chooser center failed pid=\(pid) error=\(error)")
                    return false
                }
            }
            if let tiledWindow = tilePendingWindows(
                pid: pid,
                appElement: appElement,
                primaryWindow: windowElement,
                edgeMargin: tilingSettings.edgeMargin
            ) {
                markCentered(windowElement: tiledWindow, pid: pid)
                processedPIDs.insert(pid)   // Bug #3: 本周期内此 app 已处理，跳过后续窗口
                startTileStabilizationRetries(
                    pid: pid,
                    appElement: appElement,
                    windowElement: tiledWindow,
                    edgeMargin: tilingSettings.edgeMargin
                )
                DiagnosticLog.debug("handle[\(notification)]: tiled pid=\(pid)")
                return true
            }
            // For tiled apps, do not fall back to centering.
            DiagnosticLog.debug("handle[\(notification)]: tiling enabled but no window tiled")
            return false
        }

        // 居中 allow-list：未开启或不在列表内（且列表非空）则跳过自动居中。
        if !tilingSettings.shouldCenter(bundleIdentifier: frontmostApp.bundleIdentifier) {
            DiagnosticLog.debug("handle[\(notification)]: center not allowed for pid=\(pid) bundle=\(frontmostApp.bundleIdentifier ?? "?")")
            return false
        }

        if hasCentered(windowElement: windowElement, pid: pid) {
            DiagnosticLog.debug("handle[\(notification)]: already centered pid=\(pid)")
            return false
        }

        do {
            try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
            markCentered(windowElement: windowElement, pid: pid)
            processedPIDs.insert(pid)   // Bug #3: 本周期内此 app 已处理，跳过后续窗口
            DiagnosticLog.debug("handle[\(notification)]: CENTERED pid=\(pid)")
            return true
        } catch {
            // Skip fullscreen or any other temporary failures silently.
            DiagnosticLog.debug("handle[\(notification)]: center failed pid=\(pid) error=\(error)")
            return false
        }
    }

    private func centerCandidateWindow(for appElement: AXUIElement, hintedElement: AXUIElement?) -> AXUIElement? {
        if
            let hintedElement,
            let hintedWindow = eligibleWindowFromElement(hintedElement)
        {
            DiagnosticLog.debug("candidate: from hint element")
            return hintedWindow
        }

        // Prefer the focused window if it is a standard main window.
        if
            let focused = appElement.axWindowElement(kAXFocusedWindowAttribute as CFString)
        {
            if isAutoCenterEligibleWindow(focused) {
                DiagnosticLog.debug("candidate: focused window eligible")
                return focused
            } else {
                DiagnosticLog.debug("candidate: focused window NOT eligible — \(eligibilityReason(focused))")
            }
        } else {
            DiagnosticLog.debug("candidate: no focused window attribute")
        }

        // Some apps do not set AXFocusedWindow immediately after activation; fall back to selecting the
        // largest standard window from AXWindows.
        let windows = appElement.axWindowElements(kAXWindowsAttribute as CFString)
        DiagnosticLog.debug("candidate: AXWindows count=\(windows.count)")
        var best: (window: AXUIElement, area: CGFloat)?
        for w in windows where isAutoCenterEligibleWindow(w) {
            guard let size = w.axSize(kAXSizeAttribute as CFString) else { continue }
            let area = max(0, size.width) * max(0, size.height)
            if let best, best.area >= area { continue }
            best = (w, area)
        }
        if let bestWindow = best?.window {
            DiagnosticLog.debug("candidate: largest eligible window fallback")
            return bestWindow
        }

        // Some apps (observed in Office) expose focused window only through system-wide AX,
        // while app-level AXFocusedWindow/AXWindows may be empty.
        if let pid = observedPID, let focused = systemWideFocusedWindow(for: pid), isAutoCenterEligibleWindow(focused) {
            DiagnosticLog.debug("candidate: system-wide focused window")
            return focused
        }

        // Last-resort fallback mirroring the manual "center now" path: accept the focused window
        // even if it does not carry the strict standard subrole, as long as it is a real window and
        // not minimized/modal/fullscreen. This is what makes auto-centering match the proven manual
        // behavior for apps whose focused window reports a non-standard subrole (or none).
        if
            let focused = appElement.axWindowElement(kAXFocusedWindowAttribute as CFString),
            isMovableNonAuxiliaryWindow(focused)
        {
            DiagnosticLog.debug("candidate: focused-window fallback (lenient)")
            return focused
        }
        if let pid = observedPID, let focused = systemWideFocusedWindow(for: pid), isMovableNonAuxiliaryWindow(focused) {
            DiagnosticLog.debug("candidate: system-wide focused fallback (lenient)")
            return focused
        }

        DiagnosticLog.debug("candidate: NONE found")
        return nil
    }

    private func eligibleWindowFromElement(_ element: AXUIElement) -> AXUIElement? {
        if isAutoCenterEligibleWindow(element) {
            return element
        }

        if
            let window = element.axWindowElement(kAXWindowAttribute as CFString),
            isAutoCenterEligibleWindow(window)
        {
            return window
        }
        return nil
    }

    private func isAutoCenterEligibleWindow(_ window: AXUIElement) -> Bool {
        // Only auto-center/tile standard main windows. This skips dialogs/sheets/panels that users perceive as
        // "secondary pages" within the same app.
        let role = window.axString(kAXRoleAttribute as CFString)
        if role != kAXWindowRole as String {
            return false
        }

        if let minimized = window.axBool(kAXMinimizedAttribute as CFString), minimized {
            return false
        }
        if let modal = window.axBool(kAXModalAttribute as CFString), modal {
            return false
        }

        if let subrole = window.axString(kAXSubroleAttribute as CFString) {
            if subrole == kAXStandardWindowSubrole as String {
                return true
            }
            // Explicitly skip common "secondary" window types.
            if subrole == kAXDialogSubrole as String ||
                subrole == kAXSystemDialogSubrole as String ||
                subrole == kAXFloatingWindowSubrole as String
            {
                return false
            }
            // For any other subrole, treat it as non-standard to avoid surprise movements.
            return false
        }

        // No subrole exposed: treat as eligible (many apps omit it for normal windows).
        return true
    }

    /// Diagnostic: human-readable reason a window was rejected by `isAutoCenterEligibleWindow`.
    private func eligibilityReason(_ window: AXUIElement) -> String {
        let role = window.axString(kAXRoleAttribute as CFString)
        if role != kAXWindowRole as String {
            return "role='\(role ?? "nil")' != AXWindow"
        }
        if let minimized = window.axBool(kAXMinimizedAttribute as CFString), minimized {
            return "minimized"
        }
        if let modal = window.axBool(kAXModalAttribute as CFString), modal {
            return "modal"
        }
        let subrole = window.axString(kAXSubroleAttribute as CFString)
        if let subrole, subrole != kAXStandardWindowSubrole as String {
            return "subrole='\(subrole)' != AXStandardWindow"
        }
        return "unknown"
    }

    /// Lenient eligibility used as a last-resort fallback to mirror the manual "center now" path.
    /// Accepts any real window that is not an auxiliary type (dialog/system dialog/floating),
    /// not minimized, not modal, and not fullscreen. Unlike `isAutoCenterEligibleWindow`, it does
    /// NOT require the `AXStandardWindow` subrole, so apps whose main window reports a different or
    /// missing subrole still get auto-centered (matching the proven manual behavior).
    private func isMovableNonAuxiliaryWindow(_ window: AXUIElement) -> Bool {
        let role = window.axString(kAXRoleAttribute as CFString)
        guard role == kAXWindowRole as String else { return false }

        if let minimized = window.axBool(kAXMinimizedAttribute as CFString), minimized {
            return false
        }
        if let modal = window.axBool(kAXModalAttribute as CFString), modal {
            return false
        }

        if let subrole = window.axString(kAXSubroleAttribute as CFString) {
            // Explicitly skip common "secondary"/auxiliary window types.
            if subrole == kAXDialogSubrole as String ||
                subrole == kAXSystemDialogSubrole as String ||
                subrole == kAXFloatingWindowSubrole as String
            {
                return false
            }
        }
        return true
    }

    private func startInitialCenteringRetries(pid: pid_t, appElement: AXUIElement, bundleIdentifier: String?) {
        initialCenterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        // 首次触发延迟 0.45s：让 app 的激活动画结束、窗口位置/尺寸稳定后再居中，
        // 等同于"动画结束后点立即居中"。太早触发会因窗口仍在抖动而算错坐标空间/visibleFrame。
        timer.schedule(deadline: .now() + 0.45, repeating: 0.35)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1

            // If user has switched away, stop retrying.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
                return
            }

            let tilingEnabledForApp = self.tilingSettingsStore.load().shouldTile(bundleIdentifier: bundleIdentifier)
            let didProcess = self.handle(notification: "initial-retry", element: appElement, forcedPID: pid)
            if didProcess, !tilingEnabledForApp {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
                return
            }

            let maxAttempts = tilingEnabledForApp ? 24 : 12
            if attempts >= maxAttempts {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
            }
        }
        initialCenterTimer = timer
        timer.resume()
    }

    private func startTileStabilizationRetries(
        pid: pid_t,
        appElement: AXUIElement,
        windowElement: AXUIElement,
        edgeMargin: CGFloat
    ) {
        tileStabilizeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + 0.30, repeating: 0.35)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1

            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.tileStabilizeTimer?.cancel()
                self.tileStabilizeTimer = nil
                return
            }

            // 若上一轮动画仍在进行中，本轮直接跳过，避免叠加；动画内部已对同一窗口去重。
            if self.service.isAnyAnimationInProgress {
                if attempts >= 8 {
                    self.tileStabilizeTimer?.cancel()
                    self.tileStabilizeTimer = nil
                }
                return
            }

            // 仅当窗口明显未达到平铺目标（尺寸偏小）时才重新触发，已基本铺满则停止重试。
            if self.isWindowNearTiledTarget(windowElement, pid: pid, appElement: appElement, edgeMargin: edgeMargin) {
                self.tileStabilizeTimer?.cancel()
                self.tileStabilizeTimer = nil
                return
            }

            _ = try? self.service.tileWindowElementAnimated(
                windowElement,
                pid: pid,
                appElement: appElement,
                edgeMargin: edgeMargin
            )

            if attempts >= 5 {
                self.tileStabilizeTimer?.cancel()
                self.tileStabilizeTimer = nil
            }
        }
        tileStabilizeTimer = timer
        timer.resume()
    }

    /// 窗口当前尺寸是否已接近平铺目标（用于停止平铺稳定重试）。
    ///
    /// 通过 `service.tiledTargetFrame` 拿到该窗口在其屏幕上的真实平铺目标（visibleFrame 内缩
    /// edgeMargin），再比较窗口当前 宽/高 与目标 宽/高 的差值是否在容差内。
    /// 替换此前"窗口面积 >= 主屏可视区 80%"的粗略启发式——后者无法区分不同屏幕尺寸、
    /// 也无法反映 edgeMargin 配置。失败时返回 false（保守地继续重试）。
    private func isWindowNearTiledTarget(_ windowElement: AXUIElement, pid: pid_t, appElement: AXUIElement, edgeMargin: CGFloat) -> Bool {
        guard let size = sizeAttributeValue(windowElement),
              let target = service.tiledTargetFrame(for: windowElement, pid: pid, edgeMargin: edgeMargin)
        else { return false }
        let tol: CGFloat = 16
        return abs(size.width - target.width) <= tol && abs(size.height - target.height) <= tol
    }

    private func pointAttributeValue(_ windowElement: AXUIElement) -> CGPoint? {
        // 委托给共享扩展；旧实现用 `as! AXValue` 强转，在 app 返回非 AXValue 类型时会崩溃，
        // 现统一走带 CFGetTypeID 防御的 AXAttributeAccess。
        windowElement.axPoint(kAXPositionAttribute as CFString)
    }

    /// 窗口是否已绑定文档（用于文档类 App 的选择器感知）。
    ///
    /// 判据：`kAXDocumentAttribute` 非空（通常为 file:// URL，表示已保存到磁盘的文档）。
    /// 空则视为「非真文档」——可能是模板/文件选择器，或未保存的新建文档。
    ///
    /// 为什么不再用「标题匹配」识别选择器（曾尝试过的方案，已弃用）：
    ///   - 时序竞争：handle() 在窗口出现 0.45s 后触发，此时 AXTitle 可能尚未异步填充 →
    ///     标题为空 → 不匹配已知标题 → 误判为普通窗口 → 被平铺（这正是报告的 bug）。
    ///   - 跨 App 标题不一致：Word/Excel（Office）与 Pages/Numbers（iWork）的模板选择器
    ///     标题不同；且该标题是 Office 内部 UI 字符串、硬编码在 app 代码中、不在本地化
    ///     资源文件里，无法可靠取得全部语言文案。
    /// 标题方案在两种情况下都会误判，故弃用，改为只看 kAXDocument。
    ///
    /// 配套语义（见 handle() 的 chooser 分支）：
    ///   - 无文档（选择器/未保存新文档）→ 只居中、不锁 processedPIDs、不 markCentered
    ///     → 后续文档窗口（含同一窗口保存后获得 kAXDocument）仍能被平铺。
    ///   - 有文档（已保存）→ 正常平铺 + 锁 PID。
    private func windowHasDocument(_ window: AXUIElement) -> Bool {
        let doc = window.axString(kAXDocumentAttribute as CFString) ?? ""
        return !doc.isEmpty
    }

    private func sizeAttributeValue(_ windowElement: AXUIElement) -> CGSize? {
        windowElement.axSize(kAXSizeAttribute as CFString)
    }

    private func systemWideFocusedWindow(for pid: pid_t) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var ownerPID: pid_t = 0
        // axWindowElement 内部已用 CFGetTypeID 校验返回值确为 AXUIElement。
        guard let window = systemWide.axWindowElement(kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        AXUIElementGetPid(window, &ownerPID)
        return ownerPID == pid ? window : nil
    }

    private func windowNumber(of window: AXUIElement) -> Int? {
        // AXWindowNumber 是 CFNumber；通过共享扩展读取并转成 Int。
        // nil / 非正数视为无有效窗口编号（调用方会回退到 CFHash 作为 key）。
        guard let n = window.axInt32("AXWindowNumber" as CFString), n > 0 else { return nil }
        return Int(n)
    }

    private func tilePendingWindows(
        pid: pid_t,
        appElement: AXUIElement,
        primaryWindow: AXUIElement,
        edgeMargin: CGFloat
    ) -> AXUIElement? {
        var candidates: [AXUIElement] = []

        if isAutoCenterEligibleWindow(primaryWindow) {
            candidates.append(primaryWindow)
        }

        for window in appElement.axWindowElements(kAXWindowsAttribute as CFString) where isAutoCenterEligibleWindow(window) {
            if candidates.contains(where: { CFEqual($0, window) }) {
                continue
            }
            candidates.append(window)
        }
        var firstTiledWindow: AXUIElement?
        for window in candidates {
            do {
                // 首次应用也走两阶段动画（先居中、再从中心扩大），保证丝滑。
                try service.tileWindowElementAnimated(
                    window,
                    pid: pid,
                    appElement: appElement,
                    edgeMargin: edgeMargin
                )
                if firstTiledWindow == nil {
                    firstTiledWindow = window
                }
            } catch WindowCenteringError.unableToWriteWindowSize {
                // Do not mark as tiled; some apps report transient resize failures before the window is fully ready.
                continue
            } catch {
                continue
            }
        }

        return firstTiledWindow
    }

    private func key(pid: pid_t, window: AXUIElement) -> String? {
        if let num = windowNumber(of: window) {
            return "\(pid):\(num)"
        }
        return "\(pid):ax:\(CFHash(window))"
    }

    private func hasCentered(windowElement: AXUIElement, pid: pid_t) -> Bool {
        guard let k = key(pid: pid, window: windowElement) else { return false }
        return centeredWindowKeySet.contains(k)
    }

    private func markCentered(windowElement: AXUIElement, pid: pid_t) {
        guard let k = key(pid: pid, window: windowElement) else { return }
        if centeredWindowKeySet.contains(k) { return }

        centeredWindowKeySet.insert(k)
        centeredWindowKeys.append(k)

        // Prevent unbounded growth.
        if centeredWindowKeys.count > 200, let oldest = centeredWindowKeys.first {
            centeredWindowKeys.removeFirst()
            centeredWindowKeySet.remove(oldest)
        }
    }

}
