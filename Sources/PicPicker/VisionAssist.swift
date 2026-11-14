import CoreGraphics
import Foundation
import ImageIO

/// 本机视觉模型（OpenAI 兼容接口）的配置。
struct VisionConfiguration: Sendable {
    var endpoint: URL
    var model: String = "default"
    var timeout: TimeInterval = 45
    var maxCalls: Int = 400
    var concurrency: Int = 4
    /// 是否用模型复核灰区照片对（慢，默认关闭；文档判定始终启用）。
    var verifiesPairs = false
    /// 发给模型的图片最长边。太小会看不清人物姿势，太大又拖慢请求。
    var imageMaxPixel: Int = 1024
}

/// 需要模型裁决的一对照片。
struct VisionPair: Sendable {
    let key: Int
    let lhs: ImageRecord
    let rhs: ImageRecord
}

/// 一轮视觉复核的结果。
struct VisionOutcome: Sendable {
    var verdicts: [Int: Bool] = [:]
    var attempted = 0
    /// 请求失败（服务没起来、超时、答非所问）。
    var failed = 0
    /// 两次提问结论不一致、交回像素判定的对数。
    var uncertain = 0
    var truncated = false
}

/// 单对照片的复核结论。
private enum ShotVerdict {
    case same
    case different
    case uncertain
    case failed
}

/// 文档/截图红标的复核结果。
struct DocumentReview: Sendable {
    /// 模型认为其实是真实场景、应当撤销红标的照片。
    var realScene: Set<ObjectIdentifier> = []
    var confirmed = 0
    var failed = 0
}

/// 用本机多模态模型复核“这两张是不是同一次按快门”。
///
/// 运行时默认不启用；主要用途是离线标定数据（见 tools/label_pairs.py），
/// 以及在需要时复核文档/截图红标。
final class VisionAssist: @unchecked Sendable {
    let configuration: VisionConfiguration
    private let session: URLSession

