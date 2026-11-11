import AppKit
import Darwin
import Foundation

enum Ansi {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let green = "\u{1B}[32m"
    static let cyan = "\u{1B}[36m"
    static let yellow = "\u{1B}[33m"
    static let red = "\u{1B}[31m"
    static let gray = "\u{1B}[90m"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let clearScreen = "\u{1B}[2J\u{1B}[H"
}

struct DisplayWidth {
    static func value(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        let value = scalar.value

        if value == 0 || (0x0300...0x036F).contains(value) || (0xFE00...0xFE0F).contains(value) {
            return 0
        }
        if (0x1100...0x115F).contains(value)
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE30...0xFE4F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || value >= 0x1F300 {
            return 2
        }
        return 1
    }

    static func string(_ text: String) -> Int {
        text.reduce(0) { $0 + value(of: $1) }
    }

    static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        var output = ""
        var used = 0
        for character in text {
            let size = value(of: character)
            if used + size > width {
                break
            }
            output.append(character)
            used += size
        }
        return output
    }

    static func pad(_ text: String, to width: Int) -> String {
        let visible = string(text)
        guard visible < width else { return truncate(text, to: width) }
        return text + String(repeating: " ", count: width - visible)
    }
}

let isInteractive = isatty(STDOUT_FILENO) == 1
let isInputTTY = isatty(STDIN_FILENO) == 1

enum Terminal {
    static var isPiped: Bool {
        !isInteractive
    }

    static var width: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
            return Int(size.ws_col)
        }
        if let columns = ProcessInfo.processInfo.environment["COLUMNS"], let value = Int(columns) {
            return value
        }
        return 100
    }

    static var height: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0 {
            return Int(size.ws_row)
        }
        if let lines = ProcessInfo.processInfo.environment["LINES"], let value = Int(lines) {
            return value
        }
        return 30
    }

    static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    static func clear() {
        if isInteractive {
            write(Ansi.clearScreen)
        }
    }

    static func home() {
        if isInteractive {
            write("\u{1B}[H\u{1B}[J")
        }
    }

    static func enterAltScreen() {
        if isInteractive {
            write("\u{1B}[?1049h")
        }
    }

    static func leaveAltScreen() {
        if isInteractive {
            write("\u{1B}[?1049l")
        }
    }

    static func beginFrames() {
        guard isInteractive else { return }
        write(Ansi.hideCursor)
    }

    static func endFrames() {
        guard isInteractive else { return }
        write(Ansi.showCursor)
    }

    static func refreshSize() {
        _ = Terminal.width
        _ = Terminal.height
    }
}

final class RawTerminal {
    private var original: termios?
    private var active = false

    func enable() {
        guard isInputTTY, !active else { return }
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else { return }
        original = settings

        settings.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
        settings.c_iflag &= ~UInt(IXON | ICRNL)
        settings.c_cc.0 = 1
        settings.c_cc.1 = 0
        guard tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0 else { return }
        active = true
        Terminal.write(Ansi.hideCursor)
    }

    func disable() {
        guard active, var settings = original else { return }
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings)
        active = false
        Terminal.write(Ansi.showCursor)
    }

    deinit {
        disable()
    }
}

enum Key {
    case up
    case down
    case left
    case right
    case enter
    case escape
    case space
    case character(Character)
    case control(Character)

    static func read() -> Key? {
        guard let byte = readByte() else { return nil }
        return decode(byte)
    }

    static func read(timeoutMilliseconds: Int32) -> Key? {
        guard let byte = readByte(timeoutMilliseconds: timeoutMilliseconds) else { return nil }
        return decode(byte)
    }

    private static func decode(_ byte: UInt8) -> Key? {
        switch byte {
        case 0x1B:
            guard let second = readByte(timeoutMilliseconds: 25) else { return .escape }
            if second == 0x5B || second == 0x4F {
                guard let third = readByte(timeoutMilliseconds: 25) else { return .escape }
                switch third {
                case 0x41: return .up
                case 0x42: return .down
                case 0x43: return .right
                case 0x44: return .left
                default:
                    var extra: [UInt8] = [third]
                    while let next = readByte(timeoutMilliseconds: 5),
                          !(0x40...0x7E).contains(next) {
                        extra.append(next)
                    }
                    return .character("?")
                }
            }
            return .escape
        case 0x0A, 0x0D:
            return .enter
        case 0x20:
            return .space
        case 0x03:
            return .control("c")
        case 0x04:
            return .control("d")
        case 0x7F, 0x08:
            return .character("⌫")
        default:
            if byte < 0x20 {
                guard let scalar = UnicodeScalar(UInt32(byte) + 0x60) else { return nil }
                return .control(Character(scalar))
            }
            var bytes: [UInt8] = [byte]
            let expectedLength: Int
            if byte & 0xE0 == 0xC0 { expectedLength = 2 }
            else if byte & 0xF0 == 0xE0 { expectedLength = 3 }
            else if byte & 0xF8 == 0xF0 { expectedLength = 4 }
            else { expectedLength = 1 }

            while bytes.count < expectedLength {
                guard let next = readByte(timeoutMilliseconds: 10) else { break }
                bytes.append(next)
            }
            guard let string = String(bytes: bytes, encoding: .utf8), let character = string.first else {
                return nil
            }
            return .character(character)
        }
    }

