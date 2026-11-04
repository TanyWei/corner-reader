import Foundation
import CoreFoundation

private enum TestFailure: Error { case assertion(String) }

@main
struct ReaderCoreTests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw TestFailure.assertion(message) }
    }

    static func expectFailure(_ operation: () throws -> Void, _ message: String) throws {
        do { try operation() }
        catch is TestFailure { throw TestFailure.assertion(message) }
        catch { return }
        throw TestFailure.assertion(message)
    }

    static func main() throws {
        let sample = "序言 🌙\r\n第一章 初见\r\n　　风吹过小巷。\r\n第二章 夜雨\r\n故事继续。\r\nChapter 3: Dawn\r\nThe end."
        let normalized = sample.replacingOccurrences(of: "\r\n", with: "\n")
        let utf8 = try ReaderText.decode(Data([0xEF, 0xBB, 0xBF]) + Data(sample.utf8), title: " 小说 ")
        try expect(utf8.text == normalized, "UTF-8 BOM or newline normalization failed")
        try expect(utf8.title == "小说", "Title normalization failed")
        try expect(utf8.chapters.count == 3, "Chinese / English chapter detection failed")
        for chapter in utf8.chapters {
            let prefix = (utf8.text as NSString).substring(from: chapter.offset)
            try expect(prefix.hasPrefix(chapter.title), "Chapter offset does not use UTF-16")
        }
        try expect(utf8.chapters[0].offset == ("序言 🌙\n" as NSString).length,
                   "Surrogate pair changed chapter offset")
        try expect(utf8.clampedOffset(-2) == 0, "Negative progress was not clamped")
        try expect(utf8.clampedOffset(Int.max) == utf8.utf16Count, "Large progress was not clamped")
        try expect(utf8.clampedOffset(4) == 3, "Progress splits a surrogate pair")
        print("PASS: UTF-8, newlines, headings, UTF-16 offsets")

        for (bom, encoding) in [([UInt8]([0xFF, 0xFE]), String.Encoding.utf16LittleEndian),
                                ([UInt8]([0xFE, 0xFF]), String.Encoding.utf16BigEndian)] {
            let data = Data(bom) + sample.data(using: encoding)!
            let result = try ReaderText.decode(data, title: "UTF-16")
            try expect(result.text == normalized, "UTF-16 decoding failed")
        }
        let legacy = "第一章 初见\n窗外的风很轻。"
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let legacyBook = try ReaderText.decode(legacy.data(using: gb18030)!, title: "中文")
        try expect(legacyBook.text == legacy, "GB18030 / GBK decoding failed")
        print("PASS: UTF-16 LE/BE and GB18030 / GBK")

        try expectFailure({ _ = try ReaderText.decode(Data(), title: "empty") }, "Empty file accepted")
        try expectFailure({ _ = try ReaderText.decode(Data(" \t\n".utf8), title: "blank") }, "Blank file accepted")
        try expectFailure({ _ = try ReaderText.decode(Data([0x61, 0x00, 0x62]), title: "binary") }, "Binary file accepted")
        try expectFailure({ _ = try ReaderText.decode(Data("%PDF-1.7 fake".utf8), title: "pdf") }, "Renamed PDF accepted")
        try expectFailure({ _ = try ReaderText.decode(Data([0xEF, 0xBB, 0xBF, 0xFF]), title: "broken") },
                          "Malformed BOM text accepted")
        try expectFailure({ _ = try ReaderText.decode(Data(repeating: 0x61, count: ReaderText.maximumFileSize + 1), title: "huge") },
                          "Oversized file accepted")
        print("PASS: empty, binary, malformed and oversized input rejection")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CornerReaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("support")
        let originalURL = root.appendingPathComponent("原书.txt")
        try Data(sample.utf8).write(to: originalURL)
        let store = ReaderStore(directory: storeURL)
        let initial = try store.load()
        try expect(initial.book == nil && initial.progress == 0, "Fresh store should be empty")
        let settings = ReaderPreferences(fontSize: 20, theme: "night", pinned: false)
        let imported = try store.importBook(from: originalURL, preferences: settings)
        try expect(imported.book?.title == "原书", "File title was lost")
        try store.saveProgress(utf8.chapters[1].offset, preferences: settings)
        let restored = try ReaderStore(directory: storeURL).load()
        try expect(restored.book?.text == normalized, "Saved normalized book was not restored")
        try expect(restored.progress == utf8.chapters[1].offset, "Reading position was not restored")
        try expect(restored.preferences == settings, "Preferences were not restored")
        try expect(try Data(contentsOf: originalURL) == Data(sample.utf8), "Original TXT was modified")
        try FileManager.default.removeItem(at: originalURL)
        let copied = try ReaderStore(directory: storeURL).load()
        try expect(copied.book?.text == normalized, "Saved book depended on original path")
        print("PASS: book copy, progress / settings restoration, original preservation")

        let invalidURL = root.appendingPathComponent("坏书.txt")
        try Data([0x00, 0x00]).write(to: invalidURL)
        let metadataBefore = try Data(contentsOf: storeURL.appendingPathComponent("reader-state.json"))
        try expectFailure({ _ = try store.importBook(from: invalidURL) }, "Invalid import succeeded")
        try expect(try Data(contentsOf: storeURL.appendingPathComponent("reader-state.json")) == metadataBefore,
                   "Failed import changed active book")
        let afterFailure = try ReaderStore(directory: storeURL).load()
        try expect(afterFailure.book?.title == "原书", "Failed import lost previous book")
        let replacementURL = root.appendingPathComponent("新书.txt")
        try Data("第一章 新故事\n新的起点。".utf8).write(to: replacementURL)
        let replacement = try store.importBook(from: replacementURL)
        try expect(replacement.progress == 0, "New book inherited old progress")
        try expect(replacement.preferences == settings, "New import discarded preferences")
        let savedCopies = try FileManager.default.contentsOfDirectory(atPath: storeURL.path).filter { $0.hasSuffix(".txt") }
        try expect(savedCopies.count == 1, "More than one active book copy remained")
        try store.saveProgress(Int.max, preferences: ReaderPreferences(fontSize: 200, theme: "paper", pinned: true))
        let bounded = try ReaderStore(directory: storeURL).load()
        try expect(bounded.progress == bounded.book?.utf16Count, "Saved progress was not bounded")
        try expect(bounded.preferences.fontSize == 30, "Invalid font size was not bounded")
        print("PASS: failed import rollback, replacement and bounded state")

        let unsupported = root.appendingPathComponent("image.pdf")
        try Data("text".utf8).write(to: unsupported)
        try expectFailure({ _ = try ReaderText.load(from: unsupported) }, "Non-TXT file accepted")
        let corrupt = root.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("{\"version\":1,\"fileName\":\"../secret.txt\",\"title\":\"x\",\"progress\":0,\"preferences\":{\"fontSize\":17,\"theme\":\"paper\",\"pinned\":true}}".utf8)
            .write(to: corrupt.appendingPathComponent("reader-state.json"))
        try expectFailure({ _ = try ReaderStore(directory: corrupt).load() }, "Metadata path traversal accepted")
        print("PASS: file type restriction and saved path containment")
        print("All ReaderCore tests passed.")
    }
}
