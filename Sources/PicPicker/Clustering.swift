import Foundation
import Vision

struct StructuralScore {
    let luma: Double
    let edge: Double
}

/// 像素复核结果缓存：同一对照片只算一次，来回调阈值不重复计算。
private final class StructuralCache: @unchecked Sendable {
    private let lock = NSLock()
    private var scores: [Int: StructuralScore] = [:]

    func score(for key: Int, _ compute: () -> StructuralScore) -> StructuralScore {
        lock.lock()
        if let cached = scores[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = compute()
        lock.lock()
        scores[key] = value
        lock.unlock()
        return value
    }
}

/// 缩放采样的坐标/权重只跟尺寸和缩放系数有关，按需缓存一次即可。
private final class ResamplePlanCache: @unchecked Sendable {
    struct Plan {
        let x0: [Int]
        let x1: [Int]
        let wx: [Double]
        let y0: [Int]
        let y1: [Int]
        let wy: [Double]
    }

    private let lock = NSLock()
    private var plans: [Int: Plan] = [:]

    func plan(side: Int, zoom: Double) -> Plan {
        let key = side * 10_000 + Int((zoom * 1000).rounded())
        lock.lock()
        defer { lock.unlock() }
        if let existing = plans[key] { return existing }

        let center = (Double(side) - 1) / 2
        func axis() -> (indices: [Int], neighbours: [Int], weights: [Double]) {
            var indices = [Int](repeating: 0, count: side)
            var neighbours = [Int](repeating: 0, count: side)
            var weights = [Double](repeating: 0, count: side)
            for index in 0..<side {
                let source = center + (Double(index) - center) * zoom
                let clamped = min(Double(side - 1), max(0, source))
                let lower = Int(clamped.rounded(.down))
                indices[index] = lower
                neighbours[index] = min(side - 1, lower + 1)
                weights[index] = clamped - Double(lower)
            }
            return (indices, neighbours, weights)
        }
        let x = axis()
        let y = axis()
        let plan = Plan(
            x0: x.indices,
            x1: x.neighbours,
            wx: x.weights,
            y0: y.indices,
            y1: y.neighbours,
            wy: y.weights
        )
        plans[key] = plan
        return plan
    }
}

struct SimilarityIndex {
    let records: [ImageRecord]
    private let count: Int
    private let distances: [Float]?
    private static let eagerMatrixLimit = 2500

    /// 全部阈值来自可重新标定的 profile，代码里不写死事件相关的数字。
    let profile: GroupingProfile
    private let structuralCache = StructuralCache()

    init(records: [ImageRecord], profile: GroupingProfile = .default) {
        self.records = records
        self.profile = profile
        self.count = records.count

        guard count <= Self.eagerMatrixLimit else {
            self.distances = nil
            return
        }

        var matrix = [Float](repeating: .greatestFiniteMagnitude, count: count * count)
        for i in 0..<count {
            matrix[i * count + i] = 0
            guard let lhs = records[i].featurePrint else { continue }
            for j in (i + 1)..<count {
                guard let rhs = records[j].featurePrint else { continue }
                if let distance = try? lhs.distance(to: rhs) {
                    matrix[i * count + j] = Float(distance)
                    matrix[j * count + i] = Float(distance)
                }
            }
        }
        self.distances = matrix
    }

    func distance(_ i: Int, _ j: Int) -> Double {
        if let distances {
            return Double(distances[i * count + j])
        }
        guard let lhs = records[i].featurePrint, let rhs = records[j].featurePrint else {
            return 1
        }
        return (try? lhs.distance(to: rhs)) ?? 1
    }

    func distance(between lhs: ImageRecord, and rhs: ImageRecord) -> Double? {
        guard let left = records.firstIndex(where: { $0 === lhs }),
              let right = records.firstIndex(where: { $0 === rhs }) else {
            return nil
        }
        return distance(left, right)
    }

