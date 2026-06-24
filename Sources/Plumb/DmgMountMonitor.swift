import AppKit
import DiskArbitration
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DmgMountMonitor
//
// 模块角色：维护「当前已挂载的磁盘映像（.dmg）卷名集合」。
//
// 职责：
//   - 监听 NSWorkspace didMount/didUnmount 通知；挂载时用 DiskArbitration 探测该卷
//     是否为磁盘映像（Device Protocol == "Virtual Interface"），是则把卷名加入集合。
//   - start() 预扫 /Volumes/* 填充「启动前已挂载」的 DMG。
//   - 对外暴露 isMountedDmgVolume(_:)：供 WindowEventObserver 判断 Finder 窗口标题
//     是否命中某个 DMG 卷名。
//
// 为什么用 Device Protocol == "Virtual Interface"：
//   这是 DiskArbitration 对磁盘映像的明确标志；USB/外接硬盘报为 "USB"/"SATA" 等，
//   故仅 DMG 安装窗口会被识别，U 盘/外接硬盘窗口不受影响。
//
// 可注入设计：
//   DMG 探测逻辑（dmgProbe 闭包）可注入，生产传真实 DA 实现，测试传 mock，
//   使单测无需真实挂载 DMG 即可确定性验证。
//
// 不变量：集合仅在内存（无持久化）；探测失败视为非 DMG（安全降级为「平铺」）。
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class DmgMountMonitor {
    /// 探测一个卷 URL 是否为 DMG；返回 (是否 DMG, 卷名)。
    /// nil = 探测失败（调用方按「非 DMG」处理，安全降级）。
    typealias DmgProbe = (URL) -> (isDmg: Bool, name: String?)?

    private let dmgProbe: DmgProbe
    /// 当前已挂载的 DMG 卷名集合。
    private var mountedDmgNames: Set<String> = []

    init(dmgProbe: @escaping DmgProbe = DmgMountMonitor.defaultDmgProbe) {
        self.dmgProbe = dmgProbe
    }

    /// 该卷名是否为当前已挂载的 DMG。
    func isMountedDmgVolume(_ name: String) -> Bool {
        !name.isEmpty && mountedDmgNames.contains(name)
    }

    /// 挂载事件处理：探测该卷，若是 DMG 则登记其卷名。
    /// 卷名优先用探测结果；探测未给名字时回退到卷 URL 的最后一段（/Volumes/<name>）。
    func registerMount(volumeURL: URL) {
        guard let result = dmgProbe(volumeURL), result.isDmg else { return }
        let name = result.name?.isEmpty == false
            ? result.name!
            : volumeURL.lastPathComponent
        guard !name.isEmpty else { return }
        mountedDmgNames.insert(name)
    }

    /// 卸载事件处理：移除该卷名。
    func registerUnmount(volumeURL: URL) {
        let name = dmgProbe(volumeURL)?.name
        let resolved = (name?.isEmpty == false ? name! : volumeURL.lastPathComponent)
        guard !resolved.isEmpty else { return }
        mountedDmgNames.remove(resolved)
    }

    // MARK: - 生产环境默认 DA 探测（Task 2 实现）

    static let defaultDmgProbe: DmgProbe = { url in
        // 占位：Task 2 替换为真实 DiskArbitration 实现。
        return nil
    }
}
