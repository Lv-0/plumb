import ApplicationServices
import CoreGraphics

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - AXAttributeAccess
//
// 模块角色：Accessibility 属性访问的共享薄封装。
//
// 职责：
//   为读取 AXUIElement 的 CGPoint / CGSize / Bool / String / 子元素 / 元素列表
//   提供唯一、类型安全且防御性的入口。所有读取都先校验 AX 调用成功，
//   再用 CFGetTypeID 确认返回值的真实 CF 类型，最后才做类型转换——
//   避免 `as!` 强转在 app 返回非预期类型（如 nil / AXValue 与 CFString 混用）
//   时直接崩溃。
//
// 为什么集中在此：
//   历史上 `WindowCenteringService` 与 `WindowEventObserver` 各自维护了一套几乎
//   相同的私有读取器，且 Observer 那套用的是更不安全的 `as! AXValue` 强转。
//   集中后两处共用同一实现，行为一致、安全性统一，也消除了约 100 行重复代码。
//
// 不变量：
//   - 读取失败一律返回 nil，调用方按 nil 处理（跳过 / 回退），绝不崩溃。
//   - 不在此处写入属性；写入（setPoint/Size/Rect）仍由各使用方按需实现，
//     因为写入语义（成功判定、回退到 AXFrame）与调用方强耦合。
// ─────────────────────────────────────────────────────────────────────────────

extension AXUIElement {
    /// 读取一个 CGPoint 属性（如 `kAXPositionAttribute`）。非 CGPoint 或读取失败返回 nil。
    func axPoint(_ attribute: CFString) -> CGPoint? {
        guard let value = axRawValue(attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    /// 读取一个 CGSize 属性（如 `kAXSizeAttribute`）。非 CGSize 或读取失败返回 nil。
    func axSize(_ attribute: CFString) -> CGSize? {
        guard let value = axRawValue(attribute) else { return nil }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// 读取一个 Bool 属性（如 `AXFullScreen` / `AXMinimized`）。非 Bool 或读取失败返回 nil。
    func axBool(_ attribute: CFString) -> Bool? {
        guard let value = axRawValue(attribute) else { return nil }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(value as! CFBoolean)
    }

    /// 读取一个 String 属性（如 `AXRole` / `AXSubrole`）。非 String 或读取失败返回 nil。
    func axString(_ attribute: CFString) -> String? {
        guard let value = axRawValue(attribute) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    /// 读取单个子元素属性（如 `AXFocusedWindow` / `AXWindow`）。
    /// 返回值非 AXUIElement 类型时返回 nil。
    func axWindowElement(_ attribute: CFString) -> AXUIElement? {
        guard let value = axRawValue(attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    /// 读取元素列表属性（如 `AXWindows`）。读取失败返回空数组。
    func axWindowElements(_ attribute: CFString) -> [AXUIElement] {
        guard let value = axRawValue(attribute) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// 读取一个 CFNumber 属性并按 Int 返回（如 `AXWindowNumber`）。
    /// 用于需要窗口编号等数值型属性的场景。非 CFNumber 或读取失败返回 nil。
    func axInt32(_ attribute: CFString) -> Int32? {
        guard let value = axRawValue(attribute) else { return nil }
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var n: Int32 = 0
        guard CFNumberGetValue(value as! CFNumber, .sInt32Type, &n) else { return nil }
        return n
    }

    /// 底层：执行 AXUIElementCopyAttributeValue 并返回原始 CFTypeRef。
    /// 仅在调用成功且值非 nil 时返回；失败返回 nil。
    private func axRawValue(_ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute, &value) == .success else {
            return nil
        }
        return value
    }
}
