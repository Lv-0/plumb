# UI Localization Design — Auto-Follow System Language (zh / en / ja)

- **Date:** 2026-06-18
- **Status:** Approved for implementation
- **Objective:** 根据系统语言自动选择展示对应的界面语言，当前支持中文（zh）、英语（en）、日语（ja）
- **Approach:** B — Swift `L10n` enum (in-code string table)

---

## 1. Background & Constraints

Plumb is a pure-SwiftPM macOS menu-bar executable (`Package.swift`, `swift-tools-version 6.2`, target `.macOS(.v26)`), packaged into `Plumb.app` by `scripts/build_app.sh` (manual binary + icon + generated `Info.plist` copy into `Contents/`). There is **no Xcode project**.

All user-facing strings today are **hardcoded Chinese** scattered across 7 files (~50 strings):
`AppDelegate.swift`, `WindowCenteringService.swift` (error descriptions), `SettingsWindowController.swift`, and `SettingsUI/{SettingsView,PermissionsSection,TilingSection,AppListSection,AppListRow}.swift`.

There is **no existing localization infrastructure**: no `.lproj`, no `.strings`, no `.xcstrings`, no `NSLocalizedString`/`String(localized:)` usage.

### Why Approach A (`.xcstrings` / String Catalog) was rejected

1. **String Catalogs are an Xcode build-time feature.** `swift build` does not compile `.xcstrings` into `.strings`. Adopting it here would require a manual catalog→strings compile step bolted onto the build.
2. **SPM resources load from `Bundle.module`; runtime lookup uses `Bundle.main` (`Contents/Resources`).** `NSLocalizedString`/`String(localized:)` resolves against `Bundle.main`. Approach A would therefore require modifying `scripts/build_app.sh` to copy `.lproj` dirs into `Contents/Resources/` — a coupling invisible to `swift test` and fragile to get right.
3. **Approach B behaves identically under `swift test` and inside the packaged `.app`** — zero bundle/`Info.plist`/`build_app.sh` coupling — and at ~50 strings is no less maintainable than a catalog.

### Out of scope (YAGNI)

- No manual language picker — "auto-follow system" is the full objective.
- No runtime language switching without app restart.
- No localization of app icon or README (UI only).
- `SelfTest*` UI-automation strings are developer tooling, not end-user-facing — left untouched.

---

## 2. Design

### 2.1 Language detection (resolved once, immutably)

A small `AppLanguage` enum resolves the active language from `Locale.preferredLanguages` at first access and caches it:

```swift
enum AppLanguage {
    case zh, en, ja

    /// Resolved once on first access and cached for the process lifetime.
    /// Immutability is intentional and sufficient: the objective is
    /// "auto-follow system language at launch". A language change requires
    /// an app restart, which is the conventional macOS contract.
    static let current: AppLanguage = resolve(from: Locale.preferredLanguages)

    /// Pure, testable resolver: takes an ordered preference list (as the
    /// system would provide) and returns the first supported match.
    static func resolve(from preferences: [String]) -> AppLanguage {
        for pref in preferences {
            let lang = Locale(identifier: pref).language.languageCode?.identifier ?? ""
            switch lang {
            case "zh": return .zh
            case "ja": return .ja
            case "en": return .en
            default: continue
            }
        }
        return .en   // universal fallback
    }
}
```

**Resolution rules:**
- Walk `Locale.preferredLanguages` in user-preference order.
- Map by ISO language code (`zh`/`ja`/`en`); region/script variants (`zh-Hans-CN`, `zh-Hant-TW`, `ja-JP`, `en-GB`) all collapse to their base language.
- First supported match wins — the user's top preference is honored.
- If **no** preference matches a supported language (e.g. French-only system), fall back to `.en`.
- If the preference list is empty (should not happen on macOS), fall back to `.en`.

### 2.2 String table — new file `Sources/Plumb/Localization.swift`

A `L10n` namespace exposing typed accessors backed by three flat `[Key: String]` dictionaries. Keys live in a `String`-backed `Key` enum so typos are compile-time errors.

```swift
enum L10n {
    static let appName = "Plumb"   // brand name, never localized

    static var menuSubtitle: String { tr(.menuSubtitle) }
    static var centerNow: String { tr(.centerNow) }
    // … full list in §3 inventory …
}
```

**Lookup** selects the dictionary for `AppLanguage.current` and indexes by `Key`:

```swift
private func tr(_ key: L10n.Key, _ args: CVarArg...) -> String {
    let template = L10n.table[AppLanguage.current]?[key]
        ?? L10n.table[.en]![key]!          // defensive: en always complete
    return args.isEmpty ? template : String(format: template, arguments: args)
}
```

The double-unwrap on the English fallback is intentional: if a language table is ever missing a key, the English value is shown rather than crashing. (Tests in §4 assert completeness so this branch never triggers in practice.)

