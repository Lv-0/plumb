#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# 图标生成脚本
#
# App 图标：直接使用设计稿静态图 assets/AppIcon-base.png（1024×1024 PNG），
#           通过 sips 缩放出 iconset 全尺寸，再用 iconutil 打包成 .icns。
#           不再用代码绘制 App 图标——设计稿由设计师/AI 出图后放入 assets/。
#
# 状态栏图标（menu bar template）：仍由代码绘制（单色 template，16px 下需清晰），
#           因为从彩色设计稿裁剪出 16px 单色图标效果差。
# ─────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.build/icons"
ICONSET_DIR="${TMP_DIR}/AppIcon.iconset"
APP_BASE_SOURCE="${ROOT_DIR}/assets/AppIcon-base.png"   # 设计稿源图（1024×1024 PNG）
APP_BASE="${TMP_DIR}/AppIconBase.png"                    # 复制到 build 目录的工作副本
STATUS_ICON="${TMP_DIR}/StatusIconTemplate.png"
APP_ICNS="${TMP_DIR}/AppIcon.icns"

mkdir -p "${TMP_DIR}"
rm -rf "${ICONSET_DIR}" "${APP_BASE}" "${STATUS_ICON}" "${APP_ICNS}"

# ── 校验设计稿存在并标准化为 1024×1024 PNG ──
if [[ ! -f "${APP_BASE_SOURCE}" ]]; then
  echo "错误：找不到 App 图标设计稿 ${APP_BASE_SOURCE}"
  echo "请将 PNG 图标放到该路径后重试（建议接近正方形构图）。"
  exit 1
fi

# 读取尺寸与格式。
SRC_W="$(sips -g pixelWidth "${APP_BASE_SOURCE}" | awk '/pixelWidth/ {print $2}')"
SRC_H="$(sips -g pixelHeight "${APP_BASE_SOURCE}" | awk '/pixelHeight/ {print $2}')"
SRC_FMT="$(sips -g format "${APP_BASE_SOURCE}" | awk '/format/ {print $2}')"

# 非 PNG 先转成 PNG（写到工作副本，不动源文件）。
if [[ "${SRC_FMT}" != "png" ]]; then
  echo "源图为 ${SRC_FMT}，转换为 PNG..."
  sips -s format png "${APP_BASE_SOURCE}" --out "${APP_BASE}" >/dev/null
else
  cp "${APP_BASE_SOURCE}" "${APP_BASE}"
fi

# 若非 1024×1024，中心裁剪为正方形再缩放到 1024。
# macOS iconutil 要求严格正方形；用 min(W,H) 居中裁剪保证主体居中、不拉伸变形。
if [[ "${SRC_W}" != "${SRC_H}" ]]; then
  CROP=$(( SRC_W < SRC_H ? SRC_W : SRC_H ))
  echo "源图 ${SRC_W}×${SRC_H} 非正方形，居中裁剪为 ${CROP}×${CROP}..."
  sips -c "${CROP}" "${CROP}" "${APP_BASE}" >/dev/null
  SRC_W="${CROP}"; SRC_H="${CROP}"
fi
if [[ "${SRC_W}" != "1024" ]]; then
  echo "缩放 ${SRC_W}×${SRC_H} → 1024×1024..."
  sips -z 1024 1024 "${APP_BASE}" >/dev/null
fi

# ── 生成状态栏 template 图标（代码绘制，单色）──
cat > "${TMP_DIR}/draw_status.swift" <<'SWIFT'
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
        width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
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

