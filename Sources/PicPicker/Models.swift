import CoreGraphics
import Foundation
import Vision

struct Options {
    var folder: URL?
    var threshold: Double = 0.28
    var apply: Bool = false
    var dryRun: Bool = false
    var json: Bool = false
    var undo: Bool = false
    var preferRaw: Bool = false
    var globalBlur: Bool = false
    var isoLimit: Int = 16_000
    var blurRatio: Double = 0.50
    var eyeRatio: Double = 0.20
    var showHelp: Bool = false

    static let usage = """
    用法: picpicker [选项]

      --folder <路径>     递归处理指定文件夹及其子文件夹（跳过选择框）
      --threshold <数值>  相似分组阈值，默认 0.28
      --iso-limit <数值>  JPG 高 ISO 红标阈值，默认 16000
      --blur-ratio <数值> 虚焦相对阈值，默认 0.50（越小越严格）
      --eye-ratio <数值>  闭眼 EAR 阈值，默认 0.20（越小越严格）
      --apply             识别完成后自动执行，无需确认
      --dry-run           只分析并输出计划，不修改任何文件
      --json              与 --dry-run 一起使用，输出机器可读 JSON
      --undo              撤销本文件夹上一次重命名
      --prefer-raw        同名的 RAW+JPG 只分析 RAW，JPG 跟随 RAW 一起改名
      --global-blur       关闭按机型的虚焦校准，改用全批中位数
      -h, --help          显示帮助
    """

    static func parse(_ args: [String]) -> Options {
        var options = Options()
        var index = 1

        func nextValue(_ name: String) -> String? {
            guard index + 1 < args.count else {
                FileHandle.standardError.write(Data("缺少参数值: \(name)\n".utf8))
                return nil
            }
            index += 1
            return args[index]
        }

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--folder", "-f":
                if let value = nextValue(arg) {
                    options.folder = URL(
                        fileURLWithPath: (value as NSString).expandingTildeInPath
                    ).standardizedFileURL
                }
            case "--threshold", "-t":
                if let value = nextValue(arg), let number = Double(value) {
                    options.threshold = min(0.95, max(0.05, number))
                }
            case "--iso-limit":
                if let value = nextValue(arg), let number = Int(value), number > 0 {
                    options.isoLimit = number
                }
            case "--blur-ratio":
                if let value = nextValue(arg), let number = Double(value) {
                    options.blurRatio = min(0.95, max(0.10, number))
                }
            case "--eye-ratio":
                if let value = nextValue(arg), let number = Double(value) {
                    options.eyeRatio = min(0.45, max(0.05, number))
                }
            case "--apply", "-y":
                options.apply = true
            case "--dry-run":
                options.dryRun = true
            case "--json":
                options.json = true
            case "--undo":
                options.undo = true
            case "--prefer-raw":
                options.preferRaw = true
            case "--global-blur":
                options.globalBlur = true
            case "-h", "--help":
                options.showHelp = true
            default:
                if !arg.hasPrefix("-"), options.folder == nil {
                    options.folder = URL(
                        fileURLWithPath: (arg as NSString).expandingTildeInPath
                    ).standardizedFileURL
                } else {
                    FileHandle.standardError.write(Data("未知参数: \(arg)\n".utf8))
                }
            }
            index += 1
        }
        return options
    }
}

final class ImageRecord: @unchecked Sendable {
    let url: URL
    let originalName: String

    var featurePrint: FeaturePrintObservation?
    var dHash: UInt64?
    var aesthetics: Double?
    var isUtility = false
    var sharpness = 0.0
    var sharpnessRaw = 0.0
    var exposure = 0.5
    var meanLuma = 0.5
    var luminanceStd = 0.0
    var clippedFraction = 0.0
    var shadowClippedFraction = 0.0
    var highlightClippedFraction = 0.0
    var faceQuality: Double?
    var faceCount = 0
    var iso: Int?
    var isJPG = false
    var isRaw = false
    var camera: String?
    var lens: String?
    /// 与 RAW 同名的 JPG：不单独分析，跟随 RAW 一起改名。
    var companionOf: ImageRecord?
    var isBlurry = false
    var captureDate: Date?
    var sequenceKey: String?
    var sequenceNumber: Int?
    var eyesClosed = false
    var headCutoff = false
    var eyesClosedScore: Double?
    var horizonAngle: Double?
    var isDocument = false
    var redReasons: [String] = []
    var yellowReasons: [String] = []
    var score = 0.0
    var groupID: Int?
    var targetName: String?
    var distanceToBest: Double?
    var blackClippedFraction = 0.0
    var whiteClippedFraction = 0.0
    /// 局部死黑/死白：过曝或欠曝后仍无结构的大片区域。
    var isDeadBlack = false
    var isDeadWhite = false
    /// 审阅阶段手动排除：不参与重命名，也不写入任何标签。
    var isUserExcluded = false
    /// 审阅阶段手动指定为组内最佳。
    var isUserWinner = false
    var error: String?
    var relativeDirectory = ""

