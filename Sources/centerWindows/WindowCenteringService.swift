import AppKit
import ApplicationServices

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
            return "缺少辅助功能权限，请在“系统设置 -> 隐私与安全性 -> 辅助功能”中授权。"
        case .noFrontmostApplication:
            return "未检测到前台应用。"
        case .noWindow:
            return "前台应用没有可操作窗口。"
        case .fullscreenWindow:
            return "当前窗口处于全屏状态，已跳过居中。"
        case .unableToReadWindowFrame:
            return "无法读取窗口位置或尺寸。"
        case .unableToWriteWindowSize:
            return "无法设置窗口尺寸（窗口可能不支持调整大小）。"
        case .unableToWriteWindowPosition:
            return "无法设置窗口位置（窗口可能不可移动）。"
        }
    }
}

enum WindowSelectionPolicy {
    case focusedOnly
    case focusedOrAnyNonFullscreen
}

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

    /// 当前进行中的动画 key（防止同一窗口叠加动画 / 重试重叠）。
    private var activeAnimationKey: String?

    /// 是否有任意窗口动画正在进行中（供观察者决定是否需要重试）。
    var isAnyAnimationInProgress: Bool { activeAnimationKey != nil }

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

        WindowAnimator.animate(
            from: CGRect(origin: startOrigin, size: windowSize),
            to: CGRect(origin: endOrigin, size: windowSize),
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
                DiagnosticLog.debug("center-animator: finished pid=\(pid.map(String.init) ?? "?")")
                completion?()
            }
        )
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

        let sizeResult = setSizeAttribute(kAXSizeAttribute as CFString, value: targetFrame.size, on: windowElement)
        if !sizeResult {
            // Tiling requires resize capability; skip windows that cannot be resized.
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
            if self?.activeAnimationKey == animKey {
                self?.activeAnimationKey = nil
            }
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

            // 阶段 B：尺寸从当前线性/ease 插值到平铺尺寸，且每帧重新居中。
            // 先探测可用坐标空间（与 tileWindowElement 一致：优先 context.space）。
            let startSize = windowSize
            let endSize = targetFrame.size

            WindowAnimator.animateCustom(
                frameForProgress: { [weak self] p in
                    guard let self else { return CGRect(origin: centerAXOrigin, size: endSize) }
                    let curW = startSize.width + (endSize.width - startSize.width) * p
                    let curH = startSize.height + (endSize.height - startSize.height) * p
                    let curSize = CGSize(width: curW, height: curH)
                    // 每帧重新居中：窗口从中心对称向外扩大。
                    let bl = WindowGeometry.centeredOrigin(windowSize: curSize, visibleFrame: visibleFrame)
                    let origin = self.toAXOrigin(
                        bottomLeftOrigin: bl,
                        windowSize: curSize,
                        screenFrame: context.screen.frame,
                        space: context.space,
                        primaryTopY: primaryTopY
                    )
                    return CGRect(origin: origin, size: curSize)
                },
                writer: { [weak self] frame in
                    guard let self else { return false }
                    // 同时写入尺寸与位置，保持居中。
                    let sizeOK = self.setSizeAttribute(kAXSizeAttribute as CFString, value: frame.size, on: windowElement)
                    _ = self.setPointAttribute(kAXPositionAttribute as CFString, value: frame.origin, on: windowElement)
                    return sizeOK
                },
                reader: reader,
                completion: {
                    // 收尾：最终落到精确的平铺目标，确保不因取整累积偏差。
                    if let pid {
                        _ = self.tileReachedTarget(windowElement, pid: pid, context: context, primaryTopY: primaryTopY, targetFrame: targetFrame)
                    }
                    finishActive()
                    DiagnosticLog.debug("tile-animator: phase B done pid=\(pid.map(String.init) ?? "?")")
                    completion?()
                }
            )
        }

        if alreadyCentered {
            runPhaseB()
            return
        }

        // 执行阶段 A，完成后进入阶段 B。
        WindowAnimator.animate(
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
            completion: {
                DiagnosticLog.debug("tile-animator: phase A done pid=\(pid.map(String.init) ?? "?")")
                runPhaseB()
            }
        )
    }

    // MARK: - 共享解算 / 动画辅助

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
        return CenterTarget(
            context: context,
            visibleFrame: visibleFrame,
            centeredBottomLeftOrigin: centeredBottomLeftOrigin,
            targetAXOrigin: targetAXOrigin
        )
    }

    /// 是否可调整窗口大小（AXEnhancedUserInterface / AXManualAccessibility 不影响该属性）。
    private func isResizable(_ windowElement: AXUIElement) -> Bool {
        // kAXSizeAttribute 可写即可调。最可靠的做法是：尝试写回当前尺寸看是否成功。
        guard let current = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement) else {
            return false
        }
        return setSizeAttribute(kAXSizeAttribute as CFString, value: current, on: windowElement)
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
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
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
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
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

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        var n: Int32 = 0
        guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .sInt32Type, &n) else {
            return nil
        }
        if n <= 0 { return nil }
        return CGWindowID(n)
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
