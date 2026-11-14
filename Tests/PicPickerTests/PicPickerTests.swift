import XCTest
@testable import PicPicker

final class PicPickerTests: XCTestCase {
    func testNaturalCompareOrdersCameraNames() {
        XCTAssertTrue(naturalCompare("DSC2.jpg", "DSC10.jpg"))
        XCTAssertFalse(naturalCompare("DSC10.jpg", "DSC2.jpg"))
    }

    func testPlannedNamesAreGroupedAndStable() {
        let first = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        let second = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3346.jpg"))
        let winner = first
        let group = PhotoGroup(id: 1, records: [second, first], winner: winner)

        let plans = FileActions.plannedNames(for: [group])
        XCTAssertEqual(plans.first { $0.0 === first }?.1, "1-DSC3345.jpg")
        XCTAssertEqual(plans.first { $0.0 === second }?.1, "1-DSC3346.jpg")
    }

    func testExistingPrefixIsReplaced() {
        let record = ImageRecord(url: URL(fileURLWithPath: "/tmp/7-DSC3345.jpg"))
        let group = PhotoGroup(id: 2, records: [record], winner: record)

        let plans = FileActions.plannedNames(for: [group])
        XCTAssertEqual(plans.first?.1, "2-DSC3345.jpg")
    }

    func testFinderGreenTagRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picpicker-tag-\(UUID().uuidString).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(try FinderTags.addGreen(to: url))
        XCTAssertTrue(FinderTags.read(from: url).contains("Green\n2"))
        try FinderTags.removeGreen(from: url)
        XCTAssertFalse(FinderTags.read(from: url).contains("Green\n2"))
    }

    func testFilenameSequenceParsing() {
        XCTAssertEqual(parseFilenameSequence("DSC3345.jpg")?.number, 3345)
        XCTAssertEqual(parseFilenameSequence("DSC3345.jpg")?.prefix, "dsc")
        XCTAssertEqual(parseFilenameSequence("1-DSC3345.JPG")?.number, 3345)
        XCTAssertEqual(parseFilenameSequence("DSC3345-2.jpg")?.number, 3345)
        XCTAssertEqual(parseFilenameSequence("IMG_2024_001.jpg")?.number, 1)
        XCTAssertNil(parseFilenameSequence("IMG_77.jpg"))
    }

    func testPhotoGroupDetectsBurstOnlyWithinSameSequence() {
        let first = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        let second = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3346.jpg"))
        let third = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3347.jpg"))
        for (record, number) in [(first, 3345), (second, 3346), (third, 3347)] {
            record.sequenceKey = "|dsc"
            record.sequenceNumber = number
        }
        XCTAssertTrue(PhotoGroup(id: 1, records: [first, second, third], winner: first).isBurst)

        third.sequenceNumber = 3400
        XCTAssertFalse(PhotoGroup(id: 1, records: [first, second, third], winner: first).isBurst)

        third.sequenceNumber = 3347
        second.sequenceKey = "Day2|dsc"
        XCTAssertFalse(PhotoGroup(id: 1, records: [first, second, third], winner: first).isBurst)
    }

    func testExcludingPhotosDropsSingletonsAndRenumbersGroups() {
        let a1 = ImageRecord(url: URL(fileURLWithPath: "/tmp/a1.jpg"))
        let a2 = ImageRecord(url: URL(fileURLWithPath: "/tmp/a2.jpg"))
        let a3 = ImageRecord(url: URL(fileURLWithPath: "/tmp/a3.jpg"))
        let b1 = ImageRecord(url: URL(fileURLWithPath: "/tmp/b1.jpg"))
        let b2 = ImageRecord(url: URL(fileURLWithPath: "/tmp/b2.jpg"))
        for record in [a1, a2, a3, b1, b2] {
            record.aesthetics = 0.5
            record.exposure = 0.5
        }
        let groups = [
            PhotoGroup(id: 1, records: [a1, a2, a3], winner: a1),
            PhotoGroup(id: 2, records: [b1, b2], winner: b1)
        ]

        a2.isUserExcluded = true
        a3.isUserExcluded = true
        let refined = GroupEditor.refine(groups: groups) { _, _ in nil }

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined.first?.id, 1)
        XCTAssertEqual(refined.first?.records.map(\.originalName), ["b1.jpg", "b2.jpg"])
    }

    func testManualWinnerOverridesScoreAndDrivesNaming() {
        let high = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        let low = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3346.jpg"))
        let group = PhotoGroup(id: 1, records: [high, low], winner: high)

        low.isUserWinner = true
        let refined = GroupEditor.refine(groups: [group]) { _, _ in nil }
        XCTAssertTrue(refined.first?.winner === low)
        XCTAssertTrue(low.isUserWinner)
        XCTAssertFalse(high.isUserWinner)

        let plans = FileActions.plannedNames(for: refined)
        XCTAssertEqual(plans.first { $0.0 === low }?.1, "1-DSC3346.jpg")
    }

    func testExcludedPhotosAreNotPreprocessed() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("picpicker-exclude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = folder.appendingPathComponent("DSC3345.jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        let record = ImageRecord(url: url)
        record.isJPG = true
        record.iso = 20_000
        record.targetName = "DSC3345.jpg"
        record.isUserExcluded = true

        let preview = FileActions.preview(groups: [], records: [record])
        XCTAssertEqual(preview.redTaggedCount, 0)
        XCTAssertEqual(preview.highISOMarkedCount, 0)

        let report = try FileActions.apply(groups: [], folder: folder, records: [record])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FinderTags.read(from: url).contains("Red\n6"))
    }

    func testImagePreviewKeepsTopRowsAtTop() throws {
        let width = 40
        let height = 40
        // 用绘制而不是手填缓冲：只需要关心“视觉上的上/中/下”，
        // 和预览渲染走的是同一条 CGContext 路径。
        let image = try XCTUnwrap(Self.makeImage(width: width, height: height) { context in
            let top = CGRect(x: 0, y: CGFloat(height) * 2 / 3, width: CGFloat(width), height: CGFloat(height) / 3)
            let middle = CGRect(x: 0, y: CGFloat(height) / 3, width: CGFloat(width), height: CGFloat(height) / 3)
            let bottom = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 3)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(top)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(middle)
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(bottom)
        })

        let lines = try XCTUnwrap(ImagePreview.render(image: image, columns: 40, rows: 10))
        XCTAssertEqual(lines.count, 10)

        // 第一行必须偏红、最后一行必须偏绿，再比较整张图的重心双重兜底。
        let (firstRed, firstBlue) = try XCTUnwrap(redBlueSums(lines[0]))
        XCTAssertGreaterThan(firstRed, firstBlue * 3, "第一行应偏红，实际 R=\(firstRed) B=\(firstBlue)")
        XCTAssertGreaterThan(try XCTUnwrap(greenSum(lines[9])), 2000, "最后一行应为绿色")

        var redCentroid = 0.0
        var greenCentroid = 0.0
        var redWeight = 0.0
        var greenWeight = 0.0
        for (row, line) in lines.enumerated() {
            let (red, blue) = try XCTUnwrap(redBlueSums(line))
            let green = try XCTUnwrap(greenSum(line))
            redCentroid += Double(row) * red
            greenCentroid += Double(row) * green
            redWeight += red
            greenWeight += green
            _ = blue
        }
        XCTAssertGreaterThan(redWeight, 0)
        XCTAssertGreaterThan(greenWeight, 0)
        redCentroid /= redWeight
        greenCentroid /= greenWeight
        XCTAssertLessThan(redCentroid, 3, "红色应集中在上半部，实际重心 \(redCentroid)")
        XCTAssertGreaterThan(greenCentroid, 6, "绿色应集中在下半部，实际重心 \(greenCentroid)")
    }

    func testImagePreviewFillsAvailableGrid() throws {
        let width = 60
        let image = try XCTUnwrap(Self.makeImage(width: width, height: width) { context in
            context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        })

        let lines = ImagePreview.render(image: image, columns: 60, rows: 30) ?? []
        XCTAssertEqual(lines.count, 30)
        for (index, line) in lines.enumerated() {
            XCTAssertFalse(line.contains("38;2;0;0;0"), "第 \(index) 行不应出现黑边")
        }
    }

    func testImagePreviewFillsGridAtWideAspectRatio() throws {
        // 网格 233 列 × 21 行 = 466×42 像素，图片保持同一宽高比才能铺满。
        let width = 466
        let height = 42
        let image = try XCTUnwrap(Self.makeImage(width: width, height: height) { context in
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: CGFloat(height) * 2 / 3, width: CGFloat(width), height: CGFloat(height) / 3))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 3))
        })

        let lines = try XCTUnwrap(ImagePreview.render(image: image, columns: 233, rows: 21))
        for (index, line) in lines.enumerated() {
            let (red, blue) = try XCTUnwrap(redBlueSums(line))
            let green = try XCTUnwrap(greenSum(line))
            XCTAssertGreaterThan(red + blue + green, 1000, "第 \(index) 行渲染为空")
        }
        let first = try XCTUnwrap(redBlueSums(lines[0]))
        XCTAssertGreaterThan(first.red, first.blue * 3, "顶部应偏红")
        XCTAssertGreaterThan(try XCTUnwrap(greenSum(lines[20])), 4000, "底部应为绿色块")
    }

    /// 创建一个全透明画布，先由调用方完成绘制再生成 CGImage。
    private static func makeImage(
        width: Int,
        height: Int,
        draw: (CGContext) -> Void
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let base = buffer.baseAddress, let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(context)
            return context.makeImage()
        }
    }

    /// 一行内所有字符格的上/下半像素 R、B 分量之和。
    private func redBlueSums(_ line: String) -> (red: Double, blue: Double)? {
        let pattern = #"38;2;(\d+);\d+;(\d+);48;2;(\d+);\d+;(\d+)m([▀]+)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex?.matches(in: line, range: range) ?? []
        guard !matches.isEmpty else { return nil }

        var red = 0.0
        var blue = 0.0
        for match in matches {
            let values = (1...4).map {
                Double((line as NSString).substring(with: match.range(at: $0))) ?? 0
            }
            let cells = Double((line as NSString).substring(with: match.range(at: 5)).count)
            red += (values[0] + values[2]) * cells
            blue += (values[1] + values[3]) * cells
        }
        return (red, blue)
    }

    /// 一行内所有字符格的上/下半像素 G 分量之和。
    private func greenSum(_ line: String) -> Double? {
        let pattern = #"38;2;\d+;(\d+);\d+;48;2;\d+;(\d+);\d+m([▀]+)"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regex?.matches(in: line, range: range) ?? []
        guard !matches.isEmpty else { return nil }

        var green = 0.0
        for match in matches {
            let cells = Double((line as NSString).substring(with: match.range(at: 3)).count)
            for group in [1, 2] {
                green += (Double((line as NSString).substring(with: match.range(at: group))) ?? 0) * cells
            }
        }
        return green
    }

    func testToneAnalyzerMarksFlatWhiteAsDead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).jpg")
        let image = try XCTUnwrap(Self.makeImage(width: 120, height: 120) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            context.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        })
        let tone = ToneAnalyzer.analyze(url: url, isRaw: false, image: image)
        XCTAssertTrue(tone.isDeadWhite, "大片纯白应判为死白")
        XCTAssertFalse(tone.isDeadBlack)
        XCTAssertGreaterThan(tone.whiteFraction, 0.5)
    }

    func testToneAnalyzerKeepsSliverWhite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).jpg")
        let image = try XCTUnwrap(Self.makeImage(width: 120, height: 120) { context in
            context.setFillColor(CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            // 2% 面积的高光（灯光、反光），不应该被判成死白。
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 110, width: 120, height: 3))
        })
        let tone = ToneAnalyzer.analyze(url: url, isRaw: false, image: image)
        XCTAssertFalse(tone.isDeadWhite)
        XCTAssertGreaterThan(tone.whiteFraction, 0)
    }

    func testDeadBlackAndWhiteAreExcludedFromPicking() {
        let record = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        XCTAssertFalse(record.isExcludedFromPicking)
        record.isDeadWhite = true
        XCTAssertTrue(record.isExcludedFromPicking)
        record.isDeadWhite = false
        record.isDeadBlack = true
        XCTAssertTrue(record.isExcludedFromPicking)
    }

    func testToneAnalyzerKeepsNightPhotoWithDetail() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).jpg")
        // 大片纯黑 + 有结构的亮部：夜景，不该判死黑。
        let image = try XCTUnwrap(Self.makeImage(width: 120, height: 120) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
            for index in 0..<60 {
                let level = CGFloat(index) / 59
                context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
                context.fill(CGRect(x: index * 2, y: 60, width: 2, height: 60))
            }
        })
        let tone = ToneAnalyzer.analyze(url: url, isRaw: false, image: image)
        XCTAssertGreaterThan(tone.blackFraction, 0.4)
        XCTAssertFalse(tone.isDeadBlack, "有细节的夜景不该判死黑")
    }

    func testToneAnalyzerFlagsFlatBlackBlob() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tone-\(UUID().uuidString).jpg")
        // 大半画面纯黑，剩下部分也是一片平坦 → 确实拍废了。
        let image = try XCTUnwrap(Self.makeImage(width: 120, height: 120) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 96))
            context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 96, width: 120, height: 24))
        })
        let tone = ToneAnalyzer.analyze(url: url, isRaw: false, image: image)
        XCTAssertTrue(tone.isDeadBlack)
    }

    func testRawJpegPairUsesRawOnly() {
        let raw = URL(fileURLWithPath: "/tmp/IMG_4498.CR3")
        let jpeg = URL(fileURLWithPath: "/tmp/IMG_4498.JPG")
        let raw2 = URL(fileURLWithPath: "/tmp/IMG_4502.NEF")
        let lone = URL(fileURLWithPath: "/tmp/DSC_0151.JPG")
        let split = RawPairing.split([raw, jpeg, raw2, lone])
        XCTAssertEqual(split.urls.map(\.lastPathComponent).sorted(), ["DSC_0151.JPG", "IMG_4498.CR3", "IMG_4502.NEF"])
        XCTAssertEqual(split.companions[raw.standardizedFileURL.path]?.map(\.lastPathComponent), ["IMG_4498.JPG"])
        XCTAssertEqual(split.companions[raw2.standardizedFileURL.path], [])
    }

    func testCompanionFollowsRawTargetName() {
        let raw = ImageRecord(url: URL(fileURLWithPath: "/tmp/IMG_4498.CR3"))
        let group = PhotoGroup(id: 3, records: [raw], winner: raw)
        let jpeg = ImageRecord(url: URL(fileURLWithPath: "/tmp/IMG_4498.JPG"))
        jpeg.companionOf = raw
        raw.groupID = 3
        jpeg.groupID = 3

        let plans = FileActions.plannedNames(for: [group], companions: [jpeg])
        XCTAssertEqual(plans.first { $0.0 === raw }?.1, "3-IMG_4498.CR3")
        XCTAssertEqual(jpeg.targetName, "3-IMG_4498.JPG")
    }

    func testMissingFileDoesNotAbortOtherRenames() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("picpicker-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let keep = folder.appendingPathComponent("IMG_0001.jpg")
        let gone = folder.appendingPathComponent("IMG_0002.jpg")
        for url in [keep, gone] {
            FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
        let first = ImageRecord(url: keep)
        let second = ImageRecord(url: gone)
        for record in [first, second] {
            record.aesthetics = 0.5
            record.exposure = 0.5
        }
        let group = PhotoGroup(id: 1, records: [first, second], winner: first)
        try FileManager.default.removeItem(at: gone)

        let report = try FileActions.apply(groups: [group], folder: folder, records: [first, second])

        XCTAssertEqual(report.renamedCount, 1, "另一张应照常改名")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("1-IMG_0001.jpg").path)
        )
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].contains("IMG_0002.jpg"))
    }

    func testLockedFileIsReportedAndOthersStillRename() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("picpicker-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let free = folder.appendingPathComponent("IMG_0001.jpg")
        let locked = folder.appendingPathComponent("IMG_0002.jpg")
        for url in [free, locked] {
            FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }

        let first = ImageRecord(url: free)
        let second = ImageRecord(url: locked)
        for record in [first, second] {
            record.aesthetics = 0.5
            record.exposure = 0.5
            record.isJPG = true
        }
        let group = PhotoGroup(id: 1, records: [first, second], winner: first)

        let report = try FileActions.apply(groups: [group], folder: folder, records: [first, second])

        XCTAssertEqual(report.renamedCount, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("1-IMG_0001.jpg").path)
        )
        XCTAssertTrue(report.failures.contains { $0.contains("锁定") && $0.contains("IMG_0002.jpg") })
    }

    // MARK: - 像素级重复复核

    private func grayImage(
        width: Int = 256,
        height: Int = 256,
        _ value: (Int, Int) -> Double
    ) -> CGImage {
        var buffer = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * width + x] = UInt8(min(255, max(0, value(x, y).rounded())))
            }
        }
        return buffer.withUnsafeMutableBytes { raw -> CGImage in
            let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func signature(_ image: CGImage) -> ThumbnailSignature {
        GrayImage(cgImage: image)!.thumbnailSignature()
    }

    /// 有细节、有结构的测试图案，避免平滑图让相关性失真。
    private func scenePattern(_ x: Int, _ y: Int) -> Double {
        let base = sin(Double(x) / 9) * cos(Double(y) / 11)
        let detail = sin(Double(x + y) / 3.5) * cos(Double(x - y) / 4.5)
        let blob = exp(-(pow(Double(x) - 90, 2) + pow(Double(y) - 160, 2)) / 2000)
        return 128 + base * 55 + detail * 25 + blob * 90
    }

    func testStructuralMatchAcceptsBrightnessAndCropVariants() {
        let base = signature(grayImage(scenePattern))
        let brighter = signature(grayImage { x, y in
            scenePattern(x, y) * 0.85 + 28
        })
        let cropped = signature(grayImage { x, y in
            scenePattern(
                Int((Double(x) - 127.5) * 1.06 + 127.5),
                Int((Double(y) - 127.5) * 1.06 + 127.5)
            )
        })

        for variant in [brighter, cropped] {
            let score = SimilarityIndex.compare(base, variant)
            let requirement = SimilarityIndex.structuralRequirement(threshold: 0.28)
            XCTAssertGreaterThan(score.luma, requirement, "亮度相关过低")
            XCTAssertGreaterThan(score.edge, requirement - 0.10, "梯度相关过低")
        }
    }

    func testStructuralMatchRejectsDifferentScenes() {
        let base = signature(grayImage(scenePattern))
        let other = signature(grayImage { x, y in
            120 + sin(Double(x) / 3.2) * sin(Double(y) / 4.7) * 80
        })

        let score = SimilarityIndex.compare(base, other)
        XCTAssertLessThan(score.luma, 0.90)
    }

    func testThresholdMapsToStructuralRequirement() {
        XCTAssertGreaterThan(
            SimilarityIndex.structuralRequirement(threshold: 0.10),
            SimilarityIndex.structuralRequirement(threshold: 0.28)
        )
        XCTAssertGreaterThan(
            SimilarityIndex.structuralRequirement(threshold: 0.28),
            SimilarityIndex.structuralRequirement(threshold: 0.60)
        )
        XCTAssertEqual(
            SimilarityIndex.structuralRequirement(threshold: 0.28),
            0.930,
            accuracy: 0.005
        )
    }

    // MARK: - 视觉模型复核

    func testVisionEndpointNormalization() {
        XCTAssertEqual(
            VisionAssist.normalizeEndpoint("127.0.0.1:8080")?.absoluteString,
            "http://127.0.0.1:8080/v1"
        )
        XCTAssertEqual(
            VisionAssist.normalizeEndpoint("http://127.0.0.1:8080/v1/")?.absoluteString,
            "http://127.0.0.1:8080/v1"
        )
        XCTAssertEqual(
            VisionAssist.normalizeEndpoint("http://localhost:1234")?.absoluteString,
            "http://localhost:1234/v1"
        )
        XCTAssertNil(VisionAssist.normalizeEndpoint("   "))
    }

    func testVisionAnswerParsing() {
        XCTAssertEqual(VisionAssist.parseYesNo("YES"), true)
        XCTAssertEqual(VisionAssist.parseYesNo("是，同一张"), true)
        XCTAssertEqual(VisionAssist.parseYesNo("NO，不同瞬间"), false)
        XCTAssertEqual(VisionAssist.parseYesNo("不是同一张"), false)
        XCTAssertNil(VisionAssist.parseYesNo("这两张照片里有人"))
    }

    func testGrayBandPairsOnlyAskForAmbiguousPairs() {
        let base = signature(grayImage(scenePattern))
        let other = signature(grayImage { x, y in
            120 + sin(Double(x) / 3.2) * sin(Double(y) / 4.7) * 80
        })
        let requirement = SimilarityIndex.structuralRequirement(threshold: 0.28)
        // 把另一张图按不同比例混进来，找一个刚好落进灰区的版本。
        let nearMiss = stride(from: 0.02, through: 0.6, by: 0.02)
            .lazy
            .map { self.blend(base, other, ratio: $0) }
            .first { SimilarityIndex.needsModel(SimilarityIndex.compare(base, $0), requirement: requirement) }
        let ambiguousSignature = try? XCTUnwrap(nearMiss)
        XCTAssertNotNil(ambiguousSignature, "应能构造出灰区样本")
        guard let ambiguousSignature else { return }
        let different = signature(grayImage { x, y in
            100 + cos(Double(x) / 7.3) * 90 + sin(Double(y) / 2.1) * 40
        })

        let similar = ImageRecord(url: URL(fileURLWithPath: "/tmp/a.jpg"))
        let ambiguous = ImageRecord(url: URL(fileURLWithPath: "/tmp/b.jpg"))
        let unrelated = ImageRecord(url: URL(fileURLWithPath: "/tmp/c.jpg"))
        similar.signature = base
        ambiguous.signature = ambiguousSignature
        unrelated.signature = different
        for record in [similar, ambiguous, unrelated] {
            record.dHash = 0
        }

        let index = SimilarityIndex(records: [similar, ambiguous, unrelated])
        let pending = index.grayBandPairs(threshold: 0.28)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending.contains { $0.lhs === similar && $0.rhs === ambiguous })
    }

    func testGrayBandCoversOnlyBorderlineScores() {
        let requirement = SimilarityIndex.structuralRequirement(threshold: 0.28)
        // 像素刚够、或者差一点没够，都要问模型。
        XCTAssertTrue(SimilarityIndex.needsModel(
            StructuralScore(luma: requirement + 0.02, edge: requirement),
            requirement: requirement
        ))
        XCTAssertTrue(SimilarityIndex.needsModel(
            StructuralScore(luma: requirement - 0.05, edge: requirement - 0.1),
            requirement: requirement
        ))
        // 像素很确信时不必问；差得太远也不必问。
        XCTAssertFalse(SimilarityIndex.needsModel(
            StructuralScore(luma: 0.99, edge: 0.97),
            requirement: requirement
        ))
        XCTAssertFalse(SimilarityIndex.needsModel(
            StructuralScore(luma: requirement - 0.3, edge: requirement - 0.3),
            requirement: requirement
        ))
    }

    private func blend(
        _ lhs: ThumbnailSignature,
        _ rhs: ThumbnailSignature,
        ratio: Double
    ) -> ThumbnailSignature {
        func mix(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
            zip(a, b).map { first, second in
                UInt8(clamping: Int((Double(first) * (1 - ratio) + Double(second) * ratio).rounded()))
            }
        }
        return ThumbnailSignature(
            luma: mix(lhs.luma, rhs.luma),
            edge: mix(lhs.edge, rhs.edge),
            coarse: mix(lhs.coarse, rhs.coarse)
        )
    }

    func testGroupingRequiresPixelLevelMatch() {
        let original = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3345.jpg"))
        let brighterCopy = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3346.jpg"))
        let different = ImageRecord(url: URL(fileURLWithPath: "/tmp/DSC3347.jpg"))
        original.signature = signature(grayImage(scenePattern))
        brighterCopy.signature = signature(grayImage { x, y in
            scenePattern(x, y) * 0.9 + 20
        })
        different.signature = signature(grayImage { x, y in
            120 + sin(Double(x) / 3.2) * sin(Double(y) / 4.7) * 80
        })
        // 没有 Vision 指纹时用 dHash 补候选，像素复核才是最终判据。
        for record in [original, brighterCopy, different] {
            record.dHash = 0
        }

        let grouped = SimilarityIndex(records: [original, brighterCopy, different])
            .groups(threshold: 0.28)

        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.records.count, 2)
        XCTAssertFalse(grouped.first?.records.contains { $0 === different } ?? true)
    }
}