// ─────────────────────────────────────────────────────────────────────────
// Plumb 状态栏图标（template，单色，自动适配深浅色菜单栏）
// 与 App 图标同一隐喻：一根细线垂下一颗水滴（真圆弧构造，极致圆润）。
// 用纯黑绘制（NSImage.isTemplate=true 由 AppDelegate 设置），系统负责上色。
//
// 几何严格对齐设计稿 assets/AppIcon-base.png：
//   • 水滴水平 + 垂直居中（占画面约 60% 高度）
//   • 球部直径约画面 35%（小尺寸下饱满而不臃肿）
//   • 悬线从水滴尖端向上、长度约为画面 25%（不到顶边，留呼吸感）
// ─────────────────────────────────────────────────────────────────────────
func drawStatusIcon(size: Int) throws -> CGImage {
    let s = CGFloat(size)
    let ctx = makeContext(size: size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    ctx.clear(rect)

    // 水滴整体高度约为画面的 60%，垂直居中 → 占 y ∈ [0.20·s, 0.80·s]。
    // 球部占下方约 2/3，颈部收尖占上方约 1/3。
    let cx = s * 0.5
    let dropHeight = s * 0.60
    let bulbHeight = dropHeight * (2.0 / 3.0)   // 球部高度
    let R = bulbHeight * 0.5                    // 球部半径 ≈ 0.20·s（直径 ≈ 0.40·s，约占画面 35% 宽）
    let circleCY = s * 0.20 + R                 // 球部圆心：球底落在 0.20·s
    let tipY = circleCY + R + (dropHeight - bulbHeight) // 尖点：落在 0.80·s

    // 真圆弧 + 相切曲线构造（与 App 图标设计稿同构的水滴形）。
    let theta: CGFloat = .pi * 50.0 / 180.0
    let tx = R * cos(theta)
    let ty = R * sin(theta)
    let tanPointR = CGPoint(x: cx + tx, y: circleCY + ty)
    let tanPointL = CGPoint(x: cx - tx, y: circleCY + ty)
    let neckLen = (tipY - tanPointR.y) * 0.55
    let cp1R = CGPoint(x: tanPointR.x + neckLen * sin(theta),
                       y: tanPointR.y + neckLen * cos(theta))
    let cp2R = CGPoint(x: cx, y: tipY - neckLen * 1.4)
    let cp1L = CGPoint(x: tanPointL.x - neckLen * sin(theta),
                       y: tanPointL.y + neckLen * cos(theta))

    let bob = CGMutablePath()
    bob.move(to: tanPointR)
    bob.addArc(center: CGPoint(x: cx, y: circleCY), radius: R,
               startAngle: theta, endAngle: .pi - theta, clockwise: true)
    bob.addCurve(to: CGPoint(x: cx, y: tipY),
                 control1: cp1L, control2: CGPoint(x: cx, y: tipY - neckLen * 1.4))
    bob.addCurve(to: tanPointR, control1: cp2R, control2: cp1R)
    bob.closeSubpath()

    ctx.setFillColor(color(0, 0, 0, 1))
    ctx.addPath(bob)
    ctx.fillPath()

    // 悬线：从水滴尖端向上垂出。尖端在 0.80·s，线顶落在 0.95·s，
    // 即线长 ≈ 画面 15%——既呼应"铅锤悬线"的隐喻，又留出顶部呼吸感、不贴边。
    let lineTopY = s * 0.95
    ctx.setStrokeColor(color(0, 0, 0, 1))
    ctx.setLineWidth(max(1.5, s * 0.05))
    ctx.setLineCap(.butt)
    ctx.move(to: CGPoint(x: cx, y: lineTopY))
    ctx.addLine(to: CGPoint(x: cx, y: tipY))
    ctx.strokePath()

    guard let image = ctx.makeImage() else {
        throw NSError(domain: "IconGen", code: 4, userInfo: [NSLocalizedDescriptionKey: "状态栏图标绘制失败"])
    }
    return image
}

let outputDir = CommandLine.arguments[1]
try writePNG(drawStatusIcon(size: 64), to: outputDir + "/StatusIconTemplate.png")
SWIFT

swift "${TMP_DIR}/draw_status.swift" "${TMP_DIR}"

# ── 由设计稿缩放出 iconset 全尺寸 ──
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
echo "  App 图标源: ${APP_BASE_SOURCE}"