    func groups(threshold: Double, verdicts: [Int: Bool] = [:]) -> [PhotoGroup] {
        guard count > 0 else { return [] }

        let clusters = distances == nil
            ? onlineClusters(threshold: threshold, verdicts: verdicts)
            : completeLinkClusters(threshold: threshold, verdicts: verdicts)

        var rawGroups = clusters
            .filter { $0.count > 1 }
            .map { indices in indices.map { records[$0] } }

        for members in rawGroups {
            rescoreGroup(members)
        }

        rawGroups.sort { lhs, rhs in
            let left = lhs.map(\.sortKey).sorted(by: naturalCompare).first ?? ""
            let right = rhs.map(\.sortKey).sorted(by: naturalCompare).first ?? ""
            return naturalCompare(left, right)
        }

        return rawGroups.enumerated().map { offset, members in
            let winner = members.max { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.0001 {
                    return lhs.score < rhs.score
                }
                if abs(lhs.sharpness - rhs.sharpness) > 0.0001 {
                    return lhs.sharpness < rhs.sharpness
                }
                return naturalCompare(rhs.sortKey, lhs.sortKey)
            } ?? members[0]

            for member in members {
                member.groupID = offset + 1
                if member === winner {
                    member.distanceToBest = 0
                } else if let winnerIndex = records.firstIndex(where: { $0 === winner }),
                          let memberIndex = records.firstIndex(where: { $0 === member }) {
                    member.distanceToBest = distance(memberIndex, winnerIndex)
                }
            }
            return PhotoGroup(id: offset + 1, records: members, winner: winner)
        }
    }

    /// Small and typical folders: a photo joins a group only when it is similar to
    /// every existing member. This keeps unrelated scenes from chaining together.
    private func completeLinkClusters(threshold: Double, verdicts: [Int: Bool]) -> [[Int]] {
        var clusters: [[Int]] = []

        for index in 0..<count where records[index].signature != nil {
            var bestCluster: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (clusterIndex, members) in clusters.enumerated() {
                var maximumDistance = 0.0
                var compatible = true
                for member in members {
                    guard isSimilar(index, member, threshold: threshold, verdicts: verdicts) else {
                        compatible = false
                        break
                    }
                    maximumDistance = max(maximumDistance, distance(index, member))
                }
                if compatible, maximumDistance < bestDistance {
                    bestDistance = maximumDistance
                    bestCluster = clusterIndex
                }
            }

            if let bestCluster {
                clusters[bestCluster].append(index)
            } else {
                clusters.append([index])
            }
        }
        return clusters
    }

    /// Very large folders: skip the O(n²) matrix and compare each photo only with
    /// the medoid of each existing cluster.
    private func onlineClusters(threshold: Double, verdicts: [Int: Bool]) -> [[Int]] {
        var clusters: [[Int]] = []

        for index in 0..<count where records[index].signature != nil {
            var bestCluster: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (clusterIndex, members) in clusters.enumerated() {
                guard let medoid = members.first else { continue }
                guard isSimilar(index, medoid, threshold: threshold, verdicts: verdicts) else {
                    continue
                }
                let candidate = distance(index, medoid)
                if candidate < bestDistance {
                    bestDistance = candidate
                    bestCluster = clusterIndex
                }
            }

            if let bestCluster {
                clusters[bestCluster].append(index)
            } else {
                clusters.append([index])
            }
        }
        return clusters
    }

    private func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// 低于任何可用阈值都救不回来的相关度，直接判负（省掉细化搜索）。
    private static let earlyExitFloor = 0.65
    private static let resamplePlans = ResamplePlanCache()

    /// 把 `source` 的中心 `zoom` 区域双线性放大到整幅，用来对齐被裁剪/缩放过的副本。
    private static func resample(
        _ source: [UInt8],
        side: Int,
        zoom: Double
    ) -> [UInt8] {
        if zoom >= 0.999 { return source }
        let plan = resamplePlans.plan(side: side, zoom: zoom)
        var output = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            let rowA = plan.y0[y] * side
            let rowB = plan.y1[y] * side
            let wy = plan.wy[y]
            let outRow = y * side
            for x in 0..<side {
                let x0 = plan.x0[x]
                let x1 = plan.x1[x]
                let wx = plan.wx[x]
                let top = Double(source[rowA + x0])
                    + (Double(source[rowA + x1]) - Double(source[rowA + x0])) * wx
                let bottom = Double(source[rowB + x0])
                    + (Double(source[rowB + x1]) - Double(source[rowB + x0])) * wx
                output[outRow + x] = UInt8(
                    clamping: Int((top + (bottom - top) * wy).rounded())
                )
            }
        }
        return output
    }

    /// 像素比对拿不准的照片对（灰区），需要视觉模型给结论。
    func grayBandPairs(threshold: Double) -> [(key: Int, lhs: ImageRecord, rhs: ImageRecord)] {
        guard count > 1, count <= Self.eagerMatrixLimit else { return [] }
        var result: [(key: Int, lhs: ImageRecord, rhs: ImageRecord)] = []
        for lhs in 0..<count where records[lhs].signature != nil {
            for rhs in (lhs + 1)..<count where records[rhs].signature != nil {
                guard isCoarseCandidate(lhs, rhs) else { continue }
                guard let left = records[lhs].signature,
                      let right = records[rhs].signature else { continue }
                let requirement = profile.requirement(
                    threshold: threshold,
                    burstRelaxation: burstRelaxation(lhs, rhs)
                )
                let score = structuralScore(lhs, rhs, left: left, right: right)
                guard needsModel(score, requirement: requirement) else { continue }
                result.append((Self.pairKey(lhs, rhs, count: count), records[lhs], records[rhs]))
            }
        }
        return result
    }

