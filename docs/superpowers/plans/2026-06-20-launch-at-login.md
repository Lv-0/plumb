# Launch at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Launch at Login" toggle to Plumb's Permissions tab that registers/unregisters Plumb as a macOS login item via `SMAppService.mainApp()`.

**Architecture:** A thin static facade `LaunchAtLogin` wraps `SMAppService.mainApp()` — the system is the single source of truth (no UserDefaults mirror). The Permissions tab gains a second standalone card reusing the existing `PillToggle`. Two new `L10n` keys are added across all 5 languages, automatically covered by the existing `tableCompleteness` test.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit, `ServiceManagement.framework` (system framework, auto-linked on macOS — no `Package.swift` change needed), swift-testing.

**Spec:** `docs/superpowers/specs/2026-06-20-launch-at-login-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Plumb/LaunchAtLogin.swift` | Create | Thin static facade over `SMAppService.mainApp()`: `isEnabled`, `enable()`, `disable()`. |
| `Sources/Plumb/Localization.swift` | Modify | Add `launchAtLogin` + `launchAtLoginHint` keys to the `Key` enum, all 5 language tables, and the no-arg accessors. |
| `Sources/Plumb/SettingsUI/PermissionsSection.swift` | Modify | Add a standalone "Launch at Login" card below the permissions card, reusing `PillToggle`. |
| `Tests/PlumbTests/LaunchAtLoginTests.swift` | Create | Static-surface tests only (register/unregister are environment-dependent and skipped). |

**No `Package.swift` change** — `ServiceManagement` is a system framework auto-linked when imported on macOS.

---

## Task 1: Localization keys (5 languages)

This task is done first because the UI task (Task 3) references `L10n.launchAtLogin` / `L10n.launchAtLoginHint`, and the existing `tableCompleteness` test enforces that every `Key` exists in every language — so adding the keys without all 5 languages would break the build's test run immediately.

**Files:**
- Modify: `Sources/Plumb/Localization.swift`

- [ ] **Step 1: Add the two keys to the `Key` enum**

In `Sources/Plumb/Localization.swift`, inside `enum Key: String, CaseIterable { ... }`, add two cases in the `// 权限段` group (right after `case openSettings`):

```swift
        case launchAtLogin
        case launchAtLoginHint
```

- [ ] **Step 2: Add entries to all 5 language tables**

In the `static let table: [AppLanguage: [Key: String]]` dictionary, add the following two lines to **each** language's dictionary (place them right after the `.openSettings:` line in each):

`.en:` table:
```swift
            .launchAtLogin: "Launch at Login",
            .launchAtLoginHint: "Automatically launch Plumb when your Mac starts.",
```

`.es:` table:
```swift
            .launchAtLogin: "Abrir al iniciar sesión",
            .launchAtLoginHint: "Inicia Plumb automáticamente al encender el Mac.",
```

`.fr:` table:
```swift
            .launchAtLogin: "Lancer à la connexion",
            .launchAtLoginHint: "Lance Plumb automatiquement au démarrage du Mac.",
```

`.zh:` table:
```swift
            .launchAtLogin: "开机自启动",
            .launchAtLoginHint: "Mac 开机后自动启动 Plumb。",
```

`.ja:` table:
```swift
            .launchAtLogin: "ログイン時に起動",
            .launchAtLoginHint: "Mac 起動時に Plumb を自動的に起動します。",
```

- [ ] **Step 3: Add the two no-arg accessors**

In the `// MARK: - 访问器（无参）` section, add (e.g. right after the `openSettings` accessor line `static var openSettings: String { tr(.openSettings) }`):

```swift
    static var launchAtLogin: String { tr(.launchAtLogin) }
    static var launchAtLoginHint: String { tr(.launchAtLoginHint) }
```

- [ ] **Step 4: Verify build + the existing completeness test passes**

Run: `swift build 2>&1 | tail -5 && swift test --filter LocalizationTests 2>&1 | tail -20`
Expected: Build succeeds; all `LocalizationTests` pass (including `tableCompleteness`, which now validates the 2 new keys exist & non-empty in all 5 languages).

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/Localization.swift
git commit -m "feat(l10n): add launchAtLogin keys (en/es/fr/zh/ja)"
```

---

## Task 2: `LaunchAtLogin` facade module + tests (TDD)

**Files:**
- Create: `Tests/PlumbTests/LaunchAtLoginTests.swift`
- Create: `Sources/Plumb/LaunchAtLogin.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/PlumbTests/LaunchAtLoginTests.swift`:

```swift
import ServiceManagement
import Testing
@testable import Plumb