**Interpolation** uses `String(format:arguments:)` (e.g. margin values, on/off state). All format templates use positional `%@`/`%d` and are verified to format cleanly under all three languages in tests.

### 2.3 Call-site migration (7 files, ~50 strings)

| Layer | Pattern | Example |
|---|---|---|
| **SwiftUI** (`SettingsUI/*.swift`) | `Text("居中")` → `Text(L10n.tabCentering)`. SwiftUI `Text` accepts any `StringProtocol`; passing a plain `String` **bypasses** its `LocalizedStringKey` lookup so our resolved value is displayed verbatim (no double-localization ambiguity). | `Text("启用自动平铺")` → `Text(L10n.enableAutoTiling)` |
| **AppKit** (`AppDelegate.swift`, `SettingsWindowController.swift`) | `NSMenuItem(title:)`, `NSAlert.messageText`, `window.title` — replace literals with `L10n.*`. | `menu.addItem(withTitle: "立即居中", …)` → `withTitle: L10n.centerNow`; `window.title = "设置"` → `L10n.settings` |
| **Errors** (`WindowCenteringService.swift`) | `errorDescription` returns `L10n.err*()`. `error.localizedDescription` (used in the alert) then flows the localized text automatically. | `return "缺少辅助功能权限…"` → `return L10n.errAccessibilityPermissionMissing()` |

### 2.4 `Info.plist` / `build_app.sh`

- **No required changes.** `L10n` is fully in-code; the binary carries all strings.
- **Optional (recommended):** add `CFBundleLocalizations` to the generated `Info.plist` in `scripts/build_app.sh`:
  ```xml
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh</string>
    <string>en</string>
    <string>ja</string>
  </array>
  ```
  This declares supported languages to the system (informational; affects things like future `.strings` fallback and App Store metadata). It does **not** change runtime resolution — `L10n` is authoritative.

---

## 3. String Inventory

Full enumeration of strings to migrate. Keys are grouped by UI region.

### Menu bar (`AppDelegate.swift`)
| Key | zh (current) | en | ja |
|---|---|---|---|
| `menuSubtitle` | 窗口居中 · 平铺 | Window Centering · Tiling | ウィンドウ中央寄せ · タイル |
| `centerNow` | 立即居中 | Center Now | 今すぐ中央寄せ |
| `settings` | 设置… | Settings… | 設定… |
| `accessibilityPermission` | 辅助功能权限… | Accessibility Permission… | アクセシビリティ権限… |
| `screenRecordingPermission` | 屏幕录制权限… | Screen Recording Permission… | 画面収録権限… |
| `quitApp` | 退出 Plumb | Quit Plumb | Plumb を終了 |

### Main menu (`AppDelegate.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `about` | 关于 Plumb | About Plumb | Plumb について |
| `fileMenu` | 文件 | File | ファイル |
| `closeWindow` | 关闭窗口 | Close Window | ウィンドウを閉じる |

### Settings tabs (`SettingsView.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `tabCentering` | 居中 | Centering | 中央寄せ |
| `tabTiling` | 平铺 | Tiling | タイル |
| `tabPermissions` | 权限 | Permissions | 権限 |

### Centering section (`SettingsView.swift`, `AppListSection.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `centeringFootnote` | 空列表 = 居中所有应用；打开开关即仅居中所选应用。 | Empty list = center all apps; toggle on to center only selected apps. | 空のリスト = すべてのアプリを中央寄せ。オンにすると選択したアプリのみ中央寄せします。 |
| `searchApps` | 搜索应用 | Search Apps | アプリを検索 |

### Tiling section (`TilingSection.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `enableAutoTiling` | 启用自动平铺 | Enable Auto-Tiling | 自動タイルを有効化 |
| `enableAutoTilingHint` | 开启后，勾选下方应用时会自动平铺到屏幕。 | When enabled, checked apps below are auto-tiled onto the screen. | オンにすると、下のチェックしたアプリが自動的に画面にタイル配置されます。 |
| `margin` | 边距 | Margin | 余白 |
| `marginHint` | 平铺时窗口与屏幕边缘之间的间距。 | Spacing between window and screen edges when tiling. | タイル配置時のウィンドウと画面端の間隔。 |
| `tilingFootnoteOn` | 勾选希望自动平铺的应用；未勾选的应用保持居中。 | Check apps to auto-tile; unchecked apps stay centered. | 自動タイルするアプリにチェックを入れてください。未チェックのアプリは中央寄せのままです。 |
| `tilingFootnoteOff` | 请先在上方开启自动平铺。 | Enable auto-tiling above first. | まず上で自動タイルを有効にしてください。 |

