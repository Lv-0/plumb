#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# 图标生成脚本
#
# App 图标：直接使用设计稿静态图 assets/AppIcon-base.png（1024×1024 PNG），
#           通过 sips 缩放出 iconset 全尺寸，再用 iconutil 打包成 .icns。
#           不再用代码绘制 App 图标——设计稿由设计师/AI 出图后放入 assets/。
#
# 状态栏图标（menu bar template）：代码绘制“居中窗口”功能符号。
#           屏幕框、垂直对齐线和中央窗口均为具象元素，只使用黑色与透明度。
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

# ── 生成状态栏 template 图标（代码绘制，128px 输出供菜单栏 Retina 缩放）──
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

/// Plumb 菜单栏 template：“居中窗口”功能符号。
///
/// 外框代表屏幕，中间的实心圆角矩形代表应用窗口，贯穿上下的短竖线说明
/// 它已落在精确中轴。无需解释即可读成“把窗口放到屏幕中央”。
/// 图形只含纯黑与透明；边缘由 Core Graphics 抗锯齿生成。
/// NSImage.isTemplate 会在浅色、深色和菜单高亮状态下自动着色。
func drawStatusIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 使用与 PNG 视觉一致的左上角坐标系，便于按菜单栏光学尺寸调节。
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    ctx.setFillColor(black)

    // 屏幕轮廓：横向比例与常见 Mac 窗口接近，18pt 下视觉范围约 15.5×11.3pt。
    let frameRect = CGRect(x: s * 0.109375, y: s * 0.2265625,
                           width: s * 0.78125, height: s * 0.546875)
    let frameRadius = s * 0.109375
    ctx.setStrokeColor(black)
    ctx.setLineWidth(s * 0.078125)
    ctx.setLineJoin(.round)
    ctx.addPath(CGPath(
        roundedRect: frameRect,
        cornerWidth: frameRadius,
        cornerHeight: frameRadius,
        transform: nil
    ))
    ctx.strokePath()

    // 铅直中轴先画，随后由中央窗口遮住中段，仅在上下露出，避免十字准星感。
    ctx.setLineWidth(s * 0.0625)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: s * 0.5, y: s * 0.265625))
    ctx.addLine(to: CGPoint(x: s * 0.5, y: s * 0.734375))
    ctx.strokePath()

    // 被管理的窗口：严格位于屏幕中心，横向矩形避免被误读为圆点或抽象孔洞。
    let windowRect = CGRect(x: s * 0.3046875, y: s * 0.3828125,
                            width: s * 0.390625, height: s * 0.234375)
    let windowRadius = s * 0.0625
    ctx.addPath(CGPath(
        roundedRect: windowRect,
        cornerWidth: windowRadius,
        cornerHeight: windowRadius,
        transform: nil
    ))
    ctx.fillPath()

    guard let image = ctx.makeImage() else { fatalError("状态栏 template 绘制失败") }
    return image
}

let outPath = CommandLine.arguments[1]
let outSize = Int(CommandLine.arguments[2]) ?? 128
try writePNG(drawStatusIcon(size: outSize), to: outPath)
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
echo "  状态栏图标: 代码绘制（屏幕 + 中轴 + 居中窗口）"