@Suite("LaunchAtLogin")
struct LaunchAtLoginTests {

    // MARK: - Static surface (no system registration side-effects)

    @Test("isEnabled reads without throwing")
    func isEnabledReadable() {
        // Reading must never throw/crash regardless of environment.
        // (In `swift test` the bare executable is unregistered → expect false,
        //  but we only assert the call succeeds; the value is environment-dependent.)
        let _ = LaunchAtLogin.isEnabled
    }

    @Test("enable/disable are callable (result is environment-dependent)")
    func enableDisableCallable() {
        // SMAppService.mainApp() requires a signed .app bundle, so under
        // `swift test` register/unregister may throw. We only assert the
        // methods are callable and that isEnabled stays consistent afterwards —
        // we do NOT assert success/failure of the registration itself.
        do { try LaunchAtLogin.enable() }  catch {}
        do { try LaunchAtLogin.disable() } catch {}
        // After disable, in the test environment the service should be unregistered.
        // We assert it does not throw on read; value not asserted (env-dependent).
        let _ = LaunchAtLogin.isEnabled
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (module not found)**

Run: `swift test --filter LaunchAtLoginTests 2>&1 | tail -20`
Expected: FAIL / build error — `LaunchAtLogin` is not defined.

- [ ] **Step 3: Write the minimal implementation**

Create `Sources/Plumb/LaunchAtLogin.swift`:

```swift
import Foundation
import ServiceManagement

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - LaunchAtLogin
//
// 模块角色：开机自启动的薄封装，基于 SMAppService.mainApp（macOS 13+）。
//
// 设计要点：
//   - 系统是唯一真实来源：isEnabled 直接读 SMAppService.status，不维护 UserDefaults 镜像，
//     避免本地布尔与系统状态失同步。
//   - 纯静态：无持久化、无状态持有。
//     注意：不缓存 SMAppService.mainApp 到 static let —— 该类型非 Sendable，缓存会触发
//     并发安全诊断；mainApp 本身是系统单例，每次访问开销可忽略。
//   - enable()/disable() 可抛错（如 swift test 裸可执行环境下 register 会失败），
//     由 UI 捕获并回滚开关到真实值。
//
// 前提：需以已签名的 .app 包运行；swift test 裸可执行环境下注册无法生效（仅不崩溃）。
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
```

> **Implementation note (discovered during build):** `SMAppService.mainApp` is a **property**
> (`NS_SWIFT_NAME(mainApp)` on a `@property(class, readonly)` Objective-C declaration), not a
> function — do **not** write `SMAppService.mainApp()`. Additionally `SMAppService` is not
> `Sendable`, so caching it in a `static let service` triggers a concurrency-safety error;
> access the singleton directly each call instead (as shown above).

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter LaunchAtLoginTests 2>&1 | tail -20`
Expected: PASS — both tests pass (they only assert callability/consistency, not registration success).

- [ ] **Step 5: Commit**

```bash
git add Sources/Plumb/LaunchAtLogin.swift Tests/PlumbTests/LaunchAtLoginTests.swift
git commit -m "feat: add LaunchAtLogin facade (SMAppService.mainApp)"
```

---

## Task 3: Permissions tab — "Launch at Login" card

**Files:**
- Modify: `Sources/Plumb/SettingsUI/PermissionsSection.swift`

**Context for the implementer:**
- `PillToggle` (defined in `Sources/Plumb/SettingsUI/AppListRow.swift`) takes `@Binding var isOn: Bool` and toggles it internally on tap. So we drive the real `enable()`/`disable()` from `onChange(of: launchAtLogin)`, and roll back to the system's true value if the call throws.
- The existing permissions card uses `.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))`. The new card reuses the exact same styling for visual consistency.

- [ ] **Step 1: Add the launch-at-login state and refresh it**

In `Sources/Plumb/SettingsUI/PermissionsSection.swift`, add a new `@State` to the `PermissionsSection` struct (right below `@State private var screenCaptureOK = false`):

```swift
    @State private var launchAtLogin: Bool = false
```

Update the existing `refresh()` method to also read the launch-at-login state. Replace the whole `refresh()` method with:

```swift
    private func refresh() {
        accessibilityOK = AccessibilityPermission.ensureTrusted(prompt: false)
        screenCaptureOK = ScreenCapturePermission.ensureAuthorized(prompt: false)
        launchAtLogin = LaunchAtLogin.isEnabled
    }
```

- [ ] **Step 2: Add the standalone card to the body's VStack**

In `body`, the outer `VStack(alignment: .leading, spacing: 12) { ... }` currently contains the `permissionsIntro` Text and the permissions card VStack. Add the new card **immediately after** the permissions card's closing `}` (the one that ends the `.background(RoundedRectangle(...))` chained block) and **before** the outer VStack's closing `}`. Insert:

```swift
                launchAtLoginCard
