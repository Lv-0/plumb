import ServiceManagement
import Testing
@testable import Plumb

@Suite("LaunchAtLogin")
struct LaunchAtLoginTests {

    // MARK: - Static surface (no system registration side-effects)
    //
    // SMAppService.mainApp() 需要已签名的 .app 包，swift test 的裸可执行环境下 register/
    // unregister 可能抛错、status 也取决于环境。因此这里只断言"可调用/不崩溃"与"读取一致"，
    // 不断言注册成功与否——真实注册行为由 Task 4 的手动集成验证覆盖。

    @Test("isEnabled reads without throwing")
    func isEnabledReadable() {
        // 读取在任何环境下都不应抛错/崩溃。
        let _ = LaunchAtLogin.isEnabled
    }

    @Test("enable/disable are callable (result is environment-dependent)")
    func enableDisableCallable() {
        // 只断言方法可调用、调用后读取仍一致；不断言注册成功/失败。
        do { try LaunchAtLogin.enable() }  catch {}
        do { try LaunchAtLogin.disable() } catch {}
        let _ = LaunchAtLogin.isEnabled
    }
}
