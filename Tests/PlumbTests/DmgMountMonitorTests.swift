import Foundation
import Testing
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// DmgMountMonitor 单测。
//
// 通过注入 DA 探测闭包（dmgProbe）实现可注入、可测：生产代码传真实 DiskArbitration
// 实现，测试传 mock，无需真实挂载 DMG 即可确定性验证判定逻辑。
// dmgProbe 签名：(URL) -> (isDmg: Bool, name: String?)?
//   - 返回 nil：探测失败（视为非 DMG，安全降级）
//   - 返回 (true, name)：是 DMG，卷名为 name
//   - 返回 (false, _)：不是 DMG
// ─────────────────────────────────────────────────────────────────────────────

@Test
@MainActor
func dmgMonitor_startsEmpty() {
    let monitor = DmgMountMonitor(dmgProbe: { _ in nil })
    #expect(monitor.isMountedDmgVolume("Anything") == false)
    #expect(monitor.isMountedDmgVolume("") == false)
}

@Test
@MainActor
func dmgMonitor_registersDmgOnMount_andRemovesOnUnmount() {
    // mock：只有 /Volumes/Plumb 是 DMG
    let probe: DmgMountMonitor.DmgProbe = { url in
        if url.path == "/Volumes/Plumb" {
            return (isDmg: true, name: "Plumb")
        }
        return (isDmg: false, name: nil)
    }
    let monitor = DmgMountMonitor(dmgProbe: probe)

    monitor.registerMount(volumeURL: URL(fileURLWithPath: "/Volumes/Plumb"))
    #expect(monitor.isMountedDmgVolume("Plumb") == true)

    monitor.registerUnmount(volumeURL: URL(fileURLWithPath: "/Volumes/Plumb"))
    #expect(monitor.isMountedDmgVolume("Plumb") == false)
}

@Test
@MainActor
func dmgMonitor_doesNotRegisterUsbDrive() {
    // mock：USB 盘 → isDmg=false
    let probe: DmgMountMonitor.DmgProbe = { _ in
        return (isDmg: false, name: "MyUSB")
    }
    let monitor = DmgMountMonitor(dmgProbe: probe)

    monitor.registerMount(volumeURL: URL(fileURLWithPath: "/Volumes/MyUSB"))
    #expect(monitor.isMountedDmgVolume("MyUSB") == false)
}

@Test
@MainActor
func dmgMonitor_probeFailureTreatedAsNonDmg() {
    // mock：探测失败（返回 nil）→ 不登记
    let probe: DmgMountMonitor.DmgProbe = { _ in nil }
    let monitor = DmgMountMonitor(dmgProbe: probe)

    monitor.registerMount(volumeURL: URL(fileURLWithPath: "/Volumes/Plumb"))
    #expect(monitor.isMountedDmgVolume("Plumb") == false)
}

@Test
@MainActor
func dmgMonitor_unmountUnknownVolumeIsNoop() {
    let probe: DmgMountMonitor.DmgProbe = { url in
        url.path == "/Volumes/A" ? (isDmg: true, name: "A") : (isDmg: false, name: nil)
    }
    let monitor = DmgMountMonitor(dmgProbe: probe)
    monitor.registerMount(volumeURL: URL(fileURLWithPath: "/Volumes/A"))

    // 卸载一个从未登记的卷：不应崩溃、不影响已登记集合。
    monitor.registerUnmount(volumeURL: URL(fileURLWithPath: "/Volumes/Unknown"))
    #expect(monitor.isMountedDmgVolume("A") == true)
}

@Test
@MainActor
func dmgMonitor_startPrescansAlreadyMountedVolumes() {
    // mock 探测：只有 /Volumes/AlreadyMounted 是 DMG。
    let probe: DmgMountMonitor.DmgProbe = { url in
        url.path == "/Volumes/AlreadyMounted"
            ? (isDmg: true, name: "AlreadyMounted")
            : (isDmg: false, name: nil)
    }
    // 注入枚举闭包：返回一组「当前已挂载卷」，模拟 /Volumes/*。
    let volumes: [URL] = [
        URL(fileURLWithPath: "/Volumes/AlreadyMounted"),
        URL(fileURLWithPath: "/Volumes/SomeUSB")
    ]
    let monitor = DmgMountMonitor(dmgProbe: probe)
    monitor.prescanExistingVolumes(volumes)

    #expect(monitor.isMountedDmgVolume("AlreadyMounted") == true)
    #expect(monitor.isMountedDmgVolume("SomeUSB") == false)
}

@Test
@MainActor
func dmgMonitor_start_doesNotCrashAndPrescansViaEnumerator() {
    let probe: DmgMountMonitor.DmgProbe = { url in
        url.path == "/Volumes/Pre" ? (isDmg: true, name: "Pre") : (isDmg: false, name: nil)
    }
    let monitor = DmgMountMonitor(dmgProbe: probe)
    // 注入枚举器返回一个已挂载 DMG；start() 应预扫它。
    monitor.start(existingVolumesEnumerator: {
        [URL(fileURLWithPath: "/Volumes/Pre")]
    })
    #expect(monitor.isMountedDmgVolume("Pre") == true)
    monitor.stop()
}
