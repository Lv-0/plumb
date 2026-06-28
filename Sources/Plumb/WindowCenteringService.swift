import AppKit
import ApplicationServices

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WindowCenteringService
//
// 模块角色：窗口几何引擎（项目的核心复杂度所在）。
//
// 职责：
//   - 读取前台窗口的位置/尺寸（AXPosition / AXSize），探测它使用的"坐标系"，
//     计算居中或平铺目标，再写回（AXPosition / AXSize / AXFrame，逐级兜底）。
//   - 提供四条对外路径：
//       centerWindowElement(_:)          —— 瞬时居中（无动画，仅写一次）。
//       centerWindowElementAnimated(_:)  —— 弹簧动画居中（手动"立即居中"使用）。
//       tileWindowElement(_:)            —— 瞬时平铺（先设尺寸再定位，逐空间兜底）。
//       tileWindowElementAnimated(_:)    —— 两阶段动画平铺：先居中、再从中心对称扩大。
//
// 坐标空间问题（本项目最棘手的复杂度）：
//   macOS 各 app 报告窗口位置时使用的坐标系不统一，单个 AXPosition 值可能落在
//   四种空间之一：globalBottomLeft / globalTopLeft / localBottomLeft / localTopLeft
//   （原点不同、Y 轴方向不同）。本服务通过"窗口中心点归属选屏 + 逐空间重叠评分 +
//   CGWindowList 辅助信号 + 按 PID 缓存"来稳定地推断正确的空间与屏幕。
//
// 不变量 / 关键约定：
//   - 全屏窗口一律跳过（AXFullScreen 属性 + 几何比对双判定）。
//   - 动画期间检测"用户拖动"：连续 jumpAbortConsecutiveTicks 帧偏离写入位置才中止，
//     以过滤 macOS 激活动画造成的瞬时弹动（见 WindowAnimator）。
//   - 切换 app 时 activeAnimationKey 锁与所有定时器都被 abortActiveAnimations() 清空。
//
// 与 WindowEventObserver 的边界：
//   Observer 决定"何时、对哪个窗口"；本服务决定"如何算坐标、如何写 AX"。
// ─────────────────────────────────────────────────────────────────────────────

enum WindowCenteringError: LocalizedError {
    case accessibilityPermissionMissing
    case noFrontmostApplication
    case noWindow
    case fullscreenWindow
    case unableToReadWindowFrame
    case unableToWriteWindowSize
    case unableToWriteWindowPosition

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return L10n.errAccessibilityPermissionMissing
        case .noFrontmostApplication:
            return L10n.errNoFrontmostApplication
        case .noWindow:
            return L10n.errNoWindow
        case .fullscreenWindow:
            return L10n.errFullscreenWindow
        case .unableToReadWindowFrame:
            return L10n.errUnableToReadWindowFrame
        case .unableToWriteWindowSize:
            return L10n.errUnableToWriteWindowSize
        case .unableToWriteWindowPosition:
            return L10n.errUnableToWriteWindowPosition
        }
    }
}

enum WindowSelectionPolicy {
    case focusedOnly
    case focusedOrAnyNonFullscreen
}

/// 窗口尺寸写入的路径与结果。
///
/// `resizeWindowWithFallback` 先尝试 `kAXSizeAttribute`；Electron/Chromium 类应用
/// （如 SiYuan、Apifox）拒绝单独写 kAXSize 但接受 AXFrame，此时回退到 AXFrame
///（连同当前 origin 一起写回，origin 不变）。返回 `.failed` 表示两条路径都失败。
/// 该枚举也用于诊断日志，区分窗口最终是通过哪条路径被放大的。
enum ResizeOutcome {
    /// kAXSizeAttribute 直接写入成功（标准窗口、大多数原生应用）。
    case axSize
    /// 回退到 AXFrame 写入成功（Electron/Chromium 类应用）。
    case axFrame
    /// 两条路径都失败（窗口不可调整尺寸或 AX 不可达）。
    case failed

    /// 尺寸是否被成功改变。
    var didResize: Bool { self != .failed }
}

@MainActor
final class WindowCenteringService {
    private enum RawSpace {
        case globalBottomLeft
        case globalTopLeft
        case localBottomLeft
        case localTopLeft
    }

    private struct WindowContext {
        let screen: NSScreen
        let space: RawSpace
        let overlap: CGFloat
        let currentGlobalRect: CGRect
    }

    private struct ContextCandidate {
        let screen: NSScreen
        let space: RawSpace
        let globalRect: CGRect
        let overlap: CGFloat
        let distance2: CGFloat
    }

    /// 共享的居中目标解算结果：非动画与动画路径共用，避免发散。
    private struct CenterTarget {
        let context: WindowContext
        let visibleFrame: CGRect
        let centeredBottomLeftOrigin: CGPoint
        let targetAXOrigin: CGPoint
    }

    // When a window is mostly off-screen, overlap-based inference becomes ambiguous.
    // Cache the last reliable coordinate system per PID to keep behavior stable.
    private var cachedSpaceByPID: [pid_t: RawSpace] = [:]
    private var cachedDisplayByPID: [pid_t: CGDirectDisplayID] = [:]

    // MARK: - Phase-B 平铺动画时序参数
    //
    // 阶段 B（架构变更，3+ 次 per-frame 尝试失败后的正确方案）：
    // 高频 per-frame 写 size 会导致 app 每帧重新布局、把窗口"弹回"到一个非目标位置，
    // 使 macOS 把尺寸 clamp 到"不溢出屏"的小值（"4 边铺不满"根因）。
    // 实测有效方案：先把 position 移到最终平铺原点（一次写），给 app 一段 settle 时间，
    // 再分少量大步把尺寸插值到目标（每步之间也 settle），最后强制 pos+size 落地。
    //
    // 提速调整（保守、绝不回归）：步数与步进可压，但 settle 引入延迟绝不动——它是防弹回的关键。
    // 历史值：steps=6 / stepIntervalMs=120ms → Phase-B ≈ 0.97s。
    // 当前值：steps=4 / stepIntervalMs=90ms  → Phase-B ≈ 0.61s（省 ~0.36s）。
    // 若某 app 出现铺不满/弹回，单独回退这两个值即可（互不影响）。

    /// Phase-B 分步推进的尺寸插值步数。每步线性逼近目标尺寸，最后一步强制落地兜底。
    private static let tilePhaseBSteps = 4

    /// Phase-B 每步之间的 settle 间隔（毫秒）。必须远大于一帧（60Hz≈16.7ms），否则会触发
    /// app 每帧重布局导致弹回。90ms ≈ 5 帧，满足约束。
    private static let tilePhaseBStepIntervalMs: Int = 90