    private static func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        var byte: UInt8 = 0
        if let timeout = timeoutMilliseconds {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, timeout)
            guard ready > 0 else { return nil }
        }
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }
}

struct Choice {
    let title: String
    let detail: String
    let value: String
}

enum Input {
    static func confirm(_ prompt: String, defaultYes: Bool = true) -> Bool {
        guard isInputTTY else {
            let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if line.isEmpty { return defaultYes }
            return ["y", "yes", "是", "确认"].contains(line.lowercased())
        }

        let terminal = RawTerminal()
        terminal.enable()
        defer { terminal.disable() }

        let suffix = defaultYes ? "[Y/n]" : "[y/N]"
        Terminal.write("\(prompt) \(suffix) ")
        guard let key = Key.read() else {
            Terminal.write("\n")
            return defaultYes
        }
        Terminal.write("\n")
        switch key {
        case .character(let character), .control(let character):
            if character == "y" || character == "Y" { return true }
            if character == "n" || character == "N" { return false }
        case .enter:
            return defaultYes
        default:
            break
        }
        return defaultYes
    }

    static func choose(_ prompt: String, choices: [Choice], selected: Int = 0) -> String? {
        guard isInputTTY, isInteractive else {
            for (index, choice) in choices.enumerated() {
                Terminal.write("  \(index + 1). \(choice.title)\n")
            }
            Terminal.write("\(prompt): ")
            let line = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            if let index = Int(line), choices.indices.contains(index - 1) {
                return choices[index - 1].value
            }
            return choices.first?.value
        }

        let terminal = RawTerminal()
        terminal.enable()
        defer { terminal.disable() }

        var current = min(max(0, selected), max(0, choices.count - 1))
        var drawn = false

        while true {
            if drawn {
                Terminal.home()
            }
            for (index, choice) in choices.enumerated() {
                let marker = index == current ? "\(Ansi.cyan)❯" : " "
                let title = index == current ? "\(Ansi.bold)\(choice.title)\(Ansi.reset)" : choice.title
                Terminal.write("\(marker) \(title)\(Ansi.reset) \(Ansi.gray)\(choice.detail)\(Ansi.reset)\n")
            }
            if !drawn {
                Terminal.write("\(Ansi.gray)\(prompt) (↑↓ 选择, Enter 确认)\(Ansi.reset)")
                drawn = true
            }

            guard let key = Key.read() else { return nil }
            switch key {
            case .up, .character("k"):
                current = (current - 1 + choices.count) % choices.count
            case .down, .character("j"):
                current = (current + 1) % choices.count
            case .enter:
                Terminal.write("\n")
                return choices[current].value
            case .escape, .control("c"):
                return nil
            default:
                break
            }
        }
    }

    static func text(_ prompt: String, initial: String = "") -> String? {
        guard isInputTTY else {
            Terminal.write("\(prompt)\(initial)")
            return readLine()
        }

        let terminal = RawTerminal()
        terminal.enable()
        defer { terminal.disable() }

        var buffer = initial
        while true {
            Terminal.write("\r\u{1B}[2K\(Ansi.bold)\(prompt)\(Ansi.reset)\(buffer)")
            guard let key = Key.read() else { return nil }
            switch key {
            case .enter:
                Terminal.write("\n")
                return buffer
            case .escape, .control("c"):
                Terminal.write("\n")
                return nil
            case .character("⌫"):
                if !buffer.isEmpty { buffer.removeLast() }
            case .character(let character):
                buffer.append(character)
            case .control("u"):
                buffer = ""
            case .control("w"):
                while buffer.last?.isWhitespace == true { buffer.removeLast() }
                while let last = buffer.last, !last.isWhitespace { buffer.removeLast() }
            default:
                break
            }
        }
    }
}

enum FolderChooser {
    static func choose(startingAt folder: URL) -> URL? {
        Terminal.write("正在打开文件夹选择框…\n")

        let script: String
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") != nil {
            script = """
            tell application "Finder"
                activate
                set startFolder to POSIX file "\(AppleScriptEscaper.escape(folder.path))" as alias
                set chosenFolder to choose folder with prompt "选择要整理的图片文件夹" default location startFolder
                return POSIX path of chosenFolder
            end tell
            """
        } else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

enum AppleScriptEscaper {
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
