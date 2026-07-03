import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TransientDetector
//
// 纯几何判据（非 @MainActor，便于单测）：判定窗口是否为"瞬态"窗口
//（登录窗 / 启动 splash / 二维码 / 小工具窗），供居中路径决定是否锁定 PID。
// ─────────────────────────────────────────────────────────────────────────────
enum TransientDetector {
    /// 面积比阈值：窗口面积 ÷ 最大屏 visibleFrame 面积 < 此值 → 瞬态。
    static let coverageThreshold: CGFloat = 0.5

    /// 面积比 < 阈值 → 瞬态。largestVisibleFrameArea ≤ 0 → 保守返回 false（正常锁，避免无限重试）。
    static func isTransient(size: CGSize, largestVisibleFrameArea: CGFloat) -> Bool {
        guard largestVisibleFrameArea > 0 else { return false }
        let coverage = (size.width * size.height) / largestVisibleFrameArea
        return coverage < coverageThreshold
    }
}

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
    /// 「手动排版」窗口集合：用户拖动(moved)或缩放(resized)过的窗口进入此集合，不再被自动居中/平铺，
    /// 直到下一次切 App / 切 Space 时才重新按规则排版。键格式与 centered 缓存一致："pid:windowNumber"。
    /// 新需求语义：任何手动移动/缩放都**不**立即吸附——被标记的窗口保持用户摆放的位置/尺寸，
    /// 由 handle() 主路径的 manualWindowKeys 守卫拦截；只有切 App（attachToFrontmostApp）或
    /// 切 Space（recenterObservedApp）时清掉该 PID 的标记后，窗口才会被重新处理。
    /// 清除条件：①切到该 App / 切 Space 时按 pid 前缀清理（manualWindowKeys/filter）②App 退出时
    /// 按 pid 前缀清理（appDidTerminate）③stop()。
    /// 设计取舍：仅真正的拖动/缩放才标记——切聚焦/创建(focusedChanged/created) 走 handle() 主路径，
    /// **不**经过 move/resize 旁路，故不会被误标记。Plumb 自身的居中/平铺动画产生的 moved/resized
    /// 由 service.isAnyAnimationInProgress 守卫排除，不会被误标记。
    private var manualWindowKeys: Set<String> = []
    /// Plumb 自己刚完成布局后的短暂宽限窗口。部分 app 会在 `activeAnimationKey` 清掉后才投递
    /// 由我们刚写入 AXPosition/AXSize 触发的迟到 move/resize 通知；这些通知不能被当作用户手动操作。
    private var selfLayoutGraceUntil: [String: Date] = [:]
    /// 每窗口平铺会话预算。key 复用 `key(pid:window:)`（`pid:windowNumber`）。
    ///
    /// 每次真正启动 `tileWindowElementAnimated`（含 stabilization 重触发）计数 +1；达到上限后
    /// 接受当前 frame（markCentered + processedPIDs.insert），保证任何几何结局下用户最多看到
    /// `maxTileSessionAttempts` 次动画。这是「反复平铺 / 死循环」的最终兜底：即使 app 持续拒绝
    /// 目标尺寸、即使完成谓词因边界容差反复拒绝，预算耗尽也会强制锁定，不再无限重试。
    ///
    /// 清理时机与 `manualWindowKeys` 完全一致（重激活 attach、appDidTerminate、Space 切换、stop），
    /// 均按 `pid:` 前缀过滤，预算绝不跨 app 生命周期泄漏。
    private var tileSessionAttempts: [String: Int] = [:]
    /// 每窗口平铺会话预算上限。3 次 = 首铺 + 最多 2 次稳定重试，覆盖大多数 app 的 layout 追平。
    private static let maxTileSessionAttempts: Int = 3
    private var initialCenterTimer: DispatchSourceTimer?
    private var tileStabilizeTimer: DispatchSourceTimer?
    /// 阶段 3.3：自布局宽限。默认 1.0s 太短——Numbers 等文档 app 会在 `activeAnimationKey` 清掉
    /// 之后仍迟到地自 resize（加载完成后一次性自设 frame），把窗口误标「手动」冻住。
    /// 改为：平铺会话进行中（动画/稳定重试期间）+ 会话结束后再延伸 `postSessionGraceInterval`
    ///（1.8s）内的 move/resize 都不标 manual。会话锁定/预算耗尽时调用
    /// `extendSelfLayoutGraceAfterSession` 写入延伸截止时间。
    private static let selfLayoutGraceInterval: TimeInterval = 1.0
    private static let postSessionGraceInterval: TimeInterval = 1.8
    /// document-chooser app（Numbers/Pages 等）会话后的延长宽限：默认 1.8s 短于这些 app
    /// 慢载入的迟到自 resize（加载完成后一次性自设 frame），可能把坏形态误标 manual 永久冻结。
    /// 对 document-chooser app 延长到 4.0s 覆盖其迟到自 resize。非 document-chooser app 仍用 1.8s。
    private static let documentChooserPostSessionGraceInterval: TimeInterval = 4.0
    /// 阶段 3.1：document-chooser 稳定门进行中的 PID 集合。用于抑制 `startInitialCenteringRetries`
    /// 在采样等待期间重复进入 `applyLayout`（否则每次重试都会启动一个新的采样循环）。
    /// 清理时机同 `processedPIDs`（attach 重激活、appDidTerminate、Space 切换、stop）。
    private var documentStableGatePIDs: Set<pid_t> = []
    /// 阶段 3.1 稳定门 + 阶段 3.2 完成后单次校正共用的可取消定时器（受 `abortActiveAnimations`
    /// 之外的前台守卫保护，按 PID 在生命周期点清空）。
    private var documentStableTimer: DispatchSourceTimer?
    private static let documentStableSampleIntervalMs: Int = 400
    private static let documentStableMaxSamples: Int = 6     // 400ms × 6 ≈ 2.4s
    private static let documentStableTolerancePx: CGFloat = 2
    /// 阶段 3.2：完成后单次校正定时器。完成回调发现读回尺寸膨胀（app 迟到的自 resize）时，
    /// 延迟 ~500ms 按「先 size 后 position」重写一次精确目标，再走判定与预算锁定，替代加载中
    /// 的多轮拉锯。一次性、可取消、带前台守卫；每个窗口至多一次（受 `tileSessionAttempts` 预算保护）。
    private var postCompletionCorrectionTimer: DispatchSourceTimer?
    private static let postCompletionCorrectionDelayMs: Int = 500

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
        manualWindowKeys.removeAll()
        selfLayoutGraceUntil.removeAll()
        tileSessionAttempts.removeAll()
        documentStableGatePIDs.removeAll()
        documentStableTimer?.cancel()
        documentStableTimer = nil
        postCompletionCorrectionTimer?.cancel()
        postCompletionCorrectionTimer = nil
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
        // 切 Space 清除该 PID 的「手动排版」标记：新需求要求用户手动移动/缩放的窗口在切 Space 时
        // 重新按规则排版（与切 App 同语义）。只有清掉 manualWindowKeys，后续 handle() / retry 才能
        // 重新处理这些窗口。
        let manualCleared = manualWindowKeys.filter { $0.hasPrefix(prefix) }.count
        if manualCleared > 0 {
            DiagnosticLog.debug("spaceDidChange: cleared \(manualCleared) manual-layout window(s) for pid=\(pid)")
            manualWindowKeys = manualWindowKeys.filter { !$0.hasPrefix(prefix) }
        }
        selfLayoutGraceUntil = selfLayoutGraceUntil.filter { !$0.key.hasPrefix(prefix) }
        tileSessionAttempts = tileSessionAttempts.filter { !$0.key.hasPrefix(prefix) }
        processedPIDs.remove(pid)
        endDocumentStableGate(pid: pid)

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
            // 所有 App 通用的二级窗口屏蔽：切 Space 回桌面时同样不居中其弹窗/设置/下载窗口
            //（与 handle 路径一致；候选非主窗口 → 跳过，保持弹出位置）。
            if isSecondaryWindowOfApp(windowElement, appElement: appElement, bundleIdentifier: bundleID) {
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
        manualWindowKeys = manualWindowKeys.filter { !$0.hasPrefix(prefix) }
        selfLayoutGraceUntil = selfLayoutGraceUntil.filter { !$0.key.hasPrefix(prefix) }
        tileSessionAttempts = tileSessionAttempts.filter { !$0.key.hasPrefix(prefix) }
        processedPIDs.remove(pid)
        endDocumentStableGate(pid: pid)
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
        reattachTimer?.cancel()
        reattachTimer = nil
        // 同步取消上一个 app 的 document-stable-gate 采样定时器（阶段 3.1），避免切走后 zombie
        // 定时器在后台继续对非前台 app 的窗口采样/平铺。
        documentStableTimer?.cancel()
        documentStableTimer = nil
        documentStableGatePIDs.removeAll()
        // 同步取消阶段 3.2 的完成后校正定时器（同属 per-app 生命周期）。
        postCompletionCorrectionTimer?.cancel()
        postCompletionCorrectionTimer = nil
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
        // ⚠️ 「手动排版」标记的清除已上移至 reactivatedPrefix 清理段（与居中缓存同处）：
        // 新需求要求用户手动移动/缩放的窗口在下一次切 App / 切 Space 时被重新按规则排版，
        // 故不再跨激活周期保留 manualWindowKeys。
        //（旧实现刻意保留 manual 标记；该需求已变更。）
        // Bug #3: 同步清除 per-PID 标记，让 app 重新激活后能重新居中其主窗口。
        processedPIDs.remove(pid)
        endDocumentStableGate(pid: pid)
        // 同步清除该 PID 的「手动排版」标记：用户手动移动/缩放过的窗口在新需求下应只在
        // 下一次切 App / 切 Space 时被重新按规则排版——故切回该 App 时把它的 manualWindowKeys
        // 一并清掉，使重新激活后的 handle() / startInitialCenteringRetries 能正常处理这些窗口。
        let manualRemoved = manualWindowKeys.filter { $0.hasPrefix(reactivatedPrefix) }.count
        if manualRemoved > 0 {
            DiagnosticLog.debug("attach: cleared \(manualRemoved) manual-layout window(s) for reactivated pid=\(pid)")
            manualWindowKeys = manualWindowKeys.filter { !$0.hasPrefix(reactivatedPrefix) }
        }
        selfLayoutGraceUntil = selfLayoutGraceUntil.filter { !$0.key.hasPrefix(reactivatedPrefix) }
        tileSessionAttempts = tileSessionAttempts.filter { !$0.key.hasPrefix(reactivatedPrefix) }
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
        // Dock 栏"的根因之一）。改为完全交给 startInitialCenteringRetries：它在 0.45s 后首次触发，
        // 等同于用户"动画结束后点立即居中"的效果——此时窗口已稳定，走的是与手动按钮完全相同、
        // 已被验证正确的居中路径。需求进一步要求：首次处理严格发生在 0.45s 之后，此前不得做任何
        // markCentered / processedPIDs 锁定，故此处不再调用任何立即校验/居中。
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

    /// 注册窗口通知到 observer，返回是否全部成功。
    /// Electron 应用冷启动时 AX 未就绪，AXObserverAddNotification 会返回 cannotComplete（-25204），
    /// 此时 observer 形同虚设，需由 startReattachLoop 周期性重试。
    @discardableResult
    private func registerNotifications(on observer: AXObserver, appElement: AXUIElement, pid: pid_t) -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let r1 = AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        let r2 = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        let r3 = AXObserverAddNotification(observer, appElement, kAXResizedNotification as CFString, refcon)
        // moved/resized 通知用于「手动排版」标记：用户拖动产生 moved、缩放产生 resized，两条都要拦，
        // 标记对应窗口为手动后由 handle() 主路径守卫拦截，直到下一次切 App / 切 Space 才重新排版。
        let r4 = AXObserverAddNotification(observer, appElement, kAXMovedNotification as CFString, refcon)
        let success = r1 == .success && r2 == .success && r3 == .success && r4 == .success
        DiagnosticLog.debug("attach: observer added; focusedChanged=\(r1.rawValue) windowCreated=\(r2.rawValue) resized=\(r3.rawValue) moved=\(r4.rawValue) success=\(success)")
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
        //（PID 已被锁）在用户缩放后，事件会被 PID 锁直接 short-circuit，到不了「标记手动」旁路。
        // handleResize 内部自带 frontmost / stale / 真实窗口 / 自身动画守卫，仅标记 manualWindowKeys。
        if notification == (kAXResizedNotification as String) {
            return handleResize(element: element, forcedPID: forcedPID)
        }

        // moved 事件走独立旁路（与 resize 同构）：用户拖动 → 标记该窗口为「手动」，不再立即吸附。
        // 必须在 processedPIDs 锁之前分流，否则已平铺窗口（PID 已锁）的 moved 永远到不了旁路。
        if notification == (kAXMovedNotification as String) {
            return handleMove(element: element, forcedPID: forcedPID)
        }

        let appElement = AXUIElementCreateApplication(pid)
        guard let windowElement = centerCandidateWindow(for: appElement, hintedElement: element) else {
            DiagnosticLog.debug("handle[\(notification)]: no centerable candidate window")
            return false
        }
        let bundleIdentifier = frontmostApp.bundleIdentifier

        // Bug #3: 本激活周期内此 PID 的主窗口已完成居中/平铺 → 默认跳过后续窗口事件
        //（二级窗口、对话框、标签页弹层等）。例外：Pages/Numbers/Office 这类文档 App
        // 同一 PID 可连续创建多个真实文档窗口，新窗口应各自平铺；二级窗口仍由下方 shield 拦截。
        if processedPIDs.contains(pid) {
            if shouldProcessAdditionalDocumentWindow(
                windowElement,
                pid: pid,
                bundleIdentifier: bundleIdentifier
            ) {
                DiagnosticLog.debug("handle[\(notification)]: PID \(pid) already processed, but new document window should tile")
            } else {
                DiagnosticLog.debug("handle[\(notification)]: PID \(pid) already processed this cycle, skip (suppress secondary window)")
                return false
            }
        }

        // 手动窗口守卫：已标记「手动」的窗口在聚焦/创建事件时一律跳过（不居中、不平铺），
        // 保持用户手动摆放的位置。必须放在候选窗口选出之后（需要 windowNumber 构造 key）、
        // 排版决策之前；且位于 processedPIDs 锁之后（与锁同向，先按周期锁过滤再按手动过滤）。
        // 标记由 handleMove/handleResize 在用户拖动/缩放时写入；清除由 attachToFrontmostApp /
        // recenterObservedApp（切 App / 切 Space）按 pid 前缀完成——这是「手动窗口只在下次切 App/Space
        // 时重新排版」新需求的实现位置。
        if let key = key(pid: pid, window: windowElement), manualWindowKeys.contains(key) {
            DiagnosticLog.debug("handle[\(notification)]: manual window — keep manual, skip pid=\(pid) key=\(key)")
            return false
        }

        // ChatGPT Atlas（com.openai.atlas）特例：仅其「设置窗口」被自动居中/平铺后会反复跳动
        //（窗口自带定位与 Plumb 的居中/平铺互相打架），故对设置窗口完全跳过（不居中也不平铺）。
        // 关键收窄：只排除设置窗口，主浏览器窗口仍正常走居中/平铺（否则 Atlas 主窗口无法平铺）。
        // 设置窗口识别：AXIdentifier 为结构化 JSON，主窗口是 {"type":"main",...}，
        // 设置窗口是 {"type":"secondary","secondary":{"type":"settings"}}——用子串匹配稳定区分
        //（标题随网页变化不可靠，subrole/modal 两者相同无法区分）。
        // 纯早退：不 markCentered、不锁 processedPIDs，不污染共享缓存语义。
        if isChatGPTAtlasBundle(bundleIdentifier),
           isAtlasSettingsWindow(windowElement)
        {
            DiagnosticLog.debug("handle[\(notification)]: ChatGPT Atlas settings window — skip (jitter fix) pid=\(pid)")
            return false
        }

        // 手记（Journal）设置窗口特例：设置窗口与主窗口 subrole/AXIdentifier/kAXMainWindow 三项硬特征
        // 完全相同（详见 isJournalSettingsWindow 注释），常规判据全部失效，只能靠 AXTitle 区分。
        // 必须在主路径此处拦截，否则会被居中/平铺。纯早退：不 markCentered、不锁 processedPIDs。
        if isJournalBundle(bundleIdentifier),
           isJournalSettingsWindow(windowElement)
        {
            DiagnosticLog.debug("handle[\(notification)]: Journal settings window — skip (no center, no tile) pid=\(pid)")
            return false
        }

        // 所有 App 通用：二级窗口屏蔽。任何 App 的二级窗口（设置/下载/弹窗/Get Info/扩展页 等）
        // 常报告 AXStandardWindow subrole，会绕过 subrole 过滤被误居中/误平铺。候选窗口若判定为
        // 该 App 的非主窗口即完全跳过——不平铺、不居中、不 markCentered、不锁 processedPIDs，
        // 保持其弹出位置；主窗口不受影响，正常居中/平铺。
        // 关键：必须放在 `if shouldTile` 分流**之前**——否则居中分支（不在平铺白名单）无保护，
        // 弹窗仍会被居中。补的是「PID 锁被清除（Space 切换/重新激活）或二级窗口先于主窗口到达」
        // 的时空档——其余情况下 processedPIDs 锁已拦截。
        //
        // isSecondaryWindowOfApp 内部对 Chromium 内核浏览器优先用 AXIdentifier 的 type 字段
        //（"main"/"secondary"）判定——kAXMainWindowAttribute 在二级窗口聚焦时会追踪聚焦窗，
        // 把扩展设置页误报成主窗口（用户报告的「扩展程序设置界面被居中」根因），靠它判定会漏；
        // 访达用 AXIdentifier 字面值（"FinderWindow" 为主窗口）；其它 App 用 kAXMainWindowAttribute
        // 回退（候选 ≠ 主窗口即视为二级窗口）。
        if isSecondaryWindowOfApp(windowElement, appElement: appElement, bundleIdentifier: bundleIdentifier)
        {
            DiagnosticLog.debug("handle[\(notification)]: secondary window — skip (no tile, no center) pid=\(pid)")
            return false
        }

        return applyLayout(
            notification: notification,
            windowElement: windowElement,
            pid: pid,
            appElement: appElement,
            bundleIdentifier: bundleIdentifier
        )
    }

    /// 排版决策（平铺 / 居中）的可复用入口。
    ///
    /// 原 handle() 末尾的「读 tilingSettings → shouldTile 分流 → 文档选择器/DMG/tilePendingWindows/
    /// centerWindowElementAnimated + markCentered + processedPIDs.insert」整段，抽成独立方法：
    /// - handle() 主路径（聚焦/创建事件、initial-retry）在通过所有守卫后调用本方法做首次排版。
    ///
    /// 语义不变：把内联代码原样挪进方法，保证「吸附恢复」与「首次排版」逻辑完全一致。
    @discardableResult
    private func applyLayout(
        notification: String,
        windowElement: AXUIElement,
        pid: pid_t,
        appElement: AXUIElement,
        bundleIdentifier: String?
    ) -> Bool {
        let tilingSettings = tilingSettingsStore.load()
        let shouldTile = tilingSettings.shouldTile(bundleIdentifier: bundleIdentifier)
        let shouldCenter = tilingSettings.shouldCenter(bundleIdentifier: bundleIdentifier)
        let centerAfterTile = shouldTile && shouldCenter
        // per-app 间距：该 app 单独设置过 → 用其四向 insets；否则回退全局 edgeInsets。
        let effectiveInsets = tilingSettings.effectiveInsets(for: bundleIdentifier)
        if shouldTile {
            // 每个"激活周期"内同一窗口只平铺一次：首次平铺后若再收到聚焦/创建通知，
            // 直接跳过，避免重试与重复事件反复触发"先居中再放大"动画，导致窗口被来回
            // 拉扯、最终回弹到小尺寸（这是"指定 App 不会自动平铺放大"的根因）。
            if hasCentered(windowElement: windowElement, pid: pid) {
                DiagnosticLog.debug("handle[\(notification)]: already tiled pid=\(pid)")
                return false
            }

            // 单飞：当前已有任何动画在进行中（平铺或居中）→ 直接返回，不启动新动画。
            // 目的：消灭 .document / .undetermined 分类摆动导致的 center/tile 并发对抗——
            // 一个动画还没完成时若再次进入本分支，旧实现会并发发起第二个动画，两个写入流
            // 互相覆盖是「窗口被来回拉扯」的另一根因。return false 让重试/事件循环稍后再来。
            if service.isAnyAnimationInProgress {
                DiagnosticLog.debug("handle[\(notification)]: animation in progress — defer tiling pid=\(pid)")
                return false
            }

            // 浏览器/访达二级窗口屏蔽：已在 handle() 主路径 if shouldTile 分流前统一拦截（同时保护居中+平铺），
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
            // 阶段 3.1：document-chooser app 的 .document 窗口（新建未保存文档）在加载完成前会
            // 反复自设 frame（Numbers 实测：内容加载完一次性把高度撑到 visibleFrame）。若在它仍在
            // 抖动时启动平铺，会陷入「铺→app 自设 frame 破坏→重铺」的对抗。改为先采样等待 frame
            // 连续两次一致（±2px）再启动平铺，最多等 ~2.4s 后无条件开始。
            var documentStableGateActive = false
            if tilingSettings.isDocumentChooserApp(bundleIdentifier: bundleIdentifier),
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
                    // 标记需要稳定门：等加载完成、frame 停止抖动后再平铺（阶段 3.1）。
                    documentStableGateActive = true
                    DiagnosticLog.debug("handle[\(notification)]: document window (no kAXDocument but has content) — fall through to tile (via stable gate) pid=\(pid)")
                }
            }
            // DMG 安装窗口感知：访达打开 .dmg 后弹出的「挂载内容窗口」（拖拽安装界面）。
            // 该窗口标题 == DMG 卷名；命中已挂载 DMG 卷名集合 → 只居中、不平铺。
            // 复用文档选择器分支的不变量：不 markCentered、不锁 processedPIDs，
            // 使 DMG 窗口关闭后同一 Finder 里打开的普通文件夹窗口仍能被平铺。
            // 不命中（非 Finder、非 DMG 标题、或 dmgMonitor 未注入）→ 落入下方正常平铺。
            if let dmgMonitor,
               isFinderBundle(bundleIdentifier),
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
            // 阶段 3.1：document-chooser .document 窗口先等 frame 稳定再平铺（避免与 app 自设 frame 对抗）。
            // 稳定门异步驱动采样 + 平铺；此处 return false 让 startInitialCenteringRetries 不停，
            // 但稳定门进行中（documentStableGatePIDs 含 pid）会在下方守卫处短路，不会重复进入。
            if documentStableGateActive {
                if documentStableGatePIDs.contains(pid) {
                    DiagnosticLog.debug("handle[\(notification)]: document stable gate already sampling pid=\(pid) — skip re-entry")
                    return false
                }
                startDocumentStableGate(
                    pid: pid,
                    appElement: appElement,
                    primaryWindow: windowElement,
                    insets: effectiveInsets,
                    bundleIdentifier: bundleIdentifier,
                    centerAfterTile: centerAfterTile
                )
                return false
            }
            let tiled = performTileAndLock(
                notification: notification,
                pid: pid,
                appElement: appElement,
                primaryWindow: windowElement,
                insets: effectiveInsets,
                bundleIdentifier: bundleIdentifier,
                centerAfterTile: centerAfterTile
            )
            return tiled
        }

        // 居中 allow-list：未开启或不在列表内（且列表非空）则跳过自动居中。
        if !shouldCenter {
            DiagnosticLog.debug("handle[\(notification)]: center not allowed for pid=\(pid) bundle=\(bundleIdentifier ?? "?")")
            return false
        }

        if hasCentered(windowElement: windowElement, pid: pid) {
            DiagnosticLog.debug("handle[\(notification)]: already centered pid=\(pid)")
            return false
        }

        do {
            try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement)
            // 瞬态窗（登录/splash/二维码/小工具窗）：居中它但【不】锁 PID、不 markCentered，
            // 让 startInitialCenteringRetries 继续接力，直到真正主窗口到达并被居中锁定。
            // 修复 WeChat 等「先登录窗后主窗口」app：登录窗居中即锁死 PID，导致 3.5s 后到达的
            // 聊天主窗口被 processedPIDs 守卫永久跳过（「第一次打开不居中」根因）。
            // 与平铺路径 didWindowActuallyTile=false（启动期小窗）/ document-chooser gallery
            // / DMG installer 分支的「不锁」不变量同构。
            // 返回 false 让 retry 循环不停（仅 handle 返回 true 才停），与平铺小窗分支 return false 一致。
            if looksLikeTransientWindow(windowElement) {
                DiagnosticLog.debug("handle[\(notification)]: centered transient window — keep PID unlocked for retry pid=\(pid)")
                return false
            }
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
        // 失败后每 1.0s 重试一次，最多 10 次（含首次）。成功处理后立即停止重试。
        timer.schedule(deadline: .now() + 0.45, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1

            // If user has switched away, stop retrying.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
                return
            }

            // handle 返回 true 表示该窗口已完成居中/平铺（含瞬态/启动小窗等不锁 PID 的情形下返回
            // false 继续重试）。成功处理后停止重试。
            let didProcess = self.handle(notification: "initial-retry", element: appElement, forcedPID: pid)
            if didProcess {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
                return
            }

            // 固定上限 10 次（首次 0.45s + 9 次重试 ≈ 9.45s）。
            if attempts >= 10 {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
            }
        }
        initialCenterTimer = timer
        timer.resume()
    }

    /// 阶段 3.2：完成后单次校正。延迟 `postCompletionCorrectionDelayMs`（500ms）后重触发一次
    /// `tileWindowElementAnimated`（其内部 emitFinalAnchor 会按「先 size 后 position」写精确目标 /
    /// 妥协形态），随后走完成判定与预算锁定。延迟给文档 app 迟到的自 resize 留出 settle 时间，
    /// 替代加载中的多轮拉锯。一次性、可取消、带前台守卫；预算耗尽则不再校正（直接锁定）。
    private func startPostCompletionCorrection(
        pid: pid_t,
        appElement: AXUIElement,
        windowElement: AXUIElement,
        insets: TileInsets,
        centerAfterTile: Bool
    ) {
        postCompletionCorrectionTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Self.postCompletionCorrectionDelayMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.postCompletionCorrectionTimer = nil

            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                DiagnosticLog.debug("post-completion-correction: pid=\(pid) no longer frontmost, cancel")
                return
            }

            // 已达标：直接锁定。
            if self.isWindowNearTiledTarget(windowElement, pid: pid, appElement: appElement, insets: insets) {
                self.finishTileSession(
                    windowElement: windowElement,
                    pid: pid,
                    appElement: appElement,
                    centerAfterTile: centerAfterTile,
                    reason: "post-completion-correction reached target after delay"
                )
                DiagnosticLog.debug("post-completion-correction: reached target after delay, lock pid=\(pid)")
                return
            }

            // 预算耗尽：接受当前 frame 锁定。
            if self.isTileBudgetExhausted(windowElement: windowElement, pid: pid) {
                self.forceLockOnBudgetExhaustion(
                    windowElement: windowElement,
                    pid: pid,
                    appElement: appElement,
                    insets: insets,
                    centerAfterTile: centerAfterTile,
                    reason: "post-completion-correction budget exhausted"
                )
                return
            }

            // 仍有预算：重触发一次精确目标平铺（消耗预算），其完成回调再次走判定/预算/校正循环。
            self.recordTileAttempt(windowElement: windowElement, pid: pid)
            _ = try? self.service.tileWindowElementAnimated(
                windowElement, pid: pid, appElement: appElement, insets: insets
            ) { [weak self] in
                guard let self else { return }
                self.recordSelfLayoutGrace(windowElement: windowElement, pid: pid, reason: "post-completion-correction completion")
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if self.didWindowActuallyTile(windowElement, pid: pid, insets: insets) {
                    self.startTileStabilizationRetries(
                        pid: pid,
                        appElement: appElement,
                        windowElement: windowElement,
                        insets: insets,
                        centerAfterTile: centerAfterTile
                    )
                    DiagnosticLog.debug("post-completion-correction: reached target, lock pid=\(pid)")
                } else {
                    // 校正后仍未达标：交给稳定重试接力（其内部也有预算兜底）。
                    self.startTileStabilizationRetries(
                        pid: pid,
                        appElement: appElement,
                        windowElement: windowElement,
                        insets: insets,
                        centerAfterTile: centerAfterTile
                    )
                    DiagnosticLog.debug("post-completion-correction: still not at target, defer to stabilization pid=\(pid)")
                }
            }
        }
        postCompletionCorrectionTimer = timer
        timer.resume()
    }

    /// 阶段 3.1：document-chooser .document 窗口的「等稳再铺」采样门。
    ///
    /// 每 `documentStableSampleIntervalMs`（400ms）采样一次窗口 frame，连续两次一致（±2px）才
    /// 启动平铺；最多采样 `documentStableMaxSamples`（6 ≈ 2.4s）次后无条件开始。定时器可取消、
    /// 带前台守卫，与「attach 后 0.45s 再首铺」的设计哲学一致，直接实现「一次就平铺完成」。
    /// 采样期间通过 `documentStableGatePIDs` 抑制 `startInitialCenteringRetries` 的重复进入。
    private func startDocumentStableGate(
        pid: pid_t,
        appElement: AXUIElement,
        primaryWindow: AXUIElement,
        insets: TileInsets,
        bundleIdentifier: String?,
        centerAfterTile: Bool
    ) {
        documentStableGatePIDs.insert(pid)
        documentStableTimer?.cancel()
        var lastFrame: CGRect?
        var samples = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(Self.documentStableSampleIntervalMs),
                       repeating: .milliseconds(Self.documentStableSampleIntervalMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            samples += 1

            // 前台守卫：切走 app 即停采样、清门标记。
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.endDocumentStableGate(pid: pid)
                DiagnosticLog.debug("document-stable-gate: pid=\(pid) no longer frontmost, cancel")
                return
            }

            let current = self.readGlobalFrame(of: primaryWindow, pid: pid)
            let stable: Bool
            if let current, let lastFrame {
                stable = abs(current.minX - lastFrame.minX) <= Self.documentStableTolerancePx &&
                    abs(current.minY - lastFrame.minY) <= Self.documentStableTolerancePx &&
                    abs(current.width - lastFrame.width) <= Self.documentStableTolerancePx &&
                    abs(current.height - lastFrame.height) <= Self.documentStableTolerancePx
            } else {
                stable = false
            }
            DiagnosticLog.debug("document-stable-gate: sample \(samples)/\(Self.documentStableMaxSamples) pid=\(pid) frame=\(current.map { String(describing: $0) } ?? "nil") stable=\(stable)")

            if stable || samples >= Self.documentStableMaxSamples {
                self.endDocumentStableGate(pid: pid)
                // 预算守卫：等稳期间若预算已被耗尽（理论上不会，但防御），直接接受当前 frame 锁定。
                if self.isTileBudgetExhausted(windowElement: primaryWindow, pid: pid) {
                    self.forceLockOnBudgetExhaustion(
                        windowElement: primaryWindow,
                        pid: pid,
                        appElement: appElement,
                        insets: insets,
                        centerAfterTile: centerAfterTile,
                        reason: "document-stable-gate budget exhausted"
                    )
                    return
                }
                let _ = self.performTileAndLock(
                    notification: "document-stable-gate",
                    pid: pid,
                    appElement: appElement,
                    primaryWindow: primaryWindow,
                    insets: insets,
                    bundleIdentifier: bundleIdentifier,
                    centerAfterTile: centerAfterTile
                )
            } else {
                lastFrame = current
            }
        }
        documentStableTimer = timer
        timer.resume()
    }

    private func endDocumentStableGate(pid: pid_t) {
        documentStableGatePIDs.remove(pid)
        documentStableTimer?.cancel()
        documentStableTimer = nil
    }

    /// 共用的「平铺 + 锁定」执行体：被 `applyLayout` 同步路径与 document-stable-gate 复用。
    /// 返回 true 表示已平铺并锁定（终止重试），false 表示未铺成/动画异步返回（继续重试）。
    @discardableResult
    private func performTileAndLock(
        notification: String,
        pid: pid_t,
        appElement: AXUIElement,
        primaryWindow: AXUIElement,
        insets: TileInsets,
        bundleIdentifier: String?,
        centerAfterTile: Bool
    ) -> Bool {
        guard let tiledWindow = tilePendingWindows(
            pid: pid,
            appElement: appElement,
            primaryWindow: primaryWindow,
            insets: insets,
            bundleIdentifier: bundleIdentifier,
            centerAfterTile: centerAfterTile
        ) else {
            DiagnosticLog.debug("handle[\(notification)]: tiling enabled but no window tiled")
            return false
        }
        // 平铺未真正放大（启动期小窗 / 不可调大小窗口）：不锁 PID、不 markCentered，
        // 让 startInitialCenteringRetries 继续接力，直到真正主窗口到达并被成功平铺。
        if didWindowActuallyTile(tiledWindow, pid: pid, insets: insets) {
            startTileStabilizationRetries(
                pid: pid,
                appElement: appElement,
                windowElement: tiledWindow,
                insets: insets,
                centerAfterTile: centerAfterTile
            )
            DiagnosticLog.debug("handle[\(notification)]: tiled pid=\(pid)")
            return true
        }
        DiagnosticLog.debug("handle[\(notification)]: tile did not actually enlarge window — keep PID unlocked for retry pid=\(pid)")
        return false
    }

    /// 读取窗口的原始 AX frame（position + size）。仅供稳定门抖动检测用——连续两次采样取
    /// 同一坐标空间，相对比较（±2px）有效，无需绝对坐标空间探测（绝对精度由平铺路径保证）。
    private func readGlobalFrame(of windowElement: AXUIElement, pid: pid_t) -> CGRect? {
        guard
            let pos = windowElement.axPoint(kAXPositionAttribute as CFString),
            let size = windowElement.axSize(kAXSizeAttribute as CFString)
        else { return nil }
        _ = pid
        return CGRect(origin: pos, size: size)
    }

    private func startTileStabilizationRetries(
        pid: pid_t,
        appElement: AXUIElement,
        windowElement: AXUIElement,
        insets: TileInsets,
        centerAfterTile: Bool
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
            if self.isWindowNearTiledTarget(windowElement, pid: pid, appElement: appElement, insets: insets) {
                self.finishTileSession(
                    windowElement: windowElement,
                    pid: pid,
                    appElement: appElement,
                    centerAfterTile: centerAfterTile,
                    reason: "tile stabilization reached target"
                )
                DiagnosticLog.debug("tile stabilization: reached target and locked pid=\(pid)")
                self.tileStabilizeTimer?.cancel()
                self.tileStabilizeTimer = nil
                return
            }

            // 每窗口平铺会话预算兜底：达到上限后接受当前 frame 并锁定，停止无限重试。
            // （Phase 1.3：稳定重试消耗同一预算。）
            if !self.canStartTileAttempt(windowElement: windowElement, pid: pid) {
                self.forceLockOnBudgetExhaustion(
                    windowElement: windowElement, pid: pid, appElement: appElement, insets: insets,
                    centerAfterTile: centerAfterTile,
                    reason: "stabilization retries exhausted"
                )
                return
            }

            self.recordTileAttempt(windowElement: windowElement, pid: pid)
            _ = try? self.service.tileWindowElementAnimated(
                windowElement,
                pid: pid,
                appElement: appElement,
                insets: insets
            )

            if attempts >= 5 {
                self.tileStabilizeTimer?.cancel()
                self.tileStabilizeTimer = nil
            }
        }
        tileStabilizeTimer = timer
        timer.resume()
    }

    private func finishTileSession(
        windowElement: AXUIElement,
        pid: pid_t,
        appElement: AXUIElement,
        centerAfterTile: Bool,
        reason: String
    ) {
        let lock: () -> Void = { [weak self] in
            guard let self else { return }
            self.markCentered(windowElement: windowElement, pid: pid)
            self.processedPIDs.insert(pid)
            self.initialCenterTimer?.cancel()
            self.initialCenterTimer = nil
            self.extendSelfLayoutGraceAfterSession(windowElement: windowElement, pid: pid)
            DiagnosticLog.debug("tile-session: locked pid=\(pid) reason=\(reason) centerAfterTile=\(centerAfterTile)")
        }

        guard centerAfterTile else {
            lock()
            return
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            DiagnosticLog.debug("tile-session: skip center-after-tile, pid=\(pid) no longer frontmost")
            return
        }

        recordSelfLayoutGrace(windowElement: windowElement, pid: pid, reason: "center-after-tile handoff")
        do {
            try service.centerWindowElementAnimated(windowElement, pid: pid, appElement: appElement) { [weak self] in
                guard let self else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                self.recordSelfLayoutGrace(windowElement: windowElement, pid: pid, reason: "center-after-tile completion")
                lock()
            }
            DiagnosticLog.debug("tile-session: center-after-tile scheduled pid=\(pid) reason=\(reason)")
        } catch {
            DiagnosticLog.debug("tile-session: center-after-tile failed pid=\(pid) error=\(error) — locking tiled frame")
            lock()
        }
    }

    /// 处理 `kAXResizedNotification`：用户缩放窗口 → 标记「手动」，不再立即重铺。
    ///
    /// 新需求：任何手动移动/缩放都不立即吸附（不再安排 resizeRetileTimer、不再因 resize 立即平铺
    /// 或居中）；被标记的窗口保持用户摆放的尺寸，直到下一次切 App / 切 Space 时由
    /// attachToFrontmostApp / recenterObservedApp 清掉该 PID 的 manualWindowKeys 后才会被重新排版。
    ///
    /// 关键守卫：Plumb 自身的平铺动画（Phase-B 写尺寸）也会触发 kAXResizedNotification 回到本旁路。
    /// 必须用 `service.isAnyAnimationInProgress` 排除——否则自己的平铺会把窗口误标记为「手动」，
    /// 导致切 App/Space 后该窗口永远不再被平铺。
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
        // resize 通知的 element 应是窗口本身；校验 role == AXWindow，排除 dialog/floating 等辅助窗口。
        // 直接复用 isMovableNonAuxiliaryWindow 的「真实窗口 + 非辅助类型」判定（不强制 AXStandardWindow，
        // 因部分 app 主窗口 subrole 缺失）。
        guard isMovableNonAuxiliaryWindow(element) else {
            DiagnosticLog.debug("handle[resize]: element not a movable non-auxiliary window, skip")
            return false
        }
        // 排除 Plumb 自身平铺动画产生的 resize：进行中的动画不视作用户手势，不标记手动。
        guard !service.isAnyAnimationInProgress else {
            DiagnosticLog.debug("handle[resize]: animation in progress (self-tile) — ignore, no manual mark")
            return false
        }
        if isWithinSelfLayoutGrace(windowElement: element, pid: pid) {
            DiagnosticLog.debug("handle[resize]: self-layout grace — ignore, no manual mark pid=\(pid)")
            return false
        }

        // 标记该窗口为「手动」：用户缩放后保持其尺寸，直到下次切 App / 切 Space 才重新排版。
        if let manualKey = key(pid: pid, window: element) {
            manualWindowKeys.insert(manualKey)
            DiagnosticLog.debug("handle[resize]: mark window manual key=\(manualKey) pid=\(pid)")
        }
        return false
    }

    /// moved 通知旁路：用户拖动窗口 → 标记「手动」，不再立即吸附。
    ///
    /// 与 `handleResize` 同构的独立旁路（绕过 processedPIDs 锁——moved 持续触发，不能锁）。
    /// 新需求：任何手动移动都不立即吸附——删除「不按 Option 拖动则立即 applyLayout 归位」的逻辑，
    /// 改为只要是通过前台 / stale / 真实窗口校验的 moved，就标记该窗口为「手动」（写入 manualWindowKeys），
    /// 由 handle() 主路径的手动窗口守卫拦截，直到下一次切 App / 切 Space 时清掉该 PID 的标记后才重新排版。
    /// Option 修饰键不再影响语义。
    ///
    /// 仅真正的拖动才标记——切聚焦(focusedChanged) 走 handle() 主路径，**不**经过本旁路，
    /// 故不会误标记（符合「仅真正拖动/改尺寸才标记」的设计决策）。
    ///
    /// 关键守卫：Plumb 自身的平铺/居中动画（Phase-A 写 AXPosition）也会触发 kAXMovedNotification
    /// 回到本旁路。必须用 `service.isAnyAnimationInProgress` 排除——否则自己的动画会把窗口误标记
    /// 为「手动」，导致切 App/Space 后该窗口永远不再被居中/平铺。
    @discardableResult
    private func handleMove(element: AXUIElement, forcedPID: pid_t? = nil) -> Bool {
        // pid 已由 handle() 入口解析过；这里仅做必要的合法性确认。
        guard let pid = forcedPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            DiagnosticLog.debug("handle[move]: cannot resolve pid, skip")
            return false
        }
        // 仅前台 app：与 handle() / handleResize() 一致，避免对后台窗口做任何写操作。
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            DiagnosticLog.debug("handle[move]: frontmost != pid \(pid), skip")
            return false
        }
        // stale observer 守卫：与 handle() 一致。
        if let observedPID, observedPID != pid {
            DiagnosticLog.debug("handle[move]: stale — observedPID=\(observedPID) pid=\(pid), skip")
            return false
        }
        // moved 通知的 element 应是窗口本身；校验 role == AXWindow，排除非窗口元素。
        guard isMovableNonAuxiliaryWindow(element) else {
            DiagnosticLog.debug("handle[move]: element not a movable non-auxiliary window, skip")
            return false
        }
        // 排除 Plumb 自身居中/平铺动画产生的 moved：进行中的动画不视作用户手势，不标记手动。
        guard !service.isAnyAnimationInProgress else {
            DiagnosticLog.debug("handle[move]: animation in progress (self-animated) — ignore, no manual mark")
            return false
        }
        if isWithinSelfLayoutGrace(windowElement: element, pid: pid) {
            DiagnosticLog.debug("handle[move]: self-layout grace — ignore, no manual mark pid=\(pid)")
            return false
        }

        // 标记该窗口为「手动」：用户拖动后保持其位置，直到下次切 App / 切 Space 才重新排版。
        if let moveKey = key(pid: pid, window: element) {
            manualWindowKeys.insert(moveKey)
            DiagnosticLog.debug("handle[move]: mark window manual key=\(moveKey) pid=\(pid)")
        }
        return false
    }

    /// 窗口当前 frame 是否已完整匹配平铺目标（用于停止平铺稳定重试）。
    ///
    /// 委托给 `service.isWindowAtTiledTarget`：它在 service 内部复用与平铺路径相同的
    /// 坐标空间探测（4 种空间 + CG 信号），并采用统一完成判定 `frameSatisfiesFinalTiledTarget`
    ///（逐边语义：左严格 3px / 底向内宽松 16px / **顶 ±6px** / 右 −16/+6px，外加妥协形态相等
    /// 与 3px 内完整覆盖两条兜底）。逐边语义挡住「贴底短高吃顶距」的错误形态（Numbers 顶距
    /// 翻倍 bug），左边严格挡住 iWork origin 漂移（实测 x: 16→25）。读取失败时保守返回 false。
    private func isWindowNearTiledTarget(_ windowElement: AXUIElement, pid: pid_t, appElement: AXUIElement, insets: TileInsets) -> Bool {
        service.isWindowAtTiledTarget(windowElement, pid: pid, insets: insets)
    }

    /// 平铺后窗口是否真正落到平铺目标（origin + size 完整到位）。
    ///
    /// 用于区分「真正成功的主窗口平铺」与「启动期小窗 / 不可调大小窗口的无效平铺」：
    /// 后者（Electron 类应用如 SiYuan 首次启动时的加载窗）虽然走完了 `tilePendingWindows`
    /// 的两阶段动画，但尺寸无法真正放大到平铺目标。若此时仍 `markCentered` + 锁 `processedPIDs`，
    /// 随后到达的真正主窗口会被 Bug #3 守卫（`processedPIDs.contains(pid)`）永久跳过，
    /// 表现为「该 App 第一次打开不平铺，之后才正常」——这正是本方法要堵住的根因。
    ///
    /// 判据委托给 `service.isWindowAtTiledTarget`（与 `isWindowNearTiledTarget` 同源、
    /// 保持一致），统一走 `frameSatisfiesFinalTiledTarget`（逐边语义判定，详见该方法注释）。
    /// 读取失败时保守返回 false（视为未成功 → 不锁，让重试接力），与既有「主窗口缺失时
    /// 保守视为主窗口」的同类取舍一致（宁可多试一次也不误锁）。
    ///
    /// 语义配合：返回 false 时调用方应【不】markCentered、【不】锁 processedPIDs，
    /// 与上方 document-chooser / DMG 分支的「不锁」不变量同构——让真正主窗口有机会被处理。
    private func didWindowActuallyTile(_ windowElement: AXUIElement, pid: pid_t, insets: TileInsets) -> Bool {
        service.isWindowAtTiledTarget(windowElement, pid: pid, insets: insets)
    }

    /// 窗口是否是"瞬态"窗口（登录窗 / 启动 splash / 二维码 / 小工具窗）——即非真正的主窗口。
    ///
    /// 用于居中路径的「不锁 PID」判据（见 applyLayout 居中分支）：当 app 首次启动先弹一个小
    /// 登录/splash 窗时，居中它但保持 PID 解锁，让 startInitialCenteringRetries 继续接力，
    /// 直到真正主窗口到达。与平铺路径 didWindowActuallyTile=false / document-chooser gallery
    /// / DMG 分支同构（"瞬态窗不锁，让真窗口有机会被处理"）。
    ///
    /// 判据：窗口面积 ÷ 最大屏 visibleFrame 面积 < 0.5 → 瞬态。仅用尺寸（坐标空间无关），
    /// 分母取所有屏中最大的 visibleFrame（保守，避免解析窗口所在屏的坐标空间复杂性）。
    /// 实测：WeChat 登录窗 280×380 ≈ 5%；WeChat 真窗口 >90%；阈值 0.5 选择空间充裕。
    ///
    /// 读取尺寸失败 → 保守返回 false（视为非瞬态 / 主窗口 → 正常锁 PID），与 didWindowActuallyTile
    /// 的保守 false 一致（避免无法读取时无限重试）。
    private func looksLikeTransientWindow(_ windowElement: AXUIElement) -> Bool {
        guard let size = sizeAttributeValue(windowElement) else { return false }
        let maxVisibleArea = NSScreen.screens.map { $0.visibleFrame.width * $0.visibleFrame.height }.max() ?? 0
        return TransientDetector.isTransient(size: size, largestVisibleFrameArea: maxVisibleArea)
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

    /// 判定候选窗口是否为该 App 的【非主】窗口（即二级窗口）。
    ///
    /// 判据分三档（按可靠性顺序）：
    ///
    /// **1. Chromium 浏览器 → AXIdentifier 的 `type` 字段（实测最可靠）**
    ///   Chromium 窗口 AXIdentifier 是结构化 JSON（实测 2026-06）：主窗口
    ///   `{"...,"type":"main"}`，设置/扩展/弹窗为 `{"...,"type":"secondary"}`。
    ///   这些二级窗口与主窗口 AXSubrole/AXModal 完全相同；且 kAXMainWindowAttribute 在
    ///   二级窗口聚焦时会追踪聚焦窗，把扩展设置页误报成主窗口。AXIdentifier 的 type 字段
    ///   是更稳定的硬特征。这里复用 ChromiumWindowIdentifier 解析 type 字段。
    ///
    /// **1.5. 访达（Finder）→ AXIdentifier（实测稳定）**
    ///   与 Chromium / Journal 同坑：Finder 的二级窗口（显示简介/连接服务器/访达设置/复制进度等）
    ///   在聚焦时 kAXMainWindowAttribute 全部误报为该二级窗口本身（isMain=true），档 2 失效。
    ///   实测（2026-07）AXIdentifier 是稳定判据：普通文件夹窗口恒为 `"FinderWindow"`，
    ///   各类二级窗口为其它值（`"Info"`/`"FinderSettings"`/`"_NS:182"` 等）。命中 Finder 时
    ///   `id == "FinderWindow"` 视为主窗口（不跳过），否则视为二级窗口（跳过）。
    ///
    /// **2. 其它 App（Safari/Firefox 等）→ `kAXMainWindowAttribute`（回退）**
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

        // 档 1.5：访达（Finder）用 AXIdentifier 判定。
        // 与 Chromium / Journal 同坑：Finder 的二级窗口（显示简介/连接服务器/访达设置/复制进度等）
        // 在聚焦时 kAXMainWindowAttribute 全部误报为该二级窗口本身（isMain=true），档 2 失效。
        // 实测（2026-07）AXIdentifier 是稳定判据：普通文件夹窗口恒为 "FinderWindow"，
        // 各类二级窗口为其它值（"Info"/"FinderSettings"/"_NS:182"/复制进度窗 等）。
        // 故 Finder 命中时：id == "FinderWindow" → 主窗口（不跳过）；否则 → 二级窗口（跳过）。
        // id 读不到（nil）时落到档 2，保持保守语义（避免误跳过真正的主窗口）。
        if isFinderBundle(bundleIdentifier) {
            if let id = window.axString("AXIdentifier" as CFString) {
                return id != "FinderWindow"
            }
            // 无 AXIdentifier：落到档 2 回退。
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
        insets: TileInsets,
        bundleIdentifier: String?,
        centerAfterTile: Bool
    ) -> AXUIElement? {
        // 所有 App 通用：滤除二级窗口。本方法会枚举该 App 的所有 AXWindow 并逐个平铺，
        // 若不同步屏蔽，则聚焦主窗口时同时打开的二级窗口（设置/扩展/弹窗/Get Info 等）会被一并平铺——
        // 这正是用户报告的「ChatGPT Atlas 二级页面被自动平铺」根因（handle() 主路径的候选
        // 是主窗口，主路径守卫放行；但 tilePendingWindows 的内部循环对二级窗口此前无任何保护）。
        // 对所有候选统一调用 isSecondaryWindowOfApp 判定，命中即跳过，保持其弹出尺寸/位置。
        // 主窗口不受影响。

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
        // 对所有 App 统一滤除二级窗口（候选 == 主窗口不会被误杀）。
        candidates = candidates.filter {
            !isSecondaryWindowOfApp($0, appElement: appElement, bundleIdentifier: bundleIdentifier)
        }
        var firstTiledWindow: AXUIElement?
        for window in candidates {
            // 每窗口平铺会话预算：达到上限不再启动新动画，直接接受当前 frame 锁定。
            // （Phase 1.3：首铺也消耗同一预算。）
            if !canStartTileAttempt(windowElement: window, pid: pid) {
                forceLockOnBudgetExhaustion(
                    windowElement: window, pid: pid, appElement: appElement, insets: insets,
                    centerAfterTile: centerAfterTile,
                    reason: "first-tile budget already exhausted"
                )
                if firstTiledWindow == nil { firstTiledWindow = window }
                continue
            }
            do {
                // 首次应用也走两阶段动画（先居中、再从中心扩大），保证丝滑。
                recordTileAttempt(windowElement: window, pid: pid)
                try service.tileWindowElementAnimated(
                    window,
                    pid: pid,
                    appElement: appElement,
                    insets: insets
                ) { [weak self] in
                    guard let self else { return }
                    self.recordSelfLayoutGrace(windowElement: window, pid: pid, reason: "tile completion")

                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        DiagnosticLog.debug("tile completion: pid=\(pid) no longer frontmost, skip final lock")
                        return
                    }

                    if self.didWindowActuallyTile(window, pid: pid, insets: insets) {
                        self.startTileStabilizationRetries(
                            pid: pid,
                            appElement: appElement,
                            windowElement: window,
                            insets: insets,
                            centerAfterTile: centerAfterTile
                        )
                        DiagnosticLog.debug("tile completion: tiled and locked pid=\(pid)")
                    } else if self.isTileBudgetExhausted(windowElement: window, pid: pid) {
                        // 预算耗尽且仍未达标：接受当前 frame 锁定，避免无限重铺。
                        self.forceLockOnBudgetExhaustion(
                            windowElement: window, pid: pid, appElement: appElement, insets: insets,
                            centerAfterTile: centerAfterTile,
                            reason: "tile completion but not reached, budget exhausted"
                        )
                    } else {
                        // 阶段 3.2：完成后仍未达标——先延迟一次再校正，给文档 app 迟到的自 resize
                        // 留出 settle 时间，避免在膨胀过程中立即重铺（多轮拉锯）。校正内会重触发
                        // tileWindowElementAnimated（先 size 后 position 的精确目标），再走判定与预算。
                        self.startPostCompletionCorrection(
                            pid: pid,
                            appElement: appElement,
                            windowElement: window,
                            insets: insets,
                            centerAfterTile: centerAfterTile
                        )
                        DiagnosticLog.debug("tile completion: still not at target, schedule post-completion correction pid=\(pid)")
                    }
                }
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

    private func pruneSelfLayoutGrace(now: Date = Date()) {
        selfLayoutGraceUntil = selfLayoutGraceUntil.filter { $0.value > now }
    }

    private func recordSelfLayoutGrace(windowElement: AXUIElement, pid: pid_t, reason: String) {
        recordSelfLayoutGrace(windowElement: windowElement, pid: pid, interval: Self.selfLayoutGraceInterval, reason: reason)
    }

    /// 阶段 3.3：平铺会话结束后延伸宽限，覆盖文档 app（Numbers）迟到的自 resize。
    /// document-chooser app 慢载入的迟到自 resize 到得更晚，用更长的 4.0s 宽限覆盖；
    /// 其它 app 用默认 1.8s。避免坏形态被 handleResize 误标 manual 永久冻结。
    private func extendSelfLayoutGraceAfterSession(windowElement: AXUIElement, pid: pid_t) {
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let isDocumentChooser = tilingSettingsStore.load().isDocumentChooserApp(bundleIdentifier: bundleID)
        let interval = isDocumentChooser
            ? Self.documentChooserPostSessionGraceInterval
            : Self.postSessionGraceInterval
        recordSelfLayoutGrace(windowElement: windowElement, pid: pid, interval: interval, reason: "post-session grace\(isDocumentChooser ? " (document-chooser)" : "")")
    }

    private func recordSelfLayoutGrace(windowElement: AXUIElement, pid: pid_t, interval: TimeInterval, reason: String) {
        pruneSelfLayoutGrace()
        guard let k = key(pid: pid, window: windowElement) else { return }
        selfLayoutGraceUntil[k] = Date().addingTimeInterval(interval)
        DiagnosticLog.debug("self-layout grace: record key=\(k) pid=\(pid) interval=\(interval)s reason=\(reason)")
    }

    private func isWithinSelfLayoutGrace(windowElement: AXUIElement, pid: pid_t) -> Bool {
        let now = Date()
        pruneSelfLayoutGrace(now: now)
        guard
            let k = key(pid: pid, window: windowElement),
            let until = selfLayoutGraceUntil[k]
        else { return false }
        if until > now {
            DiagnosticLog.debug("self-layout grace: ignore late AX move/resize key=\(k) pid=\(pid)")
            return true
        }
        selfLayoutGraceUntil.removeValue(forKey: k)
        return false
    }

    private func hasCentered(windowElement: AXUIElement, pid: pid_t) -> Bool {
        guard let k = key(pid: pid, window: windowElement) else { return false }
        return centeredWindowKeySet.contains(k)
    }

    private func shouldProcessAdditionalDocumentWindow(
        _ windowElement: AXUIElement,
        pid: pid_t,
        bundleIdentifier: String?
    ) -> Bool {
        let settings = tilingSettingsStore.load()
        guard
            settings.shouldTile(bundleIdentifier: bundleIdentifier),
            settings.isDocumentChooserApp(bundleIdentifier: bundleIdentifier),
            !hasCentered(windowElement: windowElement, pid: pid)
        else { return false }

        // 护栏：当前有动画进行中、或该窗口预算已耗尽时，不再放行新的平铺会话——否则它会对
        // 「达不到目标的窗口」永久放行 PID 锁，成为无限重铺入口。
        if service.isAnyAnimationInProgress || isTileBudgetExhausted(windowElement: windowElement, pid: pid) {
            DiagnosticLog.debug("shouldProcessAdditionalDocumentWindow: animation in progress or budget exhausted pid=\(pid) — suppress re-tile entry")
            return false
        }

        if windowHasDocument(windowElement) {
            return true
        }
        return classifyDocumentAppWindow(windowElement) == .document
    }

    // MARK: - 每窗口平铺会话预算（见 tileSessionAttempts 注释）

    /// 该窗口本会话是否还有剩余预算可启动一次新的 `tileWindowElementAnimated`。
    private func canStartTileAttempt(windowElement: AXUIElement, pid: pid_t) -> Bool {
        guard let k = key(pid: pid, window: windowElement) else { return true }
        return (tileSessionAttempts[k] ?? 0) < Self.maxTileSessionAttempts
    }

    private func isTileBudgetExhausted(windowElement: AXUIElement, pid: pid_t) -> Bool {
        !canStartTileAttempt(windowElement: windowElement, pid: pid)
    }

    /// 记录一次真实启动（+1）。返回该窗口本次启动后的累计次数。
    @discardableResult
    private func recordTileAttempt(windowElement: AXUIElement, pid: pid_t) -> Int {
        guard let k = key(pid: pid, window: windowElement) else { return Self.maxTileSessionAttempts }
        let next = (tileSessionAttempts[k] ?? 0) + 1
        tileSessionAttempts[k] = next
        return next
    }

    /// 预算耗尽兜底：接受当前 frame，markCentered + processedPIDs.insert + 停所有重试定时器。
    /// 保证任何几何结局下用户最多看到 `maxTileSessionAttempts` 次动画。
    private func forceLockOnBudgetExhaustion(
        windowElement: AXUIElement,
        pid: pid_t,
        appElement: AXUIElement,
        insets: TileInsets,
        centerAfterTile: Bool,
        reason: String
    ) {
        DiagnosticLog.debug("tile-budget: exhausted — accept current frame and lock pid=\(pid) reason=\(reason) insets=\(insets)")
        // 锁定前的终末位置修正：读实际 frame，若未满足统一判定，按妥协形态只写一次 position。
        // 位置写入 app 从不抗拒（Numbers 抢的是尺寸），保证锁定结局顶距或底距之一等于设置值，
        // 不再出现「贴底短高、缺口全堆到顶部」被锁定的形态（顶距翻倍 bug 的最后一道防线）。
        service.anchorWindowToFallbackOrigin(windowElement, pid: pid, insets: insets)
        tileStabilizeTimer?.cancel()
        tileStabilizeTimer = nil
        finishTileSession(
            windowElement: windowElement,
            pid: pid,
            appElement: appElement,
            centerAfterTile: centerAfterTile,
            reason: "budget exhausted: \(reason)"
        )
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
