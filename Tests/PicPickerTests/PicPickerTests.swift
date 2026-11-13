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
}
