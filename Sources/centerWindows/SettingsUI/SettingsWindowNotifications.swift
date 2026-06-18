import Foundation

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
}
