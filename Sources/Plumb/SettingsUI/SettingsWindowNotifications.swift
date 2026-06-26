import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SettingsWindowNotifications (SettingsUI)
//
// 模块角色：设置窗口相关通知名的集中定义。
//
// 唯一定义的 windowDidShow：SettingsWindowController 在每次 showWindow 完成后发出，
// SettingsView 监听后重新扫描已安装应用。存在原因：AppDelegate 把控制器缓存为单例，
// 再次"打开设置"复用同一 SettingsView，其 .task 不再触发——故用本通知驱动刷新。
// 通知名加产品前缀，避免与系统/第三方通知冲突。
// ─────────────────────────────────────────────────────────────────────────────

/// 设置窗口相关的通知名集中定义。
///
/// 设计目的：`AppDelegate` 将 `SettingsWindowController` 缓存为单例，再次"打开设置"
/// 会复用同一个 `SettingsView`，其 `.task` 不会再次触发。因此新安装的应用不会出现在
/// 选择列表里。这里定义一个窗口"每次显示"都会发出的通知，供 `SettingsView` 监听后
/// 重新扫描已安装应用。通知名前缀使用产品标识，避免与系统/第三方通知冲突。
enum SettingsWindowNotifications {
    /// 设置窗口每次 `showWindow` 完成后发出。
    static let windowDidShow =
        Notification.Name("plumb.settings.windowDidShow")

    /// 「隐藏菜单栏图标」开关变化时发出。
    /// AppDelegate 监听后按当前 hideStatusBarIcon 设置增/删 NSStatusItem，
    /// 实现「拨动开关 → 图标立即消失/出现」。用通知解耦：设置 UI 不持有 AppDelegate。
    static let statusBarIconVisibilityChanged =
        Notification.Name("plumb.settings.statusBarIconVisibilityChanged")
}
