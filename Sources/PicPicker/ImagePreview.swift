import CoreGraphics
import Foundation
import ImageIO

/// 在终端里用 24 位真彩色半块字符渲染图片预览。
enum ImagePreview {
    static func render(url: URL, columns: Int, rows: Int) -> [String]? {
        guard columns >= 8, rows >= 3 else { return nil }
        guard let image = loadThumbnail(url: url, maxPixel: max(columns * 6, 512)) else {
            return nil
        }
        return render(image: image, columns: columns, rows: rows)
    }

    static func render(image: CGImage, columns: Int, rows: Int) -> [String]? {
        guard columns >= 8, rows >= 3 else { return nil }
        return renderGrid(image: image, columns: columns, rows: rows)
    }

    private static func loadThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func renderGrid(image: CGImage, columns: Int, rows: Int) -> [String]? {
        let pixelRows = rows * 2
        // 终端字符是 ~2:1 的竖长格，一列宽约等于两行高，所以直接把整块网格交给
        // CoreGraphics 等比缩放铺满，不再人为留边，分辨率不被吃掉。

        var pixels = [UInt8](repeating: 0, count: columns * pixelRows * 4)
        let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let base = buffer.baseAddress,
                let context = CGContext(
                    data: base,
                    width: columns,
                    height: pixelRows,
                    bitsPerComponent: 8,
                    bytesPerRow: columns * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else {
                return false
            }
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: columns, height: pixelRows))
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: columns, height: pixelRows)
            )
            return true
        }
        guard created else { return nil }

        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            // 目标缓冲按 CGContext 惯例是行 0 在底部；ctx.draw 会把源图写成
            // 行 0 在顶部的内存布局，所以自上而下直接取 row*2 / row*2+1 即可。
            // ▀ 的前景色画上半格，背景色画下半格。
            let topRow = row * 2
            let bottomRow = topRow + 1
            var line = ""
            line.reserveCapacity(columns * 24)
            var lastTop: UInt32?
            var lastBottom: UInt32?

            for column in 0..<columns {
                let top = color(pixels, columns: columns, x: column, y: topRow)
                let bottom = color(pixels, columns: columns, x: column, y: bottomRow)
                if top != lastTop || bottom != lastBottom {
                    line += "\u{1B}[38;2;\(red(top));\(green(top));\(blue(top))"
                        + ";48;2;\(red(bottom));\(green(bottom));\(blue(bottom))m"
                    lastTop = top
                    lastBottom = bottom
                }
                line.append("\u{2580}")
            }
            line += Ansi.reset
            lines.append(line)
        }
        return lines
    }

    private static func color(_ pixels: [UInt8], columns: Int, x: Int, y: Int) -> UInt32 {
        let index = (y * columns + x) * 4
        guard index + 3 < pixels.count else { return 0 }
        return (UInt32(pixels[index]) << 16)
            | (UInt32(pixels[index + 1]) << 8)
            | UInt32(pixels[index + 2])
    }

    private static func red(_ color: UInt32) -> UInt32 { (color >> 16) & 0xFF }
    private static func green(_ color: UInt32) -> UInt32 { (color >> 8) & 0xFF }
    private static func blue(_ color: UInt32) -> UInt32 { color & 0xFF }
}