    /// Phase-B 启动前的 settle 引入延迟（毫秒）：先把 position 写到平铺原点，给 app 这段时间
    /// 稳定，再开始扩大尺寸。**这是防弹回的关键防线，不要压缩。**
    private static let tilePhaseBLeadInMs: Int = 250

    /// 当前进行中的动画 key（防止同一窗口叠加动画 / 重试重叠）。
    private var activeAnimationKey: String?

    /// 进行中的动画定时器句柄（Phase-A 由 WindowAnimator 返回；Phase-B 平铺推进由本类持有）。
    /// 切换 app 时通过 `abortActiveAnimations()` 全部取消，避免 zombie 定时器在后台继续
    /// 移动已非前台 app 的窗口（"切走后 Safari 跑到另一个屏幕"的根因）。
    private var activeAnimatorTimers: [DispatchSourceTimer] = []
    /// 平铺 Phase-B 的分步推进定时器（独立追踪，因其不在 WindowAnimator 体系内）。
    private var activeTileTimer: DispatchSourceTimer?

    /// 是否有任意窗口动画正在进行中（供观察者决定是否需要重试）。
    var isAnyAnimationInProgress: Bool { activeAnimationKey != nil }

    /// 切换 app / 手动中止时调用：立即停止所有进行中的动画，窗口停在最后一帧已写入的位置
    ///（不回弹、不再写）。消除 zombie 定时器在非前台时继续移动窗口的缺陷。
    func abortActiveAnimations() {
        let hadActive = activeAnimationKey != nil || !activeAnimatorTimers.isEmpty || activeTileTimer != nil
        activeTileTimer?.cancel()
        activeTileTimer = nil
        for timer in activeAnimatorTimers {
            timer.cancel()
        }
        activeAnimatorTimers.removeAll()
        // 清空锁，确保后续动画能正常启动（被 cancel 的定时器不会触发其 completion，故主动清空）。
        activeAnimationKey = nil
        if hadActive {
            DiagnosticLog.debug("abortActiveAnimations: stopped all in-flight animations")
        }
    }

    func centerFrontmostWindow(selectionPolicy: WindowSelectionPolicy = .focusedOrAnyNonFullscreen) throws {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else {
            throw WindowCenteringError.accessibilityPermissionMissing
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowCenteringError.noFrontmostApplication
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        let focusedWindow = focusedWindowElement(for: appElement)
        let allWindows = windowElements(for: appElement)
        guard let windowElement = selectCenterableWindow(
            focused: focusedWindow,
            windows: allWindows,
            selectionPolicy: selectionPolicy
        ) else {
            if let focusedWindow, isFullscreenWindow(focusedWindow) {
                throw WindowCenteringError.fullscreenWindow
            }
            throw WindowCenteringError.noWindow
        }

        // 手动"立即居中"同样采用丝滑动画。
        try centerWindowElementAnimated(windowElement, pid: app.processIdentifier)
    }

    func centerWindowElement(_ windowElement: AXUIElement, pid: pid_t? = nil, appElement: AXUIElement? = nil) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(windowElement: windowElement, pid: pid, rawPosition: currentPosition, windowSize: windowSize, primaryTopY: primaryTopY) {
            context = cgContext
        } else {
            context = detectWindowContext(rawPosition: currentPosition, windowSize: windowSize, pid: pid, primaryTopY: primaryTopY)
        }

        guard let context else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let centeredBottomLeftOrigin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        let targetAXOrigin = toAXOrigin(
            bottomLeftOrigin: centeredBottomLeftOrigin,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )

        if setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement) {
            return
        }

        // If the window is far out-of-bounds, some apps reject "ideal" coordinates.
        // Try bringing it back into the visible region first, then re-apply centering.
        let backInVisible = WindowGeometry.constrainedOrigin(origin: context.currentGlobalRect.origin, windowSize: windowSize, bounds: visibleFrame)
        let backAXOrigin = toAXOrigin(
            bottomLeftOrigin: backInVisible,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )
        _ = setPointAttribute(kAXPositionAttribute as CFString, value: backAXOrigin, on: windowElement)

