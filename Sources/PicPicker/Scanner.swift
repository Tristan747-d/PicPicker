import Foundation

enum ImageScanner {
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "srw"
    ]

    static func scan(folder: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if values.isSymbolicLink == true || url.lastPathComponent == Preprocess.blurryFolderName {
                    enumerator.skipDescendants()
                }
                continue
            }

            let ext = url.pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else { continue }
            guard values.isRegularFile == true, values.isHidden != true else { continue }
            result.append(url)
        }

        return result.sorted {
            naturalCompare(relativePath(of: $0, in: folder), relativePath(of: $1, in: folder))
        }
    }
}

func relativePath(of url: URL, in base: URL) -> String {
    let basePath = base.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == basePath {
        return ""
    }
    if path.hasPrefix(basePath + "/") {
        return String(path.dropFirst(basePath.count + 1))
    }
    return url.lastPathComponent
}

func relativeDirectory(of url: URL, in base: URL) -> String {
    relativePath(of: url.deletingLastPathComponent(), in: base)
}

/// RAW+JPG 同名配对：同目录、同文件名（不含扩展名）时，只分析 RAW。
enum RawPairing {
    struct Split {
        var urls: [URL]
        /// RAW 标准化路径 → 需要跟随改名的 JPG。
        var companions: [String: [URL]]
    }

    static func split(_ urls: [URL]) -> Split {
        var byKey: [String: (raw: [URL], jpeg: [URL])] = [:]
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            let key = url.deletingLastPathComponent().standardizedFileURL.path + "|" + base
            if ImageRecord.rawExtensions.contains(ext) {
                byKey[key, default: ([], [])].raw.append(url)
            } else if ImageRecord.jpegExtensions.contains(ext) {
                byKey[key, default: ([], [])].jpeg.append(url)
            }
        }

        var companions: [String: [URL]] = [:]
        var pairedJPEGs = Set<URL>()
        for pair in byKey.values {
            guard pair.raw.count == 1, let raw = pair.raw.first else { continue }
            companions[raw.standardizedFileURL.path] = pair.jpeg
            pairedJPEGs.formUnion(pair.jpeg)
        }

        return Split(
            urls: urls.filter { !pairedJPEGs.contains($0) },
            companions: companions
        )
    }
}
