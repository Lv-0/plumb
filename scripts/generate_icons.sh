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

    // Aurora gradient (deep violet → indigo → blue → teal → mint) — richer, award-medallion depth.
    let aurora: [CGColor] = [
        color(0.30, 0.10, 0.55, 1.0),  // deep violet
        color(0.24, 0.26, 0.90, 1.0),  // indigo
        color(0.13, 0.46, 0.97, 1.0),  // blue
        color(0.10, 0.66, 0.85, 1.0),  // teal
        color(0.18, 0.80, 0.62, 1.0)   // mint
    ]
    let auroraGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: aurora as CFArray,
                                locations: [0, 0.32, 0.6, 0.85, 1])!
    ctx.drawLinearGradient(auroraGrad,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: s, y: 0),
                           options: [])

    // Large soft radial bloom behind the mark for premium glow.
    let bloomC = CGPoint(x: s * 0.5, y: s * 0.56)
    let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [color(0.62, 0.78, 1.0, 0.45),
                                    color(0.40, 0.55, 1.0, 0.12),
                                    color(0.30, 0.40, 1.0, 0)] as CFArray,
                           locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.drawRadialGradient(bloom,
                           startCenter: bloomC, startRadius: 0,
                           endCenter: bloomC, endRadius: s * 0.62,
                           options: [])
    ctx.restoreGState()

    // Subtle vignette at the very corners for depth.
    let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0, 0, 0, 0), color(0.02, 0.03, 0.12, 0.35)] as CFArray,
                              locations: [0.55, 1])!
    ctx.saveGState()
    ctx.drawRadialGradient(vignette,
                           startCenter: CGPoint(x: s/2, y: s/2), startRadius: s * 0.35,
                           endCenter: CGPoint(x: s/2, y: s/2), endRadius: s * 0.75,
                           options: [])
    ctx.restoreGState()

    // Glass window card: frosted, rounded, with strong top highlight + edge ring.
    let winRect = CGRect(x: 232 * scale, y: 272 * scale, width: 560 * scale, height: 480 * scale)
    let winPath = CGPath(roundedRect: winRect, cornerWidth: 104 * scale, cornerHeight: 104 * scale, transform: nil)

    // Drop shadow under the card (award-medallion float).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26 * scale), blur: 78 * scale,
                  color: color(0.02, 0.04, 0.22, 0.5))
    ctx.addPath(winPath)
    ctx.setFillColor(color(1, 1, 1, 0.97))
    ctx.fillPath()
    ctx.restoreGState()

    // Inner glass tint: faint cool wash.
    ctx.saveGState()
    ctx.addPath(winPath)
    ctx.clip()
    let glassWash = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [color(0.94, 0.97, 1.0, 0.65), color(0.86, 0.91, 1.0, 0.25)] as CFArray,
                               locations: [0, 1])!
    ctx.drawLinearGradient(glassWash, start: CGPoint(x: 0, y: winRect.maxY), end: CGPoint(x: 0, y: winRect.minY), options: [])

    // Top highlight band on the card.
    let hiRect = CGRect(x: winRect.minX, y: winRect.maxY - 140 * scale, width: winRect.width, height: 140 * scale)
    let hiGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [color(1, 1, 1, 0.7), color(1, 1, 1, 0)] as CFArray,
                            locations: [0, 1])!
    ctx.drawLinearGradient(hiGrad, start: CGPoint(x: 0, y: hiRect.maxY), end: CGPoint(x: 0, y: hiRect.minY), options: [])
    ctx.restoreGState()

    // Outer bright edge ring on the card.
    ctx.saveGState()
    ctx.addPath(winPath)
    ctx.setStrokeColor(color(1, 1, 1, 0.55))
    ctx.setLineWidth(2 * scale)
    ctx.strokePath()
    ctx.restoreGState()

    // Center target ring (medallion-style): faint ring + crosshair.
    let midX = winRect.midX
    let midY = winRect.midY - 6 * scale

    // Concentric target rings.
    for (radius, alpha) in [(170 * scale, 0.10), (120 * scale, 0.16), (72 * scale, 0.22)] {
        let rRect = CGRect(x: midX - radius, y: midY - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.addEllipse(in: rRect)
        ctx.setStrokeColor(color(0.16, 0.34, 0.92, alpha))
        ctx.setLineWidth(6 * scale)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Crosshair arms.
    ctx.setStrokeColor(color(0.20, 0.40, 0.92, 1.0))
    ctx.setLineWidth(20 * scale)
    ctx.setLineCap(.round)
    let arm = 150 * scale
    let gap = 40 * scale  // 留出中心给高亮圆点
    ctx.move(to: CGPoint(x: midX - arm, y: midY))
    ctx.addLine(to: CGPoint(x: midX - gap, y: midY))
    ctx.move(to: CGPoint(x: midX + gap, y: midY))
    ctx.addLine(to: CGPoint(x: midX + arm, y: midY))
    ctx.move(to: CGPoint(x: midX, y: midY - arm))
    ctx.addLine(to: CGPoint(x: midX, y: midY - gap))
    ctx.move(to: CGPoint(x: midX, y: midY + gap))
    ctx.addLine(to: CGPoint(x: midX, y: midY + arm))
    ctx.strokePath()

    // Center glowing bead with halo.
    let haloR = 70 * scale
    let haloRect = CGRect(x: midX - haloR, y: midY - haloR, width: haloR * 2, height: haloR * 2)
    ctx.saveGState()
    ctx.addEllipse(in: haloRect)
    ctx.clip()
    let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0.5, 0.7, 1.0, 0.55), color(0.5, 0.7, 1.0, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(halo,
                           startCenter: CGPoint(x: midX, y: midY), startRadius: 0,
                           endCenter: CGPoint(x: midX, y: midY), endRadius: haloR,
                           options: [])
    ctx.restoreGState()

    let dotR = 32 * scale
    let dotRect = CGRect(x: midX - dotR, y: midY - dotR, width: dotR * 2, height: dotR * 2)
    let dotGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [color(0.55, 0.45, 1.0, 1.0), color(0.20, 0.50, 0.98, 1.0)] as CFArray,
                             locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: dotRect)
    ctx.clip()
    ctx.drawRadialGradient(dotGrad,
                           startCenter: CGPoint(x: dotRect.minX, y: dotRect.maxY), startRadius: 0,
                           endCenter: CGPoint(x: dotRect.minX, y: dotRect.maxY), endRadius: dotR * 2.4,
                           options: [])
    // Specular highlight on the bead.
    let spec = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(1, 1, 1, 0.85), color(1, 1, 1, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(spec,
                           startCenter: CGPoint(x: midX - dotR * 0.3, y: midY + dotR * 0.3), startRadius: 0,
                           endCenter: CGPoint(x: midX - dotR * 0.3, y: midY + dotR * 0.3), endRadius: dotR * 0.7,
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
