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
    private let dmgMonitor: DmgMountMonitor?

    private var observer: AXObserver?
    private var observedPID: pid_t?
    /// observer 通知注册是否失败（AXError.cannotComplete，常见于 Electron 应用冷启动时 AX 未就绪）。
    /// 为 true 时，attachToFrontmostApp 的 `observedPID == pid` 早退守卫放行，允许重连。
    private var observerRegistrationFailed: Bool = false
    /// 注册失败后的重连重试定时器：周期性销毁/重建 observer 并重新注册通知，直到成功或 app 失焦。
    private var reattachTimer: DispatchSourceTimer?
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
    /// resize 后「延迟重铺」的防抖定时器。
    ///
    /// 用于应对 Terminal 这类 app：在同一个窗口内开关标签页，会因「字符网格对齐 + 标签栏
    /// 出现/消失」改变窗口尺寸，但既不触发 focusedWindowChanged 也不触发 windowCreated，
    /// 且标签页共享 windowNumber → 命不中原有缓存 → 已平铺窗口不会被重新平铺。
    /// 改为：监听 `kAXResizedNotification`，尺寸变化后防抖 ~0.4s（合并多次抖动），
    /// 仅当窗口明显偏离平铺目标（>16px）时重新平铺。仅对平铺白名单内的 app 生效。
    private var resizeRetileTimer: DispatchSourceTimer?

    init(service: WindowCenteringService, tilingSettingsStore: AppTilingSettingsStore, dmgMonitor: DmgMountMonitor? = nil) {
        self.service = service
        self.tilingSettingsStore = tilingSettingsStore
        self.dmgMonitor = dmgMonitor
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
        // Space（虚拟桌面）切换监听：切 Space 时前台 app 通常不变 → 不触发 didActivate →
        // attachToFrontmostApp 的早退守卫会挡住，导致已居中窗口不会被重新居中。这里独立触发，
        // 让切回来的前台 app 主窗口能重新居中（在该场景下放宽「每个窗口只居中一次」契约）。
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
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
        resizeRetileTimer?.cancel()
        resizeRetileTimer = nil
        reattachTimer?.cancel()
        reattachTimer = nil
        observerRegistrationFailed = false
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

    /// Space（虚拟桌面）切换处理。
    ///
    /// 两件事：
    ///   1. 前台 app 重新居中。切 Space 时若前台 app 不变，macOS 不发 `didActivate`，
    ///      `attachToFrontmostApp` 也不被调用（且其 `observedPID == pid` 早退守卫会挡住），
    ///      故已居中窗口永远命中缓存。这里绕过早退守卫，清缓存 + 重启重试。
    ///      若前台 app 变了（如全屏软件 → 桌面，前台从 X 变 Finder），走 `attachToFrontmostApp` 切 observer。
    ///   2. 居中当前屏可见的**后台**标准窗口。切回桌面时前台 = Finder，桌面上的 app 窗口是后台，
    ///      原「只动前台」架构不会碰它们——用户期望这些窗口也被整理居中（打破该契约，用户已确认）。
    @objc private func activeSpaceDidChange() {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }

        // 1) 前台 app：已观察 → 清缓存重启重试；前台变了 → 切 observer。
        if observedPID == frontmost.processIdentifier {
            recenterObservedApp(pid: frontmost.processIdentifier)
        } else {
            attachToFrontmostApp()
        }

        // 2) 扫描当前屏可见的后台标准窗口，逐个居中。
        recenterVisibleBackgroundWindows(excluding: frontmost.processIdentifier)
    }

    /// 对当前已观察的前台 app 重新居中：中止动画 → 清居中缓存与 PID 标记 → 重启重试。
    /// 绕过 `attachToFrontmostApp` 的 `observedPID == pid` 早退守卫（切 Space 时前台不变，
    /// 守卫会挡住，缓存不会清理）。observer 仍绑定当前 PID，无需重建。
    private func recenterObservedApp(pid: pid_t) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        DiagnosticLog.debug("spaceDidChange: pid=\(pid) bundle=\(app.bundleIdentifier ?? "?") — recenter frontmost")

        service.abortActiveAnimations()
        initialCenterTimer?.cancel()
        initialCenterTimer = nil

        let prefix = "\(pid):"
        let removedCount = centeredWindowKeySet.filter { $0.hasPrefix(prefix) }.count
        if removedCount > 0 {
            DiagnosticLog.debug("spaceDidChange: cleared \(removedCount) cache entries for pid=\(pid)")
            centeredWindowKeySet = centeredWindowKeySet.filter { !$0.hasPrefix(prefix) }
            centeredWindowKeys = centeredWindowKeys.filter { !$0.hasPrefix(prefix) }
        }
        processedPIDs.remove(pid)

        let appElement = AXUIElementCreateApplication(pid)
        startInitialCenteringRetries(pid: pid, appElement: appElement, bundleIdentifier: app.bundleIdentifier)
    }

    /// 居中当前屏上可见的、非前台 app 的标准窗口（切回桌面场景）。
    ///
    /// 打破「只动前台」契约：用户从全屏软件切回桌面后，桌面上的 app 窗口是后台，
    /// 原 `handle`/`startInitialCenteringRetries` 路径会因前台守卫直接拒绝它们。这里用
    /// `CGWindowList` 枚举屏上标准窗口（layer==0），筛出当前屏可见、非前台、符合 shouldCenter
    /// 白名单（且非 Atlas 排除项）的，用 `centerWindowElementAnimated` 直接居中。
    /// 副作用控制：仅当前屏、仅标准窗口、同一 app 只动一个主窗口。
    private func recenterVisibleBackgroundWindows(excluding frontmostPID: pid_t) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        // 当前屏：main = 菜单栏/聚焦所在屏。仅动与该屏有实质重叠的窗口，避免误动其他屏。
        guard let screenRect = NSScreen.main?.frame else { return }

        var seenPIDs: Set<pid_t> = []
        let settings = tilingSettingsStore.load()

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int else { continue }
            let pid = pid_t(ownerPID)
            if pid == frontmostPID { continue }            // 跳过前台 app
            if seenPIDs.contains(pid) { continue }         // 同 app 只处理一次
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }  // 仅标准窗口层
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // 仅当前屏：与当前屏有实质重叠（width/height 均 > 1），排除其他屏 / 桌面特殊层。
            let overlap = rect.intersection(screenRect)
            guard !overlap.isNull, overlap.width > 1, overlap.height > 1 else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = app?.bundleIdentifier
            if !settings.shouldCenter(bundleIdentifier: bundleID) { seenPIDs.insert(pid); continue }  // 白名单

            let appElement = AXUIElementCreateApplication(pid)
            guard let windowElement = centerCandidateWindow(for: appElement, hintedElement: nil) else { continue }
            // Atlas 设置窗口跳动：仅排除设置窗口，主窗口正常居中（与 handle 一致）。
            if isChatGPTAtlasBundle(bundleID), isAtlasSettingsWindow(windowElement) { seenPIDs.insert(pid); continue }
            // 浏览器/访达二级窗口：切 Space 回桌面时同样不居中其弹窗/设置/下载窗口
            //（与 handle 路径一致；命中屏蔽列表且候选非主窗口 → 跳过，保持弹出位置）。
            if shieldedFromSecondaryWindowTiling(bundleID),
               isSecondaryWindowOfApp(windowElement, appElement: appElement, bundleIdentifier: bundleID)
            {
                seenPIDs.insert(pid); continue
            }
            do {
                try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
                markCentered(windowElement: windowElement, pid: pid)
                DiagnosticLog.debug("spaceDidChange: centered background window pid=\(pid) bundle=\(bundleID ?? "?")")
            } catch {
                // 全屏/读取失败等静默跳过（与 handle 的错误语义一致）。
                DiagnosticLog.debug("spaceDidChange: background center failed pid=\(pid) error=\(error)")
            }
            seenPIDs.insert(pid)
        }
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
            resizeRetileTimer?.cancel()
            resizeRetileTimer = nil
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

        if observedPID == app.processIdentifier, !observerRegistrationFailed {
            DiagnosticLog.debug("attach: already observing pid=\(app.processIdentifier) (\(app.bundleIdentifier ?? "?"))")
            return
        }
        if observedPID == app.processIdentifier, observerRegistrationFailed {
            // observer 注册曾失败（Electron 冷启动 AX 未就绪）：放行，触发重连流程。
            DiagnosticLog.debug("attach: reattaching pid=\(app.processIdentifier) (previous registration failed)")
        }

        DiagnosticLog.debug("attach: switching to pid=\(app.processIdentifier) bundle=\(app.bundleIdentifier ?? "?")")

        // 切换到新 app 前：立即中止上一个 app 进行中的平铺/居中动画，窗口停在最后一帧
        //（不回弹、不再写）。这消除"平铺动画进行中切走 → zombie Phase-B 定时器在后台继续
        // 移动已非前台 app 的窗口 → 切回来时它跳到另一个屏幕"的根因。
        service.abortActiveAnimations()

        initialCenterTimer?.cancel()
        initialCenterTimer = nil
        resizeRetileTimer?.cancel()
        resizeRetileTimer = nil
        reattachTimer?.cancel()
        reattachTimer = nil
        observerRegistrationFailed = false
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
        let registrationSucceeded = registerNotifications(on: newObserver, appElement: appElement, pid: pid)

        // 注册失败（Electron 冷启动 AX 未就绪，AXError.cannotComplete）：启动重连循环，
        // 周期性重建 observer 并重新注册，直到成功或 app 失焦。详见 startReattachLoop。
        observerRegistrationFailed = !registrationSucceeded
        if observerRegistrationFailed {
            DiagnosticLog.debug("attach: registration failed (AX not ready) pid=\(pid), starting reattach loop")
            startReattachLoop(pid: pid, appElement: appElement, bundleIdentifier: app.bundleIdentifier)
        }

        // 不在 attach 当下立即居中：app 刚被激活时 macOS 还在做激活动画，窗口位置/尺寸在抖动，
        // 此时探测坐标空间与读取 visibleFrame 都不稳定，会导致居中位置算错（"切换后居中没考虑
        // Dock 栏"的根因之一）。改为完全交给 startInitialCenteringRetries：它在短延迟后首次触发，
        // 等同于用户"动画结束后点立即居中"的效果——此时窗口已稳定，走的是与手动按钮完全相同、
        // 已被验证正确的居中路径。
        // （这里刻意不再调用 handle("initial")。立即居中会抢在动画完成前写入，反而出错。）

        // Some apps only create their focused window after a short delay (splash screens, permission prompts, etc.).
        // Retry briefly without showing alerts; stop once we successfully process a window or after a timeout.
        // 即使 observer 注册失败，轮询路径仍会读取 AXWindows，是 observer 漏通知时的兜底。
        startInitialCenteringRetries(
            pid: pid,
            appElement: appElement,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    /// 注册三个窗口通知到 observer，返回是否全部成功。
    /// Electron 应用冷启动时 AX 未就绪，AXObserverAddNotification 会返回 cannotComplete（-25204），
    /// 此时 observer 形同虚设，需由 startReattachLoop 周期性重试。
    @discardableResult
    private func registerNotifications(on observer: AXObserver, appElement: AXUIElement, pid: pid_t) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let r1 = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        let r2 = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        let r3 = AXObserverAddNotification(observer, appElement, kAXResizedNotification as CFString, refcon)
        let success = r1 == .success && r2 == .success && r3 == .success
        DiagnosticLog.debug("attach: observer added; focusedChanged=\(r1.rawValue) windowCreated=\(r2.rawValue) resized=\(r3.rawValue) success=\(success)")
        return success
    }

    /// 注册失败后的重连循环：每 500ms 重建 observer 并重新注册通知，直到成功或 app 失焦。
    /// 直接消除「observer 注册失败后永不重连」导致 Electron 应用窗口创建后无通知、不平铺的死路。
    private func startReattachLoop(pid: pid_t, appElement: AXUIElement, bundleIdentifier: String?) {
        reattachTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1

            // 前台守卫：app 已不是前台则停止重连。
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.reattachTimer?.cancel()
                self.reattachTimer = nil
                DiagnosticLog.debug("reattach: stopped (pid=\(pid) no longer frontmost) attempts=\(attempts)")
                return
            }

            // 重建 observer 并重新注册。
            if let oldObserver = self.observer {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(oldObserver), .defaultMode)
            }
            self.observer = nil
            self.observedPID = nil

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
                DiagnosticLog.debug("reattach: AXObserverCreate failed attempts=\(attempts) result=\(result.rawValue)")
                return
            }
            self.observer = newObserver
            self.observedPID = pid
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(newObserver), .defaultMode)

            let success = self.registerNotifications(on: newObserver, appElement: appElement, pid: pid)
            if success {
                self.observerRegistrationFailed = false
                self.reattachTimer?.cancel()
                self.reattachTimer = nil
                DiagnosticLog.debug("reattach: succeeded pid=\(pid) attempts=\(attempts)")
                // 重连成功后重置 initial retry，立即开始处理（窗口可能已就绪）。
                self.startInitialCenteringRetries(pid: pid, appElement: appElement, bundleIdentifier: bundleIdentifier)
                return
            }

            // 重连上限（15 次 × 500ms ≈ 7.5s），避免无限重试；超时后依赖轮询路径兜底。
            if attempts >= 15 {
                self.reattachTimer?.cancel()
                self.reattachTimer = nil
                DiagnosticLog.debug("reattach: gave up after \(attempts) attempts pid=\(pid), relying on poll path")
            }
        }
        reattachTimer = timer
        timer.resume()
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

        // 跳过 Plumb 自身：设置窗口由 SettingsWindowController.showWindow 的 completionHandler 精确居中
        //（动画结束后 setFrameOrigin）。通用 AX retry 居中会与 showWindow 的缩放动画 + 液态玻璃 resize +
        // .accessory→.regular 切换竞争，把窗口拉到偏上位置（实测偏上 112px，用户报告“没居中”）。
        // 纯早退：不 markCentered、不锁 processedPIDs，不影响其他 app。
        if pid == ProcessInfo.processInfo.processIdentifier {
            DiagnosticLog.debug("handle[\(notification)]: own PID \(pid) — settings window centered by showWindow, skip")
            return false
        }

        // Reject stale notifications delivered from a previously-observed app after the observer has
        // already been rebound to a different app.
        if let observedPID, observedPID != pid {
            DiagnosticLog.debug("handle[\(notification)]: stale — observedPID=\(observedPID) pid=\(pid), skip")
            return false
        }

        // resize 事件走独立旁路：必须在下方 processedPIDs 守卫之前分流，否则一个已平铺的窗口
        //（PID 已被锁）在尺寸因标签开关变化后，事件会被 PID 锁直接 short-circuit，永远无法重铺。
        // handleResize 内部自带 frontmost 守卫已由上方覆盖、白名单守卫、subrole 守卫与防抖。
        if notification == (kAXResizedNotification as String) {
            return handleResize(element: element, forcedPID: forcedPID)
        }

        // 用户按住 Option (⌥) 拖动/分屏窗口时，完全跳过居中与平铺——把布局权交给用户。
        // Option 是「手动排版」的显式信号。纯早退：不 markCentered、不锁 processedPIDs，
        // 松开 Option 后下次激活/事件仍按原逻辑处理（与 Atlas/Journal 设置窗口纯早退同构）。
        // 必须在 resize 分流之后：resize 走独立 handleResize 旁路，Option 检查在旁路内部单独做。
        if isUserHoldingOption() {
            DiagnosticLog.debug("handle[\(notification)]: Option key held — manual layout, skip (no center, no tile) pid=\(pid)")
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

        // ChatGPT Atlas（com.openai.atlas）特例：仅其「设置窗口」被自动居中/平铺后会反复跳动
        //（窗口自带定位与 Plumb 的居中/平铺互相打架），故对设置窗口完全跳过（不居中也不平铺）。
        // 关键收窄：只排除设置窗口，主浏览器窗口仍正常走居中/平铺（否则 Atlas 主窗口无法平铺）。
        // 设置窗口识别：AXIdentifier 为结构化 JSON，主窗口是 {"type":"main",...}，
        // 设置窗口是 {"type":"secondary","secondary":{"type":"settings"}}——用子串匹配稳定区分
        //（标题随网页变化不可靠，subrole/modal 两者相同无法区分）。
        // 纯早退：不 markCentered、不锁 processedPIDs，不污染共享缓存语义。
        if isChatGPTAtlasBundle(frontmostApp.bundleIdentifier),
           isAtlasSettingsWindow(windowElement)
        {
            DiagnosticLog.debug("handle[\(notification)]: ChatGPT Atlas settings window — skip (jitter fix) pid=\(pid)")
            return false
        }

        // 手记（Journal）设置窗口特例：设置窗口与主窗口 subrole/AXIdentifier/kAXMainWindow 三项硬特征
        // 完全相同（详见 isJournalSettingsWindow 注释），常规判据全部失效，只能靠 AXTitle 区分。
        // 必须在主路径此处拦截，否则会被居中/平铺。纯早退：不 markCentered、不锁 processedPIDs。
        if isJournalBundle(frontmostApp.bundleIdentifier),
           isJournalSettingsWindow(windowElement)
        {
            DiagnosticLog.debug("handle[\(notification)]: Journal settings window — skip (no center, no tile) pid=\(pid)")
            return false
        }

        // 浏览器/访达二级窗口屏蔽：这些 App 的二级窗口（设置/下载/弹窗/Get Info/扩展页 等）常报告
        // AXStandardWindow subrole，会绕过 subrole 过滤被误居中/误平铺。命中屏蔽列表且候选不是主窗口
        // 时完全跳过——不平铺、不居中、不 markCentered、不锁 processedPIDs，保持其弹出位置。
        // 主窗口不受影响，正常居中/平铺。
        // 关键：必须放在 `if shouldTile` 分流**之前**——浏览器默认走居中分支（不在平铺白名单），
        // 若只在 shouldTile 分支内拦截（c1a1d34 原做法），居中分支无保护，弹窗仍会被居中。
        // 仿上方 Atlas 设置窗口特例的纯早退语义。补的是「PID 锁被清除（Space 切换/重新激活）
        // 或二级窗口先于主窗口到达」时空档——其余情况下 processedPIDs 锁已拦截。
        //
        // isSecondaryWindowOfApp 内部对 Chromium 内核浏览器优先用 AXIdentifier 的 type 字段
        //（"main"/"secondary"）判定——kAXMainWindowAttribute 在二级窗口聚焦时会追踪聚焦窗，
        // 把扩展设置页误报成主窗口（用户报告的「扩展程序设置界面被居中」根因），靠它判定会漏；
        // AXIdentifier 是 Chromium 进程内窗口管理的稳定结构化标识，能可靠区分主/二级窗口。
        if shieldedFromSecondaryWindowTiling(frontmostApp.bundleIdentifier),
           isSecondaryWindowOfApp(windowElement, appElement: appElement, bundleIdentifier: frontmostApp.bundleIdentifier)
        {
            DiagnosticLog.debug("handle[\(notification)]: shielded browser/Finder secondary window — skip (no tile, no center) pid=\(pid)")
            return false
        }

        let tilingSettings = tilingSettingsStore.load()
        let shouldTile = tilingSettings.shouldTile(bundleIdentifier: frontmostApp.bundleIdentifier)
        // per-app 边距：该 app 单独设置过 → 用自定义值；否则回退全局 edgeMargin。
        let effectiveMargin = tilingSettings.effectiveMargin(for: frontmostApp.bundleIdentifier)
        if shouldTile {
            // 每个"激活周期"内同一窗口只平铺一次：首次平铺后若再收到聚焦/创建通知，
            // 直接跳过，避免重试与重复事件反复触发"先居中再放大"动画，导致窗口被来回
            // 拉扯、最终回弹到小尺寸（这是"指定 App 不会自动平铺放大"的根因）。
            if hasCentered(windowElement: windowElement, pid: pid) {
                DiagnosticLog.debug("handle[\(notification)]: already tiled pid=\(pid)")
                return false
            }

            // 浏览器/访达二级窗口屏蔽：已在上方 if shouldTile 分流前统一拦截（同时保护居中+平铺），
            // 此处不再重复检查。

            // 文档类 App 选择器感知（Pages/Word/Excel/Numbers 等）。
            // 这些 App 有三类「无 kAXDocument」窗口（subrole 均 AXStandardWindow）：文件列表、
            // 模板选择器、新建未保存文档。只有「新建未保存文档」该平铺，前两类只居中。
            //
            // 判据（见 classifyDocumentAppWindow 注释的实测证据），按 windowHasDocument +
            // classifyDocumentAppWindow 的三态分流：
            //   - 有 kAXDocument（已保存文档）→ 跳过本分支，落到下方正常平铺 + 锁 PID。
            //   - .gallery（子树含选择器 role）→ 只居中，不锁、不 markCentered。
            //   - .document（无 kAXDocument 但子树含文档内容 role，如新建未保存文档）
            //     → 跳过本分支，落到下方平铺（这正是 bbfdd1c 想要、又不破坏选择器的行为）。
            //   - .undetermined（子树未就绪，Office 启动期 0.45s 空壳）→ 只居中，不锁、不 markCentered，
            //     return true 但【不终止重试】。这是修复「Excel/Word 文件列表被平铺」的根因：
            //     运行时日志确证 Office 在 0.45s 时子树还没构建出 AXCollectionList，旧实现把它当
            //     「非选择器」→ 平铺 + processedPIDs.insert 锁死，导致即使几秒后子树就绪也永不再评估。
            //     改为只居中、不锁，让 startInitialCenteringRetries 继续重试，直到子树能明确判定
            //     为 .gallery（继续居中）或 .document（平铺）。
            //
            // （childCount 阈值判据已两次失败：只对 Pages 实测，Excel 文件列表 childCount=9 击穿；
            //  AXTitle 判据也曾失败：文件列表标题非空 + 新文档标题填充延迟。AX role 是结构性硬特征，
            //  状态切换瞬间即准确，不受子元素计数、标题时序/语言影响。）
            //
            // 关键不变量：gallery / undetermined 两分支都【不】锁 processedPIDs、也【不】markCentered ——
            // 否则后续真正文档窗口（含同一窗口保存后获得 kAXDocument）会被 hasCentered/processedPIDs
            // 永久挡住无法平铺（这正是此前「打开文稿后不平铺」的根因）。.document 与有 kAXDocument 的
            // 窗口一样落到下方正常平铺+锁。重复居中由 service 的动画去重防抖（activeAnimationKey），
            // 居中不涉及 resize，无「来回拉扯」风险。
            //
            // 设计决策：选择器居中不受 shouldCenter 白名单约束——只要该 App 在平铺白名单 +
            // 选择器感知列表内，选择器/未定型窗口一律居中（符合"选择器不平铺但整理到屏幕中央"的预期）。
            if tilingSettings.isDocumentChooserApp(bundleIdentifier: frontmostApp.bundleIdentifier),
               !windowHasDocument(windowElement)
            {
                switch classifyDocumentAppWindow(windowElement) {
                case .gallery:
                    DiagnosticLog.debug("handle[\(notification)]: gallery window — center only, keep PID unlocked, not marked pid=\(pid)")
                    do {
                        try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
                        return true   // 重试会继续；gallery 不会变成文档，但保持不锁语义一致。
                    } catch {
                        DiagnosticLog.debug("handle[\(notification)]: chooser center failed pid=\(pid) error=\(error)")
                        return false
                    }
                case .undetermined:
                    // 子树未就绪（Office 启动期空壳）：只居中、不锁、不 markCentered、继续重试。
                    // ⚠️ 不落入下方 tilePendingWindows——那会平铺并锁死 PID，造成「文件列表被平铺」
                    // 且后续真文档被永久挡住。等子树构建完成（后续重试）能明确判定后再处理。
                    DiagnosticLog.debug("handle[\(notification)]: undetermined window (subtree not ready) — center only, keep PID unlocked, retry will re-evaluate pid=\(pid)")
                    do {
                        try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
                        return true
                    } catch {
                        DiagnosticLog.debug("handle[\(notification)]: undetermined center failed pid=\(pid) error=\(error)")
                        return false
                    }
                case .document:
                    // 无 kAXDocument 但子树含文档内容（新建未保存文档）→ 落到下方正常平铺。
                    DiagnosticLog.debug("handle[\(notification)]: document window (no kAXDocument but has content) — fall through to tile pid=\(pid)")
                }
            }
            // DMG 安装窗口感知：访达打开 .dmg 后弹出的「挂载内容窗口」（拖拽安装界面）。
            // 该窗口标题 == DMG 卷名；命中已挂载 DMG 卷名集合 → 只居中、不平铺。
            // 复用文档选择器分支的不变量：不 markCentered、不锁 processedPIDs，
            // 使 DMG 窗口关闭后同一 Finder 里打开的普通文件夹窗口仍能被平铺。
            // 不命中（非 Finder、非 DMG 标题、或 dmgMonitor 未注入）→ 落入下方正常平铺。
            if let dmgMonitor,
               isFinderBundle(frontmostApp.bundleIdentifier),
               let title = windowElement.axString(kAXTitleAttribute as CFString),
               dmgMonitor.isMountedDmgVolume(title)
            {
                DiagnosticLog.debug("handle[\(notification)]: DMG installer window — center only, keep PID unlocked, not marked pid=\(pid) title=\(title)")
                do {
                    try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
                    return true
                } catch {
                    DiagnosticLog.debug("handle[\(notification)]: DMG center failed pid=\(pid) error=\(error)")
                    return false
                }
            }
            if let tiledWindow = tilePendingWindows(
                pid: pid,
                appElement: appElement,
                primaryWindow: windowElement,
                edgeMargin: effectiveMargin
            ) {
                // 平铺未真正放大（启动期小窗 / 不可调大小窗口）：不锁 PID、不 markCentered，
                // 让 startInitialCenteringRetries 继续接力，直到真正主窗口到达并被成功平铺。
                // 典型场景：SiYuan 等 Electron 应用首次启动先弹加载小窗，若在此小窗上锁了 PID，
                // 随后到达的真正主窗口会被 Bug #3 守卫永久跳过（"第一次打开不平铺"的根因）。
                // 与上方 document-chooser / DMG 分支的「不锁」不变量同构。
                if didWindowActuallyTile(tiledWindow, pid: pid, edgeMargin: effectiveMargin) {
                    markCentered(windowElement: tiledWindow, pid: pid)
                    processedPIDs.insert(pid)   // Bug #3: 本周期内此 app 已处理，跳过后续窗口
                    startTileStabilizationRetries(
                        pid: pid,
                        appElement: appElement,
                        windowElement: tiledWindow,
                        edgeMargin: effectiveMargin
                    )
                    DiagnosticLog.debug("handle[\(notification)]: tiled pid=\(pid)")
                    return true
                } else {
                    // 动画异步返回，此时窗口尚未放大到目标尺寸——保持 PID 解锁，由 retry 循环在动画完成后确认。                    // 启动期小窗等：不锁、不标记，让重试继续接力处理后续到达的真正主窗口。
                    DiagnosticLog.debug("handle[\(notification)]: tile did not actually enlarge window — keep PID unlocked for retry pid=\(pid)")
                    return false
                }
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

            // maxAttempts：平铺 app 取 40（~14s），覆盖 Electron 冷启动窗口创建延迟（常 >8s）；
            // 非 tiling app 取 12。即使 observer 注册成功，轮询路径也作为「窗口延迟创建」的兜底。
            let maxAttempts = tilingEnabledForApp ? 40 : 12
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

    /// 处理 `kAXResizedNotification`：在窗口尺寸变化后延迟重新平铺。
    ///
    /// 场景：Terminal 这类 app 在同一窗口内开关标签页时，会因「字符网格对齐 + 标签栏出现/消失」
    /// 改变窗口尺寸。原监听集合（focusedWindowChanged / windowCreated）覆盖不到该场景，且
    /// 标签页共享 windowNumber 命不中原有缓存 → 已平铺窗口不会被重铺（用户报告的 bug）。
    ///
    /// 本方法是一条【独立旁路】：
    ///   - 仅对平铺白名单内的 app 生效（shouldTile == true），居中类 app 一律不响应 resize。
    ///   - 防抖 ~0.4s：合并开关标签时的连续多次 resize 抖动，只触发一次重铺评估。
    ///   - 重铺前用 isWindowNearTiledTarget 判定：尺寸已在平铺目标 16px 容差内 → 不做事，
    ///     避免对已是平铺态的窗口反复触发动画。
    ///   - 进行中的动画（isAnyAnimationInProgress）跳过本回合，防止与自身平铺动画叠加。
    ///   - 刻意【不】触碰 processedPIDs / markCentered：resize 重铺不应破坏原「一次即可」语义，
    ///     也避免二级窗口因 resize 被误触发。
    ///
    /// 关于「用户手动拖动改尺寸」：按设计取舍，白名单 app 本就应处于平铺态，手动改尺寸被拉回
    /// 属可接受行为；故此处不区分「用户手势 vs 标签 resize」，偏移即重铺。
    ///
    /// `element`：resize 通知的 element 通常就是被缩放的窗口本身（非 app 元素）。
    private func handleResize(element: AXUIElement, forcedPID: pid_t? = nil) -> Bool {
        // pid 已由 handle() 入口解析过；这里仅做必要的合法性确认。
        guard let pid = forcedPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            DiagnosticLog.debug("handle[resize]: cannot resolve pid, skip")
            return false
        }
        // 仅前台 app：与 handle() 一致，避免对后台窗口的 resize 做任何写操作。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            DiagnosticLog.debug("handle[resize]: frontmost != pid \(pid), skip")
            return false
        }
        // stale observer 守卫：与 handle() 一致。
        if let observedPID, observedPID != pid {
            DiagnosticLog.debug("handle[resize]: stale — observedPID=\(observedPID) pid=\(pid), skip")
            return false
        }

        // 用户按住 Option (⌥) 拖动窗口边缘改尺寸时，跳过重铺——把布局权交给用户。
        // resize 旁路绕过 processedPIDs 锁（见 828 行注释），故 Option 检查必须在此处独立设置，
        // 不能只靠 handle() 主路径。纯早退：不安排 retile 定时器，最干净。
        if isUserHoldingOption() {
            DiagnosticLog.debug("handle[resize]: Option key held — manual layout, skip retile pid=\(pid)")
            return false
        }

        // 仅平铺白名单 app 响应 resize；居中类 app 尺寸变化不重铺（保持原行为）。
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              tilingSettingsStore.load().shouldTile(bundleIdentifier: bundleID)
        else {
            DiagnosticLog.debug("handle[resize]: pid \(pid) not in tile whitelist, skip")
            return false
        }

        // resize 通知的 element 应是窗口本身；校验 role == AXWindow，并排除 dialog/floating 等辅助窗口。
        // 直接复用 isMovableNonAuxiliaryWindow 的「真实窗口 + 非辅助类型」判定（不强制 AXStandardWindow，
        // 因部分 app 主窗口 subrole 缺失）。
        guard isMovableNonAuxiliaryWindow(element) else {
            DiagnosticLog.debug("handle[resize]: element not a movable non-auxiliary window, skip")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        let edgeMargin = tilingSettingsStore.load().effectiveMargin(for: bundleID)
        let windowElement = element

        // 手记（Journal）设置窗口特例（resize 旁路补丁）——【这是本 bug 的根因路径】。
        // 手记设置窗口打开时的尺寸动画触发 kAXResizedNotification，走本旁路（绕过 processedPIDs 锁），
        // 设置窗口被强行平铺成全屏（实测 640×533 → 1480×835，被移到左上角）。
        // handle() 主路径已被 processedPIDs 锁挡住，挡不住 resize 旁路——故必须在此处也拦截。
        // 判据用 AXTitle（subrole/AXIdentifier/kAXMainWindow 三项硬特征全失效，见 isJournalSettingsWindow）。
        // 放在防抖定时器之前：连 retile schedule 都不安排，最干净。
        if isJournalBundle(bundleID),
           isJournalSettingsWindow(windowElement)
        {
            DiagnosticLog.debug("handle[resize]: Journal settings window — skip retile (no tile) pid=\(pid)")
            return false
        }

        DiagnosticLog.debug("handle[resize]: scheduling retile for pid=\(pid) bundle=\(bundleID)")

        // 防抖：每次 resize 重置定时器，停止抖动 ~0.4s 后才评估重铺。
        resizeRetileTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.40)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.resizeRetileTimer = nil

            // 切走/退出后残留的定时器不应在后台写窗口（与 abortActiveAnimations 同理念）。
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                DiagnosticLog.debug("handle[resize]: fired but no longer frontmost pid=\(pid), skip")
                return
            }

            // 与自身平铺动画叠加会导致「来回拉扯」：进行中则放弃本回合。
            if self.service.isAnyAnimationInProgress {
                DiagnosticLog.debug("handle[resize]: animation in progress, skip this round")
                return
            }

            // 浏览器/访达二级窗口屏蔽（resize 旁路补丁）。
            // 现象：Chrome/Edge 等 Chromium 浏览器打开扩展设置页/详情页/弹窗时，会弹出一个
            // 独立的**非主**小窗口（实测如 390x171），它触发 kAXResizedNotification 走本旁路。
            // 由于 handleResize 刻意不查 processedPIDs（见 828 行注释），且此前也没有二级窗口
            // 守卫，这个小窗口被判为「偏离平铺目标」→ 被强行拉满全屏（用户报告的
            // 「打开扩展程序设置界面会被自动居中/放大」根因）。
            // 修复：与 handle() 主路径守卫一致——命中屏蔽列表（浏览器/访达）且候选是该 App 的
            // 非主窗口时，完全跳过重铺，保持其弹出尺寸/位置。主窗口（候选 == 主窗口）不受影响。
            if self.shieldedFromSecondaryWindowTiling(bundleID) {
                if self.isSecondaryWindowOfApp(windowElement, appElement: appElement, bundleIdentifier: bundleID) {
                    DiagnosticLog.debug("handle[resize]: shielded browser/Finder secondary window — skip retile pid=\(pid)")
                    return
                }
            }

            // 文档类 App 选择器感知（resize 旁路补丁）：
            // 与 handle() 的 chooser 分支同构。文档 App 必须在平铺白名单内（真文档要平铺），故其
            // 文件列表/模板画廊窗口一旦 resize（缩略图加载、入场动画）会通过上方 shouldTile 守卫，
            // 直接走到下面的 tileWindowElementAnimated 被强行平铺——这正是"文件列表界面又被平铺"的根因。
            // 命中 .gallery 或 .undetermined（子树未就绪）时改为只居中、不平铺；不锁 processedPIDs、
            // 不 markCentered（同 handle() 不变量，否则后续真文档窗口会被永久挡住无法平铺）。
            // .undetermined 同样只居中：resize 时刻子树可能仍未就绪，平铺会锁死误判（同主路径根因）。
            // 居中不涉及 resize、无"来回拉扯"风险。
            if self.tilingSettingsStore.load().isDocumentChooserApp(bundleIdentifier: bundleID),
               !self.windowHasDocument(windowElement)
            {
                let kind = self.classifyDocumentAppWindow(windowElement)
                if kind == .gallery || kind == .undetermined {
                    DiagnosticLog.debug("handle[resize]: document-chooser \(kind) window — center only, skip retile pid=\(pid)")
                    _ = try? self.service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
                    return
                }
                // .document（无 kAXDocument 但有文档内容）→ 落到下方正常 retile。
            }

            // 已在平铺目标 16px 容差内 → 无需重铺（避免对平铺态窗口反复触发）。
            if self.isWindowNearTiledTarget(windowElement, pid: pid, appElement: appElement, edgeMargin: edgeMargin) {
                DiagnosticLog.debug("handle[resize]: window already near tiled target, skip retile")
                return
            }

            DiagnosticLog.debug("handle[resize]: window off target → retile pid=\(pid)")
            _ = try? self.service.tileWindowElementAnimated(
                windowElement,
                pid: pid,
                appElement: appElement,
                edgeMargin: edgeMargin
            )
        }
        resizeRetileTimer = timer
        timer.resume()
        return true
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

    /// 平铺后窗口是否真正放大到接近目标尺寸。
    ///
    /// 用于区分「真正成功的主窗口平铺」与「启动期小窗 / 不可调大小窗口的无效平铺」：
    /// 后者（Electron 类应用如 SiYuan 首次启动时的加载窗）虽然走完了 `tilePendingWindows`
    /// 的两阶段动画，但尺寸无法真正放大到平铺目标。若此时仍 `markCentered` + 锁 `processedPIDs`，
    /// 随后到达的真正主窗口会被 Bug #3 守卫（`processedPIDs.contains(pid)`）永久跳过，
    /// 表现为「该 App 第一次打开不平铺，之后才正常」——这正是本方法要堵住的根因。
    ///
    /// 判据：当前尺寸在目标尺寸的 16px 容差内（沿用 `isWindowNearTiledTarget` 的容差语义，
    /// 两者同源、保持一致）。读取失败时保守返回 false（视为未成功 → 不锁，让重试接力），
    /// 与既有「主窗口缺失时保守视为主窗口」的同类取舍一致（宁可多试一次也不误锁）。
    ///
    /// 语义配合：返回 false 时调用方应【不】markCentered、【不】锁 processedPIDs，
    /// 与上方 document-chooser / DMG 分支的「不锁」不变量同构——让真正主窗口有机会被处理。
    private func didWindowActuallyTile(_ windowElement: AXUIElement, pid: pid_t, edgeMargin: CGFloat) -> Bool {
        guard let size = sizeAttributeValue(windowElement),
              let target = service.tiledTargetFrame(for: windowElement, pid: pid, edgeMargin: edgeMargin)
        else { return false }
        let tol: CGFloat = 16
        return size.width >= target.width - tol && size.height >= target.height - tol
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

    /// 对一个无文档窗口做三态分类：选择器/画廊、文档、或「未定型」。
    ///
    /// 背景：文档类 App（Pages/Numbers/Word/Excel）有三类「无 kAXDocument」窗口，subrole 均
    /// 为 AXStandardWindow，仅凭 subrole 与 kAXDocument 无法区分：
    ///   - 文件列表（「打开」面板）
    ///   - 模板选择器画廊
    ///   - 新建未保存文档（标题「未命名」/「文档1」/「工作簿2」）
    /// 其中只有「新建未保存文档」应当平铺，前两类只居中。
    ///
    /// 判据：**窗口子树是否含选择器特有的 AX 角色**（而非数子元素数）。来自 2026-06 对
    /// Excel/Word/Pages/Numbers 的「文件列表 / 模板画廊 / 真实文档」三态实测（osascript 采
    /// 全子树），选择器窗口稳定含以下 role 组合之一：
    ///   - Office（Word/Excel）文件列表、iWork（Pages/Numbers）模板画廊：含 `AXCollectionList`
    ///   - iWork（Pages/Numbers）文件列表（「打开」面板）：同时含 `AXOutline` 与 `AXBrowser`
    ///
    /// ⚠️ 三态的关键——为什么需要区分「未定型」（运行时日志 2026-06-29 确证）：
    ///   Office 启动慢，attach 后 0.45s 首次 handle 触发时，文件列表窗口子树**还没构建出
    ///   AXCollectionList**。此刻遍历子树「既找不到选择器 role、也找不到文档内容」。
    ///   旧实现把这种情况当「不是选择器」→ 落入平铺 + processedPIDs.insert 锁死 PID，
    ///   导致即使几秒后子树就绪也永远不再被评估（Excel/Word 文件列表被平铺的根因）。
    ///   因此必须把它单独识别为 .undetermined：只居中、不锁 PID、让重试继续，直到子树就绪
    ///   能明确判定为 .gallery（继续居中）或 .document（平铺）。
    ///
    /// 如何区分「未定型」与「真文档」：两者此刻都不含选择器 role。但真文档窗口子树非空且
    /// 含文档内容 role（如 AXLayoutArea / AXTextArea / AXSplitGroup 等），未定型窗口子树
    /// 极度贫瘠（Office 0.45s 时往往只有空壳）。用「子树是否含任意文档内容 role」区分：
    ///   - 含选择器 role → .gallery
    ///   - 不含选择器 role，但含文档内容 role → .document（应平铺）
    ///   - 两者都不含（子树未构建/空壳）→ .undetermined（只居中、不锁、继续重试）
    ///
    /// 为什么不用 childCount 阈值（曾两次失败）：见 git log（bbfdd1c/2912c5d）。
    /// 为什么不用 AXTitle：见 windowHasDocument 注释（时序错 + 跨 App 文案不一致）。
    private func classifyDocumentAppWindow(_ window: AXUIElement) -> DocumentAppWindowKind {
        var foundCollectionList = false
        var foundOutline = false
        var foundBrowser = false
        var foundDocumentContent = false
        subtreeRoles(window, maxDepth: Self.chooserRoleScanDepth) { role in
            switch role {
            case "AXCollectionList": foundCollectionList = true
            case "AXOutline":        foundOutline = true
            case "AXBrowser":        foundBrowser = true
            // 文档内容 role（实测：Excel/Word/Pages/Numbers 文档窗口都含其中之一或多个）。
            // 用于区分「真文档」与「未定型空壳」。
            // ⚠️ 不能用 AXSplitGroup——它是通用容器 role，iWork 文件列表/模板页也含（实测
            // Numbers 文件列表顶层就是 AXSplitGroup，但选择器 role AXOutline/AXBrowser 藏在它
            // 内层）。若把 AXSplitGroup 当文档内容，会过早剪枝，扫不到内层的选择器 role，
            // 导致 Numbers 文件列表被误判为 .document（运行时日志 2026-06-29 确证）。
            // 只用「文档画布/可编辑文本」这种真正的文档内容 role。
            case "AXLayoutArea", "AXTextArea":
                foundDocumentContent = true
            default: break
            }
            // 只有命中选择器签名（明确是 gallery）才剪枝；文档内容不剪枝——因为选择器 role
            // 可能藏在更深层（如 Numbers 文件列表的 Outline/Browser 在 AXSplitGroup 内层），
            // 过早因 foundDocumentContent 停止会漏扫选择器 role。让遍历走完整个 maxDepth 子树。
            return Self.isChooserRoleSignature(
                hasCollectionList: foundCollectionList,
                hasOutline: foundOutline,
                hasBrowser: foundBrowser
            )
        }
        return Self.classifyWindow(
            hasCollectionList: foundCollectionList,
            hasOutline: foundOutline,
            hasBrowser: foundBrowser,
            hasDocumentContent: foundDocumentContent
        )
    }

    /// 递归遍历元素子树，对每个节点的 AXRole 调用 `visit`；`visit` 返回 true 时立即剪枝终止。
    ///
    /// 深度受 `maxDepth` 限制以防大子树（如 Office 文档窗口）遍历爆炸；实测选择器特征 role 都
    /// 在 ≤4 层内出现。读取失败/无子元素的节点安全跳过，不崩溃。
    private func subtreeRoles(
        _ element: AXUIElement,
        maxDepth: Int,
        visit: (String) -> Bool
    ) {
        let role = element.axString(kAXRoleAttribute as CFString) ?? ""
        if visit(role) { return }
        guard maxDepth > 0 else { return }
        for child in element.axWindowElements(kAXChildrenAttribute as CFString) {
            subtreeRoles(child, maxDepth: maxDepth - 1, visit: visit)
        }
    }

    /// 选择器子树扫描的最大深度。实测选择器特征 role（AXCollectionList / AXOutline / AXBrowser）
    /// 都在窗口根下 4 层以内出现；给到 6 留余量，同时避免对 Office 文档这种大子树全量遍历。
    private static let chooserRoleScanDepth = 6

    /// 文档类 App 无文档窗口的三态分类。纯逻辑（无 actor 依赖），可单测。
    ///
    /// - gallery: 选择器/文件列表（只居中、不平铺，可安全锁/不锁均可——它不会再变成文档）
    /// - document: 真文档窗口（应平铺 + 锁 PID）
    /// - undetermined: 子树未就绪，无法判定（只居中、不锁 PID、继续重试，直到能明确判定）
    enum DocumentAppWindowKind: Equatable {
        case gallery
        case document
        case undetermined
    }

    /// 纯逻辑判定：给定子树中各特征 role 的命中情况，是否构成「文件列表 / 模板画廊」签名。
    ///
    /// 与 AX 取值解耦——遍历子树负责收集 role，本函数负责签名判定，规则集中、可单测。
    /// 规则（实测验证，见 classifyDocumentAppWindow 注释）：
    ///   - 含 AXCollectionList（Office 文件列表 + iWork 模板画廊）=> 选择器
    ///   - 同时含 AXOutline + AXBrowser（iWork「打开」文件列表）=> 选择器
    /// nonisolated：纯逻辑无任何 actor 状态依赖，可脱离 MainActor 在任意上下文（含单测）调用。
    nonisolated static func isChooserRoleSignature(
        hasCollectionList: Bool,
        hasOutline: Bool,
        hasBrowser: Bool
    ) -> Bool {
        return hasCollectionList || (hasOutline && hasBrowser)
    }

    /// 纯逻辑三态分类：给定子树特征 role 命中情况，判定窗口是 gallery / document / undetermined。
    ///
    /// 规则（实测验证，见 classifyDocumentAppWindow 注释）：
    ///   - 命中选择器签名（AXCollectionList 或 AXOutline+AXBrowser）=> .gallery
    ///   - 否则若含文档内容 role（AXLayoutArea / AXTextArea / AXSplitGroup）=> .document
    ///   - 两者都不含（Office 启动期 0.45s 空壳、子树未构建）=> .undetermined
    /// 这是修复「Excel/Word 文件列表 0.45s 时被误判平铺并锁死 PID」的关键纯函数：
    /// 让调用方对 .undetermined 采取「只居中、不锁、继续重试」而非「平铺+锁」。
    /// nonisolated：纯逻辑，可单测。
    nonisolated static func classifyWindow(
        hasCollectionList: Bool,
        hasOutline: Bool,
        hasBrowser: Bool,
        hasDocumentContent: Bool
    ) -> DocumentAppWindowKind {
        if isChooserRoleSignature(
            hasCollectionList: hasCollectionList,
            hasOutline: hasOutline,
            hasBrowser: hasBrowser
        ) {
            return .gallery
        }
        return hasDocumentContent ? .document : .undetermined
    }

    /// bundle id 是否为访达（归一化比较）。
    /// 访达的 DMG 挂载内容窗口与普通文件夹窗口同属 com.apple.finder，仅靠此 id 缩窄 DMG 检测范围。
    private func isFinderBundle(_ bundleIdentifier: String?) -> Bool {
        AppTilingSettings.normalizeBundleID(bundleIdentifier ?? "") == "com.apple.finder"
    }

    /// bundle id 是否为 ChatGPT Atlas 浏览器（归一化比较）。
    private func isChatGPTAtlasBundle(_ bundleIdentifier: String?) -> Bool {
        AppTilingSettings.normalizeBundleID(bundleIdentifier ?? "") == "com.openai.atlas"
    }

    /// bundle id 是否为手记 Journal（归一化比较）。
    private func isJournalBundle(_ bundleIdentifier: String?) -> Bool {
        AppTilingSettings.normalizeBundleID(bundleIdentifier ?? "") == "com.apple.journal"
    }

    /// 需要屏蔽「二级窗口平铺」的浏览器 bundle id（归一化小写比较）。
    /// 这些 App 的二级窗口（设置/下载/弹窗/PWA/扩展窗）常报告 AXStandardWindow subrole，
    /// 会绕过 subrole 过滤被误平铺。硬编码默认覆盖主流浏览器；访达单独由 isFinderBundle 处理。
    /// ChatGPT Atlas (com.openai.atlas) 本质是 Chromium 内核浏览器，二级窗口同样会泄漏——
    /// 它原有的 isAtlasSettingsWindow 特例只覆盖「设置窗口」，弹窗/PWA/工具窗仍被居中/平铺，
    /// 故纳入此表走通用的二级窗口屏蔽（候选 ≠ kAXMainWindow 即跳过）。
    private static let secondaryWindowShieldedBundleIDs: Set<String> = [
        "com.apple.safari",
        "com.google.chrome",
        "com.google.chrome.canary",
        "com.google.chromefortesting",
        "org.chromium.chromium",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.beta",
        "com.microsoft.edgemac.dev",
        "com.microsoft.edgemac.canary",
        "org.mozilla.firefox",
        "com.brave.browser",
        "com.brave.browser.beta",
        "com.brave.browser.nightly",
        "company.thebrowser.browser",   // Arc
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "com.openai.atlas"              // ChatGPT Atlas（Chromium 内核，二级窗口同样泄漏）
    ]

    /// bundle id 是否属于「需屏蔽二级窗口平铺」的浏览器或访达（归一化比较）。
    /// 作用域收窄：仅命中此集合的 App 才进入二级窗口跳过逻辑，不影响文档类 App 或其他白名单 App。
    private func shieldedFromSecondaryWindowTiling(_ bundleIdentifier: String?) -> Bool {
        let id = AppTilingSettings.normalizeBundleID(bundleIdentifier ?? "")
        return Self.secondaryWindowShieldedBundleIDs.contains(id) || id == "com.apple.finder"
    }

    /// 判定候选窗口是否为该 App 的【非主】窗口（即二级窗口）。
    ///
    /// 判据分两档（按可靠性顺序）：
    ///
    /// **1. Chromium 浏览器 → AXIdentifier 的 `type` 字段（实测最可靠）**
    ///   Chromium 窗口 AXIdentifier 是结构化 JSON（实测 2026-06）：主窗口
    ///   `{"...,"type":"main"}`，设置/扩展/弹窗为 `{"...,"type":"secondary"}`。
    ///   这些二级窗口与主窗口 AXSubrole/AXModal 完全相同；且 kAXMainWindowAttribute 在
    ///   二级窗口聚焦时会追踪聚焦窗，把扩展设置页误报成主窗口。AXIdentifier 的 type 字段
    ///   是更稳定的硬特征。这里复用 ChromiumWindowIdentifier 解析 type 字段。
    ///
    /// **2. 其它 App（Safari/Firefox/访达 等）→ `kAXMainWindowAttribute`（回退）**
    ///   候选窗口 ≠ 主窗口即视为二级窗口。这是结构性硬特征，由系统维护。
    ///   实测（2026-06）：Chrome 打开扩展弹窗/设置页时弹出的独立小窗口（如 390x171）确实
    ///   ≠ kAXMainWindowAttribute（main!=cand），本判据能正确识别它为二级窗口并跳过。
    ///   - 主窗口缺失（nil）：保守地视为「主窗口」返回 false
    ///     （不平铺一次的风险 < 误跳过主窗口致其永远不平铺的风险，与「主窗口优先平铺」预期一致）。
    ///   - 候选 == 主窗口：返回 false（是主窗口，正常平铺）。
    ///   - 候选 ≠ 主窗口：返回 true（二级窗口 → 跳过）。
    ///
    /// 注意：Chromium 分类器返回 nil（AXIdentifier 不可读 / 非 JSON / 无 type）时回退到档 2，
    /// 不影响保守语义。
    private func isSecondaryWindowOfApp(_ window: AXUIElement, appElement: AXUIElement, bundleIdentifier: String? = nil) -> Bool {
        // 档 1：Chromium 浏览器用 AXIdentifier 判定；kAXMainWindowAttribute 在扩展页聚焦时不可靠。
        if ChromiumWindowIdentifier.isKnownChromiumBrowser(bundleIdentifier: bundleIdentifier) {
            if let id = window.axString("AXIdentifier" as CFString),
               let classification = ChromiumWindowIdentifier.classify(axIdentifier: id)
            {
                // 分类成功：secondary → 跳过；main → 不跳过。
                return classification == .secondary
            }
            // 分类失败（无 AXIdentifier / 非 JSON / 无 type）：落到档 2 回退。
        }

        // 档 2：kAXMainWindowAttribute 判定。
        guard let main = appElement.axWindowElement(kAXMainWindowAttribute as CFString) else {
            return false  // 主窗口不可得：保守视为主窗口，不跳过
        }
        return !CFEqual(main, window)
    }

    /// Atlas 窗口是否为「设置窗口」。
    ///
    /// 判据：AXIdentifier 为 Atlas 内部的结构化 JSON。实测（2026-06）：
    ///   - 主浏览器窗口：{"type":"main","main":{...}}
    ///   - 设置窗口：    {"type":"secondary","secondary":{"type":"settings"}}
    /// 用子串 `"secondary"` + `"settings"` 匹配，避免 JSON 解析开销与格式漂移风险。
    /// 这比标题（随网页变化）与 subrole/modal（主窗口与设置窗口相同）都稳定可靠——
    /// 设置窗口被自动居中/平铺后会反复跳动，需完全跳过它，但主窗口仍要正常居中/平铺。
    private func isAtlasSettingsWindow(_ window: AXUIElement) -> Bool {
        guard let id = window.axString("AXIdentifier" as CFString) else { return false }
        return id.contains("secondary") && id.contains("settings")
    }

    /// 手记（Journal）窗口是否为「设置窗口」。
    ///
    /// 实证（2026-06，日志 + AX 探查）：手记的设置窗口与主窗口三项硬特征完全相同，无法用常规判据区分——
    ///   - subrole：两者都是 `AXStandardWindow`（与 Atlas 同类坑）；
    ///   - AXIdentifier：两者都是 `SceneWindow`（AppKit 默认场景标识，无区分性）；
    ///   - kAXMainWindowAttribute：设置窗口聚焦时会追踪到设置窗口本身（main==候选），
    ///     故 `isSecondaryWindowOfApp` 档 2 误判为主窗口 → 屏蔽失效。
    /// 唯一稳定的区分硬特征是 **AXTitle**：主窗口标题是 app 名「手记/Journal」，
    /// 设置窗口标题是 AppKit 标准 Settings 窗口标题。
    ///
    /// 关键：本判据**同时被 handle() 主路径与 handleResize() 旁路使用**。resize 旁路刻意绕过
    /// processedPIDs 锁（见 828 行注释），手记设置窗口打开时的尺寸动画会触发 kAXResizedNotification
    /// → 走 resize 旁路 → 被强行平铺成全屏（用户报告「设置窗口被移到左上角」的根因）。两处都必须拦截。
    ///
    /// 多语言：设置窗口标题由 AppKit 在运行时按系统语言生成（不在 app bundle 字符串文件里），
    /// 是 macOS 数十年不变的固定翻译词汇。这里覆盖 Plumb 支持的语言（zh/en/es/fr/ja）+ 主流语言。
    /// 作用域收窄：仅在 bundle == com.apple.journal 时判定，避免误伤其他名为「设置」的主窗口。
    private static let journalSettingsTitles: Set<String> = [
        "设置", "设置…", "偏好设置", "偏好设置…",           // zh
        "Settings", "Settings…", "Preferences", "Preferences…",  // en
        "Configuración", "Configuración…", "Preferencias", "Preferencias…",  // es
        "Réglages", "Réglages…", "Préférences", "Préférences…",  // fr
        "設定", "設定…", "環境設定", "環境設定…",           // ja
        "Einstellungen", "Einstellungen…",              // de
        "Impostazioni", "Impostazioni…",                // it
        "Ajustes", "Ajustes…",                          // es (alt)
        "설정", "설정…",                                // ko
        "Настройки", "Настройки…"                       // ru
    ]

    private func isJournalSettingsWindow(_ window: AXUIElement) -> Bool {
        guard let title = window.axString(kAXTitleAttribute as CFString),
              !title.isEmpty
        else { return false }
        return Self.journalSettingsTitles.contains(title)
    }

    /// 判定用户当前是否按住 Option (⌥) 键——作为「手动排版」的显式信号。
    ///
    /// 用途：当用户按住 Option 拖动/分屏窗口时，Plumb 完全跳过居中与平铺，
    /// 把布局权交给用户。Option 是瞬时修饰键，松开即失效，故按事件处理时刻的
    /// 瞬时状态判定，不追踪历史。
    ///
    /// 读取时机：AXObserver 回调与防抖定时器均在主线程执行（main run loop / .main queue），
    /// NSEvent.modifierFlags 在主线程读取是可靠的。
    private func isUserHoldingOption() -> Bool {
        NSEvent.modifierFlags.contains(.option)
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
        // AXWindowNumber 是 CFNumber；通过共享扩展以 64 位安全方式读取正整数。
        // nil / 非正数视为无有效窗口编号（调用方会回退到 CFHash 作为 key）。
        return window.axPositiveInteger("AXWindowNumber" as CFString)
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
