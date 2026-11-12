import AppKit
import Foundation

final class ProgressBar: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRendered = 0.0
    private var lastWidth = 0
    private var total: Int

    init(total: Int) {
        self.total = total
    }

    func update(completed: Int, name: String) {
        guard !Terminal.isPiped else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let fraction = total > 0 ? Double(completed) / Double(total) : 0
        lock.lock()
        let shouldRender = now - lastRendered > 0.08 || completed == total
        guard shouldRender else {
            lock.unlock()
            return
        }
        lastRendered = now
        lock.unlock()

        let width = max(20, min(80, Terminal.width - 46))
        let filled = Int(clamp(fraction) * Double(width))
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: max(0, width - filled))
        let percent = String(format: "%3d%%", Int(fraction * 100))
        let counter = total > 0 ? "\(completed)/\(total)" : ""
        let visibleName = DisplayWidth.truncate(name, to: max(8, Terminal.width - width - 30))

        let line = "\r\(Ansi.green)\(bar)\(Ansi.reset) \(percent) \(Ansi.dim)\(counter)\(Ansi.reset) \(visibleName)"
        lastWidth = DisplayWidth.string(line)
        Terminal.write(line + "\u{1B}[K")
    }

    func finish() {
        Terminal.write("\n")
    }
}

struct PreviewResult: Codable {
    let folder: String
    let threshold: Double
    let totalFound: Int
    let analyzed: Int
    let skipped: Int
    let manualExcluded: Int
    let isoFlagged: [PreviewExcluded]
    let blurry: [PreviewExcluded]
    let redFlagged: [PreviewFlagged]
    let yellowFlagged: [PreviewFlagged]
    let metrics: [PreviewMetric]
    let groups: [PreviewGroup]
    let skippedFiles: [String]
}

struct PreviewExcluded: Codable {
    let path: String
    let iso: Int?
    let focus: Double
}

struct PreviewFlagged: Codable {
    let path: String
    let reasons: [String]
}

struct PreviewMetric: Codable {
    let path: String
    let iso: Int?
    let captureDate: String?
    let sequenceNumber: Int?
    let isHighISO: Bool
    let isUtility: Bool
    let isDocument: Bool
    let isRedFlagged: Bool
    let redReasons: [String]
    let isYellowFlagged: Bool
    let yellowReasons: [String]
    let eyesClosedScore: Double?
    let horizonAngle: Double?
    let isBlurry: Bool
    let focus: Double
    let focusRaw: Double
    let lumaStd: Double
    let aesthetics: Double?
    let exposure: Double
}

struct PreviewGroup: Codable {
    let id: Int
    let winner: String
    let burst: Bool
    let files: [PreviewFile]
}

struct PreviewFile: Codable {
    let from: String
    let to: String
    let score: Double
    let aesthetics: Double?
    let sharpness: Double
    let exposure: Double
    let meanLuma: Double
    let clippedFraction: Double
    let distanceToBest: Double?
    let faceQuality: Double?
    let iso: Int?
    let isHighISO: Bool
    let isBlurry: Bool
    let focus: Double
    let winner: Bool
    let manualWinner: Bool
}