    /// 离线标定用：把所有候选照片对的像素特征导成 TSV。
    func calibrationRows(threshold: Double, root: URL) -> [String] {
        guard count > 1, count <= Self.eagerMatrixLimit else { return [] }
        var rows: [String] = []
        for lhs in 0..<count where records[lhs].signature != nil {
            for rhs in (lhs + 1)..<count where records[rhs].signature != nil {
                guard isCoarseCandidate(lhs, rhs) else { continue }
                guard let left = records[lhs].signature,
                      let right = records[rhs].signature else { continue }
                let score = structuralScore(lhs, rhs, left: left, right: right)
                let requirement = profile.requirement(
                    threshold: threshold,
                    burstRelaxation: burstRelaxation(lhs, rhs)
                )
                let grouped = score.luma >= requirement
                    && score.edge >= requirement - profile.pair.edgeAllowance
                let gap: Double
                if let a = records[lhs].captureDate, let b = records[rhs].captureDate {
                    gap = abs(a.timeIntervalSince(b)).rounded()
                } else {
                    gap = -1
                }
                rows.append(String(
                    format: "%@\t%.1f\t%.1f\t%.1f\t%.4f\t%.4f\t%d\t%@\t%@\t%@",
                    root.path,
                    distance(lhs, rhs),
                    Double(hammingDistance(records[lhs].dHash ?? 0, records[rhs].dHash ?? 0)),
                    gap,
                    score.luma,
                    score.edge,
                    grouped ? 1 : 0,
                    records[lhs].sortKey,
                    records[rhs].sortKey,
                    Self.isBurstNeighbor(records[lhs], records[rhs]) ? "burst" : "-"
                ))
            }
        }
        return rows
    }

    private static func isBurstNeighbor(_ left: ImageRecord, _ right: ImageRecord) -> Bool {
        guard let leftKey = left.sequenceKey, let rightKey = right.sequenceKey,
              leftKey == rightKey,
              let leftNumber = left.sequenceNumber,
              let rightNumber = right.sequenceNumber,
              leftNumber != rightNumber,
              abs(leftNumber - rightNumber) <= 3 else {
            return false
        }
        return true
    }

    static func needsModel(_ score: StructuralScore, requirement: Double) -> Bool {
        GroupingProfile.default.needsModel(score, requirement: requirement)
    }

    func needsModel(_ score: StructuralScore, requirement: Double) -> Bool {
        guard !isIdenticalCopy(score) else { return false }
        return score.luma >= requirement - profile.pair.grayTolerance
            && score.luma <= requirement + profile.pair.confidentMargin
            && score.edge >= requirement - 0.25
    }

    private func isIdenticalCopy(_ score: StructuralScore) -> Bool {
        score.luma >= profile.pair.identicalLuma
            && score.edge >= profile.pair.identicalEdge
    }

    private func isCoarseCandidate(_ lhs: Int, _ rhs: Int) -> Bool {
        let left = records[lhs]
        let right = records[rhs]
        if left.featurePrint != nil, right.featurePrint != nil,
           distance(lhs, rhs) <= profile.pair.featureCutoff {
            return true
        }
        if let a = left.dHash, let b = right.dHash {
            return hammingDistance(a, b) <= profile.pair.hashCutoff
        }
        return false
    }

    private func isSimilar(
        _ lhs: Int,
        _ rhs: Int,
        threshold: Double,
        verdicts: [Int: Bool]
    ) -> Bool {
        let left = records[lhs]
        let right = records[rhs]
        guard let leftSignature = left.signature,
              let rightSignature = right.signature else {
            return false
        }

        guard isCoarseCandidate(lhs, rhs) else { return false }

        let score = structuralScore(
            lhs,
            rhs,
            left: leftSignature,
            right: rightSignature
        )
        let requirement = profile.requirement(
            threshold: threshold,
            burstRelaxation: burstRelaxation(lhs, rhs)
        )
        let pixelVerdict = score.luma >= requirement
            && score.edge >= requirement - profile.pair.edgeAllowance
        if isIdenticalCopy(score) {
            return pixelVerdict
        }
        if let verdict = verdicts[Self.pairKey(lhs, rhs, count: count)],
           needsModel(score, requirement: requirement) {
            return verdict
        }
        return pixelVerdict
    }

