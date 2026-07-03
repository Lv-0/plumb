#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────
# 图标生成脚本
#
# App 图标：直接使用设计稿静态图 assets/AppIcon-base.png（1024×1024 PNG），
#           通过 sips 缩放出 iconset 全尺寸，再用 iconutil 打包成 .icns。
#           不再用代码绘制 App 图标——设计稿由设计师/AI 出图后放入 assets/。
#
# 状态栏图标（menu bar template）：由 assets/logo.png 裁切缩放并转为单色 template。
#           源图为线稿风格；浅色背景去透明、深色线条保留为纯黑，供 NSImage.isTemplate 着色。
# ─────────────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="${ROOT_DIR}/.build/icons"
ICONSET_DIR="${TMP_DIR}/AppIcon.iconset"
APP_BASE_SOURCE="${ROOT_DIR}/assets/AppIcon-base.png"   # 设计稿源图（1024×1024 PNG）
APP_BASE="${TMP_DIR}/AppIconBase.png"                    # 复制到 build 目录的工作副本
STATUS_ICON_SOURCE="${ROOT_DIR}/assets/logo.png"
STATUS_ICON="${TMP_DIR}/StatusIconTemplate.png"
STATUS_ICON_WORK="${TMP_DIR}/StatusIconWork.png"
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

# ── 生成状态栏 template 图标（由 assets/logo.png 裁切 → 256px 处理 → 128px 输出）──
if [[ ! -f "${STATUS_ICON_SOURCE}" ]]; then
  echo "错误：找不到状态栏图标源图 ${STATUS_ICON_SOURCE}"
  exit 1
fi

cp "${STATUS_ICON_SOURCE}" "${STATUS_ICON_WORK}"
LOGO_W="$(sips -g pixelWidth "${STATUS_ICON_WORK}" | awk '/pixelWidth/ {print $2}')"
LOGO_H="$(sips -g pixelHeight "${STATUS_ICON_WORK}" | awk '/pixelHeight/ {print $2}')"
if [[ "${LOGO_W}" != "${LOGO_H}" ]]; then
  CROP=$(( LOGO_W < LOGO_H ? LOGO_W : LOGO_H ))
  echo "状态栏源图 ${LOGO_W}×${LOGO_H} 非正方形，居中裁剪为 ${CROP}×${CROP}..."
  sips -c "${CROP}" "${CROP}" "${STATUS_ICON_WORK}" >/dev/null
fi
# 先在 256px 做 template 转换（保留线稿细节 + 加粗），输出 128px 供菜单栏（含 Retina）。
STATUS_ICON_256="${TMP_DIR}/StatusIcon256.png"
sips -z 256 256 "${STATUS_ICON_WORK}" --out "${STATUS_ICON_256}" >/dev/null

cat > "${TMP_DIR}/make_status_template.swift" <<'SWIFT'
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

/// 线稿 PNG → 菜单栏 template：浅色背景透明，深色线条纯黑不透明（避免半透明导致菜单栏发灰）。
func makeStatusTemplate(from source: CGImage, outputSize: Int) -> CGImage {
    let w = source.width
    let h = source.height
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))

    guard let data = ctx.data else { fatalError("状态栏图标像素读取失败") }
    let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    // 阈值偏高，只保留线芯像素，线条更细。
    let lineThreshold: CGFloat = 0.76
    var mask = [Bool](repeating: false, count: w * h)

    // CGContext 像素缓冲首行在底部；转为视觉坐标（row 0 = 图像顶部，与 PNG 一致）。
    for memY in 0..<h {
        let visualY = h - 1 - memY
        for x in 0..<w {
            let i = (memY * w + x) * 4
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            mask[visualY * w + x] = lum < lineThreshold
        }
    }

    // 裁掉空白边距，放大主体至贴边（仅留 1px 安全边）。
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
        for x in 0..<w where mask[y * w + x] {
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard minX <= maxX, minY <= maxY else { fatalError("状态栏图标未检测到线条") }

    let out = outputSize
    let margin: CGFloat = 1
    let avail = CGFloat(out) - margin * 2
    let srcW = CGFloat(maxX - minX + 1)
    let srcH = CGFloat(maxY - minY + 1)
    let scale = min(avail / srcW, avail / srcH)

    let outCtx = CGContext(
        data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    outCtx.clear(CGRect(x: 0, y: 0, width: out, height: out))
    guard let outData = outCtx.data else { fatalError("状态栏图标像素写入失败") }
    let outPixels = outData.bindMemory(to: UInt8.self, capacity: out * out * 4)

    let offsetX = margin + (avail - srcW * scale) / 2
    let offsetY = margin + (avail - srcH * scale) / 2
    for y in minY...maxY {
        for x in minX...maxX where mask[y * w + x] {
            let ox = Int((offsetX + CGFloat(x - minX) * scale).rounded())
            let oy = Int((offsetY + CGFloat(y - minY) * scale).rounded())
            guard ox >= 0, ox < out, oy >= 0, oy < out else { continue }
            let memOy = out - 1 - oy
            let i = (memOy * out + ox) * 4
            outPixels[i] = 0
            outPixels[i + 1] = 0
            outPixels[i + 2] = 0
            outPixels[i + 3] = 255
        }
    }

    guard let image = outCtx.makeImage() else { fatalError("状态栏 template 转换失败") }
    return image
}

let inPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let outSize = Int(CommandLine.arguments[3]) ?? 128
let srcURL = URL(fileURLWithPath: inPath) as CFURL
guard let src = CGImageSourceCreateWithURL(srcURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("无法读取状态栏源图: \(inPath)")
}
try writePNG(makeStatusTemplate(from: cgImage, outputSize: outSize), to: outPath)
SWIFT

swift "${TMP_DIR}/make_status_template.swift" "${STATUS_ICON_256}" "${STATUS_ICON}" 128


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
echo "  状态栏图标源: ${STATUS_ICON_SOURCE}"
