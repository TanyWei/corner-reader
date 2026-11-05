import Foundation

/// A bounded rendering slice. The range always refers to the unchanged full book.
struct ReaderTextWindow: Equatable {
    let range: NSRange
    let text: String

    /// Includes the insertion position immediately after this window's last character.
    func localOffset(forGlobal offset: Int) -> Int? {
        guard offset >= range.location, offset <= NSMaxRange(range) else { return nil }
        return offset - range.location
    }

    /// NSTextView offsets stay in UTF-16; out-of-window positions clamp to either edge.
    func globalOffset(forLocal offset: Int) -> Int {
        range.location + min(max(offset, 0), range.length)
    }
}

extension ReaderBook {
    /// The target can grow by at most two boundary slacks, plus the graphemes crossing
    /// its edges. Paragraph searches are bounded even for a book with no line breaks.
    func window(aroundGlobalOffset offset: Int,
                targetLength: Int = 16_384,
                boundarySlack: Int = 512) -> ReaderTextWindow {
        let source = text as NSString
        let count = source.length
        guard count > 0 else {
            return ReaderTextWindow(range: NSRange(location: 0, length: 0), text: "")
        }
        let target = min(max(targetLength, 1), count)
        if count <= target {
            return ReaderTextWindow(range: NSRange(location: 0, length: count), text: text)
        }

        let slack = min(max(boundarySlack, 0), count)
        let anchor = clampedOffset(offset)
        var start = min(max(anchor - target / 2, 0), count - target)
        var end = start + target

        // Prefer complete paragraphs without allowing a long paragraph to escape the budget.
        if start > 0, slack > 0, source.character(at: start - 1) != 0x0A {
            let lowerBound = max(0, start - slack)
            let newline = source.range(of: "\n", options: .backwards,
                                       range: NSRange(location: lowerBound, length: start - lowerBound))
            if newline.location != NSNotFound { start = NSMaxRange(newline) }
        }
        if end < count, slack > 0, source.character(at: end - 1) != 0x0A {
            let newline = source.range(of: "\n", options: [],
                                       range: NSRange(location: end, length: min(slack, count - end)))
            if newline.location != NSNotFound { end = NSMaxRange(newline) }
        }

        // Expanding, rather than truncating, keeps surrogate pairs, combining marks,
        // emoji modifiers and ZWJ sequences intact while retaining the requested anchor.
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        return ReaderTextWindow(range: range, text: source.substring(with: range))
    }
}