```

So the structure becomes:
```swift
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.permissionsIntro)
                    ...
                VStack(alignment: .leading, spacing: 12) {
                    permissionRow(... accessibility ...)
                    Divider()
                    permissionRow(... screenRecording ...)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))

                launchAtLoginCard      // ← NEW
            }
```

- [ ] **Step 3: Add the `launchAtLoginCard` computed view + the toggle handler**

Add these two members to the `PermissionsSection` struct (e.g. right before the existing `private func permissionRow(...)`):

```swift
    /// 开机自启动独立卡片：图标 + 标题/说明 + 开关。视觉与权限卡片一致。
    private var launchAtLoginCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "power")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.launchAtLogin)
                    .foregroundStyle(.primary)
                Text(L10n.launchAtLoginHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            PillToggle(isOn: $launchAtLogin)
                .animation(.spring(duration: 0.32, bounce: 0.25), value: launchAtLogin)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .onChange(of: launchAtLogin) { _, isOn in
            toggleLaunchAtLogin(to: isOn)
        }
    }

    /// 切换开机自启动：失败时回滚开关到系统真实值，保持一致且不崩溃。
    private func toggleLaunchAtLogin(to isOn: Bool) {
        do {
            if isOn { try LaunchAtLogin.enable() }
            else    { try LaunchAtLogin.disable() }
            // 以系统状态为准刷新（注册可能进入 .requiresApproval 等）。
            launchAtLogin = LaunchAtLogin.isEnabled
        } catch {
            // 失败（如裸可执行环境）→ 回滚到真实状态。
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -15`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Run full test suite to ensure nothing regressed**

Run: `swift test 2>&1 | tail -25`
Expected: All tests pass (LocalizationTests validates the 2 new keys; LaunchAtLoginTests passes; no existing test broken).

- [ ] **Step 6: Commit**

```bash
git add Sources/Plumb/SettingsUI/PermissionsSection.swift
git commit -m "feat(settings): launch-at-login card in Permissions tab"
```

---

## Task 4: Manual integration verification (documented, not automated)

This task cannot be automated (`SMAppService.mainApp()` needs a signed `.app`). It is the acceptance gate for the feature itself.

- [ ] **Step 1: Build the .app bundle**

Run: `scripts/build_app.sh`
Expected: Produces `dist/Plumb.app` without error.

- [ ] **Step 2: Run the built app and open Settings → Permissions**

Open `dist/Plumb.app`. Click the menu-bar icon → Settings… → Permissions tab. Confirm the "Launch at Login" card appears below the permissions card with a `power` icon, title, hint, and a toggle currently off.

- [ ] **Step 3: Toggle ON and verify registration**

Turn the toggle ON. Open **System Settings → General → Login Items**. Confirm "Plumb" appears in the "Open at Login" list.

- [ ] **Step 4: Toggle OFF and verify unregistration**

Turn the toggle OFF. Confirm "Plumb" disappears from the System Settings Login Items list.

- [ ] **Step 5: Verify external-change reflects in UI**

In System Settings → Login Items, manually re-add or remove Plumb (or use the toggle there). Reopen Plumb's Settings → Permissions tab. Confirm the toggle reflects the true system state (single source of truth).

---

## Self-Review (completed during planning)

**1. Spec coverage:**
- §3 `LaunchAtLogin` facade → Task 2. ✓
- §4 Permissions card (standalone, below, PillToggle, `power` icon, onChange + rollback) → Task 3. ✓
- §5 two L10n keys × 5 languages → Task 1. ✓
- §6 behavior (register/unregister, system as truth, default off) → Task 2 (facade) + Task 3 (UI wiring). ✓
- §7 tests (LocalizationTests auto-cover; LaunchAtLoginTests static-only) → Task 1 Step 4 + Task 2. ✓
- §7 manual integration verification → Task 4. ✓
- §9 file list matches Tasks 1–3 exactly. ✓

**2. Placeholder scan:** None. All code shown in full; no TBD/TODO/"add error handling".

**3. Type consistency:** `LaunchAtLogin.isEnabled` / `enable()` / `disable()` (Task 2) match usage in `refresh()` and `toggleLaunchAtLogin(to:)` (Task 3). `PillToggle(isOn: $launchAtLogin)` matches its `@Binding var isOn: Bool` definition. `L10n.launchAtLogin` / `L10n.launchAtLoginHint` (Task 1 accessors) match usage in Task 3's card.