enum Renderer {
    static func analysisPreview(_ snapshot: AppModel.Snapshot) -> PreviewResult {
        let folder = snapshot.folder?.path ?? ""
        let skippedFiles = snapshot.records
            .filter { !$0.isAnalyzed }
            .map { "\($0.sortKey): \($0.error ?? "未知错误")" }

        let groups = snapshot.groups.map { group in
            PreviewGroup(
                id: group.id,
                winner: group.winner.plannedDisplayPath,
                burst: group.isBurst,
                files: group.sortedRecords.map { record in
                    PreviewFile(
                        from: record.sortKey,
                        to: record.plannedDisplayPath,
                        score: (record.score * 1000).rounded() / 1000,
                        aesthetics: record.aesthetics.map { ($0 * 1000).rounded() / 1000 },
                        sharpness: (record.sharpness * 1000).rounded() / 1000,
                        exposure: (record.exposure * 1000).rounded() / 1000,
                        meanLuma: (record.meanLuma * 1000).rounded() / 1000,
                        clippedFraction: (record.clippedFraction * 10000).rounded() / 10000,
                        distanceToBest: record.distanceToBest.map { ($0 * 1000).rounded() / 1000 },
                        faceQuality: record.faceQuality.map { ($0 * 1000).rounded() / 1000 },
                        iso: record.iso,
                        isHighISO: record.isHighISOJPG,
                        isBlurry: record.isBlurry,
                        focus: (record.sharpness * 1000).rounded() / 1000,
                        winner: record === group.winner,
                        manualWinner: record === group.winner && record.isUserWinner
                    )
                }
            )
        }

        let isoFlagged = snapshot.records
            .filter { $0.isHighISOJPG }
            .map { PreviewExcluded(path: $0.sortKey, iso: $0.iso, focus: $0.sharpness) }
        let blurry = snapshot.records
            .filter { $0.isBlurry }
            .map { PreviewExcluded(path: $0.sortKey, iso: $0.iso, focus: $0.sharpness) }
        let redFlagged = snapshot.records
            .filter { $0.isAnalyzed && $0.isExcludedFromPicking }
            .map { PreviewFlagged(path: $0.sortKey, reasons: $0.redReasons) }
        let yellowFlagged = snapshot.records
            .filter { $0.isAnalyzed && !$0.isExcludedFromPicking && $0.hasYellowFlag }
            .map { PreviewFlagged(path: $0.sortKey, reasons: $0.yellowReasons) }
        let metrics = snapshot.records
            .filter { $0.isAnalyzed }
            .map { record in
                PreviewMetric(
                    path: record.sortKey,
                    iso: record.iso,
                    captureDate: record.captureDate.map(Self.isoFormatter.string(from:)),
                    sequenceNumber: record.sequenceNumber,
                    isHighISO: record.isHighISOJPG,
                    isUtility: record.isUtility,
                    isDocument: record.isDocument,
                    isRedFlagged: record.isExcludedFromPicking,
                    redReasons: record.redReasons,
                    isYellowFlagged: record.hasYellowFlag,
                    yellowReasons: record.yellowReasons,
                    eyesClosedScore: record.eyesClosedScore.map { ($0 * 1000).rounded() / 1000 },
                    horizonAngle: record.horizonAngle,
                    isBlurry: record.isBlurry,
                    focus: (record.sharpness * 1000).rounded() / 1000,
                    focusRaw: (record.sharpnessRaw * 100).rounded() / 100,
                    lumaStd: (record.luminanceStd * 1000).rounded() / 1000,
                    aesthetics: record.aesthetics.map { ($0 * 1000).rounded() / 1000 },
                    exposure: (record.exposure * 1000).rounded() / 1000
                )
            }

        return PreviewResult(
            folder: folder,
            threshold: (snapshot.threshold * 100).rounded() / 100,
            totalFound: snapshot.summary.totalFound,
            analyzed: snapshot.summary.analyzed,
            skipped: snapshot.summary.skipped,
            manualExcluded: snapshot.records.filter(\.isUserExcluded).count,
            isoFlagged: isoFlagged,
            blurry: blurry,
            redFlagged: redFlagged,
            yellowFlagged: yellowFlagged,
            metrics: metrics,
            groups: groups,
            skippedFiles: skippedFiles
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func report(_ snapshot: AppModel.Snapshot, json: Bool) {
        if json {
            let result = analysisPreview(snapshot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            return
        }

        Terminal.write("\(Ansi.bold)PicPicker 选片结果\(Ansi.reset)\n")
        if let folder = snapshot.folder {
            Terminal.write("文件夹  \(folder.path)\n")
        }
        Terminal.write(
            "识别 \(snapshot.summary.analyzed)/\(snapshot.summary.totalFound) 张 · "
                + "\(snapshot.summary.groups) 组重复 · "
                + "阈值 \(String(format: "%.2f", snapshot.threshold))\n"
        )
        if snapshot.summary.isoFlagged > 0 || snapshot.summary.blurry > 0 {
            Terminal.write(
                "\(Ansi.yellow)预处理：ISO>\(Preprocess.isoLimit) 红标 \(snapshot.summary.isoFlagged) 张 · "
                    + "虚焦移出 \(snapshot.summary.blurry) 张 · "
                    + "参与选片 \(snapshot.summary.pickable) 张\(Ansi.reset)\n"
            )
        }
        if snapshot.summary.skipped > 0 {
            Terminal.write("\(Ansi.yellow)跳过 \(snapshot.summary.skipped) 张无法读取的文件\(Ansi.reset)\n")
        }

        if snapshot.groups.isEmpty {
            Terminal.write("\n未发现内容重复的照片。\n")
        }
        for group in snapshot.groups {
            let burst = group.isBurst ? " · 连拍" : ""
            Terminal.write(
                "\n\(Ansi.cyan)第 \(group.id) 组\(Ansi.reset)  "
                    + "\(group.records.count) 张\(burst)\n"
            )
            for record in group.sortedRecords {
                let isWinner = record === group.winner
                let prefix = isWinner ? "\(Ansi.green)●" : "○"
                let suffix = isWinner ? "  ← 最佳\(Ansi.reset)" : Ansi.reset
                let score = String(format: "%.3f", record.score)
                let exposure = String(format: "%.2f", record.exposure)
                let sharpness = String(format: "%.2f", record.sharpness)
                Terminal.write(
                    "  \(prefix) \(record.sortKey) → \(record.plannedDisplayPath)\(suffix)"
                        + "\(Ansi.dim)  评分 \(score) · 曝光 \(exposure) · 对焦 \(sharpness)\(Ansi.reset)\n"
                )
            }
        }

        if let report = snapshot.applyReport {
            Terminal.write("\n")
            if snapshot.isPreview {
                Terminal.write("\(Ansi.yellow)试运行：未修改任何文件。\(Ansi.reset)\n")
            } else if report.failures.isEmpty {
                var parts: [String] = []
                if report.redTaggedCount > 0 { parts.append("红标 \(report.redTaggedCount) 张（不参选）") }
                if report.yellowTaggedCount > 0 { parts.append("黄标 \(report.yellowTaggedCount) 张（仍参选）") }
                if report.movedToBlurryCount > 0 { parts.append("虚焦移出 \(report.movedToBlurryCount) 张") }
                if report.renamedCount > 0 { parts.append("重命名 \(report.renamedCount) 个文件") }
                if report.taggedCount > 0 { parts.append("绿色标签 \(report.taggedCount) 张") }
                Terminal.write("\(Ansi.green)完成：\(parts.joined(separator: "，"))。\(Ansi.reset)\n")
            }
            if !report.failures.isEmpty {
                Terminal.write("\(Ansi.red)问题：\(Ansi.reset)\n")
                for failure in report.failures {
                    Terminal.write("  - \(failure)\n")
                }
            }
            if let undoURL = report.undoURL {
                Terminal.write("\(Ansi.dim)撤销记录: \(undoURL.path)\(Ansi.reset)\n")
            }
        }
    }
}

enum TUI {
    static func runMain(model: AppModel, options: Options) -> Int32 {
        if !isInteractive {
            return runPiped(model: model)
        }

        let rawTerminal = RawTerminal()
        rawTerminal.enable()
        defer { rawTerminal.disable() }

        Terminal.enterAltScreen()
        defer { Terminal.leaveAltScreen() }

        if options.undo {
            let folder = options.folder ?? FolderChooser.choose(startingAt: defaultFolder())
            guard let folder else {
                return renderFailure("未选择文件夹。", interactive: true)
            }
            model.undoLast(folder: folder)
        } else if let folder = options.folder {
            model.start(folder: folder)
        } else {
            guard let folder = chooseFolderScreen() else {
                return 0
            }
            model.start(folder: folder)
        }

        var selectedGroup = 0
        var scrollOffset = 0
        var tick = 0
        var lastStage: Stage = .menu
        var lastDrawn = ""

        while true {
            tick += 1
            let snapshot = model.snapshot()
            if snapshot.stage != lastStage {
                selectedGroup = 0
                scrollOffset = 0
                lastStage = snapshot.stage
            }
            let frame = GroupListScreen.make(
                snapshot: snapshot,
                selected: selectedGroup,
                scroll: scrollOffset,
                tick: tick
            )
            if frame.text != lastDrawn {
                Terminal.home()
                Terminal.write(frame.text)
                lastDrawn = frame.text
            }

            let key: Key?
            switch snapshot.stage {
            case .analyzing, .scanning, .grouping, .applying:
                key = Key.read(timeoutMilliseconds: 100)
            default:
                key = Key.read()
            }

            guard let key else {
                continue
            }

            switch key {
            case .control("c"), .escape:
                switch snapshot.stage {
                case .reviewing:
                    if confirmExit() {
                        return 0
                    }
                case .finished, .failed:
                    return 0
                case .applying:
                    continue
                default:
                    return 0
                }
            case .up, .character("k"):
                if snapshot.stage == .reviewing || snapshot.stage == .finished {
                    selectedGroup = max(0, selectedGroup - 1)
                    if selectedGroup < scrollOffset { scrollOffset = selectedGroup }
                } else if snapshot.stage == .reviewing {
                    model.adjustThreshold(by: -0.02)
                }
            case .left, .character("h"):
                if snapshot.stage == .reviewing {
                    model.adjustThreshold(by: -0.02)
                }
            case .down, .character("j"):
                if snapshot.stage == .reviewing || snapshot.stage == .finished {
                    selectedGroup = min(max(0, snapshot.groups.count - 1), selectedGroup + 1)
                    let visible = max(4, Terminal.height - 14)
                    if selectedGroup >= scrollOffset + visible {
                        scrollOffset = selectedGroup - visible + 1
                    }
                }
            case .right, .character("l"):
                if snapshot.stage == .reviewing {
                    model.adjustThreshold(by: 0.02)
                }
            case .character("+"), .character("="):
                if snapshot.stage == .reviewing { model.adjustThreshold(by: 0.02) }
            case .character("-"), .character("_"):
                if snapshot.stage == .reviewing { model.adjustThreshold(by: -0.02) }
            case .enter:
                if snapshot.stage == .reviewing,
                   !snapshot.groups.isEmpty
                    || snapshot.summary.isoFlagged + snapshot.summary.blurry > 0 {
                    Terminal.write("\u{1B}[?25h")
                    let shouldApply = Input.confirm("确认重命名并给每组最佳照片打绿色标签？")
                    Terminal.write(Ansi.hideCursor)
                    if shouldApply {
                        model.beginApply(preview: false)
                        lastDrawn = ""
                    }
                } else if snapshot.stage == .finished {
                    return 0
                } else if case .failed = snapshot.stage {
                    return 1
                }
            case .character("r"):
                if snapshot.stage == .finished, let folder = snapshot.folder {
                    model.start(folder: folder)
                    lastDrawn = ""
                }
            case .character("u"):
                if snapshot.stage == .finished, let folder = snapshot.folder {
                    Terminal.write("\u{1B}[?25h")
                    let shouldUndo = Input.confirm("撤销刚才的重命名和标签？")
                    Terminal.write(Ansi.hideCursor)
                    if shouldUndo {
                        model.undoLast(folder: folder)
                        lastDrawn = ""
                    } else {
                        lastDrawn = ""
                    }
                }
            case .character("d"):
                if snapshot.stage == .reviewing,
                   !snapshot.groups.isEmpty
                    || snapshot.summary.isoFlagged + snapshot.summary.blurry > 0 {
                    model.beginApply(preview: true)
                    lastDrawn = ""
                }
            case .character("["), .character("]"):
                let forward = key == Key.character("]")
                if snapshot.stage == .reviewing,
                   snapshot.groups.indices.contains(selectedGroup) {
                    model.rotateWinner(
                        of: snapshot.groups[selectedGroup],
                        forward: forward
                    )
                    lastDrawn = ""
                }
            case .character("x"):
                if snapshot.stage == .reviewing,
                   snapshot.groups.indices.contains(selectedGroup) {
                    model.setExcluded(snapshot.groups[selectedGroup].winner, excluded: true)
                    selectedGroup = min(selectedGroup, max(0, snapshot.groups.count - 2))
                    lastDrawn = ""
                }
            case .character("s"):
                if snapshot.stage == .reviewing,
                   snapshot.groups.indices.contains(selectedGroup) {
                    model.skipGroup(snapshot.groups[selectedGroup])
                    selectedGroup = min(selectedGroup, max(0, snapshot.groups.count - 2))
                    lastDrawn = ""
                }
            case .character("R"):
                if snapshot.stage == .reviewing {
                    Terminal.write("\u{1B}[?25h")
                    let shouldReset = Input.confirm("清除所有手动改选和排除？")
                    Terminal.write(Ansi.hideCursor)
                    if shouldReset {
                        model.resetManualSelections()
                    }
                    lastDrawn = ""
                }
            case .character("f"):
                let target: URL?
                if snapshot.stage == .reviewing,
                   snapshot.groups.indices.contains(selectedGroup) {
                    target = snapshot.groups[selectedGroup].winner.url
                } else {
                    target = snapshot.folder
                }
                if let target {
                    Finder.reveal(target)
                }
            case .character("v"):
                if snapshot.stage == .reviewing,
                   snapshot.groups.indices.contains(selectedGroup) {
                    previewOverlay(model: model, group: snapshot.groups[selectedGroup])
                    lastDrawn = ""
                }
            case .character("o"):
                if snapshot.stage == .reviewing,
                   snapshot.groups.indices.contains(selectedGroup) {
                    NSWorkspace.shared.open(snapshot.groups[selectedGroup].winner.url)
                } else if snapshot.stage == .finished, let folder = snapshot.folder {
                    NSWorkspace.shared.open(folder)
                }
            case .character("c"):
                let text = copyableSummary(snapshot)
                Clipboard.copy(text)
                Terminal.write("\u{1B}[?25h\r\n  已复制到剪贴板，按任意键继续…")
                _ = Key.read()
                Terminal.write(Ansi.hideCursor)
                lastDrawn = ""
            case .character("q"):
                return snapshot.stage == .reviewing || snapshot.stage == .finished ? 0 : 130
            default:
                break
            }
        }
    }

    static func runPiped(model: AppModel) -> Int32 {
        var finalSnapshot: AppModel.Snapshot?

        while true {
            Thread.sleep(forTimeInterval: 0.1)
            let snapshot = model.snapshot()
            switch snapshot.stage {
            case .reviewing:
                if model.autoApply {
                    model.beginApply(preview: false)
                    continue
                }
                finalSnapshot = snapshot
            case .finished:
                finalSnapshot = snapshot
            case .failed:
                finalSnapshot = snapshot
            default:
                continue
            }
            break
        }

        guard let finalSnapshot else { return 1 }
        if case .failed(let message) = finalSnapshot.stage {
            FileHandle.standardError.write(Data("错误: \(message)\n".utf8))
            return 1
        }
        Renderer.report(finalSnapshot, json: model.jsonOutput)
        return finalSnapshot.stage == .finished ? 0 : 0
    }

    static func chooseFolderScreen() -> URL? {
        let shortcut = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop")
        let pictures = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Pictures")
        var choices: [Choice] = [
            Choice(title: "选择文件夹…", detail: "打开 macOS 文件夹选择框", value: "pick")
        ]
        if FileManager.default.fileExists(atPath: shortcut.path) {
            choices.append(Choice(title: "桌面", detail: shortcut.path, value: shortcut.path))
        }
        if FileManager.default.fileExists(atPath: pictures.path) {
            choices.append(Choice(title: "照片", detail: pictures.path, value: pictures.path))
        }

        let folder: URL?
        if let path = Input.choose("PicPicker · 选择要整理的照片文件夹", choices: choices, selected: 0) {
            if path == "pick" {
                folder = FolderChooser.choose(startingAt: pictures)
            } else {
                folder = URL(fileURLWithPath: path)
            }
        } else {
            return nil
        }

        if let folder, folderHasManifest(folder) {
            Terminal.write("该文件夹包含上一次的撤销记录（.picpicker-undo.json）。\n")
        }
        return folder
    }

    static func confirmExit() -> Bool {
        Input.confirm("识别结果尚未执行，确定退出？", defaultYes: false)
    }

    /// 全屏查看当前组每张照片的终端真彩色预览，翻页不会改变任何选片结果。
    static func previewOverlay(model: AppModel, group: PhotoGroup) {
        let records = group.sortedRecords
        guard !records.isEmpty else { return }

        var cursor = records.firstIndex { $0 === group.winner } ?? 0
        var rendered: [String?] = []
        let width = Terminal.width
        let height = Terminal.height

        defer {
            Terminal.clear()
            Terminal.write(Ansi.hideCursor)
        }

        func lines(for index: Int) -> [String] {
            if rendered.count != records.count {
                rendered = Array(repeating: nil, count: records.count)
            }
            if let cached = rendered[index] {
                return cached.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            }

            // 字符格约 2:1 高宽比，用满宽和剩余行数就是最大的物理像素面积。
            let rows = max(5, height - 9)
            let columns = max(20, min(width - 4, rows * 2))
            let picture = ImagePreview.render(url: records[index].url, columns: columns, rows: rows)
            guard let picture else {
                return fallbackLines(for: records[index])
            }
            rendered[index] = picture.joined(separator: "\n")
            return picture
        }

        while true {
            let record = records[cursor]
            var body: [String] = []
            body.append(
                "  \(Ansi.bold)\(record.plannedDisplayPath)\(Ansi.reset)"
                    + (record === group.winner ? "  \(Ansi.green)● 最佳\(Ansi.reset)" : "")
            )
            body.append("  \(scoreLine(record))")
            for line in lines(for: cursor) {
                body.append("  " + line)
            }
            let frame = Layout.frame(
                title: "PicPicker · 第 \(group.id) 组",
                subtitle: "\(cursor + 1)/\(records.count)",
                body: body,
                footer: "\(Ansi.bold)[ ]←→\(Ansi.reset) 上一张/下一张  \(Ansi.bold)x\(Ansi.reset) 排除这张  "
                    + "\(Ansi.bold)Enter\(Ansi.reset) 指定为最佳  \(Ansi.bold)v/Esc\(Ansi.reset) 返回",
                width: width
            )
            Terminal.home()
            Terminal.write(frame)

            guard let key = Key.read() else { return }
            switch key {
            case .escape, .character("v"), .character("q"), .control("c"):
                return
            case .left, .character("["), .up, .character("k"):
                cursor = max(0, cursor - 1)
            case .right, .character("]"), .down, .character("j"):
                cursor = min(records.count - 1, cursor + 1)
            case .enter:
                model.setWinner(record)
                return
            case .character("x"):
                model.setExcluded(record, excluded: true)
                return
            default:
                break
            }
        }
    }

    private static func scoreLine(_ record: ImageRecord) -> String {
        var parts = ["评分 \(String(format: "%.3f", record.score))"]
        if let aesthetics = record.aesthetics {
            parts.append("美学 \(String(format: "%.2f", aesthetics))")
        }
        if let face = record.faceQuality {
            parts.append("人像 \(record.faceCount)人/\(String(format: "%.2f", face))")
        }
        if let angle = record.horizonAngle {
            parts.append("地平 \(String(format: "%.0f°", angle))")
        }
        if record.hasYellowFlag {
            parts.append("黄标 \(record.yellowReasonText)")
        }
        return parts.joined(separator: " · ")
    }

    private static func fallbackLines(for record: ImageRecord) -> [String] {
        var lines = ["", "\(Ansi.gray)无法在终端中渲染该图片，按 o 用默认看图程序打开。\(Ansi.reset)"]
        if let error = record.error {
            lines.append("\(Ansi.red)\(error)\(Ansi.reset)")
        }
        return lines
    }

    static func folderHasManifest(_ folder: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent(FileActions.manifestName).path
        )
    }

    static func copyableSummary(_ snapshot: AppModel.Snapshot) -> String {
        var lines: [String] = []
        if let folder = snapshot.folder {
            lines.append(folder.path)
        }
        for group in snapshot.groups {
            lines.append("[\(group.id)]")
            for record in group.sortedRecords {
                lines.append(
                    "\(record.sortKey)\t\(record.plannedDisplayPath)\t"
                        + "\(record === group.winner ? "BEST" : "")"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    static func defaultFolder() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        for candidate in ["Desktop", "Pictures", "Downloads"] {
            let url = home.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return home
    }

    static func renderFailure(_ message: String, interactive: Bool) -> Int32 {
        if interactive {
            Terminal.write("\(Ansi.red)\(message)\(Ansi.reset)\n")
        } else {
            FileHandle.standardError.write(Data("错误: \(message)\n".utf8))
        }
        return 1
    }
}

struct Screen {
    let text: String
}

enum Layout {
    static func frame(title: String, subtitle: String, body: [String], footer: String, width: Int) -> String {
        var lines: [String] = []
        lines.append("")
        let headerWidth = max(0, width - 4)
        let titleWidth = DisplayWidth.string(title) + DisplayWidth.string(subtitle)

        var header = "  \(Ansi.bold)\(title)\(Ansi.reset)"
        if !subtitle.isEmpty {
            let padding = max(2, headerWidth - titleWidth)
            header += "\(Ansi.dim)\(String(repeating: " ", count: padding))\(subtitle)\(Ansi.reset)"
        }
        lines.append(header)
        lines.append("  \(Ansi.gray)\(String(repeating: "─", count: headerWidth))\(Ansi.reset)")
        lines.append("")
        lines.append(contentsOf: body)
        lines.append("")
        if !footer.isEmpty {
            lines.append("  \(Ansi.gray)\(String(repeating: "─", count: headerWidth))\(Ansi.reset)")
            lines.append("  \(footer)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func bar(value: Double, width: Int) -> String {
        let filled = Int(clamp(value) * Double(width))
        return "\(Ansi.green)\(String(repeating: "█", count: filled))"
            + "\(Ansi.gray)\(String(repeating: "░", count: max(0, width - filled)))\(Ansi.reset)"
    }
}

enum GroupListScreen {
    static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    static func make(snapshot: AppModel.Snapshot, selected: Int, scroll: Int, tick: Int) -> Screen {
        let width = Terminal.width
        let height = Terminal.height
        let spinner = spinnerFrames[tick % spinnerFrames.count]
        switch snapshot.stage {
        case .menu:
            return Screen(text: Layout.frame(title: "PicPicker", subtitle: "准备中", body: [], footer: "", width: width))
        case .scanning:
            let body = [
                "  \(Ansi.cyan)\(spinner)\(Ansi.reset) 正在读取 \(snapshot.folder?.lastPathComponent ?? "文件夹")…",
                "",
                "  扫描支持的图片格式（JPEG / HEIC / PNG / TIFF / RAW）"
            ]
            return Screen(text: Layout.frame(
                title: "PicPicker · 识别",
                subtitle: "扫描中",
                body: body,
                footer: "\(Ansi.gray)Ctrl-C 取消\(Ansi.reset)",
                width: width
            ))
        case .analyzing:
            let fraction = snapshot.total > 0 ? Double(snapshot.completed) / Double(snapshot.total) : 0
            let barWidth = max(20, min(72, width - 14))
            var body: [String] = []
            body.append(
                "  \(Layout.bar(value: fraction, width: barWidth)) "
                    + "\(String(format: "%3d%%", Int(fraction * 100))) "
                    + "\(Ansi.dim)\(snapshot.completed)/\(snapshot.total)\(Ansi.reset)"
            )
            body.append("")
            body.append("  \(Ansi.gray)正在分析  \(DisplayWidth.truncate(snapshot.currentName, to: max(10, width - 42)))\(Ansi.reset)")
            let elapsed = snapshot.startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let rate = elapsed > 0.1 ? Double(snapshot.completed) / elapsed : 0
            let remaining = rate > 0 ? Double(max(0, snapshot.total - snapshot.completed)) / rate : 0
            body.append("")
            body.append(
                "  \(Ansi.dim)每秒 \(String(format: "%.1f", rate)) 张 · 剩余约 "
                    + "\(formatDuration(remaining)) · 已用 \(formatDuration(elapsed))\(Ansi.reset)"
            )
            body.append("")
            body.append("  \(Ansi.gray)使用 macOS Vision：图像指纹 · 美学评分 · 人脸质量 · 显著性\(Ansi.reset)")
            body.append("  \(Ansi.gray)对焦与曝光：基于 2048px 灰度缩略图计算\(Ansi.reset)")
            let folder = snapshot.folder?.path ?? ""
            body.append("  \(Ansi.dim)\(DisplayWidth.truncate(folder, to: max(10, width - 6)))\(Ansi.reset)")
            return Screen(text: Layout.frame(
                title: "PicPicker · 识别",
                subtitle: "分析中",
                body: body,
                footer: "\(Ansi.gray)识别完成后可调整分组阈值，再确认执行 · Ctrl-C 取消\(Ansi.reset)",
                width: width
            ))
        case .grouping:
            return Screen(text: Layout.frame(
                title: "PicPicker · 识别",
                subtitle: "分组中",
                body: [
                    "  已完成 \(snapshot.summary.analyzed) 张图片分析。",
                    "",
                    "  \(Ansi.cyan)\(spinner)\(Ansi.reset) 正在计算相似度…"
                ],
                footer: "",
                width: width
            ))
        case .reviewing, .finished, .applying, .failed:
            return resultsScreen(snapshot: snapshot, selected: selected, scroll: scroll, width: width, height: height)
        }
    }

    static func resultsScreen(
        snapshot: AppModel.Snapshot,
        selected rawSelection: Int,
        scroll: Int,
        width: Int,
        height: Int
    ) -> Screen {
        let selected = snapshot.groups.isEmpty ? 0 : min(rawSelection, snapshot.groups.count - 1)
        var body: [String] = []
        let summary = snapshot.summary
        let elapsed = snapshot.startedAt.map {
            (snapshot.endedAt ?? Date()).timeIntervalSince($0)
        } ?? 0
        body.append(
            "  \(Ansi.bold)\(summary.analyzed)\(Ansi.reset) 张已识别   "
                + "\(Ansi.bold)\(summary.groups)\(Ansi.reset) 组重复   "
                + "\(summary.groupedPhotos) 张待整理   "
                + "\(Ansi.gray)\(formatDuration(elapsed))\(Ansi.reset)"
        )
        if summary.skipped > 0 {
            body.append("  \(Ansi.yellow)\(summary.skipped) 张无法读取，已跳过\(Ansi.reset)")
        }
        if summary.isoFlagged > 0 || summary.blurry > 0 {
            body.append(
                "  \(Ansi.yellow)预处理\(Ansi.reset) "
                    + "ISO>\(Preprocess.isoLimit) 红标 \(summary.isoFlagged) 张 · "
                    + "虚焦移出 \(summary.blurry) 张 · "
                    + "\(Ansi.green)参与选片 \(summary.pickable) 张\(Ansi.reset)"
            )
        }
        if summary.redFlagged > 0 || summary.yellowFlagged > 0 {
            body.append(
                "  \(Ansi.red)红标 \(summary.redFlagged) 张不参选\(Ansi.reset) · "
                    + "\(Ansi.yellow)黄标 \(summary.yellowFlagged) 张仍参选（闭眼/断头）\(Ansi.reset)"
            )
        }
        let manualExcluded = snapshot.records.filter(\.isUserExcluded).count
        let manualPinned = snapshot.groups.filter { $0.winner.isUserWinner }.count
        if manualExcluded > 0 || manualPinned > 0 {
            var parts: [String] = []
            if manualPinned > 0 { parts.append("\(manualPinned) 组手动指定最佳") }
            if manualExcluded > 0 { parts.append("\(manualExcluded) 张手动排除") }
            body.append(
                "  \(Ansi.cyan)手动调整\(Ansi.reset) \(parts.joined(separator: " · "))"
                    + "\(Ansi.gray)（R 重置）\(Ansi.reset)"
            )
        }
        if snapshot.stage == .reviewing {
            body.append(
                "  \(Ansi.gray)相似阈值\(Ansi.reset) \(String(format: "%.2f", snapshot.threshold)) "
                    + "\(Ansi.gray)（+ / - 调整，范围 0.10–0.60）\(Ansi.reset)"
            )
        }
        body.append("")

        let reserved = 12
        let visible = max(4, height - reserved)
        if snapshot.groups.isEmpty {
            body.append("  \(Ansi.green)✓ 未发现内容重复的照片，无需重命名。\(Ansi.reset)")
        } else if let group = snapshot.groups.indices.contains(selected) ? snapshot.groups[selected] : nil {
            body.append(groupDetail(group, width: width, available: visible))
        }

        var footer = ""
        switch snapshot.stage {
        case .reviewing:
            footer = "\(Ansi.bold)↑↓\(Ansi.reset) 切换组  \(Ansi.bold)←→ / +-\(Ansi.reset) 阈值  "
                + "\(Ansi.bold)[ ]\(Ansi.reset) 改最佳  \(Ansi.bold)x\(Ansi.reset) 排除  \(Ansi.bold)s\(Ansi.reset) 跳过组  "
                + "\(Ansi.bold)v\(Ansi.reset) 大图  \(Ansi.bold)f\(Ansi.reset) Finder  \(Ansi.bold)o\(Ansi.reset) 打开  "
                + "\(Ansi.bold)Enter\(Ansi.reset) 执行  \(Ansi.bold)d\(Ansi.reset) 试运行  \(Ansi.bold)Esc\(Ansi.reset) 退出"
        case .applying:
            footer = "\(Ansi.green)\(snapshot.progressNote)\(Ansi.reset)"
        case .finished:
            footer = finishedFooter(snapshot)
        case .failed:
            footer = "\(Ansi.red)按 Enter 退出\(Ansi.reset)"
        default:
            footer = ""
        }

        var text = Layout.frame(
            title: "PicPicker · 选片结果",
            subtitle: snapshot.folder?.lastPathComponent ?? "",
            body: body,
            footer: footer,
            width: width
        )

        if case .failed(let message) = snapshot.stage {
            text += "\n  \(Ansi.red)\(message)\(Ansi.reset)\n"
        }
        if let undoReport = snapshot.undoReport {
            text += "\n  \(Ansi.green)已撤销 \(undoReport.restored.count) 个文件名。\(Ansi.reset)\n"
            for failure in undoReport.failures {
                text += "  \(Ansi.yellow)\(failure)\(Ansi.reset)\n"
            }
        }
        return Screen(text: text)
    }

    static func groupDetail(_ group: PhotoGroup, width: Int, available: Int) -> String {
        var lines: [String] = []
        let best = group.winner
        lines.append(
            "  \(Ansi.cyan)\(Ansi.bold)第 \(group.id) 组\(Ansi.reset)"
                + "\(Ansi.gray) · \(group.records.count) 张重复"
                + (group.isBurst ? " · \(Ansi.yellow)连拍\(Ansi.gray)" : "")
                + " · 最佳 \(best.plannedDisplayPath)\(Ansi.reset)"
                + (best.isUserWinner ? "\(Ansi.cyan) (手动)\(Ansi.reset)" : "")
        )
        lines.append("")

        let nameWidth = max(18, min(64, width - 62))
        let maxSharpness = group.records.map(\.sharpnessRaw).max() ?? 0
        for record in group.sortedRecords {
            let isWinner = record === group.winner
            let relativeSharpness = maxSharpness > 0
                ? clamp(sqrt(record.sharpnessRaw / maxSharpness))
                : 0.5
            let marker = isWinner ? "\(Ansi.green)●\(Ansi.reset)" : "\(Ansi.gray)○\(Ansi.reset)"
            let name = DisplayWidth.pad(
                DisplayWidth.truncate(record.plannedDisplayPath, to: nameWidth),
                to: nameWidth
            )
            let nameColor = isWinner ? "\(Ansi.bold)\(Ansi.green)\(name)\(Ansi.reset)" : name
            let displayName = nameColor
            lines.append(
                "  \(marker) \(displayName)  \(scoreText(record.score))  "
                    + "\(barText("曝光", record.exposure)) \(barText("对焦", relativeSharpness))"
            )
            let detail = metricDetail(record)
            lines.append("      \(Ansi.gray)\(detail)\(Ansi.reset)")
            if isWinner {
                lines.append("      \(Ansi.green)✓ 将打上 Finder 绿色标签\(Ansi.reset)")
            }
            lines.append("")
        }

        if lines.count > available {
            return lines.prefix(max(1, available - 1)).joined(separator: "\n")
                + "\n  \(Ansi.gray)…\(Ansi.reset)"
        }
        return lines.joined(separator: "\n")
    }

    static func scoreText(_ score: Double) -> String {
        let color = score >= 0.70 ? Ansi.green : (score >= 0.55 ? Ansi.yellow : Ansi.red)
        return "\(color)\(String(format: "%.3f", score))\(Ansi.reset)"
    }

    static func barText(_ label: String, _ value: Double) -> String {
        let filled = Int(clamp(value) * 5)
        let bar = String(repeating: "▰", count: filled) + String(repeating: "▱", count: 5 - filled)
        return "\(Ansi.gray)\(label)\(Ansi.reset) \(bar)"
    }

    static func metricDetail(_ record: ImageRecord) -> String {
        var parts: [String] = []
        if let aesthetics = record.aesthetics {
            parts.append("美学 \(String(format: "%.2f", aesthetics))")
        }
        if let face = record.faceQuality {
            parts.append("人像 \(record.faceCount)人/\(String(format: "%.2f", face))")
        }
        if let distance = record.distanceToBest, distance > 0 {
            parts.append("与最佳距离 \(String(format: "%.3f", distance))")
        }
        if record.hasYellowFlag {
            parts.append("\(Ansi.yellow)黄标 \(record.yellowReasonText)\(Ansi.reset)")
        }
        if record.isDocument {
            parts.append("文档/截图")
        }
        if let angle = record.horizonAngle {
            parts.append("地平 \(String(format: "%.0f°", angle))")
        }
        parts.append("亮度 \(String(format: "%.2f", record.meanLuma))")
        parts.append("过曝高光 \(String(format: "%.1f%%", record.clippedFraction * 100))")
        if record.isUtility {
            parts.append("\(Ansi.yellow)文档/截屏类\(Ansi.reset)")
        }
        if let error = record.error {
            parts.append("\(Ansi.red)\(error)\(Ansi.reset)")
        }
        return parts.joined(separator: " · ")
    }

    static func finishedFooter(_ snapshot: AppModel.Snapshot) -> String {
        guard let report = snapshot.applyReport else {
            return "\(Ansi.green)没有需要处理的照片。\(Ansi.reset)  \(Ansi.bold)Enter\(Ansi.reset) 退出"
        }
        if snapshot.isPreview {
            var plan: [String] = []
            if report.redTaggedCount > 0 { plan.append("红标 \(report.redTaggedCount) 张") }
            if report.yellowTaggedCount > 0 { plan.append("黄标 \(report.yellowTaggedCount) 张") }
            if report.movedToBlurryCount > 0 { plan.append("移入虚焦 \(report.movedToBlurryCount) 张") }
            if report.renamedCount > 0 { plan.append("重命名 \(report.renamedCount) 个") }
            if report.taggedCount > 0 { plan.append("绿色标签 \(report.taggedCount) 张") }
            let detail = plan.isEmpty ? "没有需要处理的照片" : plan.joined(separator: " · ")
            return "\(Ansi.yellow)试运行：未修改文件。\(Ansi.reset) 计划 \(detail)  "
                + "\(Ansi.bold)r\(Ansi.reset) 重新扫描  \(Ansi.bold)Enter\(Ansi.reset) 退出"
        }
        var parts: [String] = []
        if report.redTaggedCount > 0 { parts.append("红标 \(report.redTaggedCount) 张（不参选）") }
        if report.yellowTaggedCount > 0 { parts.append("黄标 \(report.yellowTaggedCount) 张（仍参选）") }
        if report.movedToBlurryCount > 0 { parts.append("虚焦移出 \(report.movedToBlurryCount) 张") }
        if report.renamedCount > 0 { parts.append("重命名 \(report.renamedCount) 个文件") }
        if report.taggedCount > 0 { parts.append("绿色标签 \(report.taggedCount) 张") }
        var text = "\(Ansi.green)✓ \(parts.joined(separator: "，"))\(Ansi.reset)"
        if !report.failures.isEmpty {
            text += "\n  \(Ansi.red)\(report.failures.count) 个问题（见下方）\(Ansi.reset)"
        }
        text += "\n  \(Ansi.bold)u\(Ansi.reset) 撤销  \(Ansi.bold)o\(Ansi.reset) 打开文件夹  "
            + "\(Ansi.bold)r\(Ansi.reset) 重新扫描  \(Ansi.bold)Enter\(Ansi.reset) 退出"
        return text
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--" }
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) 秒" }
    let minutes = total / 60
    let remaining = total % 60
    if minutes < 60 { return "\(minutes) 分 \(remaining) 秒" }
    return "\(minutes / 60) 时 \(minutes % 60) 分"
}

