import Foundation
import Vision

struct SimilarityIndex {
    let records: [ImageRecord]
    private let count: Int
    private let distances: [Float]?
    private static let eagerMatrixLimit = 2500

    init(records: [ImageRecord]) {
        self.records = records
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

    func groups(threshold: Double) -> [PhotoGroup] {
        guard count > 0 else { return [] }

        let clusters = distances == nil
            ? onlineClusters(threshold: threshold)
            : completeLinkClusters(threshold: threshold)

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
    private func completeLinkClusters(threshold: Double) -> [[Int]] {
        var clusters: [[Int]] = []

        for index in 0..<count where records[index].featurePrint != nil {
            var bestCluster: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (clusterIndex, members) in clusters.enumerated() {
                var maximumDistance = 0.0
                var compatible = true
                for member in members {
                    guard isSimilar(index, member, threshold: threshold) else {
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
    private func onlineClusters(threshold: Double) -> [[Int]] {
        var clusters: [[Int]] = []

        for index in 0..<count where records[index].featurePrint != nil {
            var bestCluster: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (clusterIndex, members) in clusters.enumerated() {
                guard let medoid = members.first else { continue }
                guard isSimilar(index, medoid, threshold: threshold) else { continue }
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

    private func isSimilar(_ lhs: Int, _ rhs: Int, threshold: Double) -> Bool {
        let contentDistance = distance(lhs, rhs)
        if contentDistance <= threshold {
            return true
        }
        if let a = records[lhs].dHash, let b = records[rhs].dHash {
            if hammingDistance(a, b) <= 4 {
                return true
            }
        }
        if let burstCutoff = burstCutoff(lhs, rhs, threshold: threshold) {
            return contentDistance <= burstCutoff
        }
        return false
    }

    /// 连续编号只是“连拍候选”，仍需内容足够接近；有拍摄时间佐证时放宽更多。
    private func burstCutoff(_ lhs: Int, _ rhs: Int, threshold: Double) -> Double? {
        let left = records[lhs]
        let right = records[rhs]
        guard
            let leftKey = left.sequenceKey,
            let rightKey = right.sequenceKey,
            leftKey == rightKey,
            let leftNumber = left.sequenceNumber,
            let rightNumber = right.sequenceNumber,
            leftNumber != rightNumber,
            abs(leftNumber - rightNumber) <= 3
        else {
            return nil
        }

        if let leftDate = left.captureDate, let rightDate = right.captureDate {
            let gap = abs(leftDate.timeIntervalSince(rightDate))
            if gap <= 10 {
                return min(0.34, threshold + 0.06)
            }
            if gap <= 60 {
                return min(0.32, threshold + 0.04)
            }
            return nil
        }
        return min(0.32, threshold + 0.04)
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
