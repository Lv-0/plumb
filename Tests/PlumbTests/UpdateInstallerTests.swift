import Testing
import Foundation
@testable import Plumb

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateInstallerTests
//
// 锁死 OTA 安装器修复的关键不变量。这些不变量历史上被破坏过，导致"无法完成
// 软件更新"：
//
//   1. 生成的 AppleScript 必须是**单行**（不含 \n）。
//      多行形式能 compile 但 execute 报 -2741，是阻塞所有 OTA 的根因。
//   2. 安装源路径在没有 UserDefaults 标志时，必须回退到当前进程的 bundle 路径
//      （coordinator 现在直接启动新 app 进安装器，新 app 自身就是源）。
//      这保证即便标志丢失也能完成安装，不再卡死。
//   3. shell 脚本用单引号包裹路径、rm + cp -R 原子替换，不接受外部输入。
//   4. AppleScript 对路径里的特殊字符（引号、反斜杠）正确转义，不破坏语法。
// ─────────────────────────────────────────────────────────────────────────────

@Suite("UpdateInstallerCommand")
struct UpdateInstallerTests {

    // MARK: AppleScript 单行不变量（回归 -2741）

    @Test("buildAppleScript produces a single-line script (regression for -2741)")
    func appleScriptIsSingleLine() {
        let shell = "rm -rf '/Applications/Plumb.app' && cp -R '/var/folders/x/Plumb.app' '/Applications/Plumb.app'"
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: shell)
        // 历史根因：多行 AppleScript 在 executeAndReturnError 报 -2741。这里钉死"单行"。
        #expect(!apple.contains("\n"))
        #expect(apple.hasPrefix("do shell script \""))
        #expect(apple.hasSuffix("\" with administrator privileges"))
    }

    @Test("buildAppleScript ends with the documented single-line form")
    func appleScriptDocumentedForm() {
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: "true")
        // 标准文档形式：单行，echo $? 在同一字符串字面量内。
        #expect(apple == "do shell script \"true ; echo $?\" with administrator privileges")
    }

    // MARK: 转义

    @Test("buildAppleScript escapes embedded double quotes")
    func escapesDoubleQuotes() {
        // 含双引号的路径必须被转义，否则破坏 AppleScript 字符串字面量。
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: "echo \"hi\"")
        #expect(apple.contains("\\\"hi\\\""))
        #expect(!apple.contains("\n"))
    }

    @Test("buildAppleScript escapes backslashes")
    func escapesBackslashes() {
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: "echo a\\b")
        #expect(apple.contains("\\\\b"))
        #expect(!apple.contains("\n"))
    }

    // MARK: shell 脚本构造

    @Test("buildShellScript uses rm + cp -R with quoted paths")
    func shellScriptShape() {
        let src = "/var/folders/abc/Plumb.app"
        let script = UpdateInstallerCommand.buildShellScript(source: src)
        #expect(script == "rm -rf '/Applications/Plumb.app' && cp -R '\(src)' '/Applications/Plumb.app'")
    }

    @Test("buildShellScript accepts custom destination")
    func shellScriptCustomDest() {
        let script = UpdateInstallerCommand.buildShellScript(
            source: "/tmp/Src.app", destination: "/tmp/Dst.app")
        #expect(script == "rm -rf '/tmp/Dst.app' && cp -R '/tmp/Src.app' '/tmp/Dst.app'")
    }

    @Test("buildShellScript escapes single quotes in paths")
    func shellScriptEscapesSingleQuotes() {
        let script = UpdateInstallerCommand.buildShellScript(
            source: "/tmp/O'Connor/Plumb.app",
            destination: "/Applications/Plumb's Copy.app")
        #expect(script == "rm -rf '/Applications/Plumb'\\''s Copy.app' && cp -R '/tmp/O'\\''Connor/Plumb.app' '/Applications/Plumb'\\''s Copy.app'")
    }

    @Test("relaunch script shell-quotes app path")
    func relaunchScriptQuotesAppPath() {
        let script = UpdateRelaunchCommand.buildScript(
            appPath: "/tmp/O'Connor/Test App/Plumb.app",
            delaySeconds: 0)
        #expect(script == "#!/bin/bash\nsleep 0\n/usr/bin/open -n -- '/tmp/O'\\''Connor/Test App/Plumb.app'\n")
    }

    // MARK: 源路径解析（本次修复核心：bundle path 回退）

    @Test("resolveSourcePath uses UserDefaults path when it exists on disk")
    func prefersDefaultsPath() throws {
        // 创建一个真实存在的临时路径，模拟解压后的新 app。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: tmp.path,
            bundlePathFallback: "/some/other/path.app")
        #expect(resolved == tmp.path)
    }

    @Test("resolveSourcePath falls back to bundle path when UserDefaults path is nil")
    func fallsBackToBundlePath() throws {
        // 模拟新 app 自启动进安装器：标志未写（或丢失），但 Bundle.main 存在。
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: nil,
            bundlePathFallback: tmp.path)
        #expect(resolved == tmp.path)
    }

    @Test("resolveSourcePath falls back to bundle path when UserDefaults path is missing on disk")
    func fallsBackToBundlePathWhenDefaultsStale() throws {
        // UserDefaults 里残留的临时路径已被系统清理（/var/folders 定期回收）。
        // 此时必须回退到 bundle path，否则安装器报 missingAppPath 卡死。
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: "/var/folders/STALE/Plumb.app",   // 不存在
            bundlePathFallback: bundle.path)
        #expect(resolved == bundle.path)
    }

    @Test("resolveSourcePath returns nil when neither path exists")
    func returnsNilWhenBothMissing() {
        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: "/nonexistent/a.app",
            bundlePathFallback: "/nonexistent/b.app")
        #expect(resolved == nil)
    }

    @Test("resolveSourcePath ignores empty UserDefaults path")
    func ignoresEmptyDefaults() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let resolved = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: "",
            bundlePathFallback: bundle.path)
        #expect(resolved == bundle.path)
    }

    // MARK: 端到端：源解析 → shell → AppleScript

    @Test("end-to-end: bundle-path fallback yields a valid single-line privileged install")
    func endToEndBundleFallback() throws {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-test-src-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        // 模拟新 app 自启动：无 UserDefaults 标志。
        let src = UpdateInstallerCommand.resolveSourcePath(
            defaultsPath: nil, bundlePathFallback: bundle.path)
        #expect(src != nil)
        let shell = UpdateInstallerCommand.buildShellScript(source: src!)
        let apple = UpdateInstallerCommand.buildAppleScript(shellScript: shell)

        // 不变量：单行、合法形式。
        #expect(!apple.contains("\n"))
        #expect(apple.contains("cp -R"))
        #expect(apple.contains("with administrator privileges"))
        #expect(apple.contains(bundle.path))
    }

    // MARK: canReplaceWithoutPrivileges（双路径核心：与 Sparkle 无密码启发式一致）
    //
    // 决定安装器走"无提权快路径"还是"AppleScript 提权路径"。
    // 逻辑（纯函数，依赖注入 owner/writable/uid，可单测全部分支）：
    //   - 目标存在：仅当目标 owner == 当前 uid 才可无提权替换；
    //   - 目标不存在：仅当父目录当前 uid 可写才可无提权创建。
    // 用注入形式避免在单测里构造 root-owned 真实文件（单测进程非 root）。

    @Test("canReplaceWithoutPrivileges: admin-owned target → true (fast path)")
    func canReplaceAdminOwnedTarget() {
        // 目标 .app 存在，owner 是当前用户（admin 组）→ 无需提权即可 rm + cp。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: true,
            destinationOwnerUID: 501,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == true)
    }

    @Test("canReplaceWithoutPrivileges: root-owned target → false (needs privileges)")
    func canReplaceRootOwnedTarget() {
        // 目标 .app 存在但 owner=root(0)，当前用户=501 → 必须提权（当前机器的真实状态）。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: true,
            destinationOwnerUID: 0,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == false)
    }

    @Test("canReplaceWithoutPrivileges: missing target + writable parent → true")
    func canReplaceMissingTargetWritableParent() {
        // 目标不存在（新装），父目录 /Applications 当前用户可写 → 直接 mv，无需提权。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: false,
            destinationOwnerUID: 0,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == true)
    }

    @Test("canReplaceWithoutPrivileges: missing target + non-writable parent → false")
    func canReplaceMissingTargetNonWritableParent() {
        // 目标不存在且父目录不可写（如受限的 /Applications）→ 需提权。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: false,
            destinationOwnerUID: 0,
            parentDirectoryWritable: false,
            currentUID: 501)
        #expect(r == false)
    }

    @Test("canReplaceWithoutPrivileges: admin-owned but uid mismatch → false")
    func canReplaceOwnedByOtherUser() {
        // 目标存在，owner 是别的非 root 用户（如 502），当前用户 501 无权删 → 需提权。
        let r = UpdateInstallerCommand.canReplaceWithoutPrivileges(
            destination: "/Applications/Plumb.app",
            destinationExists: true,
            destinationOwnerUID: 502,
            parentDirectoryWritable: true,
            currentUID: 501)
        #expect(r == false)
    }

    // MARK: 快路径替换语义（无提权 rm + mv，纯 FileManager，无 shell 注入面）
    //
    // 快路径与提权路径的等价性：都把 source 完整放到 destination。
    // 用真实临时目录验证 FileManager 替换语义（rm 旧 + mv 新），覆盖"目标已存在"
    // 与"目标不存在"两种情况——这正是 admin-owned 目标走快路径时的真实行为。

    @Test("replaceWithoutPrivileges: missing destination → mv source into place")
    func replaceMissingDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-replace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // source: 一个假的 .app 目录（含一个文件，模拟 bundle 内容）
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "binary".write(to: src.appendingPathComponent("Plumb"), atomically: true, encoding: .utf8)

        let dest = tmp.appendingPathComponent("Plumb.app")
        #expect(!FileManager.default.fileExists(atPath: dest.path))

        try UpdateInstallerCommand.replaceWithoutPrivileges(
            source: src.path, destination: dest.path)

        // 替换后 dest 存在，且内容来自 source。
        #expect(FileManager.default.fileExists(atPath: dest.path))
        let moved = try String(contentsOf: dest.appendingPathComponent("Plumb"), encoding: .utf8)
        #expect(moved == "binary")
        // source 应已被 mv 走（不再在原位）。
        #expect(!FileManager.default.fileExists(atPath: src.path))
    }

    @Test("replaceWithoutPrivileges: existing destination → rm old + mv new")
    func replaceExistingDestination() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("plumb-replace-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // source（新版本内容）
        let src = tmp.appendingPathComponent("Source.app", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "new-binary".write(to: src.appendingPathComponent("Plumb"), atomically: true, encoding: .utf8)

        // destination（旧版本，存在且内容不同）
        let dest = tmp.appendingPathComponent("Plumb.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "old-binary".write(to: dest.appendingPathComponent("Plumb"), atomically: true, encoding: .utf8)

        try UpdateInstallerCommand.replaceWithoutPrivileges(
            source: src.path, destination: dest.path)

        // 替换后 dest 内容是新版本。
        let moved = try String(contentsOf: dest.appendingPathComponent("Plumb"), encoding: .utf8)
        #expect(moved == "new-binary")
        #expect(!FileManager.default.fileExists(atPath: src.path))
    }
}
