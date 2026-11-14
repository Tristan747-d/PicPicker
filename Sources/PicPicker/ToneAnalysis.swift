import CoreGraphics
import CoreImage
import Foundation

/// 判断高光/阴影是“还能拉回来”，还是已经没有任何细节。
///
/// - 8 位图像（JPG/HEIC/PNG 等）：被写成 255 / 0 的像素本身就不含信息，
///   直接按面积判定。
/// - RAW：渲染到 255 只说明当前色调曲线到头了，未必没有数据。先按 0 EV
///   找出可疑区域，再在 -3 EV / +3 EV 各解码一次；如果该区域仍然一片平坦
///   （标准差接近 0），才是真的没有细节。
struct ToneClipping {
    var whiteFraction = 0.0
    var blackFraction = 0.0
    var isDeadWhite = false
    var isDeadBlack = false
    var highlightRecoverable = false
    var shadowRecoverable = false
}

enum ToneAnalyzer {
    /// 画面里超过这个比例没有高光/阴影细节，才视为“死白/死黑”并排除出选片。
    /// 面积小的高光/暗部（灯光、反光、夜景天空）是正常画面，不参与判定。
    static let deadAreaThreshold = 0.35
    /// 只对超过这个比例的区域做 RAW 二次解码，避免拖慢整批扫描。
    static let rawCandidateThreshold = 0.03
    /// -3 EV 下区域标准差低于该值，说明拉回来依然没有结构。
    static let flatSigma = 3.0
    /// 8 位图像没法二次解码，改用“未裁切部分是否还有细节”来判断：
    /// 归一化标准差低于该值，说明画面剩下部分也是一片平坦。
    static let flatDetailSigma = 0.10

    private static let whiteLevel: UInt8 = 254
    private static let blackLevel: UInt8 = 2
    private static let context = CIContext(
        options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!]
    )

    static func analyze(url: URL, isRaw: Bool, image: CGImage) -> ToneClipping {
        let width = min(512, image.width)
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(1, image.width))))

        guard let tone = grayPixels(from: image, width: width, height: height) else {
            return ToneClipping()
        }
        return analyze(
            url: url,
            isRaw: isRaw,
            toneMap: tone,
            width: width,
            height: height
        )
    }

    private static func analyze(
        url: URL,
        isRaw: Bool,
        toneMap: [UInt8],
        width: Int,
        height: Int
    ) -> ToneClipping {
        var result = ToneClipping()
        result.whiteFraction = fraction(toneMap) { $0 >= whiteLevel }
        result.blackFraction = fraction(toneMap) { $0 <= blackLevel }

        let hasCandidate = max(result.whiteFraction, result.blackFraction) >= rawCandidateThreshold
        guard isRaw, hasCandidate else {
            let isFlat = detailSigma(toneMap) < flatDetailSigma
            result.isDeadWhite = isFlat && result.whiteFraction >= deadAreaThreshold
            result.isDeadBlack = isFlat && result.blackFraction >= deadAreaThreshold
            return result
        }

        guard let whiteSigma = rawStructure(url: url, width: width, height: height, kind: .highlight),
              let blackSigma = rawStructure(url: url, width: width, height: height, kind: .shadow) else {
            // RAW 解码失败时退回保守判断：只按面积标记，不声称可恢复。
            let isFlat = detailSigma(toneMap) < flatDetailSigma
            result.isDeadWhite = isFlat && result.whiteFraction >= deadAreaThreshold
            result.isDeadBlack = isFlat && result.blackFraction >= deadAreaThreshold
            return result
        }

        result.isDeadWhite = result.whiteFraction >= deadAreaThreshold && whiteSigma < flatSigma
        result.isDeadBlack = result.blackFraction >= deadAreaThreshold && blackSigma < flatSigma
        result.highlightRecoverable = !result.isDeadWhite
            && result.whiteFraction >= rawCandidateThreshold
            && whiteSigma >= flatSigma
        result.shadowRecoverable = !result.isDeadBlack
            && result.blackFraction >= rawCandidateThreshold
            && blackSigma >= flatSigma
        return result
    }

    private enum Kind { case highlight, shadow }

    /// 在 -3 EV（高光）或 +3 EV（阴影）下，检查可疑区域是否出现结构。
    private static func rawStructure(url: URL, width: Int, height: Int, kind: Kind) -> Double? {
        guard let filter = CIRAWFilter(imageURL: url.standardizedFileURL) else { return nil }
        if #available(macOS 26.0, *) {
            filter.isHighlightRecoveryEnabled = true
        }
        guard let base = filter.outputImage else { return nil }

        let exposure = kind == .highlight ? -3.0 : 3.0
        let shifted = base.applyingFilter(
            "CIExposureAdjust",
            parameters: [kCIInputEVKey: exposure]
        )
        guard let shiftedPixels = grayPixels(from: shifted, width: width, height: height) else {
            return nil
        }

        // 用 0 EV 的渲染决定哪些像素可疑，保证掩码和移位后的图像对齐。
        guard let basePixels = grayPixels(from: base, width: width, height: height) else {
            return nil
        }
        let isCandidate: (UInt8) -> Bool = kind == .highlight
            ? { $0 >= whiteLevel }
            : { $0 <= blackLevel }
        return standardDeviation(shiftedPixels, mask: basePixels.map(isCandidate))
    }

    private static func grayPixels(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress, let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    private static func grayPixels(from image: CIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return grayPixels(from: cgImage, width: width, height: height)
    }

    private static func fraction(_ pixels: [UInt8], matching: (UInt8) -> Bool) -> Double {
        guard !pixels.isEmpty else { return 0 }
        let count = pixels.reduce(0) { $0 + (matching($1) ? 1 : 0) }
        return Double(count) / Double(pixels.count)
    }

    private static func standardDeviation(_ pixels: [UInt8], mask: [Bool]) -> Double {
        var count = 0.0
        var sum = 0.0
        var sumSquares = 0.0
        for index in pixels.indices where mask[index] {
            let value = Double(pixels[index])
            count += 1
            sum += value
            sumSquares += value * value
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean).squareRoot()
    }

    /// 去掉已经写到 255 / 0 的像素之后，剩下区域的归一化标准差。
    ///
    /// 夜景照片大片黑、逆光照片大片白都是正常画面；只有“剩下部分也没有细节”
    /// 才说明这张确实拍废了。
    private static func detailSigma(_ pixels: [UInt8]) -> Double {
        var count = 0.0
        var sum = 0.0
        var sumSquares = 0.0
        for value in pixels where value > blackLevel && value < whiteLevel {
            let normalized = Double(value) / 255
            count += 1
            sum += normalized
            sumSquares += normalized * normalized
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean).squareRoot()
    }
}
