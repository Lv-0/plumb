# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run all tests (uses swift-testing framework)
swift test --filter TestName   # Run a single test by name
```

## Distribution

```bash
scripts/build_app.sh           # Build Plumb.app into dist/
scripts/create_dmg.sh          # Package into dist/Plumb.dmg
scripts/sign_and_notarize.sh   # Sign with Developer ID + notarize (requires env vars)
scripts/publish_release.sh     # Create GitHub release with DMG attachment
```

## Architecture

This is a macOS menu-bar utility (no Dock icon) that automatically centers or tiles application windows. Built with Swift Package Manager (swift-tools-version 6.2), targeting macOS 13+. Product/module name: **Plumb** (directories `Sources/Plumb/`, `Tests/PlumbTests/`).

### Core Flow

1. **Entry** (`main.swift`): Creates `NSApplication` with `.accessory` policy (menu-bar only). `AppDelegate` wires everything together.

2. **Event Observation** (`WindowEventObserver`): Uses `AXObserver` to watch `kAXFocusedWindowChangedNotification` / `kAXWindowCreatedNotification`. On app switch, re-binds the observer to the new frontmost app's PID. Includes retry timers to handle apps that create windows asynchronously (splash screens, etc.).

3. **Window Service** (`WindowCenteringService`): The core engine. Reads window position/size via Accessibility API, infers which coordinate space the app uses, computes the target position, and writes it back.

4. **Geometry** (`WindowGeometry`): Pure math — `centeredOrigin()`, `constrainedOrigin()`, `tiledFrame()`. No macOS dependencies, fully unit-testable.

### Coordinate Space Problem (Critical Complexity)

macOS window position reporting is inconsistent across apps. A single AX position value might be in one of **four coordinate spaces**:

| Space | Origin | Y-axis |
|-------|--------|--------|
| `globalBottomLeft` | Screen origin | Up |
| `globalTopLeft` | Primary screen top-left | Down |
| `localBottomLeft` | Per-screen origin | Up |
| `localTopLeft` | Per-screen top-left | Down |

`WindowCenteringService` handles this by:
- Trying all 4 spaces × all screens, scoring by overlap with screen bounds
- Caching the resolved space per PID for stability
- Using `CGWindowListCopyWindowInfo` as a secondary signal to disambiguate (requires Screen Recording permission)
- Falling back to AXFrame when AXPosition fails

### Tiling System

- `AppTilingSettings` / `AppTilingSettingsStore`: Settings model persisted in `UserDefaults` (keys prefixed `tiling.`)
- `InstalledAppCatalog`: Scans `/Applications`, `/System/Applications`, `~/Applications` for `.app` bundles
- `TilingSettingsWindowController`: Programmatic AppKit UI for selecting which apps to tile and configuring margin
- Tiled apps are a whitelist; when matched, tiling takes priority over centering

### Permission Requirements

- **Accessibility** (`AXIsProcessTrusted`): Required to read/write window positions. Without it, nothing works.
- **Screen Recording** (`CGPreflightScreenCaptureAccess`): Optional but improves multi-monitor coordinate detection via CGWindowList API.

### Key Design Decisions

- Each window is centered/tiled **once** (tracked by `pid:windowNumber` key). User dragging does not re-trigger.
- Only `kAXStandardWindowSubrole` windows are processed — dialogs, panels, and floating windows are skipped.
- Full-screen detection uses both `AXFullScreen` attribute and geometric comparison (tolerance: 6px).
- The centered-window cache caps at 200 entries to prevent unbounded growth.
- Document apps (Pages/Numbers/Word/Excel, configurable via `documentChooserBundleIDs`) show a template/file picker before the real document. Both windows are `AXStandardWindow`, so they are distinguished by `kAXDocumentAttribute` (empty on picker, `file://` URL on document). The picker is centered-only and **does not** lock `processedPIDs`, so the subsequent document window still gets tiled.
