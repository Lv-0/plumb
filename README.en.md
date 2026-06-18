<div align="center">

<img src="assets/AppIcon-base.png" width="140" height="140" alt="Plumb">

# Plumb

A single line descends, and finds its point.

> Make your Mac feel more elegant to use.

Auto-centers and tiles macOS apps — a blessing for neat freaks!

[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg?style=flat-square)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6.2-F05138.svg?style=flat-square)](https://swift.org)
[![Release](https://img.shields.io/badge/release-v1.0.0-success.svg?style=flat-square)](#download--install)

English · [简体中文](./README.md) · [Download](#download--install) · [Usage](#usage) · [Permissions](#permissions)

</div>

---

## 📖 Table of Contents

- [About](#about)
- [✨ Features](#-features)
- [📐 Auto-Tiling](#-auto-tiling)
- [📸 Screenshots](#-screenshots)
- [Download & Install](#download--install)
- [Usage](#usage)
- [Permissions](#permissions)
- [Requirements](#requirements)
- [Build locally](#build-locally)
- [Package & Release](#package--release)
- [FAQ](#faq)
- [License](#license)

## About

`Plumb` is a **macOS menu-bar window manager** that supports both auto-centering and per-app auto-tiling.

Named after the **plumb line** — the weight a carpenter drops to find true vertical, true center. That's exactly what Plumb does: gently place a window at the true center of the screen, or at a designated position.

- 🪧 Lives in the menu bar — no Dock icon, zero intrusion
- 🎯 Centers once on launch, then only when a window is re-opened / a new window is focused
- 🖥️ Computes within the usable screen area (auto-excludes Dock & menu bar), stable across multi-display
- 📐 Per-app auto-tiling (allowlist) with a configurable uniform edge margin
- 🪟 Liquid Glass settings UI (macOS 26) — frosted glass, app search, pill toggles

## ✨ Features

| Feature | Description |
| --- | --- |
| 🎯 Center once | Centers once on launch; afterwards only when a window is re-opened / a new window is focused |
| ✋ Won't fight your layout | Dragging a window never re-triggers centering |
| 🖥️ Precisely avoids Dock/menu bar | Based on `screen.frame - screen.visibleFrame`, stable across multi-display |
| 📐 Per-app auto-tiling | Allowlist mechanism with a configurable uniform edge margin (px) |
| 🔄 Live app-list refresh | Newly installed apps appear in the settings picker immediately, no restart needed |
| 🪟 Liquid Glass settings UI | macOS 26 frosted glass, search, pill toggles |
| 🧠 Smart coordinate-space detection | Auto-detects each app's window coordinate space and caches it for stability |
| 🪧 Non-intrusive menu-bar presence | Menu-bar icon only, does not occupy the Dock |

## 📐 Auto-Tiling

Open `Tiling Settings…` from the menu bar to enable/disable the feature and manage your workflow.

- Configure a single uniform edge margin (px)
- Select allowlisted apps from installed applications (system apps hidden by default, toggleable)
- For allowlisted apps, **tiling has priority** over auto-centering
- Trigger scope is once per process startup (PID); no repeated tiling within the same process
- If a window cannot be resized, it is skipped

> Semantics are inspired by Amethyst configuration concepts:
> - `window-margin-size`: equivalent to tiling margin in this project
> - `floating + floating-is-blacklist=false`: equivalent to allowlisted auto-tiling here

## 📸 Screenshots

<table>
  <tr>
    <td width="50%" align="center"><b>Liquid Glass Settings UI</b></td>
    <td width="50%" align="center"><b>Per-App Auto-Tiling</b></td>
  </tr>
  <tr>
    <td width="50%" align="center"><img src="assets/setting.png" alt="Settings UI"></td>
    <td width="50%" align="center"><img src="assets/layout.png" alt="Tiling effect"></td>
  </tr>
</table>

## Download & Install

### Option 1: Download the DMG (recommended)

1. Download the latest `Plumb.dmg` from [Releases](../../releases).
2. Open the DMG and drag `Plumb.app` into `Applications`.
3. In `Applications`, right-click `Plumb.app` → `Open` → click `Open` again.
4. If blocked, go to `System Settings → Privacy & Security` and click "Open Anyway".

### Option 2: Build from source

```bash
swift build -c release
./.build/release/Plumb
```

See [Build locally](#build-locally).

## Usage

1. After launch, a water-drop icon appears in the menu bar.
2. Grant the [Accessibility](#accessibility) permission — centering depends on it.
3. (Optional) Grant the [Screen Recording](#screen-recording) permission to improve multi-display coordinate detection stability.
4. Click the menu-bar icon:
   - Trigger centering manually
   - Open `Tiling Settings…` to configure the allowlist and margin

> 💡 **Design principle**: each window is centered/tiled **only once** (keyed by `pid:windowNumber`). Manually dragging a window is never "corrected" back — Plumb won't fight your manual layout.

## Permissions

### Accessibility

- **Path**: `System Settings → Privacy & Security → Accessibility`
- **Why required**: The app uses macOS Accessibility APIs to read the frontmost window's frame and write a new position for centering.
- **Without it**: The app cannot read window geometry or move windows, so centering will not work.

### Screen Recording

- **Path**: `System Settings → Privacy & Security → Screen Recording`
- **Why required**: The app needs full screen context to reliably compute usable display bounds and avoid Dock/menu bar while centering.
- **Without it**: Screen-context-dependent centering can become unstable on multi-display or complex layouts.

### Permission boundary

- ❌ The app **does not upload screen content** and **does not perform telemetry collection**.
- ✅ Permissions are used **only** for local window geometry calculations and positioning.

## Requirements

- **macOS 26+** (built on the macOS 26 SDK with the Liquid Glass UI; older versions are not supported)
- Xcode Command Line Tools (`xcode-select --install`)

## Build locally

```bash
# Run tests
swift test

# Build a Release binary
swift build -c release

# Run directly
./.build/release/Plumb
```

## Package & Release

### Package as .app and .dmg

```bash
scripts/build_app.sh      # produces dist/Plumb.app
scripts/create_dmg.sh     # produces dist/Plumb.dmg
```

The DMG includes:

- `Plumb.app`
- `Applications` (shortcut to the system Applications folder)

> Install by dragging `Plumb.app` into `Applications`.

### Sign and notarize (Developer ID)

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/sign_and_notarize.sh
```

### One-shot release flow (for GitHub Releases)

```bash
export DEVELOPER_ID_APP="Developer ID Application: YOUR_NAME (TEAMID)"
export NOTARY_PROFILE="AC_NOTARY"
scripts/release_build.sh              # build + package + sign/notarize + verify

GITHUB_TOKEN=... scripts/publish_release.sh v1.0.0   # publish to GitHub Releases
```

> ⚠️ Unsigned/unnotarized DMG files can be blocked by Gatekeeper on a new Mac and may appear as "damaged".

## FAQ

<details>
<summary><b>"Damaged" or "unidentified developer" warning when opening Plumb.app?</b></summary>

This is the normal Gatekeeper flow for unnotarized distribution — **not** a corruption of the app code. Run:

```bash
xattr -dr com.apple.quarantine /Applications/Plumb.app
```

Or go to `System Settings → Privacy & Security` and click "Open Anyway" at the bottom.

</details>

<details>
<summary><b>Centering doesn't work?</b></summary>

Please make sure the **Accessibility** permission is granted: `System Settings → Privacy & Security → Accessibility`, and that Plumb is enabled. You may need to restart Plumb after granting.

</details>

<details>
<summary><b>Window centering is inaccurate on a multi-display setup?</b></summary>

Please grant the **Screen Recording** permission. Plumb uses the `CGWindowList` API as a secondary signal to more precisely identify the window's screen and coordinate space.

</details>

<details>
<summary><b>I dragged a window and it got re-centered?</b></summary>

No. Plumb centers/tiles each window **only once** — manual drags are never "corrected".

</details>

## License

This project is open-sourced under the [MIT License](./LICENSE).

---

<div align="center">

English · **[简体中文](./README.md)**

If Plumb helps you, a ⭐ Star is appreciated.

</div>
