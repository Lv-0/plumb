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

# ── 生成状态栏 template 图标（从设计稿提取水滴剪影，单色）──
# 直接从彩色设计稿 AppIcon-base.png 提取水滴 silhouette：
#   1. 以亮度阈值找出所有"亮"像素（包含水滴主体与四角白色填充伪影）。
#   2. 从画面中心做 flood-fill，只保留与中心连通的亮块——即水滴本身，
#      自动丢弃四角的白色填充（它们与中心不连通）。
#   3. 输出纯黑 + 透明 alpha 的单色 template，交给 macOS 上色。
# 这样状态栏剪影与 App 图标完全同构，而非代码近似的几何。
cat > "${TMP_DIR}/extract_status.swift" <<'SWIFT'
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

let argv = CommandLine.arguments
let srcPath = argv[1]        // 已标准化的 1024×1024 AppIcon-base.png 工作副本
let outPath = argv[2]        // StatusIconTemplate.png

// Load source into an RGBA buffer.
guard
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
else {
    throw NSError(domain: "IconGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法读取设计稿"])
}
let W = img.width, H = img.height
let cs = CGColorSpace(name: CGColorSpace.genericRGBLinear)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)

// Bright-pixel test. 阈值 90 兼顾半透明边缘与高光，同时仍能排除深色背景。
func isBright(_ x: Int, _ y: Int) -> Bool {
    let o = (y * W + x) * 4
    let l = 0.299 * Double(buf[o]) + 0.587 * Double(buf[o + 1]) + 0.114 * Double(buf[o + 2])
    return Int(l) >= 90
}

// 从画面中心做 flood-fill，保留与中心连通的亮块。
var keep = [UInt8](repeating: 0, count: W * H)
let seed = (W / 2, H / 2)
var queue = [(Int, Int)]()
if isBright(seed.0, seed.1) {
    queue.append(seed)
    keep[seed.1 * W + seed.0] = 1
}
var head = 0
while head < queue.count {
    let (x, y) = queue[head]; head += 1
    let nbrs = [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    for (nx, ny) in nbrs {
        guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
        let idx = ny * W + nx
        guard keep[idx] == 0, isBright(nx, ny) else { continue }
        keep[idx] = 1
        queue.append((nx, ny))
    }
}

// 把连通的水滴块写入一个单色（黑）+ 透明 alpha 的输出上下文。
let out = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.clear(CGRect(x: 0, y: 0, width: W, height: H))
let obuf = out.data!.assumingMemoryBound(to: UInt8.self)
for y in 0..<H {
    for x in 0..<W {
        if keep[y * W + x] == 1 {
            let o = (y * W + x) * 4
            obuf[o] = 0; obuf[o + 1] = 0; obuf[o + 2] = 0; obuf[o + 3] = 255
        }
    }
}
guard let fullRes = out.makeImage() else {
    throw NSError(domain: "IconGen", code: 4, userInfo: [NSLocalizedDescriptionKey: "状态栏剪影合成失败"])
}

// 缩放到 64×64（菜单栏实际渲染尺寸，@1x）。高质量重采样保证 16px 渲染清晰。
let px = 64
let scaled = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
scaled.interpolationQuality = .high
scaled.clear(CGRect(x: 0, y: 0, width: px, height: px))
scaled.draw(fullRes, in: CGRect(x: 0, y: 0, width: px, height: px))
guard let final = scaled.makeImage() else {
    throw NSError(domain: "IconGen", code: 5, userInfo: [NSLocalizedDescriptionKey: "状态栏图标缩放失败"])
}
try writePNG(final, to: outPath)
SWIFT

swift "${TMP_DIR}/extract_status.swift" "${APP_BASE}" "${STATUS_ICON}"


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
