#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# 图标生成脚本
#
# App 图标：直接使用设计稿静态图 assets/AppIcon-base.png（1024×1024 PNG），
#           通过 sips 缩放出 iconset 全尺寸，再用 iconutil 打包成 .icns。
#           不再用代码绘制 App 图标——设计稿由设计师/AI 出图后放入 assets/。
#
# 状态栏图标（menu bar template）：代码绘制简化版——倒三角 + 荷鲁斯之眼，
#           无内部繁复纹样，22pt 菜单栏下清晰可辨。
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

# ── 生成状态栏 template 图标（代码绘制：倒三角 + 简化荷鲁斯之眼）──
cat > "${TMP_DIR}/draw_status_icon.swift" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// 简化菜单栏图标：倒三角描边 + 杏仁眼 / 眉弓 / 竖线 / 右卷（荷鲁斯之眼要素），无内部纹样。
func drawSimplifiedStatusIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    ctx.setStrokeColor(black)
    ctx.setFillColor(black)
    let lw = CGFloat(max(2, size / 52))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let cx = s * 0.5
    let margin = s * 0.07
    let topY = margin
    let apexY = s - margin
    let halfW = (s - margin * 2) * 0.5

    // 倒三角（顶点朝下）
    let topLeft = CGPoint(x: cx - halfW, y: topY)
    let topRight = CGPoint(x: cx + halfW, y: topY)
    let apex = CGPoint(x: cx, y: apexY)
    ctx.move(to: topLeft)
    ctx.addLine(to: topRight)
    ctx.addLine(to: apex)
    ctx.closePath()
    ctx.strokePath()

    // 荷鲁斯之眼：杏仁形描边
    let eyeCY = s * 0.455
    let eyeW = s * 0.28
    let eyeH = s * 0.115
    ctx.strokeEllipse(in: CGRect(x: cx - eyeW / 2, y: eyeCY - eyeH / 2, width: eyeW, height: eyeH))

    // 瞳孔
    let pupilR = s * 0.03
    ctx.fillEllipse(in: CGRect(x: cx - pupilR, y: eyeCY - pupilR, width: pupilR * 2, height: pupilR * 2))

    // 眉弓
    let browY = eyeCY - eyeH * 0.82
    ctx.move(to: CGPoint(x: cx - eyeW * 0.36, y: browY))
    ctx.addQuadCurve(
        to: CGPoint(x: cx + eyeW * 0.36, y: browY),
        control: CGPoint(x: cx, y: browY - s * 0.028)
    )
    ctx.strokePath()

    // 眼下竖线
    let markTop = eyeCY + eyeH * 0.5
    let markBot = eyeCY + eyeH * 1.45
    ctx.move(to: CGPoint(x: cx, y: markTop))
    ctx.addLine(to: CGPoint(x: cx, y: markBot))
    ctx.strokePath()

    // 右侧卷尾（荷鲁斯之眼标志卷曲）
    ctx.move(to: CGPoint(x: cx + s * 0.015, y: markBot - s * 0.008))
    ctx.addQuadCurve(
        to: CGPoint(x: cx + eyeW * 0.34, y: markBot + s * 0.015),
        control: CGPoint(x: cx + eyeW * 0.2, y: markBot - s * 0.035)
    )
    ctx.strokePath()

    guard let image = ctx.makeImage() else { fatalError("状态栏图标绘制失败") }
    return image
}

let outPath = CommandLine.arguments[1]
let outSize = Int(CommandLine.arguments[2]) ?? 128
try writePNG(drawSimplifiedStatusIcon(size: outSize), to: outPath)
SWIFT

swift "${TMP_DIR}/draw_status_icon.swift" "${STATUS_ICON}" 128


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
echo "  状态栏图标: 代码绘制（倒三角 + 荷鲁斯之眼）"
