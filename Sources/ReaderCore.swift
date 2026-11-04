import Foundation
import CoreFoundation

enum ReaderCoreError: LocalizedError {
    case unsupportedFile
    case tooLarge
    case empty
    case invalidText
    case invalidSavedBook

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "请选择一个 TXT 小说文件。"
        case .tooLarge: return "文件超过 50 MB，请先拆分为较小的 TXT 文件。"
        case .empty: return "这个文件没有可阅读的文字。"
        case .invalidText: return "无法识别文字编码，或文件不是纯文本。请使用 UTF-8、UTF-16 或 GB18030 编码的 TXT 文件。"
        case .invalidSavedBook: return "上次保存的阅读记录无法读取，请重新导入 TXT 文件。"
        }
    }
}

struct ReaderChapter: Equatable {
    let title: String
    /// A UTF-16 character offset, matching NSTextView and NSRange.
    let offset: Int
}

struct ReaderBook: Equatable {
    let title: String
    let text: String
    let chapters: [ReaderChapter]

    var utf16Count: Int { text.utf16.count }

    func clampedOffset(_ offset: Int) -> Int {
        let bounded = min(max(offset, 0), utf16Count)
        guard bounded < utf16Count else { return bounded }
        return (text as NSString).rangeOfComposedCharacterSequence(at: bounded).location
    }
}

struct ReaderPreferences: Codable, Equatable {
    var fontSize: Double = 17
    var theme: String = "paper"
    var pinned: Bool = true

    fileprivate var sanitized: ReaderPreferences {
        ReaderPreferences(
            fontSize: fontSize.isFinite ? min(max(fontSize, 12), 30) : 17,
            theme: theme.isEmpty || theme.count > 64 ? "paper" : theme,
            pinned: pinned
        )
    }
}

struct ReaderState {
    let book: ReaderBook?
    let progress: Int
    let preferences: ReaderPreferences
}

enum ReaderText {
    static let maximumFileSize = 50 * 1_024 * 1_024

    static func load(from url: URL) throws -> ReaderBook {
        guard url.isFileURL, url.pathExtension.lowercased() == "txt" else {
            throw ReaderCoreError.unsupportedFile
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ReaderCoreError.unsupportedFile }
        guard (values.fileSize ?? 0) <= maximumFileSize else { throw ReaderCoreError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decode(data, title: url.deletingPathExtension().lastPathComponent)
    }

    static func decode(_ data: Data, title: String) throws -> ReaderBook {
        guard data.count <= maximumFileSize else { throw ReaderCoreError.tooLarge }
        guard !data.isEmpty else { throw ReaderCoreError.empty }
        let bytes = [UInt8](data.prefix(8))
        let decoded: String?
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(4), encoding: .utf32BigEndian)
        } else if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            decoded = String(data: data.dropFirst(4), encoding: .utf32LittleEndian)
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else {
            let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            ))
            decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030)
        }
        guard let decoded else { throw ReaderCoreError.invalidText }
        // Binary files can contain valid byte sequences for legacy text encodings.
        guard !decoded.unicodeScalars.contains(where: {
            ($0.value < 0x20 && ![0x09, 0x0A, 0x0D].contains($0.value)) ||
            (0x7F...0x9F).contains($0.value)
        }) else { throw ReaderCoreError.invalidText }
        let binaryHeaders: [[UInt8]] = [
            [0x25, 0x50, 0x44, 0x46, 0x2D], // PDF
            [0x50, 0x4B, 0x03, 0x04],       // ZIP / Office / EPUB
            [0x89, 0x50, 0x4E, 0x47],       // PNG
            [0xFF, 0xD8, 0xFF],             // JPEG
            [0x47, 0x49, 0x46, 0x38]        // GIF
        ]
        guard !binaryHeaders.contains(where: { bytes.starts(with: $0) }) else {
            throw ReaderCoreError.invalidText
        }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReaderCoreError.empty
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReaderBook(title: cleanTitle.isEmpty ? "未命名小说" : cleanTitle,
                          text: text, chapters: chapters(in: text))
    }

    static func chapters(in text: String) -> [ReaderChapter] {
        let pattern = #"(?im)^[\t \u3000]*(第[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+[章回卷部节集篇][^\n]{0,80}|chapter[\t ]+(?:[0-9]+|[ivxlcdm]+|one|two|three|four|five|six|seven|eight|nine|ten)(?:[\t .:：—-][^\n]{0,80})?)[\t \u3000]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            let range = $0.range(at: 1)
            return ReaderChapter(title: source.substring(with: range).trimmingCharacters(in: .whitespaces),
                                 offset: range.location)
        }
    }
}

