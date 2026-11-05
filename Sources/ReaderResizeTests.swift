import AppKit

enum ReaderResizeTests {
    static func run(temporary: URL, outputDirectory: URL) throws {
        let unit = "山里的风穿过树梢，落在旧书的纸页上。👩🏽‍💻\n\n"
        let text = String(repeating: unit, count: 7_000_000 / unit.utf16.count + 1)
        let source = temporary.appendingPathComponent("长篇缩放测试.txt")
        try text.write(to: source, atomically: true, encoding: .utf8)
        let store = ReaderStore(directory: temporary.appendingPathComponent("resize-library"))
        let imported = try store.importBook(from: source)
        let fullBook = imported.book!
        let middle = fullBook.clampedOffset(fullBook.utf16Count / 2)
        try store.saveProgress(middle, preferences: imported.preferences)
        let reader = ReaderController(store: store, testing: true)
        let view = reader.view
        let metadataURL = store.directory.appendingPathComponent("reader-state.json")
        try ReaderUITests.require(fullBook.utf16Count >= 7_000_000, "Resize regression must use a realistically long novel")
        try ReaderUITests.require(view.text.string.utf16.count < 18_000, "TextKit must never receive the entire long novel")
        try ReaderUITests.require(reader.renderedWindow!.range.location > 0, "Restoration must use the original book's middle position")
        let metadataBefore = try Data(contentsOf: metadataURL)
        let frozenWidth = view.text.textContainer!.containerSize.width
        reader.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: view.panel))
        try ReaderUITests.require(reader.isLiveResizing && !view.text.textContainer!.widthTracksTextView, "Dragging must freeze text reflow")
        var steps: [Double] = []
        for width: CGFloat in [300, 260, 400, 240, 340, 280, 500, 260] {
            let started = ProcessInfo.processInfo.systemUptime
            view.panel.setFrame(NSRect(origin: view.panel.frame.origin, size: NSSize(width: width, height: 420)), display: false)
            view.surface.layoutSubtreeIfNeeded()
            steps.append((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            try ReaderUITests.require(view.text.textContainer!.containerSize.width == frozenWidth, "Each drag step must retain the existing line layout")
        }
        try ReaderUITests.require(try Data(contentsOf: metadataURL) == metadataBefore, "Temporary resize coordinates must not overwrite saved progress")
        let ended = ProcessInfo.processInfo.systemUptime
        reader.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: view.panel))
        let endMilliseconds = (ProcessInfo.processInfo.systemUptime - ended) * 1_000
        let afterResize = try store.load()
        try ReaderUITests.require(!reader.isLiveResizing && view.text.textContainer!.widthTracksTextView, "Releasing the border must resume normal text layout")
        try ReaderUITests.require(abs(afterResize.progress - middle) < 100, "Resizing must retain the reader's global position")
        try ReaderUITests.require(afterResize.book?.text == text, "Only the displayed slice may change; the complete saved book must remain intact")
        try ReaderUITests.require(steps.max()! < 250 && endMilliseconds < 250, "Long-book resizing must not block for hundreds of milliseconds")

        // Ordinary scrolling must cross both slice boundaries without a visible jump.
        reader.jump(to: middle)
        let originalRange = reader.renderedWindow!.range
        let forward = fullBook.clampedOffset(NSMaxRange(originalRange) - 1_024)
        scroll(to: forward, reader: reader)
        let beforeY = lineY(for: forward, reader: reader)
        reader.rebaseIfNeeded()
        try ReaderUITests.require(reader.renderedWindow!.range.location > originalRange.location, "Scrolling forward must load later text")
        try ReaderUITests.require(abs(lineY(for: forward, reader: reader) - beforeY) < 2, "Loading the next slice must preserve the on-screen line position")
        try ReaderUITests.require(view.progress.stringValue != "100.0%", "The slice end must not be mistaken for the novel's end")
        let laterRange = reader.renderedWindow!.range
        let backward = fullBook.clampedOffset(laterRange.location + 1_024)
        scroll(to: backward, reader: reader)
        reader.rebaseIfNeeded()
        try ReaderUITests.require(reader.renderedWindow!.range.location < laterRange.location, "Scrolling backward must load earlier text")
        _ = reader.saveNow()
        let saved = try ReaderStore(directory: store.directory).load()
        try ReaderUITests.require(saved.progress > middle - 20_000, "Window rebasing must persist a global book offset, not a local slice offset")

        // A selection that stays in the overlap remains selectable and copyable.
        reader.jump(to: middle)
        let selectedRange = reader.renderedWindow!.range
        let selectedGlobal = fullBook.clampedOffset(NSMaxRange(selectedRange) - 1_000)
        scroll(to: selectedGlobal, reader: reader)
        let local = reader.renderedWindow!.localOffset(forGlobal: selectedGlobal)!
        view.text.setSelectedRange(NSRange(location: local, length: 4))
        let selectedText = (view.text.string as NSString).substring(with: view.text.selectedRange())
        reader.rebaseIfNeeded()
        try ReaderUITests.require((view.text.string as NSString).substring(with: view.text.selectedRange()) == selectedText, "Rebasing must preserve the current text selection")
        reader.jump(to: middle)
        let beforeOldSelection = reader.renderedWindow!.range
        view.text.setSelectedRange(NSRange(location: 0, length: 4))
        scroll(to: fullBook.clampedOffset(NSMaxRange(beforeOldSelection) - 1_024), reader: reader)
        reader.rebaseIfNeeded()
        try ReaderUITests.require(reader.renderedWindow!.range.location > beforeOldSelection.location, "An old off-screen selection must not trap reading at a slice boundary")
        reader.jump(to: fullBook.utf16Count)
        try ReaderUITests.require(NSMaxRange(reader.renderedWindow!.range) == fullBook.utf16Count && view.progress.stringValue == "100.0%", "Jumping to EOF must still reach the actual end")
        let empty = ReaderController(store: ReaderStore(directory: temporary.appendingPathComponent("empty-resize-library")), testing: true)
        empty.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: empty.view.panel))
        empty.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: empty.view.panel))
        try ReaderUITests.require(empty.book == nil && !empty.isLiveResizing, "Empty reader must also finish a resize cleanly")

        let report: [String: Any] = [
            "bookUTF16Count": fullBook.utf16Count,
            "renderedUTF16Count": view.text.string.utf16.count,
            "liveResizeStepMilliseconds": steps,
            "endResizeMilliseconds": endMilliseconds,
            "progressBefore": middle,
            "progressAfterResize": afterResize.progress,
            "forwardAndBackwardRebase": "passed",
            "selectionAndEOF": "passed"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: outputDirectory.appendingPathComponent("resize-report.json"), options: .atomic)
        print(String(format: "Long-book resize: %d UTF16, drag max %.2f ms, release %.2f ms; global progress, bidirectional scrolling, selection and EOF passed.", fullBook.utf16Count, steps.max()!, endMilliseconds))
    }

    private static func scroll(to globalOffset: Int, reader: ReaderController) {
        let view = reader.view
        let local = reader.renderedWindow!.localOffset(forGlobal: globalOffset)!
        let layout = view.text.layoutManager!
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: local, length: 1), actualCharacterRange: nil)
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: line.minY + view.text.textContainerOrigin.y))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
    }

    private static func lineY(for globalOffset: Int, reader: ReaderController) -> CGFloat {
        let view = reader.view
        let local = reader.renderedWindow!.localOffset(forGlobal: globalOffset)!
        let layout = view.text.layoutManager!
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: local, length: 1), actualCharacterRange: nil)
        let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        return line.minY + view.text.textContainerOrigin.y - view.scroll.contentView.bounds.minY
    }
}
