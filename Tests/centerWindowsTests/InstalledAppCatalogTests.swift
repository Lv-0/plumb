import Foundation
import Testing
@testable import centerWindows

/// 验证 `InstalledAppCatalog.loadInstalledApps()` 的"可重复调用、无内部缓存"契约。
///
/// 背景：设置视图 `SettingsView` 在窗口每次显示时都会重新调用本方法（修复
/// "新安装的软件不会出现在查询列表中"）。该刷新能否生效，完全取决于本方法
/// 每次调用都重新扫描文件系统、不缓存上次结果。本测试用一个带唯一 bundle id 的
/// 临时 `.app` 包，验证"第一次未出现 → 创建 → 第二次出现"，并保证清理副作用。
struct InstalledAppCatalogTests {

    /// `loadInstalledApps` 扫描的根目录之一，且属于当前用户可写位置，
    /// 适合放置临时 `.app` 包而不污染系统目录。
    private static var userApplicationsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    @Test
    func loadInstalledAppsReflectsNewlyInstalledAppOnRecall() async throws {
        let fm = FileManager.default
        let appsDir = Self.userApplicationsURL

        // 若用户机器上不存在 ~/Applications（如某些 CI 沙箱），本测试无落脚点：
        // 直接 return（视为通过），而非依赖跨版本不稳定的 swift-testing Skip API。
        guard fm.fileExists(atPath: appsDir.path) else {
            return
        }

        // 唯一标识，避免与任何真实安装的应用冲突。
        // 注意：catalog 内部会对 bundle id 做 normalizeBundleID（trim + 小写）后再存储，
        // 因此断言时必须与归一化后的形式比较，否则大小写不一致会误判为"未发现"。
        let uniqueRaw = "com.comet.plumb.tests.\(UUID().uuidString)"
        let unique = uniqueRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let appName = "PlumbSelfTest-\(UUID().uuidString.prefix(8))"
        let appURL = appsDir.appendingPathComponent("\(appName).app")

        // 前置清理：防御性确保测试产物不存在。
        try? fm.removeItem(at: appURL)
        defer { try? fm.removeItem(at: appURL) }

        // 1) 首次扫描：目标应用尚未安装，不应出现。
        let before = InstalledAppCatalog.loadInstalledApps()
        #expect(before.contains { $0.bundleID == unique } == false)

        // 2) 在扫描根下创建一个最小但合法的 `.app` 包（含 Info.plist，给出 bundle id 与名称）。
        Self.makeMinimalAppBundle(at: appURL, bundleID: uniqueRaw, name: appName)

        // 3) 再次扫描：必须能发现刚安装的应用——证明方法每次都重读文件系统，无内部缓存。
        //    这正是设置窗口"重新打开即刷新"所依赖的契约。
        let after = InstalledAppCatalog.loadInstalledApps()
        let match = after.first { $0.bundleID == unique }
        #expect(match != nil, "重新调用 loadInstalledApps 应能发现新安装的应用")
        #expect(match?.name == appName)
    }

    /// 构造一个最小但可被 `Bundle(url:)` 识别的 `.app` 包。
    private static func makeMinimalAppBundle(at url: URL, bundleID: String, name: String) {
        let fm = FileManager.default
        let contentsURL = url.appendingPathComponent("Contents")
        let macosURL = contentsURL.appendingPathComponent("MacOS")
        // createDirectory 抛错时直接让测试失败（签名无 throws 故用 try!）。
        try! fm.createDirectory(at: macosURL, withIntermediateDirectories: true)

        // 可执行文件占位（无需可执行权限即可被识别为 app 包）。
        let execURL = macosURL.appendingPathComponent(name)
        try! Data().write(to: execURL)

        // Info.plist：提供 bundle id 与名称，使 catalog 能读取并去重。
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        (plist as NSDictionary).write(to: plistURL, atomically: true)
    }
}

