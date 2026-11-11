import Foundation

final class AppModel: @unchecked Sendable {
    struct Snapshot {
        var stage: Stage
        var folder: URL?
        var threshold: Double
        var total: Int
        var completed: Int
        var currentName: String
        var startedAt: Date?
        var endedAt: Date?
        var records: [ImageRecord]
        var groups: [PhotoGroup]
        var summary: AnalysisSummary
        var applyReport: ApplyReport?
        var undoReport: UndoReport?
        var errorMessage: String?
        var progressNote: String
        var isPreview: Bool
    }

    private let lock = NSLock()
    private var stage: Stage = .menu
    private var folder: URL?
    private var threshold: Double
    private var total = 0
    private var completed = 0
    private var currentName = ""
    private var startedAt: Date?
    private var endedAt: Date?
    private var records: [ImageRecord] = []
    private var groups: [PhotoGroup] = []
    private var summary = AnalysisSummary()
    private var applyReport: ApplyReport?
    private var undoReport: UndoReport?
    private var errorMessage: String?
    private var progressNote = ""
    private var similarityIndex: SimilarityIndex?
    private var recomputeGeneration = 0
    var autoApply: Bool
    var jsonOutput: Bool
    var dryRun: Bool
    private var isPreview = false

    init(threshold: Double, autoApply: Bool, jsonOutput: Bool = false, dryRun: Bool = false) {
        self.threshold = threshold
        self.autoApply = autoApply
        self.jsonOutput = jsonOutput
        self.dryRun = dryRun
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            stage: stage,
            folder: folder,
            threshold: threshold,
            total: total,
            completed: completed,
            currentName: currentName,
            startedAt: startedAt,
            endedAt: endedAt,
            records: records,
            groups: groups,
            summary: summary,
            applyReport: applyReport,
            undoReport: undoReport,
            errorMessage: errorMessage,
            progressNote: progressNote,
            isPreview: isPreview
        )
    }

    func setFolder(_ url: URL) {
        lock.lock()
        folder = url
        stage = .scanning
        total = 0
        completed = 0
        currentName = ""
        progressNote = "正在扫描文件夹…"
        records = []
        groups = []
        summary = AnalysisSummary()
        similarityIndex = nil
        applyReport = nil
        undoReport = nil
        errorMessage = nil
        startedAt = Date()
        endedAt = nil
        lock.unlock()
    }

    func start(folder: URL) {
        setFolder(folder)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let urls = try ImageScanner.scan(folder: folder)
                self.mutate {
                    self.total = urls.count
                    self.progressNote = "共 \(urls.count) 张图片"
                    self.stage = urls.isEmpty ? .reviewing : .analyzing
                    if urls.isEmpty {
                        self.endedAt = Date()
                    }
                }
                guard !urls.isEmpty else { return }

                let analyzed = await ImageAnalyzer.analyzeAll(urls: urls) { completed, name in
                    self.mutate {
                        self.completed = completed
                        self.currentName = name
                        self.progressNote = "提取指纹 · 美学评分 · EXIF/ISO · 对焦/曝光"
                    }
                }

                self.mutate {
                    self.stage = .grouping
                    self.progressNote = "正在计算相似度并分组…"
                    self.currentName = ""
                }

                for record in analyzed {
                    record.relativeDirectory = relativeDirectory(of: record.url, in: folder)
                    if let sequence = parseFilenameSequence(record.originalName) {
                        record.sequenceNumber = sequence.number
                        record.sequenceKey = "\(record.relativeDirectory)|\(sequence.prefix)"
                    }
                }
                let ordered = analyzed.sorted { naturalCompare($0.sortKey, $1.sortKey) }

                let candidates = ordered.filter { $0.isAnalyzed && !$0.isExcludedFromPicking }
                let judgeable = candidates.filter { record in
                    guard record.luminanceStd >= Preprocess.blurMinimumDetail,
                          record.sharpnessRaw >= Preprocess.blurMinimumRaw else {
                        return false
                    }
                    if record.faceCount > 0, (record.faceQuality ?? 0) > 0.5 {
                        return false
                    }
                    return true
                }
                let focusMedian = median(judgeable.map(\.sharpnessRaw))
                let cutoff = min(focusMedian * Preprocess.blurRelativeCutoff, Preprocess.blurRawCap)
                let judgeableIDs = Set(judgeable.map(ObjectIdentifier.init))
                for record in candidates {
                    record.isBlurry = judgeableIDs.contains(ObjectIdentifier(record))
                        && record.sharpnessRaw < cutoff
                }

                let pickable = candidates.filter { !$0.isBlurry }
                let index = SimilarityIndex(records: pickable)
                let grouped = index.groups(threshold: self.currentThreshold)
                _ = FileActions.plannedNames(for: grouped)

                let analyzedCount = ordered.filter { $0.isAnalyzed }.count
                let isoFlagged = ordered.filter { $0.isHighISOJPG }.count
                let blurry = ordered.filter { $0.isBlurry }.count
                var nextSummary = AnalysisSummary()
                nextSummary.totalFound = urls.count
                nextSummary.analyzed = analyzedCount
                nextSummary.skipped = analyzed.count - analyzedCount
                nextSummary.isoFlagged = isoFlagged
                nextSummary.redFlagged = ordered.filter { $0.isExcludedFromPicking }.count
                nextSummary.yellowFlagged = ordered.filter {
                    $0.isAnalyzed && !$0.isExcludedFromPicking && $0.hasYellowFlag
                }.count
                nextSummary.blurry = blurry
                nextSummary.pickable = pickable.count
                nextSummary.groups = grouped.count
                nextSummary.groupedPhotos = grouped.reduce(0) { $0 + $1.records.count }

                self.mutate {
                    self.records = ordered
                    self.similarityIndex = index
                    self.groups = grouped
                    self.summary = nextSummary
                    self.stage = .reviewing
                    self.endedAt = Date()
                    self.progressNote = ""
                }

                if self.autoApply {
                    self.beginApply(preview: false)
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func adjustThreshold(by delta: Double) {
        lock.lock()
        let next = min(0.60, max(0.10, threshold + delta))
        guard abs(next - threshold) > 0.0001 else {
            lock.unlock()
            return
        }
        threshold = next
        recomputeGeneration += 1
        let generation = recomputeGeneration
        let index = similarityIndex
        let nextThreshold = next
        lock.unlock()

        guard let index else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let grouped = index.groups(threshold: nextThreshold)
            _ = FileActions.plannedNames(for: grouped)
            self.mutate {
                guard self.recomputeGeneration == generation else { return }
                self.groups = grouped
                self.summary.groups = grouped.count
                self.summary.groupedPhotos = grouped.reduce(0) { $0 + $1.records.count }
            }
        }
    }

    func beginApply(preview: Bool) {
        lock.lock()
        guard stage == .reviewing else {
            lock.unlock()
            return
        }
        let flaggedCount = records.filter {
            $0.isExcludedFromPicking || $0.isBlurry || $0.hasYellowFlag
        }.count
        guard !groups.isEmpty || flaggedCount > 0 else {
            stage = .finished
            endedAt = Date()
            isPreview = false
            applyReport = nil
            lock.unlock()
            return
        }
        let folder = self.folder
        let groups = self.groups
        let records = self.records
        stage = .applying
        let usePreview = preview || dryRun
        isPreview = usePreview
        progressNote = usePreview ? "正在生成试运行计划…" : "正在重命名并写入 Finder 标签…"
        lock.unlock()

        guard let folder else { return }
        if usePreview {
            let report = FileActions.preview(groups: groups, records: records)
            mutate {
                self.applyReport = report
                self.stage = .finished
                self.endedAt = Date()
                self.progressNote = ""
            }
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let report = try FileActions.apply(
                    groups: groups,
                    folder: folder,
                    records: records
                )
                self.mutate {
                    self.applyReport = report
                    self.stage = .finished
                    self.endedAt = Date()
                    self.progressNote = ""
                }
            } catch {
                self.fail("执行失败: \(error.localizedDescription)")
            }
        }
    }

    func undoLast(folder: URL) {
        mutate {
            self.stage = .applying
            self.folder = folder
            self.progressNote = "正在撤销上一次重命名…"
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let report = try FileActions.undo(folder: folder)
                self.mutate {
                    self.undoReport = report
                    self.stage = .finished
                    self.endedAt = Date()
                    self.progressNote = ""
                }
            } catch {
                self.fail("撤销失败: \(error.localizedDescription)")
            }
        }
    }

    func fail(_ message: String) {
        mutate {
            self.stage = .failed(message)
            self.errorMessage = message
            self.endedAt = Date()
            self.progressNote = ""
        }
    }

    private var currentThreshold: Double {
        lock.lock()
        defer { lock.unlock() }
        return threshold
    }

    private func mutate(_ block: () -> Void) {
        lock.lock()
        block()
        lock.unlock()
    }
}
