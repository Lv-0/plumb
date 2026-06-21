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
}