    init(url: URL) {
        self.url = url
        self.originalName = url.lastPathComponent
        self.isRaw = Self.rawExtensions.contains(url.pathExtension.lowercased())
        self.isJPG = Self.jpegExtensions.contains(url.pathExtension.lowercased())
    }

    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw", "nrw", "rwl", "3fr", "erf"
    ]
    static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe"]

    var isAnalyzed: Bool {
        featurePrint != nil
    }

    var isHighISOJPG: Bool {
        isJPG && (iso ?? 0) > Preprocess.isoLimit
    }

    var hasYellowFlag: Bool {
        eyesClosed || headCutoff
    }

    /// 红标照片不参与重复检测和选片；黄标照片照常参与。
    var isExcludedFromPicking: Bool {
        isHighISOJPG || !redReasons.isEmpty || isDeadWhite || isDeadBlack
    }

    var redReasonText: String {
        redReasons.joined(separator: "、")
    }

    var yellowReasonText: String {
        yellowReasons.joined(separator: "、")
    }

    /// 虚焦校准分组：同一机型、同一镜头的照片亮度与锐度口径一致。
    var calibrationGroup: String {
        let body = camera ?? "unknown"
        let optic = lens ?? "unknown"
        return "\(body)|\(optic)|\(isRaw ? "raw" : "8bit")"
    }

    /// RAW+JPG 同名配对里的 JPG：不单独分析，跟随 RAW 一起改名。
    var isCompanion: Bool { companionOf != nil }

    /// 相对根目录的原始路径，例如 `2026-11-11/Day2/DSC3345.jpg`
    var sortKey: String {
        relativeDirectory.isEmpty ? originalName : "\(relativeDirectory)/\(originalName)"
    }

    /// 重命名后相对根目录的路径，用于界面和报告展示
    var plannedDisplayPath: String {
        let name = targetName ?? originalName
        return relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
    }
}

struct PhotoGroup: @unchecked Sendable {
    var id: Int
    var records: [ImageRecord]
    var winner: ImageRecord

    var sortedRecords: [ImageRecord] {
        records.sorted { naturalCompare($0.originalName, $1.originalName) }
    }

    /// 组内成员是否来自同一目录、同一文件名前缀，且编号连续（允许少量缺号）。
    var isBurst: Bool {
        guard records.count > 1,
              let key = records.first?.sequenceKey,
              records.allSatisfy({ $0.sequenceKey == key }) else {
            return false
        }
        let numbers = records.compactMap(\.sequenceNumber).sorted()
        guard numbers.count == records.count, let first = numbers.first, let last = numbers.last else {
            return false
        }
        return (last - first) <= max(2, (numbers.count - 1) * 3)
    }
}

struct AnalysisSummary {
    var totalFound: Int = 0
    var analyzed: Int = 0
    var skipped: Int = 0
    var isoFlagged: Int = 0
    var redFlagged: Int = 0
    var yellowFlagged: Int = 0
    var deadBlack: Int = 0
    var deadWhite: Int = 0
    var rawCompanions: Int = 0
    var blurry: Int = 0
    var pickable: Int = 0
    var groups: Int = 0
    var groupedPhotos: Int = 0
}

enum Preprocess {
    static var isoLimit = 16_000
    static let blurryFolderName = "虚焦"
    static var blurRelativeCutoff = 0.50
    static let blurRawCap = 6.0
    static let blurMinimumDetail = 0.10
    static let blurMinimumRaw = 0.5
    static var eyeClosedRatio = 0.20
    static let eyeClosedMinimumFaceHeight = 0.06
    static let headCutoffMargin = 0.08
    static let horizonMaxAngle = 35.0
    static let eyeMaxYawDegrees = 25.0
    static let extremeOverexposureLuma = 0.92
    static let extremeUnderexposureLuma = 0.08
    static let extremeExposureClipped = 0.62
}

enum Stage: Equatable {
    case menu
    case scanning
    case analyzing
    case grouping
    case reviewing
    case applying
    case finished
    case failed(String)
}

func naturalCompare(_ lhs: String, _ rhs: String) -> Bool {
    lhs.compare(rhs, options: [.numeric, .caseInsensitive, .widthInsensitive]) == .orderedAscending
}

func clamp(_ value: Double, _ lower: Double = 0, _ upper: Double = 1) -> Double {
    min(upper, max(lower, value))
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 0 {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

func parseFilenameSequence(_ filename: String) -> (prefix: String, number: Int)? {
    var name = (filename as NSString).deletingPathExtension
    // 忽略上一次运行写入的组号前缀，例如 "12-DSC3345"
    if let dash = name.firstIndex(of: "-") {
        let prefix = name[..<dash]
        if !prefix.isEmpty, prefix.allSatisfy(\.isNumber) {
            name = String(name[name.index(after: dash)...])
        }
    }

    let characters = Array(name)
    var runs: [(start: Int, end: Int, value: Int)] = []
    var index = 0
    while index < characters.count {
        guard characters[index].isNumber else {
            index += 1
            continue
        }
        let start = index
        while index < characters.count, characters[index].isNumber {
            index += 1
        }
        if index - start >= 3, let value = Int(String(characters[start..<index])) {
            runs.append((start, index, value))
        }
    }
    guard let run = runs.last else { return nil }

    var prefix = String(characters[..<run.start])
    while let last = prefix.last, "-_. ".contains(last) {
        prefix.removeLast()
    }
    return (prefix.lowercased(), run.value)
}