    /// 阈值越大表示越宽松；连拍相邻帧可以放宽一点点，但仍需通过像素复核。
    static func structuralRequirement(threshold: Double) -> Double {
        GroupingProfile.default.requirement(threshold: threshold)
    }

    /// 连续编号只是“连拍候选”，像素复核仍然必须通过。
    private func burstRelaxation(_ lhs: Int, _ rhs: Int) -> Double {
        let left = records[lhs]
        let right = records[rhs]
        guard
            let leftKey = left.sequenceKey,
            let rightKey = right.sequenceKey,
            leftKey == rightKey,
            let leftNumber = left.sequenceNumber,
            let rightNumber = right.sequenceNumber,
            leftNumber != rightNumber,
            abs(leftNumber - rightNumber) <= profile.burst.numberGap
        else {
            return 0
        }

        if let leftDate = left.captureDate, let rightDate = right.captureDate {
            return abs(leftDate.timeIntervalSince(rightDate)) <= profile.burst.maxGapSeconds
                ? profile.burst.relaxation
                : 0
        }
        return profile.burst.relaxation * 0.67
    }

    private func structuralScore(
        _ lhs: Int,
        _ rhs: Int,
        left: ThumbnailSignature,
        right: ThumbnailSignature
    ) -> StructuralScore {
        let key = Self.pairKey(lhs, rhs, count: count)
        return structuralCache.score(for: key) {
            Self.compare(left, right, profile: profile)
        }
    }

    /// 照片对的下标哈希，与调用顺序无关。
    private static func pairKey(_ lhs: Int, _ rhs: Int, count: Int) -> Int {
        min(lhs, rhs) * count + max(lhs, rhs)
    }

    /// 先在小图上搜索平移和缩放，再到大图上细化；最后分别比较亮度与梯度结构。
    static func compare(
        _ lhs: ThumbnailSignature,
        _ rhs: ThumbnailSignature,
        profile: GroupingProfile = .default
    ) -> StructuralScore {
        // 1. 粗层：同时搜索平移和缩放，容忍小幅裁剪 / 画幅差异。
        let coarseSide = ThumbnailSignature.coarseSide
        var bestCoarse = -Double.infinity
        var bestLHS = 1.0
        var bestRHS = 1.0
        var coarseOffset = (dx: 0, dy: 0)
        for lhsZoom in profile.pair.zoomLevels {
            let left = resample(lhs.coarse, side: coarseSide, zoom: lhsZoom)
            for rhsZoom in profile.pair.zoomLevels {
                let right = resample(rhs.coarse, side: coarseSide, zoom: rhsZoom)
                let shift = bestShift(
                    left,
                    right,
                    side: coarseSide,
                    radius: 2
                )
                let score = correlation(
                    left,
                    right,
                    side: coarseSide,
                    dx: shift.dx,
                    dy: shift.dy
                )
                if score > bestCoarse {
                    bestCoarse = score
                    bestLHS = lhsZoom
                    bestRHS = rhsZoom
                    coarseOffset = shift
                }
            }
        }

        let baseX = coarseOffset.dx * 4
        let baseY = coarseOffset.dy * 4
        let leftLuma = resample(
            lhs.luma,
            side: ThumbnailSignature.side,
            zoom: bestLHS
        )
        let rightLuma = resample(
            rhs.luma,
            side: ThumbnailSignature.side,
            zoom: bestRHS
        )

        // 2. 细层：在粗层给出的位置上做 ±3 像素的亮度复核。
        let size = ThumbnailSignature.side
        var luma = correlation(
            leftLuma,
            rightLuma,
            side: size,
            dx: baseX,
            dy: baseY
        )
        // 粗层位置上的相关性已经明显不及格，就没有必要细找。
        if luma < Self.earlyExitFloor {
            return StructuralScore(luma: luma, edge: 0)
        }

        var bestX = baseX
        var bestY = baseY
        for dy in (baseY - 3)...(baseY + 3) {
            for dx in (baseX - 3)...(baseX + 3) {
                let candidate = correlation(
                    leftLuma,
                    rightLuma,
                    side: size,
                    dx: dx,
                    dy: dy
                )
                if candidate > luma {
                    luma = candidate
                    bestX = dx
                    bestY = dy
                }
            }
        }

        let leftEdge = resample(lhs.edge, side: size, zoom: bestLHS)
        let rightEdge = resample(rhs.edge, side: size, zoom: bestRHS)
        var edge = -1.0
        for dy in (bestY - 1)...(bestY + 1) {
            for dx in (bestX - 1)...(bestX + 1) {
                let candidate = correlation(
                    leftEdge,
                    rightEdge,
                    side: size,
                    dx: dx,
                    dy: dy
                )
                edge = max(edge, candidate)
            }
        }
        return StructuralScore(luma: luma, edge: edge)
    }

