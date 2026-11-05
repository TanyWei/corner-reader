import Foundation

private enum WindowTestFailure: Error { case assertion(String) }

@main
struct ReaderTextWindowTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw WindowTestFailure.assertion(message) }
    }

    static func book(_ text: String) -> ReaderBook {
        ReaderBook(title: "窗口测试", text: text, chapters: ReaderText.chapters(in: text))
    }

    static func check(_ slice: ReaderTextWindow, in book: ReaderBook, anchor: Int) throws {
        let source = book.text as NSString
        try expect(slice.range.location >= 0 && NSMaxRange(slice.range) <= source.length,
                   "Window escaped the full book")
        try expect(slice.text == source.substring(with: slice.range), "Window text changed original content")
        try expect(source.rangeOfComposedCharacterSequences(for: slice.range) == slice.range,
                   "Window boundary splits a composed character")
        let safeAnchor = book.clampedOffset(anchor)
        guard let localAnchor = slice.localOffset(forGlobal: safeAnchor) else {
            throw WindowTestFailure.assertion("Requested anchor is outside its window")
        }
        try expect(slice.globalOffset(forLocal: localAnchor) == safeAnchor, "Anchor mapping did not round-trip")
        try expect(slice.localOffset(forGlobal: slice.range.location) == 0, "Window start is not addressable")
        try expect(slice.localOffset(forGlobal: NSMaxRange(slice.range)) == slice.range.length,
                   "Window end insertion position is not addressable")
        try expect(slice.localOffset(forGlobal: slice.range.location - 1) == nil, "Offset before window was accepted")
        try expect(slice.localOffset(forGlobal: NSMaxRange(slice.range) + 1) == nil, "Offset after window was accepted")
        try expect(slice.globalOffset(forLocal: Int.min) == slice.range.location, "Negative local offset did not clamp")
        try expect(slice.globalOffset(forLocal: Int.max) == NSMaxRange(slice.range), "Large local offset did not clamp")
    }

    static func main() throws {
        let small = book("第一章\n风吹过。👨‍👩‍👧‍👦 e\u{301}")
        for anchor in [Int.min, 0, 1, small.utf16Count, Int.max] {
            let slice = small.window(aroundGlobalOffset: anchor)
            try expect(slice.text == small.text, "Small book must remain an exact full string")
            try expect(slice.range == NSRange(location: 0, length: small.utf16Count), "Small book range is incorrect")
            try check(slice, in: small, anchor: anchor)
        }
        let empty = book("").window(aroundGlobalOffset: Int.max)
        try expect(empty.range == NSRange(location: 0, length: 0) && empty.text.isEmpty, "Empty book window failed")
        try expect(empty.localOffset(forGlobal: 0) == 0 && empty.globalOffset(forLocal: 100) == 0,
                   "Empty insertion point failed")
        print("PASS: small and empty books, beginning / end / out-of-range anchors")

        let plain = book(String(repeating: "abcdefghij", count: 10_000))
        try expect(plain.chapters.isEmpty, "Plain fixture unexpectedly has chapters")
        for anchor in [Int.min, 0, 1, 64, 40_000, 99_999, 100_000, Int.max] {
            let slice = plain.window(aroundGlobalOffset: anchor, targetLength: 129, boundarySlack: 64)
            try expect(slice.range.length == 129, "Long unbroken paragraph expanded beyond target")
            try check(slice, in: plain, anchor: anchor)
            for local in 0...slice.range.length {
                let global = slice.globalOffset(forLocal: local)
                try expect(slice.localOffset(forGlobal: global) == local, "UTF-16 offset did not round-trip")
            }
        }
        for (target, slack) in [(0, -1), (-1, 0), (Int.min, Int.min), (Int.max, Int.max)] {
            let slice = plain.window(aroundGlobalOffset: Int.max, targetLength: target, boundarySlack: slack)
            try check(slice, in: plain, anchor: Int.max)
            try expect(slice.range.length == (target <= 0 ? 1 : plain.utf16Count), "Extreme budgets are not bounded")
        }
        print("PASS: no-heading long paragraph, offset round-trip and extreme budgets")

        let lines = book("第1章 初见\n" + String(repeating: "青石路边的花开了。\n", count: 1_000))
        for anchor in stride(from: 0, through: lines.utf16Count, by: 37) {
            let slice = lines.window(aroundGlobalOffset: anchor, targetLength: 81, boundarySlack: 12)
            try check(slice, in: lines, anchor: anchor)
            let source = lines.text as NSString
            try expect(slice.range.length <= 81 + 24, "Chinese newline window exceeded its budget")
            try expect(slice.range.location == 0 || source.character(at: slice.range.location - 1) == 0x0A,
                       "Available nearby paragraph start was not used")
            try expect(NSMaxRange(slice.range) == source.length || source.character(at: NSMaxRange(slice.range) - 1) == 0x0A,
                       "Available nearby paragraph end was not used")
        }
        let exactBoundary = book(String(repeating: "A", count: 12) + "\n" + String(repeating: "B", count: 20) + "\n" + String(repeating: "C", count: 12))
        try expect(exactBoundary.window(aroundGlobalOffset: 23, targetLength: 10, boundarySlack: 6).range == NSRange(location: 13, length: 21),
                   "Bounded newline expansion chose incorrect endpoints")
        try expect(exactBoundary.window(aroundGlobalOffset: 23, targetLength: 10, boundarySlack: 5).range == NSRange(location: 18, length: 10),
                   "Newline search exceeded its permitted slack")
        print("PASS: Chinese paragraphs and strictly bounded newline searches")

        let unicodePattern = "汉🙂e\u{301}👨‍👩‍👧‍👦🇨🇳👍🏽末"
        let unicode = book(String(repeating: unicodePattern, count: 120))
        let maxCluster = unicodePattern.map { String($0).utf16.count }.max()!
        for target in [1, 2, 3, 7, 16, 129] {
            for anchor in stride(from: 0, through: unicode.utf16Count, by: 3) {
                let slice = unicode.window(aroundGlobalOffset: anchor, targetLength: target, boundarySlack: 0)
                try check(slice, in: unicode, anchor: anchor)
                try expect(slice.range.length <= target + 2 * maxCluster,
                           "Unicode window expanded beyond its boundary graphemes")
            }
        }
        let giantCluster = book("a" + String(repeating: "\u{301}", count: 100) + "b")
        let wholeCluster = giantCluster.window(aroundGlobalOffset: 55, targetLength: 1, boundarySlack: 0)
        try expect(wholeCluster.range == NSRange(location: 0, length: 101), "Long combining sequence was split")
        try check(wholeCluster, in: giantCluster, anchor: 55)
        print("PASS: surrogate pairs, combining marks, emoji ZWJ / flags / modifiers")

        let original = lines
        let large = book(String(repeating: "长段没有换行。👩🏽‍🚀", count: 80_000))
        let maxLargeCluster = "长段没有换行。👩🏽‍🚀".map { String($0).utf16.count }.max()!
        for anchor in stride(from: 0, through: large.utf16Count, by: 13_101) {
            let slice = large.window(aroundGlobalOffset: anchor)
            try check(slice, in: large, anchor: anchor)
            try expect(slice.range.length <= 16_384 + 2 * 512 + 2 * maxLargeCluster,
                       "Default render window scaled with full book length")
        }
        for anchor in stride(from: 0, through: lines.utf16Count, by: 31) {
            _ = lines.window(aroundGlobalOffset: anchor, targetLength: 17, boundarySlack: 4)
        }
        try expect(lines == original, "Window construction changed full book, title or chapters")
        print("PASS: stable default maximum on a large book; full book / title / chapters unchanged")
        print("All ReaderTextWindow tests passed.")
    }
}
