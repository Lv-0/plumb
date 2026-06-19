import Foundation
import ServiceManagement

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LaunchAtLogin
//
// 模块角色：开机自启动的薄封装，基于 SMAppService.mainApp（macOS 13+）。
//
// 设计要点：
//   - 系统是唯一真实来源：isEnabled 直接读 SMAppService.status，不维护 UserDefaults 镜像，
//     避免本地布尔与系统状态失同步（用户在系统设置手动改动后，开关仍能反映真实值）。
//   - 纯静态：无持久化、无状态持有。
//     注意：不缓存 SMAppService.mainApp 到 static let —— 该类型非 Sendable，缓存会触发
//     并发安全诊断；mainApp 本身是系统单例，每次访问开销可忽略。
//   - enable()/disable() 可抛错（如 swift test 裸可执行环境下 register 会失败），
//     由 UI 捕获并回滚开关到真实值。
//
// 前提：需以已签名的 .app 包运行；swift test 裸可执行环境下注册无法生效（仅保证不崩溃）。
// 真实注册/取消注册行为由手动集成验证（见 docs/superpowers/plans/2026-06-20-launch-at-login.md Task 4）。
// ─────────────────────────────────────────────────────────────────────────────

/// 开机自启动封装：注册/取消注册 Plumb 为 macOS 登录项。
enum LaunchAtLogin {
    /// 当前是否已注册为登录项。以系统真实状态为准（不读 UserDefaults 镜像）。
    /// `.requiresApproval`（已注册待批准）也视为开启态，与系统设置登录项列表一致。
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    /// 启用开机自启动。可能抛错（如非 .app 包环境）。
    static func enable() throws  { try SMAppService.mainApp.register() }

    /// 禁用开机自启动。
    static func disable() throws { try SMAppService.mainApp.unregister() }
}
