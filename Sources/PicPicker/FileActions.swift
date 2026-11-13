import Darwin
import Foundation

struct RenameRecord: Codable {
    let originalName: String
    let renamedName: String
    let directory: String?
    let groupID: Int
    let winner: Bool
    let previousTags: [String]
    let movedFrom: String?
    let movedTo: String?

    init(
        originalName: String,
        renamedName: String,
        directory: String?,
        groupID: Int,
        winner: Bool,
        previousTags: [String],
        movedFrom: String? = nil,
        movedTo: String? = nil
    ) {
        self.originalName = originalName
        self.renamedName = renamedName
        self.directory = directory
        self.groupID = groupID
        self.winner = winner
        self.previousTags = previousTags
        self.movedFrom = movedFrom
        self.movedTo = movedTo
    }
}

struct UndoManifest: Codable {
    let version: Int
    let createdAt: Date
    let folder: String
    let entries: [RenameRecord]
}

struct AppliedRename {
    let originalName: String
    let renamedName: String
    let directory: String
    let groupID: Int
    let winner: Bool
    let previousTags: [String]
}

struct ApplyReport {
    var renames: [AppliedRename] = []
    var renamedCount = 0
    var highISOMarkedCount = 0
    var redTaggedCount = 0
    var yellowTaggedCount = 0
    var movedToBlurryCount = 0
    var taggedCount = 0
    var newlyTagged = 0
    var failures: [String] = []
    var undoURL: URL?
}

struct UndoReport {
    var restored: [String] = []
    var failures: [String] = []
}

enum FileActions {
    static let manifestName = ".picpicker-undo.json"

    struct PreprocessResult {
        var redTagChanges: [(path: String, previousTags: [String])] = []
        var yellowTagChanges: [(path: String, previousTags: [String])] = []
        var moves: [(from: String, to: String)] = []
        var failures: [String] = []
    }

