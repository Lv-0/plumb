#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.build/icons"
ICONSET_DIR="${TMP_DIR}/AppIcon.iconset"
APP_BASE="${TMP_DIR}/AppIconBase.png"
STATUS_ICON="${TMP_DIR}/StatusIconTemplate.png"
APP_ICNS="${TMP_DIR}/AppIcon.icns"

mkdir -p "${TMP_DIR}"
rm -rf "${ICONSET_DIR}" "${APP_BASE}" "${STATUS_ICON}" "${APP_ICNS}"

cat > "${TMP_DIR}/draw_icons.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func makeContext(size: Int) -> CGContext {
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    return ctx
}

func writePNG(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG 输出"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "IconGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG 写入失败"])
    }
}

func drawAppIcon(size: Int) throws -> CGImage {
    let s = CGFloat(size)
    let scale = s / 1024.0
    let ctx = makeContext(size: size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)

    // Squircle (superellipse-ish via rounded rect with large corner) — full bleed.
    let bgPath = CGPath(roundedRect: rect, cornerWidth: 224 * scale, cornerHeight: 224 * scale, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()

    // Vibrant diagonal gradient (indigo → blue → teal), Apple Design Award vibe.
    let gradientColors: [CGColor] = [
        color(0.36, 0.28, 0.92, 1.0),  // indigo
        color(0.16, 0.52, 0.98, 1.0),  // blue
        color(0.12, 0.74, 0.82, 1.0)   // teal
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )

    // Soft radial glow behind the window for depth.
    let glowRect = CGRect(x: s * 0.18, y: s * 0.16, width: s * 0.64, height: s * 0.64)
    let glowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(1, 1, 1, 0.35), color(1, 1, 1, 0)] as CFArray,
                              locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: glowRect)
    ctx.clip()
    ctx.drawRadialGradient(glowGrad,
                           startCenter: CGPoint(x: glowRect.midX, y: glowRect.midY), startRadius: 0,
                           endCenter: CGPoint(x: glowRect.midX, y: glowRect.midY), endRadius: glowRect.width / 2,
                           options: [])
    ctx.restoreGState()

    // Glass window card: frosted, rounded, with subtle inner highlight.
    let winRect = CGRect(x: 230 * scale, y: 286 * scale, width: 564 * scale, height: 452 * scale)
    let winPath = CGPath(roundedRect: winRect, cornerWidth: 96 * scale, cornerHeight: 96 * scale, transform: nil)

    // Drop shadow under the card.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 60 * scale, color: color(0.04, 0.10, 0.30, 0.45))
    ctx.addPath(winPath)
    ctx.setFillColor(color(1, 1, 1, 0.96))
    ctx.fillPath()
    ctx.restoreGState()

    // Top highlight band on the card.
    ctx.saveGState()
    ctx.addPath(winPath)
    ctx.clip()
    let hiRect = CGRect(x: winRect.minX, y: winRect.maxY - 120 * scale, width: winRect.width, height: 120 * scale)
    let hiGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [color(1, 1, 1, 0.55), color(1, 1, 1, 0)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(hiGrad, start: CGPoint(x: 0, y: hiRect.maxY), end: CGPoint(x: 0, y: hiRect.minY), options: [])
    ctx.restoreGState()

    // Crosshair "center" target inside the card — the app's core concept.
    let midX = winRect.midX
    let midY = winRect.midY - 8 * scale
    ctx.setStrokeColor(color(0.20, 0.40, 0.92, 1.0))
    ctx.setLineWidth(22 * scale)
    ctx.setLineCap(.round)
    let arm = 118 * scale
    ctx.move(to: CGPoint(x: midX - arm, y: midY))
    ctx.addLine(to: CGPoint(x: midX + arm, y: midY))
    ctx.move(to: CGPoint(x: midX, y: midY - arm))
    ctx.addLine(to: CGPoint(x: midX, y: midY + arm))
    ctx.strokePath()

    // Center dot — accent gradient bead.
    let dotR = 34 * scale
    let dotRect = CGRect(x: midX - dotR, y: midY - dotR, width: dotR * 2, height: dotR * 2)
    let dotGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [color(0.42, 0.34, 1.0, 1.0), color(0.16, 0.52, 0.98, 1.0)] as CFArray,
                             locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    ctx.drawRadialGradient(dotGrad,
                           startCenter: CGPoint(x: dotRect.minX, y: dotRect.maxY), startRadius: 0,
                           endCenter: CGPoint(x: dotRect.minX, y: dotRect.maxY), endRadius: dotR * 2.4,
                           options: [])
    ctx.restoreGState()

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "IconGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "应用图标绘制失败"])
    }
    return image
}

func drawStatusIcon(size: Int) throws -> CGImage {
    let s = CGFloat(size)
    let ctx = makeContext(size: size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.clear(rect)

    let windowRect = CGRect(x: 8, y: 10, width: 48, height: 36)
    let windowPath = CGPath(roundedRect: windowRect, cornerWidth: 7, cornerHeight: 7, transform: nil)
    ctx.addPath(windowPath)
    ctx.setStrokeColor(color(0, 0, 0, 1))
    ctx.setLineWidth(4)
    ctx.strokePath()

    ctx.setStrokeColor(color(0, 0, 0, 1))
    ctx.setLineWidth(4)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: windowRect.midX - 10, y: windowRect.midY))
    ctx.addLine(to: CGPoint(x: windowRect.midX + 10, y: windowRect.midY))
    ctx.move(to: CGPoint(x: windowRect.midX, y: windowRect.midY - 10))
    ctx.addLine(to: CGPoint(x: windowRect.midX, y: windowRect.midY + 10))
    ctx.strokePath()

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "IconGen", code: 4, userInfo: [NSLocalizedDescriptionKey: "状态栏图标绘制失败"])
    }
    return image
}

let outputDir = CommandLine.arguments[1]
try writePNG(drawAppIcon(size: 1024), to: outputDir + "/AppIconBase.png")
try writePNG(drawStatusIcon(size: 64), to: outputDir + "/StatusIconTemplate.png")
SWIFT

swift "${TMP_DIR}/draw_icons.swift" "${TMP_DIR}"

mkdir -p "${ICONSET_DIR}"

make_icon() {
  local px="$1"
  local name="$2"
  sips -s format png -z "${px}" "${px}" "${APP_BASE}" --out "${ICONSET_DIR}/${name}" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png

iconutil -c icns "${ICONSET_DIR}" -o "${APP_ICNS}"
echo "图标已生成: ${APP_ICNS}, ${STATUS_ICON}"