        if setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement) {
            return
        }

        // Last resort: some windows accept AXFrame but not AXPosition.
        let frameRect = CGRect(origin: targetAXOrigin, size: windowSize)
        if setRectAttribute("AXFrame" as CFString, value: frameRect, on: windowElement) {
            return
        }

        throw WindowCenteringError.unableToWriteWindowPosition
    }

    /// 带动画的居中：与 `centerWindowElement` 使用相同的坐标空间探测与目标解算，
    /// 然后用 `WindowAnimator` 把窗口从当前位置丝滑滑到居中位置（仅移动，不改尺寸）。
    func centerWindowElementAnimated(
        _ windowElement: AXUIElement,
        pid: pid_t? = nil,
        appElement: AXUIElement? = nil,
        completion: (() -> Void)? = nil
    ) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard let target = resolveCenterTarget(windowElement: windowElement, pid: pid) else {
            // 解算失败：退回非动画路径（保持原有错误语义）。
            try centerWindowElement(windowElement, pid: pid, appElement: appElement)
            completion?()
            return
        }

        let context = target.context
        let windowSize = CGSize(width: context.currentGlobalRect.width, height: context.currentGlobalRect.height)

        // 动画起点：窗口当前在 AX 坐标系下的原点（与 targetAXOrigin 同空间）。
        let startOrigin = toAXOrigin(
            bottomLeftOrigin: context.currentGlobalRect.origin,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryScreenTopY()
        )
        let endOrigin = target.targetAXOrigin

        // 已在目标位置：直接返回。
        if abs(startOrigin.x - endOrigin.x) < 1, abs(startOrigin.y - endOrigin.y) < 1 {
            completion?()
            return
        }

        let animKey = animationKey(for: windowElement, pid: pid, kind: "center")
        // 重叠保护：若该窗口已有进行中的居中动画，则跳过，避免多个定时器并发写 AXPosition。
        if activeAnimationKey == animKey {
            DiagnosticLog.debug("center-animator: already animating, skip")
            completion?()
            return
        }
        activeAnimationKey = animKey

        // 用 box 持有定时器引用：completion 闭包需要引用它，但它本身是 animate 的返回值，
        // 不能在声明前被同一作用域的闭包捕获。声明在前、赋值在后即可。
        var animatorTimerBox: DispatchSourceTimer?
        animatorTimerBox = WindowAnimator.animate(
            from: CGRect(origin: startOrigin, size: windowSize),
            to: CGRect(origin: endOrigin, size: windowSize),
            easing: WindowAnimator.spring,
            writer: { [weak self] frame in
                guard let self else { return false }
                if self.setPointAttribute(kAXPositionAttribute as CFString, value: frame.origin, on: windowElement) {
                    return true
                }
                // 尝试 AXFrame 兜底。
                return self.setRectAttribute("AXFrame" as CFString, value: frame, on: windowElement)
            },
            reader: { [weak self] in
                guard let self else { return nil }
                guard let p = self.pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
                      let s = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
                else { return nil }
                return CGRect(origin: p, size: s)
            },
            completion: { [weak self] in
                if self?.activeAnimationKey == animKey {
                    self?.activeAnimationKey = nil
                }
                // 正常完成后从追踪列表移除（已 cancel，保留也无害，但避免堆积）。
                if let timer = animatorTimerBox {
                    self?.activeAnimatorTimers.removeAll { $0 === timer }
                }
                DiagnosticLog.debug("center-animator: finished pid=\(pid.map(String.init) ?? "?")")
                completion?()
            }
        )
        if let animatorTimer = animatorTimerBox {
            activeAnimatorTimers.append(animatorTimer)
        }
    }

    func tileWindowElement(_ windowElement: AXUIElement, pid: pid_t? = nil, appElement: AXUIElement? = nil, edgeMargin: CGFloat) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(
            windowElement: windowElement,
            pid: pid,
            rawPosition: currentPosition,
            windowSize: windowSize,
            primaryTopY: primaryTopY
        ) {
            context = cgContext
        } else {
            context = detectWindowContext(
                rawPosition: currentPosition,
                windowSize: windowSize,
                pid: pid,
                primaryTopY: primaryTopY
            )
        }

        guard let context else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, edgeMargin: edgeMargin)

        let sizeResult = resizeWindowWithFallback(windowElement, newSize: targetFrame.size)
        if !sizeResult.didResize {
            // Tiling requires resize capability; skip windows that cannot be resized.
            //（覆盖 Electron 应用：kAXSize 写不进但 AXFrame 可写——它们在此不会被判失败。）
            throw WindowCenteringError.unableToWriteWindowSize
        }

        if tileReachedTarget(windowElement, pid: pid, context: context, primaryTopY: primaryTopY, targetFrame: targetFrame) {
            return
        }

        let spaces = prioritizedSpaces(primary: context.space)
        for space in spaces {
            let candidateOrigin = toAXOrigin(
                bottomLeftOrigin: targetFrame.origin,
                windowSize: targetFrame.size,
                screenFrame: context.screen.frame,
                space: space,
                primaryTopY: primaryTopY
            )
            if setPointAttribute(kAXPositionAttribute as CFString, value: candidateOrigin, on: windowElement),
               tileReachedTarget(windowElement, pid: pid, context: context, primaryTopY: primaryTopY, targetFrame: targetFrame)
            {
                return
            }
        }

        // Last resort: try AXFrame with all coordinate-space candidates.
        for space in spaces {
            let candidateOrigin = toAXOrigin(
                bottomLeftOrigin: targetFrame.origin,
                windowSize: targetFrame.size,
                screenFrame: context.screen.frame,
                space: space,
                primaryTopY: primaryTopY
            )
            let frameRect = CGRect(origin: candidateOrigin, size: targetFrame.size)
            if setRectAttribute("AXFrame" as CFString, value: frameRect, on: windowElement),
               tileReachedTarget(windowElement, pid: pid, context: context, primaryTopY: primaryTopY, targetFrame: targetFrame)
            {
                return
            }
        }

        throw WindowCenteringError.unableToWriteWindowPosition
    }

    /// 带动画的两阶段平铺：
    ///   阶段 A — 在保持当前尺寸的前提下，把窗口平滑移到居中位置；
    ///   阶段 B — 从当前尺寸平滑扩大到平铺尺寸，并每帧重新居中（从中心向外对称生长）。
    /// 若窗口不可调整大小，则跳过阶段 B，仅完成居中。
    func tileWindowElementAnimated(
        _ windowElement: AXUIElement,
        pid: pid_t? = nil,
        appElement: AXUIElement? = nil,
        edgeMargin: CGFloat,
        completion: (() -> Void)? = nil
    ) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(
            windowElement: windowElement,
            pid: pid,
            rawPosition: currentPosition,
            windowSize: windowSize,
            primaryTopY: primaryTopY
        ) {
            context = cgContext
        } else {
            context = detectWindowContext(
                rawPosition: currentPosition,
                windowSize: windowSize,
                pid: pid,
                primaryTopY: primaryTopY
            )
        }

        guard let context else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let targetFrame = WindowGeometry.tiledFrame(visibleFrame: visibleFrame, edgeMargin: edgeMargin)
        DiagnosticLog.debug("tile-animator: detect pid=\(pid.map(String.init) ?? "?") rawPos=\(currentPosition) size=\(windowSize) visibleFrame=\(visibleFrame) space=\(context.space) targetFrame=\(targetFrame)")
        // 防止同一窗口叠加动画 / 重试重叠。
        let animKey = animationKey(for: windowElement, pid: pid, kind: "tile")
        if activeAnimationKey == animKey {
            // 已有该窗口的平铺动画在进行中：直接返回，避免重叠。
            DiagnosticLog.debug("tile-animator: already animating pid=\(pid.map(String.init) ?? "?"), skip")
            completion?()
            return
        }
        activeAnimationKey = animKey

        let reader: () -> CGRect? = { [weak self] in
            guard let self else { return nil }
            guard let p = self.pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
                  let s = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
            else { return nil }
            return CGRect(origin: p, size: s)
        }

        let finishActive = { [weak self] in
            guard let self else { return }
            if self.activeAnimationKey == animKey {
                self.activeAnimationKey = nil
            }
            // 正常完成后清空 Phase-B 定时器追踪（已 cancel）。
            self.activeTileTimer = nil
        }

        // === 阶段 A：以当前尺寸居中（仅移动） ===
        let centeredBottomLeftNow = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        let centerAXOrigin = toAXOrigin(
            bottomLeftOrigin: centeredBottomLeftNow,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )

        // 如果当前已大致居中，则跳过阶段 A 直接进入阶段 B。
        let alreadyCentered = abs(currentPosition.x - centerAXOrigin.x) < 2 && abs(currentPosition.y - centerAXOrigin.y) < 2

        // 阶段 B 的尺寸能否写入（即窗口是否可调整大小）。
        let canResize = isResizable(windowElement)


        // 若既已居中又不可调整大小，则无需动画。
        if alreadyCentered, !canResize {
            finishActive()
            completion?()
            return
        }

        let runPhaseB: () -> Void = { [weak self] in
            guard let self else { return }
            guard canResize else {
                // 不可调整大小：仅居中即可，阶段 A 已处理。
                finishActive()
                completion?()
                return
            }

            // 阶段 B 的时序参数见类顶 tilePhaseB* 常量（含提速调整与回归风险注释）。
            let endSize = targetFrame.size
            let targetAXOrigin = toAXOrigin(
                bottomLeftOrigin: targetFrame.origin,
                windowSize: endSize,
                screenFrame: context.screen.frame,
                space: context.space,
                primaryTopY: primaryTopY
            )

            // 1) 先把窗口左下角移到平铺原点。
            _ = setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement)

            // 2) 用 DispatchSource 定时器分步推进尺寸（每步 settle，见 tilePhaseBStepIntervalMs），
            //    避免高频写触发 app 弹回。从 startSize 线性到 endSize，分 tilePhaseBSteps 步。
            //    定时器存入 self.activeTileTimer 以便切换 app 时由 abortActiveAnimations() 取消；
            //    此外每步开头有前台守卫（双保险），防止 zombie 定时器在非前台 app 上继续写窗口。
            let steps = Self.tilePhaseBSteps
            let timer = DispatchSource.makeTimerSource(queue: .main)
            activeTileTimer = timer
            var step = 0
            timer.schedule(deadline: .now() + .milliseconds(Self.tilePhaseBLeadInMs), repeating: .milliseconds(Self.tilePhaseBStepIntervalMs))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // 前台守卫：若该 pid 已不是前台 app，立即停止——这是消除"切走后 Safari
                // 被 zombie 定时器拉到另一屏"的关键防线（即便外部未调用 abort）。
                if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                    timer.cancel()
                    if self.activeTileTimer === timer { self.activeTileTimer = nil }
                    if self.activeAnimationKey == animKey { self.activeAnimationKey = nil }
                    DiagnosticLog.debug("tile-animator: phase B aborted (pid=\(pid) no longer frontmost)")
                    return
                }
                step += 1
                if step >= steps {
                    timer.cancel()
                    if self.activeTileTimer === timer { self.activeTileTimer = nil }
                    // 最终强制 pos+size 落到目标。
                    _ = self.setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement)
                    let sizeOutcome = self.resizeWindowWithFallback(windowElement, newSize: endSize)
                    if let pid {
                        _ = self.tileReachedTarget(windowElement, pid: pid, context: context, primaryTopY: primaryTopY, targetFrame: targetFrame)
                    }
                    // 终端类 app（如 electerm）按字符行网格 snap，高度可能无法精确到目标。
                    // 读回实际尺寸；若与目标差异较大（app 拒绝缩小），则按实际尺寸在
                    // visibleFrame 内重新居中，避免窗口顶部对齐而底部溢出/贴边。
                    let actualSize = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
                    if let actualSize, (abs(actualSize.width - endSize.width) > 4 || abs(actualSize.height - endSize.height) > 4) {
                        let recenteredBL = WindowGeometry.centeredOrigin(windowSize: actualSize, visibleFrame: visibleFrame)
                        let recenteredAX = self.toAXOrigin(
                            bottomLeftOrigin: recenteredBL,
                            windowSize: actualSize,
                            screenFrame: context.screen.frame,
                            space: context.space,
                            primaryTopY: primaryTopY
                        )
                        _ = self.setPointAttribute(kAXPositionAttribute as CFString, value: recenteredAX, on: windowElement)
                        DiagnosticLog.debug("tile-animator: app snapped size to \(actualSize) (target \(endSize)); recentered to \(recenteredAX)")
                    }
                    let postSize = self.sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
                    let postPos = self.pointAttribute(kAXPositionAttribute as CFString, on: windowElement)
                    DiagnosticLog.debug("tile-animator: phase B done pid=\(pid.map(String.init) ?? "?") target=\(targetFrame) targetAX=\(targetAXOrigin) via=\(sizeOutcome) actualPos=\(postPos.map { String(describing: $0) } ?? "nil") actualSize=\(postSize.map { String(describing: $0) } ?? "nil")")
                    finishActive()
                    completion?()
                    return
                }
                let p = CGFloat(step) / CGFloat(steps)
                let curW = windowSize.width + (endSize.width - windowSize.width) * p
                let curH = windowSize.height + (endSize.height - windowSize.height) * p
                let curSize = CGSize(width: curW, height: curH)
                _ = self.resizeWindowWithFallback(windowElement, newSize: curSize)
            }
            timer.resume()
        }

        if alreadyCentered {
            runPhaseB()
            return
        }

        // 执行阶段 A，完成后进入阶段 B。
        var phaseATimerBox: DispatchSourceTimer?
        phaseATimerBox = WindowAnimator.animate(
            from: CGRect(origin: currentPosition, size: windowSize),
            to: CGRect(origin: centerAXOrigin, size: windowSize),
            writer: { [weak self] frame in
                guard let self else { return false }
                if self.setPointAttribute(kAXPositionAttribute as CFString, value: frame.origin, on: windowElement) {
                    return true
                }
                return self.setRectAttribute("AXFrame" as CFString, value: frame, on: windowElement)
            },
            reader: reader,
            completion: { [weak self] in
                // Phase-A 正常完成：从追踪列表移除（已 cancel），随后进入 Phase-B。
                if let timer = phaseATimerBox {
                    self?.activeAnimatorTimers.removeAll { $0 === timer }
                }
                DiagnosticLog.debug("tile-animator: phase A done pid=\(pid.map(String.init) ?? "?")")
                runPhaseB()
            }
        )
        if let phaseATimer = phaseATimerBox {
            activeAnimatorTimers.append(phaseATimer)
        }
    }

    // MARK: - 共享解算 / 动画辅助

    /// 只读查询：返回给定窗口在当前屏幕上的平铺目标 frame（`visibleFrame` 内缩 edgeMargin）。
    /// 复用与平铺动画相同的坐标空间探测与 `WindowGeometry.tiledFrame` 计算，但不写任何 AX 属性、
    /// 也不启动动画。供 `WindowEventObserver.isWindowNearTiledTarget` 判断"窗口是否已铺满、
    /// 可停止重试"使用——替换此前无法访问内部接口时的粗略面积启发式。
    /// 读取失败或无法确定坐标空间时返回 nil。
    func tiledTargetFrame(for windowElement: AXUIElement, pid: pid_t?, edgeMargin: CGFloat) -> CGRect? {
        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return nil
        }
        let primaryTopY = primaryScreenTopY()
        // 优先 CG 信号（需 pid 以匹配 CGWindowList 的 ownerPID），回退 AX 推断；与平铺路径一致。
        if let pid {
            if let cgContext = detectWindowContextUsingCG(
                windowElement: windowElement,
                pid: pid,
                rawPosition: currentPosition,
                windowSize: windowSize,
                primaryTopY: primaryTopY
            ) {
                let visibleFrame = effectiveVisibleFrame(for: cgContext.screen)
                return WindowGeometry.tiledFrame(visibleFrame: visibleFrame, edgeMargin: edgeMargin)
            }
        }
        guard let context = detectWindowContext(
            rawPosition: currentPosition,
            windowSize: windowSize,
            pid: pid,
            primaryTopY: primaryTopY
        ) else { return nil }
        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        return WindowGeometry.tiledFrame(visibleFrame: visibleFrame, edgeMargin: edgeMargin)
    }


    /// 解算居中目标（坐标空间探测 + 居中原点 + AX 原点）。非动画与动画路径共用。
    private func resolveCenterTarget(windowElement: AXUIElement, pid: pid_t?) -> CenterTarget? {
        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return nil
        }

        let primaryTopY = primaryScreenTopY()
        let context: WindowContext?
        if let pid, let cgContext = detectWindowContextUsingCG(windowElement: windowElement, pid: pid, rawPosition: currentPosition, windowSize: windowSize, primaryTopY: primaryTopY) {
            context = cgContext
        } else {
            context = detectWindowContext(rawPosition: currentPosition, windowSize: windowSize, pid: pid, primaryTopY: primaryTopY)
        }
        guard let context else { return nil }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let centeredBottomLeftOrigin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        let targetAXOrigin = toAXOrigin(
            bottomLeftOrigin: centeredBottomLeftOrigin,
            windowSize: windowSize,
            screenFrame: context.screen.frame,
            space: context.space,
            primaryTopY: primaryTopY
        )
        DiagnosticLog.debug("resolveCenterTarget: pid=\(pid.map(String.init) ?? "?") rawPos=\(currentPosition) size=\(windowSize) visibleFrame=\(visibleFrame) space=\(context.space) centeredBL=\(centeredBottomLeftOrigin) targetAX=\(targetAXOrigin)")
        return CenterTarget(
            context: context,
            visibleFrame: visibleFrame,
            centeredBottomLeftOrigin: centeredBottomLeftOrigin,
            targetAXOrigin: targetAXOrigin
        )
    }

    /// 是否可调整窗口大小。
    /// 探测顺序：先试 kAXSizeAttribute（标准窗口都走这条）；若失败再试 AXFrame
    /// （同时写 origin+size）。许多 Electron / Chromium 应用（如 Apifox）拒绝单独写
    /// kAXSize 但接受 AXFrame —— 旧实现只试 kAXSize，导致这类应用被判为"不可调整大小"，
    /// 平铺阶段 B 被跳过，窗口永远无法放大（用户反馈"平铺对 Apifox 无效"的根因之一）。
    private func isResizable(_ windowElement: AXUIElement) -> Bool {
        guard let current = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement) else {
            return false
        }
        if setSizeAttribute(kAXSizeAttribute as CFString, value: current, on: windowElement) {
            return true
        }
        // kAXSize 写不进：尝试用 AXFrame 写回当前 origin+size（需读 position）。
        if let pos = pointAttribute(kAXPositionAttribute as CFString, on: windowElement) {
            let frame = CGRect(origin: pos, size: current)
            return setRectAttribute("AXFrame" as CFString, value: frame, on: windowElement)
        }
        return false
    }

    /// 生成动画去重 key。
    private func animationKey(for windowElement: AXUIElement, pid: pid_t?, kind: String) -> String {
        let pidPart = pid.map { String($0) } ?? "?"
        if let num = windowIDAttribute(on: windowElement) {
            return "\(kind):\(pidPart):\(num)"
        }
        return "\(kind):\(pidPart):ax:\(CFHash(windowElement))"
    }

    private func focusedWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        windowAttribute(kAXFocusedWindowAttribute as CFString, on: appElement)
    }

    private func mainWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        windowAttribute(kAXMainWindowAttribute as CFString, on: appElement)
    }

    private func windowElements(for appElement: AXUIElement) -> [AXUIElement] {
        appElement.axWindowElements(kAXWindowsAttribute as CFString)
    }

    private func isApplicationInFullscreen(_ appElement: AXUIElement) -> Bool {
        // Prefer checking main/focused window to avoid scanning too many windows.
        if let main = mainWindowElement(for: appElement), isFullscreenWindow(main) {
            return true
        }
        if let focused = focusedWindowElement(for: appElement), isFullscreenWindow(focused) {
            return true
        }
        return false
    }

    private func selectCenterableWindow(
        focused: AXUIElement?,
        windows: [AXUIElement],
        selectionPolicy: WindowSelectionPolicy
    ) -> AXUIElement? {
        if let focused, !isFullscreenWindow(focused) {
            return focused
        }
        if selectionPolicy == .focusedOnly {
            return nil
        }
        return windows.first(where: { !isFullscreenWindow($0) })
    }

    private func windowAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        // 委托给共享 AXAttributeAccess 扩展（带 CFGetTypeID 防御，行为与旧实现一致）。
        element.axWindowElement(attribute)
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
        element.axPoint(attribute)
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        element.axSize(attribute)
    }

    private func setPointAttribute(_ attribute: CFString, value: CGPoint, on element: AXUIElement) -> Bool {
        var mutablePoint = value
        guard let axValue = AXValueCreate(.cgPoint, &mutablePoint) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    private func setSizeAttribute(_ attribute: CFString, value: CGSize, on element: AXUIElement) -> Bool {
        var mutableSize = value
        guard let axValue = AXValueCreate(.cgSize, &mutableSize) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    private func setRectAttribute(_ attribute: CFString, value: CGRect, on element: AXUIElement) -> Bool {
        var mutableRect = value
        guard let axValue = AXValueCreate(.cgRect, &mutableRect) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
    }

    /// 设置窗口尺寸，先试 kAXSizeAttribute；写不进（Electron/Chromium 类应用，如 SiYuan、Apifox）
    /// 时读取当前 origin 并用 AXFrame 写回 (currentOrigin, newSize)。
    ///
    /// 这是平铺阶段 B（以及同步 tileWindowElement）能放大 Electron 应用窗口的关键——这类应用
    /// 拒绝单独写 kAXSize 但接受 AXFrame（与 Phase A 居中时的 AXFrame fallback 行为一致）。
    /// 旧实现只试 kAXSize 且丢弃结果，导致 Electron 应用窗口只居中、不放大（用户反馈
    /// "设置了自动平铺但不生效"的根因）。
    /// 返回 ResizeOutcome：.axSize（kAXSize 直接成功）/ .axFrame（回退成功，Electron 走这条）/
    /// .failed（两条都失败）。调用方据此判断是否放大成功，日志也可区分走的是哪条路径。
    @discardableResult
    private func resizeWindowWithFallback(_ windowElement: AXUIElement, newSize: CGSize) -> ResizeOutcome {
        if setSizeAttribute(kAXSizeAttribute as CFString, value: newSize, on: windowElement) {
            return .axSize
        }
        if let pos = pointAttribute(kAXPositionAttribute as CFString, on: windowElement) {
            if setRectAttribute("AXFrame" as CFString, value: CGRect(origin: pos, size: newSize), on: windowElement) {
                return .axFrame
            }
        }
        return .failed
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        element.axBool(attribute)
    }

    private func isFullscreenWindow(_ windowElement: AXUIElement) -> Bool {
        // Primary signal if available.
        if boolAttribute("AXFullScreen" as CFString, on: windowElement) == true {
            return true
        }

        // Fallback for apps/spaces that don't expose AXFullScreen reliably.
        // Try both coordinate interpretations against every screen and accept the best match.
        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return false
        }

        let primaryTopY = primaryScreenTopY()
        for screen in NSScreen.screens {
            let screenFrame = screen.frame

            for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
                let rect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                if isFullscreenLike(windowFrame: rect, screenFrame: screenFrame) {
                    return true
                }
            }
        }

        return false
    }

    private func isFullscreenLike(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
        // Be tolerant of minor off-by-few-pixels differences (rounded corners, scaling, etc.).
        let tol: CGFloat = 6.0
        let posMatch = abs(windowFrame.minX - screenFrame.minX) <= tol &&
            abs(windowFrame.minY - screenFrame.minY) <= tol
        let sizeMatch = abs(windowFrame.width - screenFrame.width) <= tol &&
            abs(windowFrame.height - screenFrame.height) <= tol

        return posMatch && sizeMatch
    }

    private func detectWindowContext(rawPosition: CGPoint, windowSize: CGSize, pid: pid_t?, primaryTopY: CGFloat) -> WindowContext? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        let cachedScreen: NSScreen? = {
            guard let pid, let id = cachedDisplayByPID[pid] else { return nil }
            return screens.first(where: { displayID(for: $0) == id })
        }()
        let cachedSpace: RawSpace? = {
            guard let pid else { return nil }
            return cachedSpaceByPID[pid]
        }()

        // === 中心点归属优先（需求4：app 原先在哪屏就在哪屏）===
        // globalBottomLeft / globalTopLeft 的全局 rect 不依赖屏幕 frame，可稳定求窗口中心，
        // 用 ScreenSelection 纯函数决定它属于哪屏。命中即锁定屏幕，再在该屏上逐空间评分。
        if let locked = lockScreenByWindowCenter(
            rawPosition: rawPosition, windowSize: windowSize, pid: pid, screens: screens,
            primaryTopY: primaryTopY, cachedScreen: cachedScreen, cachedSpace: cachedSpace
        ) {
            return locked
        }

        // === 回退：旧的逐屏 × 逐空间最大重叠评分 ===
        var best: ContextCandidate?

        for screen in screens {
            let screenFrame = screen.frame

            for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
                let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                let overlap = globalRect.intersection(screenFrame).area
                let dist2 = distanceSquaredFromRectCenter(globalRect, to: screenFrame)
                consider(
                    candidate: ContextCandidate(screen: screen, space: space, globalRect: globalRect, overlap: overlap, distance2: dist2),
                    best: &best,
                    cachedScreen: cachedScreen,
                    cachedSpace: cachedSpace
                )
            }
        }

        if let best {
            // If we had any meaningful overlap, treat this as reliable and update cache.
            if let pid, best.overlap > 1 {
                if let id = displayID(for: best.screen) {
                    cachedDisplayByPID[pid] = id
                }
                cachedSpaceByPID[pid] = best.space
            } else if cachedScreen != nil, let cachedScreen, let cachedSpace {
                let screenFrame = cachedScreen.frame
                let globalRect = rawToGlobalRect(space: cachedSpace, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
                return WindowContext(screen: cachedScreen, space: cachedSpace, overlap: 0, currentGlobalRect: globalRect)
            }
            return WindowContext(screen: best.screen, space: best.space, overlap: best.overlap, currentGlobalRect: best.globalRect)
        }
        return nil
    }

    /// 用窗口中心点（globalBottomLeft / globalTopLeft 两种全局空间）决定它属于哪个屏幕。
    /// 锁定屏幕后，在该屏上逐空间评分选最优 RawSpace，并更新缓存。
    /// 返回 nil 表示中心归属无法确定（应回退到最大重叠评分）。
    private func lockScreenByWindowCenter(
        rawPosition: CGPoint,
        windowSize: CGSize,
        pid: pid_t?,
        screens: [NSScreen],
        primaryTopY: CGFloat,
        cachedScreen: NSScreen?,
        cachedSpace: RawSpace?
    ) -> WindowContext? {
        // 这两个空间的全局 rect 不依赖屏幕 frame，可稳定计算窗口中心。
        let globalSpaces: [RawSpace] = [.globalBottomLeft, .globalTopLeft]
        // 用任一稳定参照屏求 local 空间的中心候选（local 转换依赖 screenFrame，
        // 但对“窗口中心在哪屏”的判定影响很小，用缓存屏/主屏作参照即可）。
        let refScreen = cachedScreen ?? screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }) ?? screens[0]
        let localSpaces: [RawSpace] = [.localBottomLeft, .localTopLeft]

        let screenFrames = screens.map { $0.frame }

        // 收集所有 (space, 该空间下的窗口全局中心) 候选。
        var centerCandidates: [(space: RawSpace, center: CGPoint)] = []
        for space in globalSpaces {
            let r = rawToGlobalRect(space: space, screenFrame: refScreen.frame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            centerCandidates.append((space, CGPoint(x: r.midX, y: r.midY)))
        }
        for space in localSpaces {
            let r = rawToGlobalRect(space: space, screenFrame: refScreen.frame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            centerCandidates.append((space, CGPoint(x: r.midX, y: r.midY)))
        }

        // 对每个候选中心，看它属于哪屏；多个 space 投票一致即采纳该屏。
        // （不同 space 给出的中心可能不同，但若多数一致，说明窗口确实在该屏。）
        var screenVotes: [CGDirectDisplayID: Int] = [:]
        var chosenScreen: NSScreen?
        for cand in centerCandidates {
            guard let idx = ScreenSelection.screenIndex(forCenter: cand.center, inScreens: screenFrames) else { continue }
            let s = screens[idx]
            chosenScreen = s
            if let id = displayID(for: s) {
                screenVotes[id, default: 0] += 1
            }
        }

        // 取得票最多的屏幕（至少 1 票）。
        let winnerID = screenVotes.max { $0.value < $1.value }?.key
        let lockedScreen: NSScreen? = {
            if let winnerID { return screens.first(where: { displayID(for: $0) == winnerID }) }
            return chosenScreen
        }()
        guard let lockedScreen else { return nil }

        // 在锁定屏幕上逐空间评分选最优 RawSpace。
        let screenFrame = lockedScreen.frame
        var best: ContextCandidate?
        for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
            let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            let overlap = globalRect.intersection(screenFrame).area
            let dist2 = distanceSquaredFromRectCenter(globalRect, to: screenFrame)
            consider(
                candidate: ContextCandidate(screen: lockedScreen, space: space, globalRect: globalRect, overlap: overlap, distance2: dist2),
                best: &best,
                cachedScreen: cachedScreen,
                cachedSpace: cachedSpace
            )
        }
        guard let best else { return nil }

        // 更新缓存（中心归属是强信号，即便重叠小也采纳）。
        if let pid {
            if let id = displayID(for: lockedScreen) {
                cachedDisplayByPID[pid] = id
            }
            cachedSpaceByPID[pid] = best.space
        }
        return WindowContext(screen: lockedScreen, space: best.space, overlap: best.overlap, currentGlobalRect: best.globalRect)
    }

    private func detectWindowContextUsingCG(
        windowElement: AXUIElement,
        pid: pid_t,
        rawPosition: CGPoint,
        windowSize: CGSize,
        primaryTopY: CGFloat
    ) -> WindowContext? {
        let fallbackContext = detectWindowContext(
            rawPosition: rawPosition,
            windowSize: windowSize,
            pid: pid,
            primaryTopY: primaryTopY
        )
        let preferredDisplayID = fallbackContext.flatMap { displayID(for: $0.screen) }

        guard
            ScreenCapturePermission.ensureAuthorized(prompt: false),
            let cgRect = cgWindowBounds(
                windowID: windowIDAttribute(on: windowElement),
                pid: pid,
                expectedSize: windowSize,
                preferredDisplayID: preferredDisplayID
            ),
            let screenPick = pickScreenForCGRect(cgRect)
        else {
            return nil
        }

        let screen = screenPick.screen
        let screenFrame = screen.frame

        // Convert CG global rect (origin at top-left of primary, y grows down) to Cocoa global rect.
        let cocoaRect = cocoaRectFromCGWindowBounds(cgRect, screen: screen, primaryTopY: primaryTopY)

        var best: (space: RawSpace, globalRect: CGRect, error: CGFloat)?
        for space in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] {
            let globalRect = rawToGlobalRect(space: space, screenFrame: screenFrame, rawPosition: rawPosition, windowSize: windowSize, primaryTopY: primaryTopY)
            let err = rectMatchError(globalRect, cocoaRect)
            if let best, best.error <= err { continue }
            best = (space, globalRect, err)
        }
        guard let best else { return nil }
        DiagnosticLog.debug("detectCG: pid=\(pid) cgRect=\(cgRect) cocoaRect=\(cocoaRect) pickedSpace=\(best.space) err=\(best.error)")

        if let id = displayID(for: screen) {
            cachedDisplayByPID[pid] = id
        }
        cachedSpaceByPID[pid] = best.space

        return WindowContext(screen: screen, space: best.space, overlap: screenPick.area, currentGlobalRect: best.globalRect)
    }

    private func rectMatchError(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) +
            abs(a.minY - b.minY) +
            abs(a.width - b.width) +
            abs(a.height - b.height)
    }

    private func windowIDAttribute(on window: AXUIElement) -> CGWindowID? {
        // AXWindowNumber 为 CFNumber；通过共享扩展以 64 位安全方式读取正整数。
        // CGWindowID 是 UInt32，故只接受落在 1...UInt32.max 的值（窗口编号总在此范围内）。
        guard let n = window.axPositiveInteger("AXWindowNumber" as CFString),
              (1...Int(UInt32.max)).contains(n)
        else { return nil }
        return CGWindowID(UInt32(n))
    }

    private func cgWindowBounds(
        windowID: CGWindowID?,
        pid: pid_t,
        expectedSize: CGSize,
        preferredDisplayID: CGDirectDisplayID?
    ) -> CGRect? {
        if let windowID {
            let options: CGWindowListOption = [.optionIncludingWindow]
            if
                let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
                let info = list.first,
                let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                ownerPID == Int(pid),
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: boundsDict)
            {
                return rect
            }
        }

        // Some apps do not expose AXWindowNumber (e.g. certain Office windows).
        // Fallback: pick the best on-screen window for this PID by closest size.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var bestRect: CGRect?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        let preferredDisplayBounds: CGRect? = {
            guard let preferredDisplayID else { return nil }
            return CGDisplayBounds(preferredDisplayID)
        }()

        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID == Int(pid) else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }

            var score = abs(rect.width - expectedSize.width) + abs(rect.height - expectedSize.height)

            if let preferredDisplayBounds {
                let overlap = rect.intersection(preferredDisplayBounds).area
                if overlap <= 1 {
                    score += 10_000
                } else {
                    let rectArea = max(1, rect.area)
                    let outsideRatio = max(0, min(1, (rectArea - overlap) / rectArea))
                    score += outsideRatio * 500
                }
            }

            if score < bestScore {
                bestScore = score
                bestRect = rect
            }
        }

        return bestRect
    }

    private func pickScreenForCGRect(_ cgRect: CGRect) -> (screen: NSScreen, area: CGFloat)? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var best: (screen: NSScreen, area: CGFloat)?
        var candidates: [NSScreen] = []

        for screen in screens {
            guard let id = displayID(for: screen) else { continue }
            let cgDisplay = CGDisplayBounds(id)
            let area = cgRect.intersection(cgDisplay).area
            if let best, abs(area - best.area) <= 0.5 {
                candidates.append(screen)
            } else if best == nil || area > best!.area + 0.5 {
                best = (screen, area)
                candidates = [screen]
            }
        }
        guard let best else { return nil }
        if candidates.count == 1 {
            return best
        }
        let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
        let chosen = candidates.first(where: {
            guard let id = displayID(for: $0) else { return false }
            return CGDisplayBounds(id).contains(center)
        }) ?? best.screen
        return (chosen, best.area)
    }

    private func cocoaRectFromCGWindowBounds(_ cgRect: CGRect, screen: NSScreen, primaryTopY: CGFloat) -> CGRect {
        guard let id = displayID(for: screen) else {
            let y = primaryTopY - cgRect.minY - cgRect.height
            return CGRect(x: cgRect.minX, y: y, width: cgRect.width, height: cgRect.height)
        }
        let cgDisplay = CGDisplayBounds(id)
        let screenFrame = screen.frame
        let cocoaX = screenFrame.minX + (cgRect.minX - cgDisplay.minX)
        let cocoaY = primaryTopY - cgRect.minY - cgRect.height
        return CGRect(x: cocoaX, y: cocoaY, width: cgRect.width, height: cgRect.height)
    }

    private func consider(candidate: ContextCandidate, best: inout ContextCandidate?, cachedScreen: NSScreen?, cachedSpace: RawSpace?) {
        let overlapTol: CGFloat = 0.5
        let cacheBonus: CGFloat = 0.25

        // Score by overlap first; break ties by distance; preserve the historic tie-break of preferring top-left.
        func adjustedOverlap(_ c: ContextCandidate) -> CGFloat {
            if let cachedScreen, let cachedSpace,
               cachedScreen == c.screen, cachedSpace == c.space
            {
                return c.overlap + cacheBonus
            }
            return c.overlap
        }

        if let currentBest = best {
            let candOverlap = adjustedOverlap(candidate)
            let bestOverlap = adjustedOverlap(currentBest)

            if candOverlap > bestOverlap + overlapTol {
                best = candidate
                return
            }

            let diff = candOverlap > bestOverlap ? (candOverlap - bestOverlap) : (bestOverlap - candOverlap)
            if diff <= overlapTol {
                if candidate.distance2 + 0.5 < currentBest.distance2 {
                    best = candidate
                    return
                }
                // If still tied, prefer top-left (original behavior).
                let distDiff = candidate.distance2 > currentBest.distance2 ? (candidate.distance2 - currentBest.distance2) : (currentBest.distance2 - candidate.distance2)
                if distDiff <= 0.5 {
                    if isBottomLeft(space: currentBest.space), isTopLeft(space: candidate.space) {
                        best = candidate
                        return
                    }
                }
            }

            // If both overlaps are zero, pick the closest screen.
            if currentBest.overlap <= overlapTol, candidate.overlap <= overlapTol {
                if candidate.distance2 + 0.5 < currentBest.distance2 {
                    best = candidate
                    return
                }
            }
            return
        }

        best = candidate
    }

    private func toAXOrigin(bottomLeftOrigin: CGPoint, windowSize: CGSize, screenFrame: CGRect, space: RawSpace, primaryTopY: CGFloat) -> CGPoint {
        switch space {
        case .globalBottomLeft:
            return CGPoint(x: bottomLeftOrigin.x.rounded(), y: bottomLeftOrigin.y.rounded())
        case .globalTopLeft:
            let y = (primaryTopY - bottomLeftOrigin.y - windowSize.height).rounded()
            return CGPoint(x: bottomLeftOrigin.x.rounded(), y: y)
        case .localBottomLeft:
            let x = (bottomLeftOrigin.x - screenFrame.minX).rounded()
            let y = (bottomLeftOrigin.y - screenFrame.minY).rounded()
            return CGPoint(x: x, y: y)
        case .localTopLeft:
            let x = (bottomLeftOrigin.x - screenFrame.minX).rounded()
            let y = (screenFrame.maxY - bottomLeftOrigin.y - windowSize.height).rounded()
            return CGPoint(x: x, y: y)
        }
    }

    private func rawToGlobalRect(space: RawSpace, screenFrame: CGRect, rawPosition: CGPoint, windowSize: CGSize, primaryTopY: CGFloat) -> CGRect {
        switch space {
        case .globalBottomLeft:
            return CGRect(origin: rawPosition, size: windowSize)
        case .globalTopLeft:
            let convertedBottomY = primaryTopY - rawPosition.y - windowSize.height
            return CGRect(x: rawPosition.x, y: convertedBottomY, width: windowSize.width, height: windowSize.height)
        case .localBottomLeft:
            return CGRect(
                x: screenFrame.minX + rawPosition.x,
                y: screenFrame.minY + rawPosition.y,
                width: windowSize.width,
                height: windowSize.height
            )
        case .localTopLeft:
            let x = screenFrame.minX + rawPosition.x
            let y = screenFrame.maxY - rawPosition.y - windowSize.height
            return CGRect(x: x, y: y, width: windowSize.width, height: windowSize.height)
        }
    }

    private func tileReachedTarget(
        _ windowElement: AXUIElement,
        pid: pid_t?,
        context: WindowContext,
        primaryTopY: CGFloat,
        targetFrame: CGRect
    ) -> Bool {
        if
            let pid,
            ScreenCapturePermission.ensureAuthorized(prompt: false),
            let cgRect = cgWindowBounds(
                windowID: windowIDAttribute(on: windowElement),
                pid: pid,
                expectedSize: targetFrame.size,
                preferredDisplayID: displayID(for: context.screen)
            ),
            let screenPick = pickScreenForCGRect(cgRect)
        {
            let cocoaRect = cocoaRectFromCGWindowBounds(cgRect, screen: screenPick.screen, primaryTopY: primaryTopY)
            let tol: CGFloat = 12
            return abs(cocoaRect.minX - targetFrame.minX) <= tol &&
                abs(cocoaRect.minY - targetFrame.minY) <= tol &&
                abs(cocoaRect.width - targetFrame.width) <= tol &&
                abs(cocoaRect.height - targetFrame.height) <= tol
        }

        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let rawSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return false
        }

        let currentFrame = rawToGlobalRect(
            space: context.space,
            screenFrame: context.screen.frame,
            rawPosition: rawPosition,
            windowSize: rawSize,
            primaryTopY: primaryTopY
        )

        let tol: CGFloat = 10
        return abs(currentFrame.minX - targetFrame.minX) <= tol &&
            abs(currentFrame.minY - targetFrame.minY) <= tol &&
            abs(currentFrame.width - targetFrame.width) <= tol &&
            abs(currentFrame.height - targetFrame.height) <= tol
    }

    private func isTopLeft(space: RawSpace) -> Bool {
        switch space {
        case .globalTopLeft, .localTopLeft:
            return true
        default:
            return false
        }
    }

    private func isBottomLeft(space: RawSpace) -> Bool {
        switch space {
        case .globalBottomLeft, .localBottomLeft:
            return true
        default:
            return false
        }
    }

    private func prioritizedSpaces(primary: RawSpace) -> [RawSpace] {
        var ordered: [RawSpace] = [primary]
        for candidate in [RawSpace.globalBottomLeft, .globalTopLeft, .localBottomLeft, .localTopLeft] where !ordered.contains(where: { $0 == candidate }) {
            ordered.append(candidate)
        }
        return ordered
    }

    private func effectiveVisibleFrame(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let insets = WindowGeometry.insetsFromVisibleFrame(frame: frame, visible: visible)
        return CGRect(
            x: frame.minX + insets.left,
            y: frame.minY + insets.bottom,
            width: frame.width - insets.left - insets.right,
            height: frame.height - insets.top - insets.bottom
        )
    }

    private func distanceSquaredFromRectCenter(_ rect: CGRect, to bounds: CGRect) -> CGFloat {
        let cx = rect.midX
        let cy = rect.midY
        let nx = clamp(cx, min: bounds.minX, max: bounds.maxX)
        let ny = clamp(cy, min: bounds.minY, max: bounds.maxY)
        let dx = cx - nx
        let dy = cy - ny
        return dx * dx + dy * dy
    }

    private func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private func primaryScreenTopY() -> CGFloat {
        // Primary display's top edge in Cocoa global coordinates (also equals its height when minY == 0).
        let screens = NSScreen.screens
        let primary = screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 })
        return (primary ?? NSScreen.main ?? screens.first)?.frame.maxY ?? 0
    }
}

private extension CGRect {
    var area: CGFloat {
        if isNull || isEmpty {
            return 0
        }
        return width * height
    }
}
