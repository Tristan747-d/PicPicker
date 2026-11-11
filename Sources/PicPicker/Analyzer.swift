import CoreGraphics
import Foundation
import ImageIO
import Vision

enum AnalyzerError: LocalizedError {
    case cannotOpen(String)
    case cannotDecode(String)
    case cannotRender(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): return "无法读取 \(name)"
        case .cannotDecode(let name): return "无法解码 \(name)"
        case .cannotRender(let name): return "无法分析 \(name)"
        }
    }
}

private struct VisionMetrics {
    let featurePrint: FeaturePrintObservation?
    let aesthetics: Double?
    let isUtility: Bool
    let faceQuality: Double?
    let faceCount: Int
    let salientRect: CGRect?
    let eyesClosed: Bool
    let eyeRatio: Double?
    let headCutoff: Bool
    let isDocument: Bool
    let horizonAngle: Double?
}

private struct DecodedImage {
    let image: CGImage
    let iso: Int?
    let captureDate: Date?
}

enum ImageAnalyzer {
    static var defaultConcurrency: Int {
        max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
    }

    static func analyzeAll(
        urls: [URL],
        concurrency: Int = defaultConcurrency,
        onProgress: @escaping @Sendable (_ completed: Int, _ name: String) -> Void
    ) async -> [ImageRecord] {
        guard !urls.isEmpty else { return [] }

        var results = [ImageRecord?](repeating: nil, count: urls.count)
        let limit = max(1, min(concurrency, urls.count))

        await withTaskGroup(of: (Int, ImageRecord).self) { group in
            var nextIndex = 0

            for _ in 0..<limit {
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    (index, await analyze(url: urls[index]))
                }
            }

            var completed = 0
            while let (index, record) = await group.next() {
                results[index] = record
                completed += 1
                onProgress(completed, record.originalName)

                if nextIndex < urls.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        (index, await analyze(url: urls[index]))
                    }
                }
            }
        }

        return results.compactMap { $0 }
    }

    static func analyze(url: URL) async -> ImageRecord {
        let record = ImageRecord(url: url)

        do {
            let decoded = try loadImage(url: url, maxPixel: 2048)
            let image = decoded.image
            record.iso = decoded.iso
            record.isJPG = ["jpg", "jpeg", "jpe"].contains(url.pathExtension.lowercased())
            record.captureDate = decoded.captureDate
            guard let gray = GrayImage(cgImage: image) else {
                throw AnalyzerError.cannotRender(url.lastPathComponent)
            }

            let metrics = await visionMetrics(for: image)
            record.featurePrint = metrics.featurePrint
            record.aesthetics = metrics.aesthetics
            record.isUtility = metrics.isUtility
            record.faceQuality = metrics.faceQuality
            record.faceCount = metrics.faceCount
            record.eyesClosed = metrics.eyesClosed
            record.eyesClosedScore = metrics.eyeRatio
            record.headCutoff = metrics.headCutoff
            record.isDocument = metrics.isDocument
            record.horizonAngle = metrics.horizonAngle

            if metrics.eyesClosed {
                record.yellowReasons.append("闭眼")
            }
            if metrics.headCutoff {
                record.yellowReasons.append("断头")
            }
            if (metrics.isDocument || metrics.isUtility), metrics.faceCount == 0 {
                record.redReasons.append("文档/截图")
            }
            if let angle = metrics.horizonAngle,
               abs(angle) > Preprocess.horizonMaxAngle {
                record.redReasons.append("地平倾斜 \(Int(angle.rounded()))°")
            }

            let exposure = gray.exposureMetrics()
            record.meanLuma = exposure.mean
            record.luminanceStd = exposure.standardDeviation
            record.clippedFraction = exposure.clippedFraction
            record.shadowClippedFraction = exposure.shadowClipped
            record.highlightClippedFraction = exposure.highlightClipped
            record.exposure = exposure.score

            if exposure.mean >= Preprocess.extremeOverexposureLuma,
               exposure.highlightClipped >= Preprocess.extremeExposureClipped {
                record.redReasons.append("极端过曝")
            }
            if exposure.mean <= Preprocess.extremeUnderexposureLuma,
               exposure.shadowClipped >= Preprocess.extremeExposureClipped {
                record.redReasons.append("极端欠曝")
            }

            let salientRect = metrics.salientRect.flatMap {
                gray.expandedPixelRect(fromNormalized: $0, padding: 0.18)
            }
            let sharpness = gray.sharpness(in: salientRect)
            record.sharpnessRaw = sharpness
            record.sharpness = normalizeSharpness(sharpness)
            record.dHash = gray.dHash()
            record.score = finalScore(for: record)
        } catch {
            record.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        return record
    }

    private static func loadImage(url: URL, maxPixel: Int) throws -> DecodedImage {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            throw AnalyzerError.cannotOpen(url.lastPathComponent)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AnalyzerError.cannotDecode(url.lastPathComponent)
        }
        return DecodedImage(
            image: image,
            iso: readISO(from: source),
            captureDate: readCaptureDate(from: source)
        )
    }

    private static func readISO(from source: CGImageSource) -> Int? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else {
            return nil
        }

        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings] as? [Any],
           let first = ratings.first as? NSNumber {
            return first.intValue
        }
        if let index = exif[kCGImagePropertyExifRecommendedExposureIndex] as? NSNumber {
            return index.intValue
        }
        return nil
    }

    private static func readCaptureDate(from source: CGImageSource) -> Date? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard
            let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: dateString) else { return nil }

        if let subsecond = exif?[kCGImagePropertyExifSubsecTimeOriginal] as? String,
           let value = Double("0." + subsecond.filter(\.isNumber)) {
            return date.addingTimeInterval(value)
        }
        return date
    }

    private static func visionMetrics(for image: CGImage) async -> VisionMetrics {
        let featureRequest = GenerateImageFeaturePrintRequest()
        let aestheticsRequest = CalculateImageAestheticsScoresRequest()
        let faceRequest = DetectFaceCaptureQualityRequest()
        let landmarkRequest = DetectFaceLandmarksRequest()
        let saliencyRequest = GenerateAttentionBasedSaliencyImageRequest()
        let documentRequest = DetectDocumentSegmentationRequest()
        let horizonRequest = DetectHorizonRequest()

        let handler = ImageRequestHandler(image)

        do {
            let (feature, aesthetics, faces, salient, landmarks, document, horizon) = try await handler.perform(
                featureRequest,
                aestheticsRequest,
                faceRequest,
                saliencyRequest,
                landmarkRequest,
                documentRequest,
                horizonRequest
            )
            return assembleVisionMetrics(
                feature: feature,
                aesthetics: aesthetics,
                faces: faces,
                saliency: salient,
                landmarks: landmarks,
                document: document,
                horizon: horizon,
                imageSize: CGSize(width: image.width, height: image.height)
            )
        } catch {
            async let feature = try? featureRequest.perform(on: image)
            async let aesthetics = try? aestheticsRequest.perform(on: image)
            async let faces = try? faceRequest.perform(on: image)
            async let saliency = try? saliencyRequest.perform(on: image)
            async let landmarks = try? landmarkRequest.perform(on: image)
            async let document = try? documentRequest.perform(on: image)
            async let horizon = try? horizonRequest.perform(on: image)

            return assembleVisionMetrics(
                feature: await feature,
                aesthetics: await aesthetics,
                faces: await faces ?? [],
                saliency: await saliency,
                landmarks: await landmarks ?? [],
                document: await document ?? nil,
                horizon: await horizon ?? nil,
                imageSize: CGSize(width: image.width, height: image.height)
            )
        }
    }

    private static func assembleVisionMetrics(
        feature: FeaturePrintObservation?,
        aesthetics: ImageAestheticsScoresObservation?,
        faces: [FaceObservation],
        saliency: SaliencyImageObservation?,
        landmarks: [FaceObservation],
        document: DetectedDocumentObservation?,
        horizon: HorizonObservation?,
        imageSize: CGSize
    ) -> VisionMetrics {
        let faceQualities = faces.compactMap { face -> (Double, Double)? in
            guard let quality = face.captureQuality?.score else { return nil }
            let box = face.boundingBox.cgRect
            let area = Double(box.width * box.height)
            return (Double(quality), area)
        }

        var faceQuality: Double?
        if !faceQualities.isEmpty {
            let areaSum = faceQualities.reduce(0) { $0 + $1.1 }
            if areaSum > 0 {
                faceQuality = faceQualities.reduce(0) { $0 + $1.0 * $1.1 } / areaSum
            } else {
                faceQuality = faceQualities.reduce(0) { $0 + $1.0 } / Double(faceQualities.count)
            }
        }

        let salientRect = saliency?.salientObjects.max { lhs, rhs in
            let left = lhs.boundingBox.cgRect.width * lhs.boundingBox.cgRect.height * CGFloat(lhs.confidence)
            let right = rhs.boundingBox.cgRect.width * rhs.boundingBox.cgRect.height * CGFloat(rhs.confidence)
            return left < right
        }?.boundingBox.cgRect

        let aestheticsScore = aesthetics.map { clamp((Double($0.overallScore) + 1) / 2) }

        let eyeAnalysis = analyzeEyes(landmarks.isEmpty ? faces : landmarks, imageSize: imageSize)
        let detectedDocument = isDocument(document)
        let horizonAngle = horizon.map {
            $0.angle.converted(to: .degrees).value
        }

        return VisionMetrics(
            featurePrint: feature,
            aesthetics: aestheticsScore,
            isUtility: aesthetics?.isUtility ?? false,
            faceQuality: faceQuality,
            faceCount: faces.count,
            salientRect: salientRect,
            eyesClosed: eyeAnalysis.eyesClosed,
            eyeRatio: eyeAnalysis.ratio,
            headCutoff: eyeAnalysis.headCutoff,
            isDocument: detectedDocument,
            horizonAngle: horizonAngle.map { ($0 * 10).rounded() / 10 }
        )
    }

    private struct EyeAnalysis {
        let eyesClosed: Bool
        let ratio: Double?
        let headCutoff: Bool
    }

    private static func analyzeEyes(_ faces: [FaceObservation], imageSize: CGSize) -> EyeAnalysis {
        var ratios: [Double] = []
        var closed = false
        var headCutoff = false

        for face in faces {
            let box = face.boundingBox.cgRect
            guard box.height >= Preprocess.eyeClosedMinimumFaceHeight else { continue }

            if box.maxY >= 1 - Preprocess.headCutoffMargin {
                headCutoff = true
            }

            let yaw = abs(face.yaw.converted(to: .degrees).value)
            let roll = abs(face.roll.converted(to: .degrees).value)
            guard yaw <= Preprocess.eyeMaxYawDegrees,
                  roll <= Preprocess.eyeMaxYawDegrees else {
                continue
            }

            guard let faceLandmarks = face.landmarks else { continue }
            for eye in [faceLandmarks.leftEye, faceLandmarks.rightEye] {
                let points = eye.pointsInImageCoordinates(imageSize)
                let ratio = eyeAspectRatio(points)
                guard let ratio else { continue }
                ratios.append(ratio)
                if ratio < Preprocess.eyeClosedRatio {
                    closed = true
                }
            }
        }

        let average = ratios.isEmpty ? nil : ratios.reduce(0, +) / Double(ratios.count)
        return EyeAnalysis(eyesClosed: closed, ratio: average, headCutoff: headCutoff)
    }

    /// 标准 EAR：上下眼睑距离与眼角水平距离之比。
    private static func eyeAspectRatio(_ points: [CGPoint]) -> Double? {
        guard points.count >= 6 else { return nil }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            sqrt(pow(Double(a.x - b.x), 2) + pow(Double(a.y - b.y), 2))
        }
        let horizontal = distance(points[0], points[3])
        guard horizontal > 0 else { return nil }
        let upperLowerA = distance(points[1], points[5])
        let upperLowerB = distance(points[2], points[4])
        return (upperLowerA + upperLowerB) / (2 * horizontal)
    }

    private static func isDocument(_ observation: DetectedDocumentObservation?) -> Bool {
        guard let observation else { return false }
        guard observation.confidence >= 0.5 else { return false }

        let corners = [
            observation.topLeft.cgPoint,
            observation.topRight.cgPoint,
            observation.bottomRight.cgPoint,
            observation.bottomLeft.cgPoint
        ]
        var area = 0.0
        for index in corners.indices {
            let current = corners[index]
            let next = corners[(index + 1) % corners.count]
            area += Double(current.x * next.y - next.x * current.y)
        }
        return abs(area) / 2 >= 0.05
    }

    private static func rotationDeviation(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 90)
        if value > 45 { value -= 90 }
        if value < -45 { value += 90 }
        return value
    }

    private static func normalizeSharpness(_ raw: Double) -> Double {
        clamp(log1p(max(0, raw)) / log1p(1400))
    }

    private static func finalScore(for record: ImageRecord) -> Double {
        let aesthetics = record.aesthetics ?? 0.5
        var score: Double

        if record.faceCount > 0, let faceQuality = record.faceQuality {
            score = aesthetics * 0.45
                + record.sharpness * 0.27
                + record.exposure * 0.18
                + faceQuality * 0.10
        } else {
            score = aesthetics * 0.50
                + record.sharpness * 0.30
                + record.exposure * 0.20
        }

        if record.isUtility {
            score -= 0.15
        }
        return clamp(score)
    }
}

private struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(cgImage: CGImage) {
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        width = imageWidth
        height = imageHeight

        var buffer = [UInt8](repeating: 0, count: imageWidth * imageHeight)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let created = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bytesPerRow: imageWidth,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            return true
        }
        guard created else { return nil }
        pixels = buffer
    }

    struct ExposureMetrics {
        let mean: Double
        let standardDeviation: Double
        let clippedFraction: Double
        let shadowClipped: Double
        let highlightClipped: Double
        let score: Double
    }

    func exposureMetrics() -> ExposureMetrics {
        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0.0
        var sumSquares = 0.0

        pixels.withUnsafeBufferPointer { buffer in
            for value in buffer {
                histogram[Int(value)] += 1
                let normalized = Double(value) / 255
                sum += normalized
                sumSquares += normalized * normalized
            }
        }

        let count = Double(pixels.count)
        let mean = sum / count
        let variance = max(0, sumSquares / count - mean * mean)
        let std = sqrt(variance)

        let low = histogram[0...2].reduce(0, +)
        let high = histogram[253...255].reduce(0, +)
        let clipped = Double(low + high) / count

        let meanScore = exp(-pow(mean - 0.55, 2) / (2 * pow(0.23, 2)))
        let clipScore = 1 - clamp(clipped / 0.06)
        let contrastScore = clamp(std / 0.24)
        let score = clamp(meanScore * 0.45 + clipScore * 0.35 + contrastScore * 0.20)

        return ExposureMetrics(
            mean: mean,
            standardDeviation: std,
            clippedFraction: clipped,
            shadowClipped: Double(low) / count,
            highlightClipped: Double(high) / count,
            score: score
        )
    }

    func sharpness(in rect: CGRect?) -> Double {
        var region = rect ?? CGRect(x: 0, y: 0, width: width, height: height)
        region = region.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        if region.width < 3 || region.height < 3 {
            region = CGRect(x: 0, y: 0, width: width, height: height)
        }

        let x0 = max(1, Int(region.minX.rounded(.down)))
        let y0 = max(1, Int(region.minY.rounded(.down)))
        let x1 = min(width - 1, Int(region.maxX.rounded(.up)))
        let y1 = min(height - 1, Int(region.maxY.rounded(.up)))
        guard x1 - x0 > 2, y1 - y0 > 2 else { return 0 }

        var sum = 0.0
        var sumSquares = 0.0
        var sampleCount = 0

        pixels.withUnsafeBufferPointer { buffer in
            for y in y0..<y1 {
                let row = y * width
                for x in x0..<x1 {
                    let center = Int(buffer[row + x]) * 4
                    let response = center
                        - Int(buffer[row + x - 1])
                        - Int(buffer[row + x + 1])
                        - Int(buffer[row - width + x])
                        - Int(buffer[row + width + x])
                    let value = Double(response)
                    sum += value
                    sumSquares += value * value
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return 0 }
        let mean = sum / Double(sampleCount)
        return max(0, sumSquares / Double(sampleCount) - mean * mean)
    }

    func expandedPixelRect(fromNormalized rect: CGRect, padding: CGFloat) -> CGRect? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return normalizedRect(rect, padding: padding)
    }

    private func normalizedRect(_ rect: CGRect, padding: CGFloat) -> CGRect? {
        let expanded = rect.insetBy(
            dx: -rect.width * padding,
            dy: -rect.height * padding
        )
        let normalized = expanded.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard normalized.width > 0.02, normalized.height > 0.02 else { return nil }

        // Vision uses a lower-left origin; the grayscale buffer uses top-left rows.
        let pixelRect = CGRect(
            x: normalized.minX * CGFloat(width),
            y: (1 - normalized.maxY) * CGFloat(height),
            width: normalized.width * CGFloat(width),
            height: normalized.height * CGFloat(height)
        )
        return pixelRect
    }

    func dHash() -> UInt64 {
        let targetWidth = 9
        let targetHeight = 8
        var cells = [Double](repeating: 0, count: targetWidth * targetHeight)

        for cellY in 0..<targetHeight {
            let y0 = cellY * height / targetHeight
            let y1 = max(y0 + 1, (cellY + 1) * height / targetHeight)
            for cellX in 0..<targetWidth {
                let x0 = cellX * width / targetWidth
                let x1 = max(x0 + 1, (cellX + 1) * width / targetWidth)
                var sum = 0
                var count = 0
                for y in y0..<min(y1, height) {
                    let row = y * width
                    for x in x0..<min(x1, width) {
                        sum += Int(pixels[row + x])
                        count += 1
                    }
                }
                cells[cellY * targetWidth + cellX] = count > 0 ? Double(sum) / Double(count) : 0
            }
        }

        var hash: UInt64 = 0
        var bit = 0
        for row in 0..<targetHeight {
            for column in 0..<(targetWidth - 1) {
                if cells[row * targetWidth + column] < cells[row * targetWidth + column + 1] {
                    hash |= (1 << UInt64(bit))
                }
                bit += 1
            }
        }
        return hash
    }
}
