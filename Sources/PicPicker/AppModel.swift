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
        var visionNote: String
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
    private var visionNote = ""
    private var similarityIndex: SimilarityIndex?
    private var recomputeGeneration = 0
    private var baseGroups: [PhotoGroup] = []
    /// 跟随 RAW 改名的同名 JPG，不参与评分和分组。
    private var rawCompanions: [ImageRecord] = []
    var autoApply: Bool
    var jsonOutput: Bool
    var dryRun: Bool
    var preferRaw: Bool
    var cameraBlur: Bool
    /// 离线标定：把候选照片对的像素特征写到这里。
    var dumpPairsPath: String?
    var groupingProfile: GroupingProfile
    /// 本机视觉模型（OpenAI 兼容接口）；为 nil 时只用像素比对。
    var visionAssist: VisionAssist?
    private var isPreview = false

    init(
        threshold: Double,
        autoApply: Bool,
        jsonOutput: Bool = false,
        dryRun: Bool = false,
        preferRaw: Bool = false,
        cameraBlur: Bool = true,
        visionConfiguration: VisionConfiguration? = nil,
        dumpPairsPath: String? = nil,
        groupingProfile: GroupingProfile = .default
    ) {
        self.threshold = threshold
        self.autoApply = autoApply
        self.jsonOutput = jsonOutput
        self.dryRun = dryRun
        self.preferRaw = preferRaw
        self.cameraBlur = cameraBlur
        self.visionAssist = visionConfiguration.map(VisionAssist.init(configuration:))
        self.dumpPairsPath = dumpPairsPath
        self.groupingProfile = groupingProfile
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
            visionNote: visionNote,
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
        rawCompanions = []
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
                let scanned = try ImageScanner.scan(folder: folder)
                let pairing = self.preferRaw
                    ? RawPairing.split(scanned)
                    : RawPairing.Split(urls: scanned, companions: [:])
                let urls = pairing.urls
                self.mutate {
                    self.total = scanned.count
                    self.progressNote = "共 \(scanned.count) 张图片"
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
                        self.progressNote = "提取指纹 · 美学评分 · EXIF/ISO · 对焦/曝光 · 死黑死白"
                    }
                }

                await self.reviewDocumentFlags(analyzed)

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
                // 不同机型/镜头的锐度口径不同，按同机型同镜头的样本单独取中位数；
                // 样本太少时退回全批中位数，结果更稳定。
                var cameraMedians: [String: Double] = [:]
                if self.cameraBlur {
                    for (key, members) in Dictionary(grouping: judgeable, by: \.calibrationGroup)
                    where members.count >= 8 {
                        cameraMedians[key] = median(members.map(\.sharpnessRaw))
                    }
                }
                let judgeableIDs = Set(judgeable.map(ObjectIdentifier.init))
                for record in candidates {
                    guard judgeableIDs.contains(ObjectIdentifier(record)) else { continue }
                    let base = cameraMedians[record.calibrationGroup] ?? focusMedian
                    record.isBlurry = record.sharpnessRaw
                        < min(base * Preprocess.blurRelativeCutoff, Preprocess.blurRawCap)
                }

                let pickable = candidates.filter { !$0.isBlurry }
                let index = SimilarityIndex(records: pickable, profile: groupingProfile)
                var grouped = index.groups(threshold: self.currentThreshold)
                if let dumpPath = self.dumpPairsPath {
                    let rows = index.calibrationRows(threshold: self.currentThreshold, root: folder)
                    let header = "root\tdist\thash\tgap\tluma\tedge\tgrouped\ta\tb\tburst"
                    let text = ([header] + rows).joined(separator: "\n") + "\n"
                    try? text.write(toFile: dumpPath, atomically: true, encoding: .utf8)
                }
                let currentThreshold = self.currentThreshold
                if let assist = self.visionAssist, assist.configuration.verifiesPairs {
                    let pending = index.grayBandPairs(threshold: currentThreshold)
                    if !pending.isEmpty {
                        let pairs = pending.map {
                            VisionPair(key: $0.key, lhs: $0.lhs, rhs: $0.rhs)
                        }
                        self.mutate {
                            self.progressNote = "视觉模型复核 \(pairs.count) 对拿不准的照片…"
                        }
                        let outcome = await assist.verify(pairs: pairs) { done, total in
                            self.mutate {
                                self.progressNote = "视觉模型复核 \(done)/\(total) 对照片…"
                            }
                        }
                        let note = Self.visionNoteText(outcome, endpoint: assist.endpointDescription)
                        self.mutate {
                            self.visionNote = self.visionNote.isEmpty
                                ? note
                                : "\(self.visionNote) · \(note)"
                        }
                        if !outcome.verdicts.isEmpty {
                            grouped = index.groups(
                                threshold: currentThreshold,
                                verdicts: outcome.verdicts
                            )
                        }
                    }
                }
                let companions = self.makeCompanions(
                    for: ordered,
                    pairing: pairing.companions,
                    folder: folder
                )
                _ = FileActions.plannedNames(for: grouped, companions: companions)

                let analyzedCount = ordered.filter { $0.isAnalyzed }.count
                let isoFlagged = ordered.filter { $0.isHighISOJPG }.count
                let blurry = ordered.filter { $0.isBlurry }.count
                var nextSummary = AnalysisSummary()
                nextSummary.totalFound = scanned.count
                nextSummary.analyzed = analyzedCount
                nextSummary.skipped = analyzed.count - analyzedCount
                nextSummary.rawCompanions = companions.count
                nextSummary.deadBlack = ordered.filter { $0.isDeadBlack }.count
                nextSummary.deadWhite = ordered.filter { $0.isDeadWhite }.count
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
                    self.records = ordered + companions
                    self.similarityIndex = index
                    self.baseGroups = grouped
                    self.groups = self.refine(groups: grouped)
                    self.summary = nextSummary
                    self.rawCompanions = companions
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
                self.baseGroups = grouped
                self.groups = self.refine(groups: grouped)
                self.summary.groups = self.groups.count
                self.summary.groupedPhotos = self.groups.reduce(0) { $0 + $1.records.count }
            }
        }
    }

    /// 只保留仍是选定最佳的成员标记，避免排除后最佳被钉在已隐藏的照片上。
    private func refine(groups: [PhotoGroup]) -> [PhotoGroup] {
        let index = similarityIndex
        let refined = GroupEditor.refine(groups: groups) { lhs, rhs in
            index?.distance(between: lhs, and: rhs)
        }
        for group in refined {
            for companion in rawCompanions where companion.companionOf === group.winner {
                companion.groupID = group.id
            }
        }
        _ = FileActions.plannedNames(for: refined, companions: rawCompanions)
        return refined
    }

    /// 把 RAW 的配对 JPG 建成跟随记录：继承排序位置与组号，但自己不参与选片。
    private func makeCompanions(
        for ordered: [ImageRecord],
        pairing: [String: [URL]],
        folder: URL
    ) -> [ImageRecord] {
        var companions: [ImageRecord] = []
        for record in ordered {
            guard let urls = pairing[record.url.standardizedFileURL.path] else { continue }
            for url in urls {
                let companion = ImageRecord(url: url)
                companion.relativeDirectory = relativeDirectory(of: url, in: folder)
                companion.companionOf = record
                companions.append(companion)
            }
        }
        return companions.sorted { naturalCompare($0.sortKey, $1.sortKey) }
    }

    private func regenerateGroups() {
        groups = refine(groups: baseGroups)
        summary.groups = groups.count
        summary.groupedPhotos = groups.reduce(0) { $0 + $1.records.count }
    }

    func setExcluded(_ record: ImageRecord, excluded: Bool) {
        mutate {
            record.isUserExcluded = excluded
            if excluded {
                record.isUserWinner = false
            }
            regenerateGroups()
        }
    }

    func setWinner(_ record: ImageRecord) {
        mutate {
            guard let group = groups.first(where: { group in
                group.records.contains { $0 === record }
            }) else {
                return
            }
            for member in group.records {
                member.isUserWinner = member === record
            }
            record.isUserExcluded = false
            regenerateGroups()
        }
    }

    func rotateWinner(of group: PhotoGroup, forward: Bool) {
        mutate {
            let sorted = group.sortedRecords
            guard sorted.count > 1 else { return }
            let current = sorted.firstIndex { $0 === group.winner } ?? 0
            let offset = forward ? 1 : -1
            let next = sorted[(current + offset + sorted.count) % sorted.count]
            for member in sorted {
                member.isUserWinner = member === next
                member.isUserExcluded = false
            }
            regenerateGroups()
        }
    }

    func skipGroup(_ group: PhotoGroup) {
        mutate {
            for member in group.records {
                member.isUserExcluded = true
                member.isUserWinner = false
            }
            regenerateGroups()
        }
    }

    func resetManualSelections() {
        mutate {
            for record in records {
                record.isUserExcluded = false
                record.isUserWinner = false
            }
            regenerateGroups()
        }
    }

    func beginApply(preview: Bool) {
        lock.lock()
        guard stage == .reviewing else {
            lock.unlock()
            return
        }
        let flaggedCount = records.filter {
            !$0.isUserExcluded
                && ($0.isExcludedFromPicking || $0.isBlurry || $0.hasYellowFlag)
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

    /// 用视觉模型复核“文档/截图”红标；只有模型确认是屏幕/文档的才保留红标。
    private func reviewDocumentFlags(_ analyzed: [ImageRecord]) async {
        guard let assist = visionAssist else { return }
        let flagged = analyzed.filter { record in
            record.redReasons.contains { $0.hasPrefix("文档/截图") }
        }
        guard !flagged.isEmpty else { return }

        self.mutate {
            self.progressNote = "视觉模型复核 \(flagged.count) 张文档/截图判定…"
        }
        let review = await assist.reviewDocumentFlags(flagged) { done, total in
            self.mutate {
                self.progressNote = "视觉模型复核文档判定 \(done)/\(total)…"
            }
        }
        self.mutate {
            var cleared = 0
            for record in flagged where review.realScene.contains(ObjectIdentifier(record)) {
                record.redReasons.removeAll { $0.hasPrefix("文档/截图") }
                record.isDocument = false
                cleared += 1
            }
            var text = "文档/截图复核：撤销 \(cleared) 张、保留 \(review.confirmed) 张"
            if review.failed > 0 {
                text += "、\(review.failed) 张无响应"
            }
            self.visionNote = text
        }
    }

    private static func visionNoteText(_ outcome: VisionOutcome, endpoint: String) -> String {
        let confirmed = outcome.verdicts.values.filter { $0 }.count
        let rejected = outcome.verdicts.count - confirmed
        var text = "视觉模型复核 \(outcome.attempted) 对：确认 \(confirmed)、否决 \(rejected)"
        if outcome.uncertain > 0 {
            text += "、\(outcome.uncertain) 对结论不一致（按像素判定）"
        }
        if outcome.failed > 0 {
            text += "、\(outcome.failed) 对无响应（检查 \(endpoint)）"
        }
        if outcome.truncated {
            text += "，已达调用上限"
        }
        return text
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