    static func preprocess(records: [ImageRecord], root: URL) -> PreprocessResult {
        var result = PreprocessResult()

        for record in records where record.isAnalyzed && !record.isUserExcluded {
            if isLocked(record.url) {
                result.failures.append("文件被锁定（uchg），跳过标签与移动 \(record.sortKey)")
                continue
            }
            if record.isExcludedFromPicking {
                do {
                    let previousTags = FinderTags.read(from: record.url)
                    if try FinderTags.addRed(to: record.url) {
                        result.redTagChanges.append((record.sortKey, previousTags))
                    }
                } catch {
                    result.failures.append("红色标签失败 \(record.sortKey): \(error.localizedDescription)")
                }
            } else if record.hasYellowFlag {
                do {
                    let previousTags = FinderTags.read(from: record.url)
                    if try FinderTags.addYellow(to: record.url) {
                        result.yellowTagChanges.append((record.sortKey, previousTags))
                    }
                } catch {
                    result.failures.append("黄色标签失败 \(record.sortKey): \(error.localizedDescription)")
                }
            }

            guard record.isBlurry else { continue }
            let sourceDirectory = record.url.deletingLastPathComponent()
            let destinationDirectory = sourceDirectory.appendingPathComponent(Preprocess.blurryFolderName)
            var target = destinationDirectory.appendingPathComponent(record.url.lastPathComponent)

            do {
                try FileManager.default.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: target.path) {
                    let base = record.url.deletingPathExtension().lastPathComponent
                    let ext = record.url.pathExtension
                    var suffix = 2
                    repeat {
                        let name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                        target = destinationDirectory.appendingPathComponent(name)
                        suffix += 1
                    } while FileManager.default.fileExists(atPath: target.path)
                }

                try FileManager.default.moveItem(at: record.url, to: target)
                result.moves.append((
                    record.sortKey,
                    relativePath(of: target, in: root)
                ))
            } catch {
                result.failures.append("移动虚焦失败 \(record.sortKey): \(error.localizedDescription)")
            }
        }
        return result
    }

    static func plannedNames(
        for groups: [PhotoGroup],
        companions: [ImageRecord] = []
    ) -> [(ImageRecord, String)] {
        // 先让所有 RAW 的名字落定，再给配对 JPG 跟名，避免占用同一目录里的名字。
        var plans: [(ImageRecord, String)] = []
        var used: [String: Set<String>] = [:]
        var reserved: [String: Set<String>] = [:]
        var listedDirectories = Set<String>()

        var sourceNamesByDirectory: [String: Set<String>] = [:]
        for group in groups {
            for record in group.records {
                let key = record.url.deletingLastPathComponent().standardizedFileURL.path
                sourceNamesByDirectory[key, default: []].insert(record.url.lastPathComponent.lowercased())
            }
        }
        for companion in companions {
            let key = companion.url.deletingLastPathComponent().standardizedFileURL.path
            sourceNamesByDirectory[key, default: []].insert(companion.url.lastPathComponent.lowercased())
        }

        for group in groups {
            for record in group.sortedRecords {
                let directory = record.url.deletingLastPathComponent()
                let directoryKey = directory.standardizedFileURL.path
                if !listedDirectories.contains(directoryKey) {
                    listedDirectories.insert(directoryKey)
                    let existing = (try? FileManager.default.contentsOfDirectory(atPath: directoryKey)) ?? []
                    let sources = sourceNamesByDirectory[directoryKey] ?? []
                    reserved[directoryKey] = Set(
                        existing.map { $0.lowercased() }.filter { !sources.contains($0) }
                    )
                }

                let base = strippingNumericPrefix(from: record.url.deletingPathExtension().lastPathComponent)
                let ext = record.url.pathExtension
                var candidate = "\(group.id)-\(base)"
                if !ext.isEmpty {
                    candidate += ".\(ext)"
                }

                var suffix = 2
                var finalName = candidate
                var usedNames = used[directoryKey] ?? []
                let reservedNames = reserved[directoryKey] ?? []
                while usedNames.contains(finalName.lowercased())
                    || reservedNames.contains(finalName.lowercased()) {
                    let extPart = ext.isEmpty ? "" : ".\(ext)"
                    finalName = "\(group.id)-\(base)-\(suffix)\(extPart)"
                    suffix += 1
                }
                usedNames.insert(finalName.lowercased())
                used[directoryKey] = usedNames
                record.targetName = finalName
                plans.append((record, finalName))
            }
        }

        // 配对的 JPG 跟随 RAW 的名字：同目录、同组号、同摘要，只保留各自的扩展名，
        // 这样 CR3 与 JPG 在 Finder/Lightroom 里始终成对出现。
        for (record, target) in plans {
            for companion in companions where companion.companionOf === record {
                let directory = companion.url.deletingLastPathComponent()
                let directoryKey = directory.standardizedFileURL.path
                let ext = companion.url.pathExtension
                let base = (target as NSString).deletingPathExtension
                var candidate = ext.isEmpty ? base : "\(base).\(ext)"
                var suffix = 2
                var usedNames = used[directoryKey] ?? []
                let reservedNames = reserved[directoryKey] ?? []
                while usedNames.contains(candidate.lowercased())
                    || reservedNames.contains(candidate.lowercased()) {
                    candidate = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
                    suffix += 1
                }
                usedNames.insert(candidate.lowercased())
                used[directoryKey] = usedNames
                companion.targetName = candidate
            }
        }
        return plans
    }

    static func preview(groups: [PhotoGroup], records: [ImageRecord]) -> ApplyReport {
        var report = ApplyReport()
        report.renames = groups.flatMap { group -> [AppliedRename] in
            group.sortedRecords.map { record in
                AppliedRename(
                    originalName: record.originalName,
                    renamedName: record.targetName ?? record.originalName,
                    directory: record.relativeDirectory,
                    groupID: group.id,
                    winner: record === group.winner,
                    previousTags: []
                )
            }
        }
        report.renamedCount = report.renames.count
        report.taggedCount = groups.count
        report.highISOMarkedCount = records.filter {
            $0.isHighISOJPG && !$0.isUserExcluded
        }.count
        report.redTaggedCount = records.filter {
            $0.isAnalyzed && $0.isExcludedFromPicking && !$0.isUserExcluded
        }.count
        report.yellowTaggedCount = records.filter {
            $0.isAnalyzed && !$0.isExcludedFromPicking && $0.hasYellowFlag && !$0.isUserExcluded
        }.count
        report.movedToBlurryCount = records.filter { $0.isBlurry && !$0.isUserExcluded }.count
        return report
    }

    static func apply(groups: [PhotoGroup], folder: URL, records: [ImageRecord]) throws -> ApplyReport {
        var report = ApplyReport()
        let root = folder.standardizedFileURL
        report.failures.append(contentsOf: lockedFolderNotices(records: records, groups: groups))
        let preprocessResult = preprocess(records: records, root: root)
        report.highISOMarkedCount = records.filter {
            $0.isAnalyzed && $0.isHighISOJPG && !$0.isUserExcluded
        }.count
        report.redTaggedCount = preprocessResult.redTagChanges.count
        report.yellowTaggedCount = preprocessResult.yellowTagChanges.count
        report.movedToBlurryCount = preprocessResult.moves.count
        report.failures.append(contentsOf: preprocessResult.failures)

        var staging: [(record: ImageRecord, original: URL, temporary: URL, target: URL, directory: String)] = []
        // 只给会被整理的组算名字，避免改动因排除而不再展示的记录。
        let plans = plannedNames(for: groups) + records
            .filter { $0.isCompanion && $0.targetName != nil }
            .map { ($0, $0.targetName ?? $0.originalName) }
        for record in records where record.groupID == nil {
            record.targetName = nil
        }

        for (record, targetName) in plans {
            let fileDirectory = record.url.deletingLastPathComponent()
            let target = fileDirectory.appendingPathComponent(targetName)
            let relativeDir = relativeDirectory(of: record.url, in: root)
            guard record.url.standardizedFileURL != target.standardizedFileURL else {
                let isWinner = groups.first(where: { $0.id == record.groupID })?.winner === record
                report.renames.append(
                    AppliedRename(
                        originalName: record.originalName,
                        renamedName: targetName,
                        directory: relativeDir,
                        groupID: record.groupID ?? 0,
                        winner: isWinner,
                        previousTags: FinderTags.read(from: record.url)
                    )
                )
                continue
            }
            let temporary = fileDirectory.appendingPathComponent(
                ".picpicker-tmp-\(UUID().uuidString).\(record.url.pathExtension)"
            )
            staging.append((record, record.url, temporary, target, relativeDir))
        }

        // 单个文件失败不应该拖垮整批：先统一改成临时名（避免互相占名），
        // 再逐个落到目标名，遇到问题只回滚这一个文件并记录原因。
        var movedToTemp: [(record: ImageRecord, original: URL, temporary: URL, target: URL, directory: String)] = []
        for item in staging {
            guard FileManager.default.fileExists(atPath: item.original.path) else {
                report.failures.append("文件已不存在，跳过 \(item.record.originalName)")
                continue
            }
            guard !isLocked(item.original) else {
                report.failures.append(
                    "文件被锁定（uchg），跳过 \(item.record.originalName)；可执行 chflags nouchg 解锁后重跑"
                )
                continue
            }
            do {
                try FileManager.default.moveItem(at: item.original, to: item.temporary)
                movedToTemp.append(item)
            } catch {
                report.failures.append(
                    "改名失败 \(item.record.originalName): \(error.localizedDescription)"
                )
            }
        }

        for item in movedToTemp {
            do {
                let previousTags = FinderTags.read(from: item.temporary)
                try FileManager.default.moveItem(at: item.temporary, to: item.target)
                report.renamedCount += 1

                let isWinner = groups.first(where: { $0.id == item.record.groupID })?.winner === item.record
                report.renames.append(
                    AppliedRename(
                        originalName: item.record.originalName,
                        renamedName: item.target.lastPathComponent,
                        directory: item.directory,
                        groupID: item.record.groupID ?? 0,
                        winner: isWinner,
                        previousTags: previousTags
                    )
                )
            } catch {
                // 只恢复这一个文件，其余成功的结果保留。
                if FileManager.default.fileExists(atPath: item.temporary.path) {
                    try? FileManager.default.moveItem(at: item.temporary, to: item.original)
                } else if FileManager.default.fileExists(atPath: item.target.path),
                          !FileManager.default.fileExists(atPath: item.original.path) {
                    try? FileManager.default.moveItem(at: item.target, to: item.original)
                }
                report.failures.append(
                    "改名失败 \(item.record.originalName): \(error.localizedDescription)"
                )
            }
        }

        let manifestEntries = makeManifestEntries(report: report, preprocess: preprocessResult)

        for group in groups {
            let winner = group.winner
            guard let renamed = report.renames.first(where: {
                $0.originalName == winner.originalName && $0.groupID == group.id
            }) else {
                continue
            }
            let winnerDirectory = renamed.directory.isEmpty
                ? root
                : root.appendingPathComponent(renamed.directory)
            let winnerURL = winnerDirectory.appendingPathComponent(renamed.renamedName)
            do {
                let added = try FinderTags.addGreen(to: winnerURL)
                report.newlyTagged += added ? 1 : 0
                report.taggedCount += 1
            } catch {
                report.failures.append("标签失败 \(renamed.renamedName): \(error.localizedDescription)")
            }
        }

        let manifestURL = folder.appendingPathComponent(manifestName)
        let didChange = report.renamedCount > 0
            || report.newlyTagged > 0
            || report.highISOMarkedCount > 0
            || report.yellowTaggedCount > 0
            || report.movedToBlurryCount > 0
        if didChange {
            let manifest = UndoManifest(
                version: 1,
                createdAt: Date(),
                folder: folder.path,
                entries: manifestEntries
            )
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
                report.undoURL = manifestURL
            } catch {
                report.failures.append("无法写入撤销记录: \(error.localizedDescription)")
            }
        } else if FileManager.default.fileExists(atPath: manifestURL.path) {
            report.undoURL = manifestURL
        }

        // 同一张照片的重命名、锁定、标签可能各报一次，按内容去重，别让界面被重复项淹没。
        var seen = Set<String>()
        report.failures = report.failures.filter { seen.insert($0).inserted }
        return report
    }

    private static func makeManifestEntries(
        report: ApplyReport,
        preprocess: PreprocessResult
    ) -> [RenameRecord] {
        var records: [RenameRecord] = []

        for renamed in report.renames {
            records.append(
                RenameRecord(
                    originalName: renamed.originalName,
                    renamedName: renamed.renamedName,
                    directory: renamed.directory,
                    groupID: renamed.groupID,
                    winner: renamed.winner,
                    previousTags: renamed.previousTags
                )
            )
        }

        for change in preprocess.redTagChanges {
            let path = change.path as NSString
            records.append(
                RenameRecord(
                    originalName: path.lastPathComponent,
                    renamedName: path.lastPathComponent,
                    directory: path.deletingLastPathComponent,
                    groupID: 0,
                    winner: false,
                    previousTags: change.previousTags,
                    movedFrom: "__redtag__"
                )
            )
        }

        for change in preprocess.yellowTagChanges {
            let path = change.path as NSString
            records.append(
                RenameRecord(
                    originalName: path.lastPathComponent,
                    renamedName: path.lastPathComponent,
                    directory: path.deletingLastPathComponent,
                    groupID: 0,
                    winner: false,
                    previousTags: change.previousTags,
                    movedFrom: "__yellowtag__"
                )
            )
        }

        for move in preprocess.moves {
            let from = move.from as NSString
            let to = move.to as NSString
            records.append(
                RenameRecord(
                    originalName: from.lastPathComponent,
                    renamedName: to.lastPathComponent,
                    directory: from.deletingLastPathComponent,
                    groupID: 0,
                    winner: false,
                    previousTags: [],
                    movedFrom: move.from,
                    movedTo: move.to
                )
            )
        }
        return records
    }

    static func readManifest(folder: URL) throws -> UndoManifest? {
        let url = folder.appendingPathComponent(manifestName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UndoManifest.self, from: Data(contentsOf: url))
    }

    static func undo(folder: URL) throws -> UndoReport {
        guard let manifest = try readManifest(folder: folder) else {
            throw NSError(
                domain: "PicPicker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "没有找到可撤销的记录"]
            )
        }

        var report = UndoReport()
        let entries = manifest.entries

        // 1. Restore renamed files (and the tags of their winners).
        for entry in entries where entry.movedFrom == nil {
            let directory = entry.directory.map { folder.appendingPathComponent($0) } ?? folder
            let current = directory.appendingPathComponent(entry.renamedName)
            let original = directory.appendingPathComponent(entry.originalName)
            guard FileManager.default.fileExists(atPath: current.path) else {
                report.failures.append("找不到 \(entry.renamedName)")
                continue
            }
            if entry.renamedName == entry.originalName {
                do {
                    try FinderTags.write(entry.previousTags, to: current)
                    report.restored.append(entry.originalName)
                } catch {
                    report.failures.append("恢复标签失败 \(entry.originalName): \(error.localizedDescription)")
                }
                continue
            }
            if FileManager.default.fileExists(atPath: original.path) {
                report.failures.append("原文件名已存在，跳过 \(entry.originalName)")
                continue
            }
            do {
                try FileManager.default.moveItem(at: current, to: original)
                try FinderTags.write(entry.previousTags, to: original)
                report.restored.append(entry.originalName)
            } catch {
                report.failures.append("撤销失败 \(entry.renamedName): \(error.localizedDescription)")
            }
        }

        // 2. Move blurry photos back from their 虚焦 folders.
        var emptiedDirectories: Set<String> = []
        for entry in entries.reversed() {
            guard let from = entry.movedFrom,
                  from != "__redtag__",
                  from != "__yellowtag__",
                  let to = entry.movedTo else {
                continue
            }
            let current = folder.appendingPathComponent(to)
            let original = folder.appendingPathComponent(from)
            guard FileManager.default.fileExists(atPath: current.path) else {
                report.failures.append("找不到 \(to)")
                continue
            }
            if FileManager.default.fileExists(atPath: original.path) {
                report.failures.append("原位置已存在，跳过 \(from)")
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    at: original.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: current, to: original)
                report.restored.append(from)
                emptiedDirectories.insert(current.deletingLastPathComponent().path)
            } catch {
                report.failures.append("撤销移动失败 \(to): \(error.localizedDescription)")
            }
        }
        for directory in emptiedDirectories {
            removeEmptyDirectories(startingAt: URL(fileURLWithPath: directory), root: folder)
        }

        // 3. Restore tags of photos that were marked with the red ISO tag.
        for entry in entries where entry.movedFrom == "__redtag__" || entry.movedFrom == "__yellowtag__" {
            let directory = entry.directory.map { folder.appendingPathComponent($0) } ?? folder
            let path = directory.appendingPathComponent(entry.originalName)
            guard FileManager.default.fileExists(atPath: path.path) else {
                report.failures.append("找不到 \(entry.originalName)")
                continue
            }
            do {
                try FinderTags.write(entry.previousTags, to: path)
                report.restored.append("红标还原 \(entry.originalName)")
            } catch {
                report.failures.append("恢复标签失败 \(entry.originalName): \(error.localizedDescription)")
            }
        }

        if report.failures.isEmpty {
            try? FileManager.default.removeItem(
                at: folder.appendingPathComponent(manifestName)
            )
        }
        return report
    }

    private static func removeEmptyDirectories(startingAt directory: URL, root: URL) {
        var current = directory.standardizedFileURL
        let rootPath = root.standardizedFileURL.path

        while current.path != rootPath, current.path.hasPrefix(rootPath + "/") {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? []
            guard contents.isEmpty else { return }
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// 用户不可变标志（Finder 里“锁定”），改名和写标签都会被系统拒绝。
    static func isLocked(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_IMMUTABLE) != 0
            || info.st_flags & UInt32(SF_IMMUTABLE) != 0
    }

    /// 整个目录被锁定时里面的文件都改不了名，提前提示一次，避免刷出一堆错误。
    private static func lockedFolderNotices(
        records: [ImageRecord],
        groups: [PhotoGroup]
    ) -> [String] {
        var seen = Set<String>()
        var notices: [String] = []
        func inspect(_ url: URL) {
            let directory = url.deletingLastPathComponent()
            guard !seen.contains(directory.path) else { return }
            seen.insert(directory.path)
            if isLocked(directory) {
                notices.append("目录被锁定（uchg），本目录下的照片不会改名: \(directory.lastPathComponent)")
            }
        }
        for record in records where !record.isAnalyzed && !record.isUserExcluded {
            inspect(record.url)
        }
        for group in groups {
            for record in group.records {
                inspect(record.url)
            }
        }
        return notices
    }

    private static func strippingNumericPrefix(from name: String) -> String {
        guard let dash = name.firstIndex(of: "-") else { return name }
        let prefix = name[..<dash]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return name }
        let remainder = name[name.index(after: dash)...]
        return remainder.isEmpty ? name : String(remainder)
    }
}