    init(configuration: VisionConfiguration) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout
        config.httpMaximumConnectionsPerHost = max(1, configuration.concurrency)
        self.session = URLSession(configuration: config)
    }

    var endpointDescription: String {
        "\(configuration.endpoint.absoluteString) (\(configuration.model))"
    }

    /// 请求体里的模型名。用户没显式指定时，先问服务端 `/v1/models`。
    private func resolveModel() async -> String {
        if configuration.model != "default" { return configuration.model }
        var resolved = configuration.model
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("models"))
        request.httpMethod = "GET"
        if let (data, response) = try? await session.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [[String: Any]],
           let first = list.first?["id"] as? String,
           !first.isEmpty {
            resolved = first
        }
        return resolved
    }

    /// 并发询问若干照片对；返回 key -> 是否同一张照片。
    func verify(
        pairs: [VisionPair],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> VisionOutcome {
        guard !pairs.isEmpty else { return VisionOutcome() }
        let model = await resolveModel()
        let limited = Array(pairs.prefix(configuration.maxCalls))
        var outcome = VisionOutcome(attempted: limited.count)
        outcome.truncated = limited.count < pairs.count
        var completed = 0
        let total = limited.count

        await withTaskGroup(of: (Int, ShotVerdict).self) { group in
            var next = 0
            let width = max(1, min(configuration.concurrency, total))
            for _ in 0..<width {
                let pair = limited[next]
                next += 1
                group.addTask { [self] in (pair.key, await sameShot(pair, model: model)) }
            }
            while let (key, verdict) = await group.next() {
                completed += 1
                onProgress?(completed, total)
                switch verdict {
                case .same:
                    outcome.verdicts[key] = true
                case .different:
                    outcome.verdicts[key] = false
                case .uncertain:
                    outcome.uncertain += 1
                case .failed:
                    outcome.failed += 1
                }
                if next < total {
                    let pair = limited[next]
                    next += 1
                    group.addTask { [self] in (pair.key, await sameShot(pair, model: model)) }
                }
            }
        }
        return outcome
    }

    /// 复核“文档/截图”红标：模型说是真实场景的，撤销红标让它照常参与选片。
    func reviewDocumentFlags(
        _ records: [ImageRecord],
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> DocumentReview {
        guard !records.isEmpty else { return DocumentReview() }
        let model = await resolveModel()
        var review = DocumentReview()
        let limited = Array(records.prefix(configuration.maxCalls))
        var completed = 0
        let total = limited.count

        await withTaskGroup(of: (ObjectIdentifier, Bool?).self) { group in
            var next = 0
            let width = max(1, min(configuration.concurrency, total))
            for _ in 0..<width {
                let record = limited[next]
                next += 1
                group.addTask { [self] in
                    (ObjectIdentifier(record), await looksLikeDocument(record, model: model))
                }
            }
            while let (id, isDocument) = await group.next() {
                completed += 1
                onProgress?(completed, total)
                switch isDocument {
                case true:
                    review.confirmed += 1
                case false:
                    review.realScene.insert(id)
                case nil:
                    review.failed += 1
                }
                if next < total {
                    let record = limited[next]
                    next += 1
                    group.addTask { [self] in
                        (ObjectIdentifier(record), await looksLikeDocument(record, model: model))
                    }
                }
            }
        }
        return review
    }

    /// 返回 nil 表示没拿到答案。
    private func looksLikeDocument(_ record: ImageRecord, model: String) async -> Bool? {
        guard let data = imageData(for: record, maxPixel: 768) else { return nil }
        let prompt = "这张照片的主体是：（A）屏幕/投影/黑板/纸张上的文字或界面；"
            + "（B）真实的人、物或活动场景。只回答 A 或 B。"
        let content: [[String: Any]] = [
            ["type": "text", "text": prompt],
            imageContent(data)
        ]
        guard let answer = await chat(content: content, model: model, maxTokens: 6) else {
            return nil
        }
        return Self.styleAnswer(answer)
    }

    /// A → 文档/屏幕；B → 真实场景。
    static func styleAnswer(_ text: String) -> Bool? {
        let upper = text.uppercased()
        for character in upper {
            if character == "A" { return true }
            if character == "B" { return false }
        }
        return nil
    }

    /// 同一对照片问两次、顺序互换：两个方向结论一致才采纳，不一致就交回像素判定。
    /// 小模型在同场景不同瞬间的照片上很容易受图片顺序影响，这一步专门挡这种抖动。
    private func sameShot(_ pair: VisionPair, model: String) async -> ShotVerdict {
        guard let lhs = imageData(for: pair.lhs),
              let rhs = imageData(for: pair.rhs) else {
            return .failed
        }
        async let forward = ask(lhs: lhs, rhs: rhs, model: model)
        async let backward = ask(lhs: rhs, rhs: lhs, model: model)
        let answers = await (forward, backward)
        switch (answers.0, answers.1) {
        case (nil, nil):
            return .failed
        case (let first?, let second?):
            if first != second { return .uncertain }
            return first ? .same : .different
        case (let answer?, nil), (nil, let answer?):
            return answer ? .same : .different
        }
    }

    private func ask(lhs: Data, rhs: Data, model: String) async -> Bool? {
        let prompt = """
        下面两张照片可能来自同一次按快门。请只比较画面内容：允许轻微裁剪、缩放、亮度或颜色差异、降噪、重新压缩；\
        人物或物体的姿势、位置、朝向完全一致才回答 YES；只是同一个场景但姿势、位置已经变了回答 NO；不确定时回答 NO。\
        只输出 YES 或 NO。
        """
        let content: [[String: Any]] = [
            ["type": "text", "text": prompt],
            imageContent(lhs),
            imageContent(rhs)
        ]
        guard let answer = await chat(content: content, model: model) else { return nil }
        return Self.parseYesNo(answer)
    }

    private func imageContent(_ data: Data) -> [String: Any] {
        [
            "type": "image_url",
            "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]
        ]
    }

    private func chat(
        content: [[String: Any]],
        model: String,
        maxTokens: Int = 24
    ) async -> String? {
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
            "temperature": 0,
            "max_tokens": maxTokens,
            "stream": false
        ]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    static func parseYesNo(_ text: String) -> Bool? {
        let upper = text.uppercased()
        if upper.contains("YES") || upper.contains("TRUE") { return true }
        // 否定要先判：中文“不是”里也含有“是”。
        if upper.contains("NO") || upper.contains("FALSE")
            || text.contains("不是") || text.contains("并非") || text.contains("否") {
            return false
        }
        return text.contains("是") ? true : nil
    }

    /// 读原图缩略图再压成 JPEG；视觉模型不需要高分辨率。
    private func imageData(for record: ImageRecord, maxPixel: Int? = nil) -> Data? {
        guard let source = CGImageSourceCreateWithURL(record.url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? configuration.imageMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// 规范化用户填写的地址：允许 `127.0.0.1:8080`、`http://host:port/v1` 等写法。
    static func normalizeEndpoint(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") {
            text.removeLast()
        }
        if !text.lowercased().hasSuffix("/v1") {
            text += "/v1"
        }
        return URL(string: text)
    }
}