    private static func bestShift(
        _ a: [UInt8],
        _ b: [UInt8],
        side: Int,
        radius: Int
    ) -> (dx: Int, dy: Int) {
        var bestScore = -Double.infinity
        var best = (dx: 0, dy: 0)
        for dy in -radius...radius {
            for dx in -radius...radius {
                let score = correlation(a, b, side: side, dx: dx, dy: dy)
                if score > bestScore {
                    bestScore = score
                    best = (dx, dy)
                }
            }
        }
        return best
    }

    /// 归一化互相关；dx/dy 表示 a(x,y) 对应 b(x+dx, y+dy)。
    private static func correlation(
        _ a: [UInt8],
        _ b: [UInt8],
        side: Int,
        dx: Int,
        dy: Int
    ) -> Double {
        let xStart = max(0, -dx)
        let xEnd = min(side, side - dx)
        let yStart = max(0, -dy)
        let yEnd = min(side, side - dy)
        guard xEnd - xStart >= 8, yEnd - yStart >= 8 else { return -1 }

        var n = 0.0
        var sa = 0.0
        var sb = 0.0
        var saa = 0.0
        var sbb = 0.0
        var sab = 0.0
        for y in yStart..<yEnd {
            let rowA = y * side
            let rowB = (y + dy) * side + dx
            for x in xStart..<xEnd {
                let va = Double(a[rowA + x])
                let vb = Double(b[rowB + x])
                n += 1
                sa += va
                sb += vb
                saa += va * va
                sbb += vb * vb
                sab += va * vb
            }
        }

        let numerator = n * sab - sa * sb
        let denominator = ((n * saa - sa * sa) * (n * sbb - sb * sb)).squareRoot()
        guard denominator > 1e-6 else { return 0 }
        return numerator / denominator
    }

    private func rescoreGroup(_ members: [ImageRecord]) {
        let maxSharpness = members.map(\.sharpnessRaw).max() ?? 0

        for record in members {
            let relativeSharpness = maxSharpness > 0
                ? clamp(sqrt(record.sharpnessRaw / maxSharpness))
                : 0.5
            let aesthetics = record.aesthetics ?? 0.5
            var score: Double

            if record.faceCount > 0, let faceQuality = record.faceQuality {
                score = aesthetics * 0.45
                    + relativeSharpness * 0.27
                    + record.exposure * 0.18
                    + faceQuality * 0.10
            } else {
                score = aesthetics * 0.50
                    + relativeSharpness * 0.30
                    + record.exposure * 0.20
            }
            if record.isUtility {
                score -= 0.15
            }
            record.score = clamp(score)
        }
    }
}

/// 把审阅阶段的人工选择（排除 / 指定最佳）应用到分组结果。
enum GroupEditor {
    static func refine(
        groups: [PhotoGroup],
        distance: (ImageRecord, ImageRecord) -> Double?
    ) -> [PhotoGroup] {
        var refined: [(members: [ImageRecord], winner: ImageRecord)] = []

        for group in groups {
            let members = group.records.filter { !$0.isUserExcluded }
            guard members.count > 1 else { continue }

            let pinned = members.filter(\.isUserWinner)
            let candidates = pinned.isEmpty ? members : pinned
            let winner = candidates.max { isWorse($0, than: $1) } ?? members[0]
            refined.append((members, winner))
        }

        refined.sort { lhs, rhs in
            let left = lhs.members.map(\.sortKey).sorted(by: naturalCompare).first ?? ""
            let right = rhs.members.map(\.sortKey).sorted(by: naturalCompare).first ?? ""
            return naturalCompare(left, right)
        }

        return refined.enumerated().map { offset, entry in
            let id = offset + 1
            for member in entry.members {
                member.groupID = id
                member.isUserWinner = member === entry.winner && member.isUserWinner
                member.distanceToBest = member === entry.winner
                    ? 0
                    : distance(member, entry.winner)
            }
            return PhotoGroup(id: id, records: entry.members, winner: entry.winner)
        }
    }

    private static func isWorse(_ lhs: ImageRecord, than rhs: ImageRecord) -> Bool {
        if abs(lhs.score - rhs.score) > 0.0001 {
            return lhs.score < rhs.score
        }
        if abs(lhs.sharpness - rhs.sharpness) > 0.0001 {
            return lhs.sharpness < rhs.sharpness
        }
        return naturalCompare(rhs.sortKey, lhs.sortKey)
    }
}