/// Owns only files inside this app's support directory. Original TXT files are never modified.
final class ReaderStore {
    let directory: URL
    private let fileManager = FileManager.default
    private var cachedMetadata: StoredMetadata?
    private var cachedBook: ReaderBook?
    private var loaded = false

    private struct StoredMetadata: Codable {
        var version: Int = 1
        var fileName: String?
        var title: String = ""
        var progress: Int = 0
        var preferences: ReaderPreferences = ReaderPreferences()
    }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                               in: .userDomainMask)[0]
            .appendingPathComponent("CornerReader", isDirectory: true)
    }

    func load() throws -> ReaderState {
        let metadata = try readMetadata() ?? StoredMetadata()
        let book: ReaderBook?
        if let fileName = metadata.fileName {
            guard isOwnedBookFile(fileName) else { throw ReaderCoreError.invalidSavedBook }
            let data = try Data(contentsOf: directory.appendingPathComponent(fileName), options: .mappedIfSafe)
            book = try ReaderText.decode(data, title: metadata.title)
        } else {
            book = nil
        }
        cachedMetadata = metadata
        cachedBook = book
        loaded = true
        return ReaderState(book: book, progress: book?.clampedOffset(metadata.progress) ?? 0,
                           preferences: metadata.preferences.sanitized)
    }

    @discardableResult
    func importBook(from url: URL, preferences: ReaderPreferences? = nil) throws -> ReaderState {
        // Validation happens before touching any saved state.
        let book = try ReaderText.load(from: url)
        let previous = cachedMetadata ?? (try? readMetadata()) ?? StoredMetadata()
        let fileName = "book-\(UUID().uuidString).txt"
        let copyURL = directory.appendingPathComponent(fileName)
        let metadata = StoredMetadata(fileName: fileName, title: book.title, progress: 0,
                                      preferences: (preferences ?? previous.preferences).sanitized)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data(book.text.utf8).write(to: copyURL, options: .atomic)
            try writeMetadata(metadata)
        } catch {
            try? fileManager.removeItem(at: copyURL)
            throw error
        }
        // Commit the new book first; deletion is limited to the previous app-owned copy.
        if let oldName = previous.fileName, isOwnedBookFile(oldName), oldName != fileName {
            try? fileManager.removeItem(at: directory.appendingPathComponent(oldName))
        }
        cachedMetadata = metadata
        cachedBook = book
        loaded = true
        return ReaderState(book: book, progress: 0, preferences: metadata.preferences)
    }

    func saveProgress(_ offset: Int, preferences: ReaderPreferences) throws {
        if !loaded { _ = try load() }
        var metadata = cachedMetadata ?? StoredMetadata()
        metadata.progress = cachedBook?.clampedOffset(offset) ?? 0
        metadata.preferences = preferences.sanitized
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeMetadata(metadata)
        cachedMetadata = metadata
    }

    private var metadataURL: URL { directory.appendingPathComponent("reader-state.json") }

    private func readMetadata() throws -> StoredMetadata? {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return nil }
        let metadata = try JSONDecoder().decode(StoredMetadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.version == 1 else { throw ReaderCoreError.invalidSavedBook }
        return metadata
    }

    private func writeMetadata(_ metadata: StoredMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private func isOwnedBookFile(_ name: String) -> Bool {
        name == URL(fileURLWithPath: name).lastPathComponent &&
        name.hasPrefix("book-") && name.hasSuffix(".txt") && !name.contains("..")
    }
}
