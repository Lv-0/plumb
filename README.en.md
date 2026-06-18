# Plumb

English | [简体中文](./README.md)

`Plumb` is a macOS menu bar window manager with both auto-center and per-app auto-tiling.

## Features

- Center once immediately on app launch
- Center once when a new window is created / focused again after being closed
- Moving a window will not trigger re-centering
- Center inside usable screen area excluding Dock and menu bar (`screen.frame - screen.visibleFrame`)
- Per-app auto-tiling (allowlist) with configurable uniform margins
- Auto-generated app icon and menu bar icon

## Auto-Tiling (Selected Apps)

- Open `Tiling Settings…` from the menu bar to enable/disable this feature
- Configure a single uniform edge margin (px)
- Select allowlisted apps from installed applications (system apps hidden by default, toggleable)
- For allowlisted apps, tiling has priority over auto-centering
- Trigger scope is once per process startup (PID); no repeated tiling in the same process
- If a window cannot be resized, it is skipped

Semantics are inspired by Amethyst configuration concepts:
- `window-margin-size`: equivalent to tiling margin in this project
- `floating + floating-is-blacklist=false`: equivalent to allowlisted auto-tiling here

## Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

## Build locally

```bash
swift test
swift build -c release
./.build/release/Plumb
```

## Package

```bash
scripts/build_app.sh
scripts/create_dmg.sh
```

Outputs:

- `dist/Plumb.app`
- `dist/Plumb.dmg`

The DMG includes:

- `Plumb.app`
- `Applications` (shortcut to system Applications folder)

Install by dragging `Plumb.app` into `Applications`.

## Sign and notarize (Developer ID)

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/sign_and_notarize.sh
```

Recommended release flow (for GitHub Releases assets):

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/release_build.sh
```

Note: Unsigned/unnotarized DMG files can be blocked on a new Mac and may show as “damaged”.

## Installation Guidelines

1. Open the DMG and drag `Plumb.app` into `Applications`.
2. In `Applications`, right-click `Plumb.app` -> `Open` -> click `Open` again.
3. If blocked, go to `System Settings -> Privacy & Security` and click “Open Anyway”.
4. If still blocked, run:

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

This is a normal Gatekeeper flow for unnotarized apps, not a corruption of app code.

## Permissions

### Accessibility

- Path: `System Settings -> Privacy & Security -> Accessibility`
- Why required:
  The app uses macOS Accessibility APIs to read the frontmost window's frame and set a new position for centering.
- Without it:
  The app cannot read window geometry or move windows, so centering will not work.

### Screen Recording

- Path: `System Settings -> Privacy & Security -> Screen Recording`
- Why required:
  The app needs full screen context to reliably compute usable display bounds and avoid Dock/menu bar while centering.
- Without it:
  Screen-context-dependent centering can become unstable on multi-display or complex layouts.

### Permission boundary

- The app does not upload screen content and does not perform telemetry collection.
- Permissions are used only for local window geometry calculations and positioning.

## License

MIT License. See [LICENSE](./LICENSE).
