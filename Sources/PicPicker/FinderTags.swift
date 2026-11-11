import Darwin
import Foundation

enum FinderTags {
    static let green = "Green\n2"
    static let red = "Red\n6"
    static let yellow = "Yellow\n5"
    private static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    static func read(from url: URL) -> [String] {
        let path = url.path
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return [] }

        var data = Data(count: size)
        let readSize = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return getxattr(path, attributeName, base, size, 0, 0)
        }
        guard readSize > 0 else { return [] }
        if readSize < data.count {
            data = data.prefix(readSize)
        }

        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let tags = plist as? [String]
        else {
            return []
        }
        return tags
    }

    static func write(_ tags: [String], to url: URL) throws {
        let path = url.path

        if tags.isEmpty {
            let result = removexattr(path, attributeName, 0)
            if result != 0, errno != ENOATTR, errno != ENODATA {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: tags,
            format: .binary,
            options: 0
        )
        let result = data.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return setxattr(path, attributeName, base, data.count, 0, 0)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    @discardableResult
    static func addGreen(to url: URL) throws -> Bool {
        var tags = read(from: url)
        let alreadyGreen = tags.contains { tag in
            tag.split(separator: "\n", maxSplits: 1).first.map(String.init) == "Green"
        }
        guard !alreadyGreen else { return false }
        tags.append(green)
        try write(tags, to: url)
        return true
    }

    static func removeGreen(from url: URL) throws {
        let tags = read(from: url).filter { tag in
            tag.split(separator: "\n", maxSplits: 1).first.map(String.init) != "Green"
        }
        try write(tags, to: url)
    }

    @discardableResult
    static func addRed(to url: URL) throws -> Bool {
        var tags = read(from: url)
        let alreadyRed = tags.contains { tag in
            tag.split(separator: "\n", maxSplits: 1).first.map(String.init) == "Red"
        }
        guard !alreadyRed else { return false }
        tags.append(red)
        try write(tags, to: url)
        return true
    }

    static func removeRed(from url: URL) throws {
        let tags = read(from: url).filter { tag in
            tag.split(separator: "\n", maxSplits: 1).first.map(String.init) != "Red"
        }
        try write(tags, to: url)
    }

    @discardableResult
    static func addYellow(to url: URL) throws -> Bool {
        var tags = read(from: url)
        let alreadyYellow = tags.contains { tag in
            tag.split(separator: "\n", maxSplits: 1).first.map(String.init) == "Yellow"
        }
        guard !alreadyYellow else { return false }
        tags.append(yellow)
        try write(tags, to: url)
        return true
    }
}
