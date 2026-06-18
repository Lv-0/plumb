# Design: App-list refresh fix + rename to Plumb

**Date:** 2026-06-18
**Status:** Ready for implementation
**Supersedes:** none

## Overview

Two independent user requests, bundled into one spec because both touch the
same UI surface and share verification:

1. **Refresh bug** — newly installed apps never appear in the settings app
   picker, because the catalog is loaded once and never refreshed.
2. **Rename** — rename the product from `centerWindows` to **Plumb**
   (carpenter's plumb line — finding true center), in the minimal & poetic
   spirit of 2026 Apple Design Award winners (e.g. *grug*, *Moonlitt*).

Both are independent; either can ship without the other. The rename is
broader (filesystem, package, scripts, docs); the refresh fix is surgical
(view lifecycle only).

---

## Part 1 — App-list refresh fix

### Root cause (verified)

`Sources/centerWindows/SettingsUI/SettingsView.swift:53-57`:

```swift
.task {
    apps = await Task.detached(priority: .userInitiated) {
        InstalledAppCatalog.loadInstalledApps()
    }.value
}
```

`.task` runs **only on the view's first appearance**. Compounding this,
`AppDelegate.openSettings()` (`AppDelegate.swift:52-59`) caches the
`SettingsWindowController` as a singleton:

```swift
if settingsWindowController == nil {
    settingsWindowController = SettingsWindowController(store: tilingSettingsStore)
}
settingsWindowController?.showWindow(nil)
```

So reopening Settings reuses the same `SettingsView`, whose `.task` will
never re-fire. Any app installed after `centerWindows` launch is invisible
in the picker until the user fully quits and relaunches the menu-bar app.

### Non-goals

- No change to `InstalledAppCatalog.loadInstalledApps()` itself (it is
  correct — it re-scans the filesystem every call; the bug is that it is
  not called again).
- No change to settings persistence, bundle IDs, or the tiling engine.
- No background file-system watcher (DispatchSource on `/Applications`) —
  out of scope; NSWorkspace notifications cover the realistic cases at a
  fraction of the complexity.

### Design

Two complementary triggers, both debounced through the same async refetch:

**Trigger 1 — refresh on window show.**
`SettingsWindowController.showWindow(_:)` already runs every time the user
opens Settings (it is the entry point of `openSettings()`). We post a
`Notification` from there and have `SettingsView` react.

- New notification name: a `static let` on a small
  `SettingsWindowNotifications` enum/namespace:
  `static let windowDidShow = Notification.Name("plumb.settings.windowDidShow")`
  (string prefixed with the new product name to avoid collisions).
- In `SettingsWindowController.showWindow`, after `super.showWindow(sender)`
  and the existing entrance animation setup, post the notification on the
  main thread.

**Trigger 2 — NSWorkspace app-launch observer.**
While the Settings window stays open, an app installed and launched (e.g.
dragged to `/Applications` then opened) should appear live. Observe
`NSWorkspace.shared.notificationCenter` for
`didLaunchApplicationNotification`. This catches the common install-then-run
flow.

**Unified handler in `SettingsView`:**
- Extract the refetch into a private `func refreshApps()` on `SettingsView`:
  spawns a `Task.detached(priority: .userInitiated)` running
  `InstalledAppCatalog.loadInstalledApps()`, assigns to `@State apps` on
  the main actor. Keeps `.task` calling the same function for initial load
  (single source of truth).
- Add `.onReceive(NotificationCenter.default.publisher(for:
  SettingsWindowNotifications.windowDidShow)) { _ in refreshApps() }`.
- Add an `onAppear`/`onDisappear` pair (or `.task`-bound
  `Task` cancellation) that registers/unregisters the NSWorkspace observer.
  Use `@State private var workspaceObserver: NSObjectProtocol?` and remove
  it on disappear to avoid leaks.

**Debounce:** the filesystem scan is cheap (tens of ms), but a rapid
show→hide→show or multiple launches should not stack up. Guard with a
`@State private var refreshTask: Task<Void, Never>?`; cancel any in-flight
refresh before starting a new one.

### Files touched (Part 1)

| File | Change |
|------|--------|
| `Sources/centerWindows/SettingsWindowController.swift` | Post `windowDidShow` notification in `showWindow`. |
| `Sources/centerWindows/SettingsUI/SettingsView.swift` | Extract `refreshApps()`; add notification receiver; add NSWorkspace observer with proper teardown; debounce. |
| (new) `Sources/centerWindows/SettingsUI/SettingsWindowNotifications.swift` | Tiny file defining the `Notification.Name` constant. |

No changes to: `InstalledAppCatalog`, `AppTilingSettings*`, `AppDelegate`,
window service, geometry, or existing tests.

### Testing (Part 1)

Follow the existing selftest pattern (see
`Sources/centerWindows/SelfTestUI.swift` for the harness style).

New selftest: `SelfTestCatalogRefresh.swift`
- A `@Test` (or the app's existing selftest function style) that:
  1. Builds an `InstalledAppCatalog.loadInstalledApps(fileManager:)` result
     with a stubbed `FileManager` that initially returns no apps, then after
     a second call returns one app.
  2. Asserts the second call sees the new app — proves the function itself
     is stateless and re-reads. (This is the contract the UI relies on.)
- Because the SwiftUI view lifecycle is hard to unit-test headlessly, the
  core assertion is at the catalog contract level (re-callable, stateless),
  plus a manual verification note in the spec for the end-to-end behavior.

Manual verification (documented in spec, run before claiming done):
1. Launch app, open Settings → note app list.
2. Install a new `.app` to `/Applications`.
3. Close and reopen Settings → new app appears.
4. Keep Settings open, launch the new app → list updates live.

---

## Part 2 — Rename `centerWindows` → `Plumb`

### Naming rationale

**Plumb** — a carpenter's plumb line finds true vertical / true center. It
is a single short word, tactile, ownable, and directly evokes the app's
core action (centering/placing windows precisely). Fits the minimal & poetic
direction of 2026 ADA winners (*grug*, *Moonlitt*, *Tide Guide*).

Scope decision: **macOS-focused** — the name may freely evoke desktop/window
concepts; no need to stay platform-neutral.

### What changes vs. what stays

**Changes (identifier / product name `centerWindows` → `Plumb`):**

| Layer | Current | New |
|-------|---------|-----|
| Package name (`Package.swift`) | `centerWindows` | `Plumb` |
| Executable product name | `centerWindows` | `Plumb` |
| Target name | `centerWindows` | `Plumb` |
| Source directory | `Sources/centerWindows/` | `Sources/Plumb/` |
| Test directory | `Tests/centerWindowsTests/` | `Tests/PlumbTests/` |
| Test target name | `centerWindowsTests` | `PlumbTests` |
| `@testable import centerWindows` | — | `@testable import Plumb` |
| `APP_NAME` in `scripts/build_app.sh` | `centerWindows` | `Plumb` |
| `BUNDLE_ID` default | `com.comet.centerwindows` | `com.comet.plumb` |
| Repo / asset refs in `scripts/publish_release.sh` | `Lv-0/centerWindows`, `centerWindows.dmg` | (left configurable via `GITHUB_REPOSITORY`/asset path; defaults updated to `Plumb`) |
| DMG name (`scripts/create_dmg.sh`) | `centerWindows.dmg` | `Plumb.dmg` |
| Window/notification string prefixes | (none yet) | `plumb.` prefix for new notification |
| README headings, install commands, paths | `centerWindows` | `Plumb` |

**Stays (intentionally NOT renamed, to preserve history / avoid breaking
installed users):**
- The git repository directory name on disk (`macOSWindows/`) — renaming a
  working tree dir is out of scope and would surprise the user; GitHub repo
  name is a separate, user-driven decision.
- The LICENSE copyright line if it names an individual (verify on edit;
  update only the product name references, not the author).
- Historical docs under `docs/superpowers/` describing past work — those
  are historical records; only the still-current design docs and CLAUDE.md
  get updated to the new name.

### Files touched (Part 2) — full inventory

Confirmed via repo-wide search (`centerWindows|centerwindows|com.comet.centerwindows`):

**Build / packaging:**
- `Package.swift` — package name, product name, target name, test target name & dependency.
- `scripts/build_app.sh` — `APP_NAME`, `BUNDLE_ID` default.
- `scripts/create_dmg.sh` — DMG output name.
- `scripts/publish_release.sh` — default `REPO`, asset path/name.
- `scripts/release_build.sh`, `scripts/sign_and_notarize.sh` — audit each for `centerWindows` refs.
- `scripts/generate_icons.sh` — audit for `centerWindows` refs (none seen in grep, but verify).

**Source (move directory + update internal refs):**
- Move `Sources/centerWindows/` → `Sources/Plumb/`.
- No `import centerWindows` exists inside the sources (all intra-module), so no import edits needed there.
- User-facing strings that must be renamed (found via grep):
  - `AppDelegate.swift` — menu-bar item title, menu header, quit item title (3 occurrences).
  - `SettingsUI/PermissionsSection.swift` — permissions intro text mentioning `centerWindows`.
- Identifier-anchored strings that MUST be renamed to stay consistent with the new bundle ID
  (because `UserDefaults.standard` domain == bundle ID, and Console.app groups by subsystem):
  - `DiagnosticLog.swift` — `OSLog(subsystem: "com.comet.centerwindows", ...)` → `"com.comet.plumb"`.
  - Selftest trigger docs in every `SelfTest*.swift` and `main.swift` —
    `defaults write com.comet.centerwindows ...` → `com.comet.plumb`,
    and `dist/centerWindows.app/Contents/MacOS/centerWindows` → `dist/Plumb.app/Contents/MacOS/Plumb`.

**Tests:**
- Move `Tests/centerWindowsTests/` → `Tests/PlumbTests/`.
- Update `@testable import centerWindows` → `@testable import Plumb` in every test file:
  `TilingGeometryTests.swift`, `WindowAnimatorTests.swift`, `ScreenSelectionTests.swift`, `SettingsStoreTests.swift`, `WindowGeometryTests.swift`.

**Docs:**
- `README.md`, `README.en.md` — product name, headings, commands, install paths, quarantine `xattr` path.
- `CLAUDE.md` — product name, architecture description, commands.
- `docs/GITHUB_PROJECT_COPY.md` — product name references.
- Historical `docs/superpowers/plans/...` and `specs/...` — leave as historical record; do not rewrite.

### Bundle ID / migration note

Changing `BUNDLE_ID` from `com.comet.centerwindows` to `com.comet.plumb`
means macOS treats it as a **new app** for any future notarization/Gatekeeper
path, and any `defaults` (UserDefaults) domain changes from
`com.comet.centerwindows` to `com.comet.plumb`. Since the app is not yet
widely distributed (pre-release, per git history) and tiling settings use
`UserDefaults.standard` keyed by `tiling.*`, existing tester settings will
not carry over. This is acceptable for the current pre-release stage and
will be noted in the commit message.

### Verification (Part 2)

- `swift build` succeeds with the new module/target names.
- `swift test` — all 30 tests pass with `@testable import Plumb`.
- `scripts/build_app.sh` produces `dist/Plumb.app` with
  `CFBundleIdentifier=com.comet.plumb` and `CFBundleName=Plumb`.
- `swift package generate-xcode-project` (if used) reflects the new name —
  bonus check, not blocking.

---

## Implementation order

1. **Part 1 (refresh fix) first** — it is small, isolated, and testable
   without touching naming. Land it green before the rename churn.
2. **Part 2 (rename)** — mechanical but broad; do it as one focused pass
   (directory moves + Package.swift + scripts + tests + docs), then verify
   build/test/build_app end-to-end.

Both parts committed separately (two commits) so history is reviewable.

---

## Open questions

None. All decisions confirmed with user:
- Refresh approach: refresh-on-show + NSWorkspace observer.
- Name: `Plumb`.
- Scope: macOS-focused.
