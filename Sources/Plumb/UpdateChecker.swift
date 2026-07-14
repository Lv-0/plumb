import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateChecker
//
// 模块角色：拉取 appcast 并判断是否有可用更新。
//
// 职责：
//   - 通过注入的 ManifestFetcher 获取 appcast 字节（生产 URLSession，测试 Mock）。
//   - 解码为 UpdateManifest。
//   - 版本比较（只升不降）+ minOS 门槛判断。
//   - 返回 UpdateResult，供 Coordinator 决定是否提示用户。
//
// 设计说明：网络抽到 ManifestFetcher 协议，使本组件可纯单测（不触网）。
// 网络错误与解码错误统一收敛为 .error（不抛出），调用方据此静默或提示。
// ─────────────────────────────────────────────────────────────────────────────

/// appcast 字节来源抽象。生产用 URLSessionManifestFetcher，测试用 Mock。
protocol ManifestFetcher: Sendable {
    func fetch() async throws -> Data
}

/// 检查结果。
enum UpdateResult {
    case upToDate                       // 无更新（含降级、版本相等、manifest 版本非法）
    case available(UpdateManifest)      // 有更新且本机满足 minOS
    case osTooOld                       // 有更新但本机系统低于 minOS（调用方静默）
    case error                          // 网络错误 / appcast 解析失败
}

/// appcast URL（随发版提交到 repo main 分支根目录）。
enum UpdateConfig {
    static let appcastURL = URL(string: "https://raw.githubusercontent.com/Lv-0/plumb/main/appcast.json")!
}

/// 生产环境 fetcher：URLSession 拉取 appcast。
struct URLSessionManifestFetcher: ManifestFetcher {
    let url: URL
    init(url: URL = UpdateConfig.appcastURL) { self.url = url }
    func fetch() async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

struct UpdateChecker: Sendable {
    let fetcher: ManifestFetcher

    init(fetcher: ManifestFetcher = URLSessionManifestFetcher()) {
        self.fetcher = fetcher
    }

    /// 检查更新（非抛出：错误统一收敛为 .error）。current=当前 app 版本；osVersion=本机系统版本。
    func check(current: AppVersion, osVersion: AppVersion) async -> UpdateResult {
        let data: Data
        do {
            data = try await fetcher.fetch()
        } catch {
            return .error
        }
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            return .error
        }
        // JSON 解码路径已拒绝非法版本；保留此守卫处理测试/未来程序化构造，仍须 fail closed，
        // 不能把发布数据损坏误报为“已是最新”。
        guard let remote = manifest.parsedVersion else { return .error }
        // 只升不降。
        guard remote.isNewerThan(current) else { return .upToDate }
        // minOS 门槛：本机低于要求 → 不提示（静默）。
        if let minOS = manifest.minOS, osVersion < minOS {
            return .osTooOld
        }
        return .available(manifest)
    }
}