### Permissions section (`PermissionsSection.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `permissionsIntro` | Plumb 需要以下权限才能控制窗口位置。 | Plumb needs the following permissions to control window positions. | Plumb がウィンドウの位置を制御するには以下の権限が必要です。 |
| `accessibility` | 辅助功能 | Accessibility | アクセシビリティ |
| `screenRecording` | 屏幕录制 | Screen Recording | 画面収録 |
| `granted` | 已授权 | Granted | 許可済み |
| `notGranted` | 未授权 | Not Granted | 未許可 |
| `openSettings` | 打开设置… | Open Settings… | 設定を開く… |

### Toggle / accessibility (`AppListRow.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `toggleSwitch` | 开关 | Switch | スイッチ |
| `on` | 开 | On | オン |
| `off` | 关 | Off | オフ |

### Settings window title (`SettingsWindowController.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `settings` (reused) | 设置 | Settings | 設定 |

### Errors / alerts (`AppDelegate.swift` + `WindowCenteringService.swift`)
| Key | zh | en | ja |
|---|---|---|---|
| `centerFailedTitle` | 窗口居中失败 | Window Centering Failed | ウィンドウの中央寄せに失敗しました |
| `errAccessibilityPermissionMissing` | 缺少辅助功能权限，请在"系统设置 -> 隐私与安全性 -> 辅助功能"中授权。 | Accessibility permission is missing. Grant it in System Settings → Privacy & Security → Accessibility. | アクセシビリティ権限がありません。「システム設定 → プライバシーとセキュリティ → アクセシビリティ」で許可してください。 |
| `errNoFrontmostApplication` | 未检测到前台应用。 | No frontmost application detected. | 最前面のアプリが検出されませんでした。 |
| `errNoWindow` | 前台应用没有可操作窗口。 | The frontmost app has no operable window. | 最前面のアプリに操作可能なウィンドウがありません。 |
| `errFullscreenWindow` | 当前窗口处于全屏状态，已跳过居中。 | The window is in fullscreen; centering skipped. | ウィンドウはフルスクリーンのため、中央寄せをスキップしました。 |
| `errUnableToReadWindowFrame` | 无法读取窗口位置或尺寸。 | Unable to read window position or size. | ウィンドウの位置またはサイズを読み取れません。 |
| `errUnableToWriteWindowSize` | 无法设置窗口尺寸（窗口可能不支持调整大小）。 | Unable to set window size (the window may not be resizable). | ウィンドウサイズを設定できません（サイズ変更不可の可能性があります）。 |
| `errUnableToWriteWindowPosition` | 无法设置窗口位置（窗口可能不可移动）。 | Unable to set window position (the window may not be movable). | ウィンドウ位置を設定できません（移動不可の可能性があります）。 |

---

## 4. Testing — new file `Tests/PlumbTests/LocalizationTests.swift`

Uses the `swift-testing` framework already wired into the package.

1. **`resolve(from:)` mapping** (pure function):
   - `["zh-Hans-CN"]` → `.zh`
   - `["zh-Hant-TW"]` → `.zh`
   - `["en-US"]` → `.en`
   - `["ja-JP"]` → `.ja`
   - `["fr-FR", "en-US"]` → `.en` (fallback to second preference)
   - `["fr-FR"]` → `.en` (no supported match → English)
   - `["ja", "zh"]` → `.ja` (user's first preference honored, not alphabetic)
   - `[]` → `.en` (empty list → fallback)

2. **Table completeness**: for each language in `[.zh, .en, .ja]`, every `Key.allCases` entry has a non-empty value. Catches any missing translation at test time.

3. **Format smoke**: for each language, render a couple of interpolated accessors (e.g. margin-style `String(format:)`) to ensure templates parse and don't crash.

---

## 5. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| A key is added later but forgotten in one language | Table-completeness test fails loudly on `swift test` |
| `Locale.preferredLanguages` returns identifiers without a language code | `?? ""` → `default: continue` → falls through to fallback |
| SwiftUI `Text` accidentally treats a string as `LocalizedStringKey` | Always pass plain `String` (from `L10n`); `Text(_:)` `StringProtocol` overload is unambiguous in current toolchain. Verified in migration. |
| Brand name "Plumb" should never change per locale | `appName` is a `let` constant, not routed through `tr`. |

---

## 6. Verification (Done criteria)

- [ ] `Localization.swift` exists with `AppLanguage` + `L10n` + all keys from §3 in all three languages.
- [ ] All 7 source files migrated; no remaining hardcoded Chinese literals in user-facing string positions.
- [ ] `LocalizationTests.swift` added; covers resolver mapping, table completeness, format smoke.
- [ ] `swift build` succeeds.
- [ ] `swift test` passes (all existing tests + new localization tests).
- [ ] (Optional) `CFBundleLocalizations` added to `scripts/build_app.sh` Info.plist.
