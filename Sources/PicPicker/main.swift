import Darwin
import Foundation

let options = Options.parse(CommandLine.arguments)
Preprocess.isoLimit = options.isoLimit
Preprocess.blurRelativeCutoff = options.blurRatio
Preprocess.eyeClosedRatio = options.eyeRatio

if options.showHelp {
    print(Options.usage)
    exit(0)
}

if options.dryRun && options.apply {
    FileHandle.standardError.write(Data("--dry-run 与 --apply 不能同时使用\n".utf8))
    exit(2)
}

signal(SIGPIPE, SIG_IGN)

var folder = options.folder
if folder == nil {
    let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: candidate,
        includingPropertiesForKeys: nil
    )) ?? []
    if contents.contains(where: {
        ImageScanner.supportedExtensions.contains($0.pathExtension.lowercased())
    }) {
        folder = candidate
    }
}

let model = AppModel(
    threshold: options.threshold,
    autoApply: options.apply || (!isInteractive && !options.dryRun),
    jsonOutput: options.json,
    dryRun: options.dryRun,
    preferRaw: options.preferRaw,
    cameraBlur: !options.globalBlur,
    visionConfiguration: options.vlmEndpoint.map {
        VisionConfiguration(
            endpoint: $0,
            model: options.vlmModel,
            verifiesPairs: options.vlmPairs
        )
    },
    dumpPairsPath: options.dumpPairsPath,
    groupingProfile: GroupingProfile.load(path: options.profilePath)
)

if folder == nil, !isInteractive, !options.undo {
    FileHandle.standardError.write(Data("非交互模式需要使用 --folder 指定文件夹\n".utf8))
    exit(2)
}

if options.undo {
    guard let folder = folder ?? (isInteractive ? TUI.defaultFolder() : nil) else {
        FileHandle.standardError.write(Data("撤销需要 --folder 指定文件夹\n".utf8))
        exit(2)
    }
    do {
        let report = try FileActions.undo(folder: folder)
        if report.failures.isEmpty {
            print("已撤销 \(report.restored.count) 个文件名。")
        } else {
            print("已撤销 \(report.restored.count) 个文件，\(report.failures.count) 个失败：")
            for failure in report.failures {
                print("  - \(failure)")
            }
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("撤销失败: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}

if let folder {
    let isDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    guard isDirectory else {
        FileHandle.standardError.write(Data("不是有效文件夹: \(folder.path)\n".utf8))
        exit(2)
    }
    model.start(folder: folder)
}

let status = TUI.runMain(model: model, options: options)
exit(status)
