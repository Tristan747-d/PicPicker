import Foundation

/// 分组算法的可标定参数。
///
/// 算法本身不含事件相关的魔法数：所有阈值都从这里读。换一批活动照片时，
/// 用 `tools/calibrate.py` 重新标定一份 JSON 覆盖即可，不需要改代码。
struct GroupingProfile: Codable, Sendable {
    struct Pair: Codable, Sendable {
        /// 特征指纹只负责粗筛，超过这个距离就不再比较。
        var featureCutoff = 0.60
        /// dHash 候选补充的汉明距离上限。
        var hashCutoff = 6
        /// 默认阈值下要求的亮度相关（0.28 → 0.90）。
        var lumaRequirement = 0.930
        /// 梯度相关允许比亮度要求低多少。
        var edgeAllowance = 0.10
        /// 两项都超过这里视为“同一张图的副本”，直接成组。
        var identicalLuma = 0.985
        var identicalEdge = 0.95
        /// 亮度相关低于要求这么多以内，交给模型/人工复核。
        var grayTolerance = 0.12
        /// 亮度相关高出要求这么多，像素证据已足够，不再复核。
        var confidentMargin = 0.06
        /// 粗对齐时尝试的缩放档位（相对中心裁切比例）。
        var zoomLevels = [1.0, 0.97, 0.94, 0.91, 0.88]

        init() {}

        /// 允许 profile 只写其中几个字段，其余沿用默认值。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Pair()
            featureCutoff = try container.decodeIfPresent(Double.self, forKey: .featureCutoff)
                ?? fallback.featureCutoff
            hashCutoff = try container.decodeIfPresent(Int.self, forKey: .hashCutoff)
                ?? fallback.hashCutoff
            lumaRequirement = try container.decodeIfPresent(Double.self, forKey: .lumaRequirement)
                ?? fallback.lumaRequirement
            edgeAllowance = try container.decodeIfPresent(Double.self, forKey: .edgeAllowance)
                ?? fallback.edgeAllowance
            identicalLuma = try container.decodeIfPresent(Double.self, forKey: .identicalLuma)
                ?? fallback.identicalLuma
            identicalEdge = try container.decodeIfPresent(Double.self, forKey: .identicalEdge)
                ?? fallback.identicalEdge
            grayTolerance = try container.decodeIfPresent(Double.self, forKey: .grayTolerance)
                ?? fallback.grayTolerance
            confidentMargin = try container.decodeIfPresent(Double.self, forKey: .confidentMargin)
                ?? fallback.confidentMargin
            zoomLevels = try container.decodeIfPresent([Double].self, forKey: .zoomLevels)
                ?? fallback.zoomLevels
        }
    }

    struct Burst: Codable, Sendable {
        /// 连拍相邻帧在像素要求上的放宽量。
        var relaxation = 0.03
        /// 文件名编号相差不超过这个数才算连拍候选。
        var numberGap = 3
        /// EXIF 拍摄时间相差不超过这么多秒才算连拍候选。
        var maxGapSeconds = 10.0

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = Burst()
            relaxation = try container.decodeIfPresent(Double.self, forKey: .relaxation)
                ?? fallback.relaxation
            numberGap = try container.decodeIfPresent(Int.self, forKey: .numberGap)
                ?? fallback.numberGap
            maxGapSeconds = try container.decodeIfPresent(Double.self, forKey: .maxGapSeconds)
                ?? fallback.maxGapSeconds
        }
    }

    struct ThresholdMap: Codable, Sendable {
        /// 用户阈值每 +1，要求放宽多少（用于 TUI 上的 ←/→ 微调）。
        var slope = 0.15
        /// 无论怎么调都夹在这个区间里。
        var lowerBound = 0.85
        var upperBound = 0.99

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fallback = ThresholdMap()
            slope = try container.decodeIfPresent(Double.self, forKey: .slope) ?? fallback.slope
            lowerBound = try container.decodeIfPresent(Double.self, forKey: .lowerBound)
                ?? fallback.lowerBound
            upperBound = try container.decodeIfPresent(Double.self, forKey: .upperBound)
                ?? fallback.upperBound
        }
    }

    var version = 1
    /// 标定来源说明，方便判断这份 profile 适用于什么数据。
    var source = "default"
    var calibratedAt: String?
    var pair = Pair()
    var burst = Burst()
    var thresholdMap = ThresholdMap()

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "default"
        calibratedAt = try container.decodeIfPresent(String.self, forKey: .calibratedAt)
        pair = try container.decodeIfPresent(Pair.self, forKey: .pair) ?? Pair()
        burst = try container.decodeIfPresent(Burst.self, forKey: .burst) ?? Burst()
        thresholdMap = try container.decodeIfPresent(ThresholdMap.self, forKey: .thresholdMap)
            ?? ThresholdMap()
    }

    static let `default` = GroupingProfile()

    /// 参数映射：`pair.lumaRequirement` 是默认阈值 0.28 时的要求，阈值调大就放宽。
    func requirement(threshold: Double) -> Double {
        let raw = pair.lumaRequirement + thresholdMap.slope * (0.28 - threshold)
        return min(thresholdMap.upperBound, max(thresholdMap.lowerBound, raw))
    }

    func requirement(threshold: Double, burstRelaxation: Double) -> Double {
        requirement(threshold: threshold) - burstRelaxation
    }

    /// 像素分数是否落在需要模型/人工复核的灰区。
    func needsModel(_ score: StructuralScore, requirement: Double) -> Bool {
        guard !(score.luma >= pair.identicalLuma && score.edge >= pair.identicalEdge) else {
            return false
        }
        return score.luma >= requirement - pair.grayTolerance
            && score.luma <= requirement + pair.confidentMargin
            && score.edge >= requirement - 0.25
    }

    static func load(path: String?) -> GroupingProfile {
        let url: URL?
        if let path {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            url = defaultURL
        }
        guard let url, let data = try? Data(contentsOf: url) else {
            return .default
        }
        let decoder = JSONDecoder()
        guard let profile = try? decoder.decode(GroupingProfile.self, from: data) else {
            FileHandle.standardError.write(Data("无法解析 profile: \(url.path)\n".utf8))
            return .default
        }
        return profile
    }

    static var defaultURL: URL? {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/picpicker/grouping.json")
    }
}
