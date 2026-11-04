import AppKit

/// An offscreen verification path. Uses only a fresh temporary store, never the reader's library.
enum ReaderUITests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw Failure(description: message) }
    }

    static func run(outputDirectory: URL) throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("CornerReader-UI-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try verifyChapterPicker(outputDirectory: outputDirectory)
        let directory = temporary.appendingPathComponent("library", isDirectory: true)
        let store = ReaderStore(directory: directory)
        let reader = ReaderController(store: store, testing: true)
        let view = reader.view
        view.surface.layoutSubtreeIfNeeded()
        try require(view.panel.frame.size == NSSize(width: 280, height: 420), "Default window must be 280 × 420")
        try require(!view.empty.isHidden && view.scroll.isHidden, "Empty state must be visible before import")
        try require(view.panel.level == .floating && !view.panel.hidesOnDeactivate, "Pinned panel must remain above other apps")
        try verifyGeometry(view)
        try snapshot(view, to: outputDirectory.appendingPathComponent("01-empty.png"))

        let paragraphs = [
            "山里的风，来得总比别处慢些。午后的阳光穿过树梢，落在门前的石阶上。",
            "她把那本旧书放在窗边，倒了一杯温热的茶。纸页翻动，像一场久别重逢。",
            "远处有人走过小桥，脚步声隐在水声里。这一刻，时间好像也停下来歇了歇。"
        ]
        var content = ""
        for chapter in 1...8 {
            content += "第\(chapter)章  \(chapter == 1 ? "山间来信" : "风经过的地方")\n\n"
            for i in 0..<12 { content += paragraphs[i % paragraphs.count] + "\n\n" }
        }
        let source = temporary.appendingPathComponent("山间来信.txt")
        try content.write(to: source, atomically: true, encoding: .utf8)
        // Exercise the same asynchronous import callback used by the two drag destinations.
        var imported = false
        reader.onImportFinished = { imported = true }
        view.surface.onDrop?(source)
        let deadline = Date().addingTimeInterval(20)
        while !imported && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try require(imported && !reader.isImporting, "Drop import must complete")
        try require(reader.book?.title == "山间来信", "Imported title must be shown")
        try require(reader.book?.chapters.count == 8, "Chinese chapter list must be available")
        try require(view.empty.isHidden && !view.scroll.isHidden, "Import must replace empty state with the reading surface")
        try require(view.text.string == content, "Displayed text must match TXT content")
        try require(view.title.stringValue == "山间来信", "Header must display the imported book name")
        try verifyGeometry(view)
        try require(view.text.textContainer!.containerSize.width > 200, "Readable width must follow the small window")
        try snapshot(view, to: outputDirectory.appendingPathComponent("02-reading-paper.png"))

        let chapter = reader.book!.chapters[3]
        let chapterPicker = reader.makeChapterPicker()!
        _ = chapterPicker.view
        chapterPicker.table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        chapterPicker.activateSelection()
        try require(view.scroll.contentView.bounds.minY > 0, "Chapter selection must scroll the text")
        try require(view.progress.stringValue != "100.0%", "A middle chapter must not be reported as the end of the book")
        let saved = try ReaderStore(directory: directory).load()
        try require(saved.progress == chapter.offset, "Chapter position must be saved as a UTF-16 offset")
        view.theme.performClick(nil)
        try require(reader.preferences.theme == "night", "Theme button must switch to night")
        reader.setFontSize(20)
        try require(reader.preferences.fontSize == 20, "Font action must change reading size")
        try require((view.text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 20, "Font preference must affect rendered text")
        try require(try ReaderStore(directory: directory).load().progress == chapter.offset, "Style changes must preserve reading position")
        try require(view.progress.stringValue != "100.0%", "Font and theme changes must not falsely report the end of the book")
        view.pin.performClick(nil)
        try require(!reader.preferences.pinned && view.panel.level == .normal, "Pin button must unset floating level")
        view.pin.performClick(nil)
        try require(reader.preferences.pinned && view.panel.level == .floating, "Pin button must restore floating level")
        try snapshot(view, to: outputDirectory.appendingPathComponent("03-reading-night.png"))

        let beforeScroll = try ReaderStore(directory: directory).load().progress
        let beforeY = view.scroll.contentView.bounds.minY
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: view.scroll.contentView.bounds.minY + 210))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.65))
        let afterScroll = try ReaderStore(directory: directory).load()
        print("Scroll proof: offset \(beforeScroll) -> \(afterScroll.progress), y \(beforeY) -> \(view.scroll.contentView.bounds.minY), document \(view.text.frame.size), container \(view.text.textContainer!.containerSize), viewport \(view.scroll.contentView.bounds)")
        try require(afterScroll.progress > beforeScroll, "Ordinary scrolling must update and debounce-save reading position")
        // Simulate a relaunch after saving, rather than two live controllers writing one store.
        let restored = ReaderController(store: ReaderStore(directory: directory), testing: true)
        restored.view.surface.layoutSubtreeIfNeeded()
        print("Restore proof: offset \(afterScroll.progress), y \(restored.view.scroll.contentView.bounds.minY), document \(restored.view.text.frame.size), container \(restored.view.text.textContainer!.containerSize), viewport \(restored.view.scroll.contentView.bounds)")
        try require(restored.book?.text == content, "Reopening must restore book content")
        try require(restored.preferences.theme == "night" && restored.preferences.fontSize == 20 && restored.preferences.pinned, "Reopening must restore theme, size and pin")
        try require(restored.view.scroll.contentView.bounds.minY > beforeY, "Ordinary scroll position must survive reopening")
        try require(restored.view.progress.stringValue != "0.0%" && restored.view.progress.stringValue != "100.0%", "Restored progress must be visible and accurate")

        view.panel.setFrame(NSRect(origin: .zero, size: NSSize(width: 240, height: 320)), display: false)
        view.surface.layoutSubtreeIfNeeded()
        try verifyGeometry(view)
        try snapshot(view, to: outputDirectory.appendingPathComponent("04-minimum-size.png"))
        try require(try String(contentsOf: source, encoding: .utf8) == content, "Import must leave original TXT unchanged")
        try require(reader.windowShouldClose(view.panel) == false, "Closing must hide the utility so the menu bar can reopen it")
        print("Verified: bounded 2,000-chapter picker, scrolling to current / final chapter, selection jump, empty list, empty state, import callback, full text, local save/restore, theme, font, pin, minimum layout, original preservation, close behavior.")
    }

    private static func verifyChapterPicker(outputDirectory: URL) throws {
        let chapters = (1...2_000).map { ReaderChapter(title: "第\($0)章 风经过的地方", offset: $0 * 100) }
        var picked: Int?
        let picker = ReaderChapterPicker(chapters: chapters, currentOffset: 12_500, palette: .named("paper")) { picked = $0 }
        _ = picker.view
        picker.revealCurrentChapter()
        try require(picker.view.frame.height <= 280 && picker.view.frame.width <= 240, "Thousands of chapters must fit a compact popover")
        try require(picker.table.numberOfRows == 2_001, "Every chapter and the beginning action must remain available")
        try require(picker.table.selectedRow == 125, "Current chapter must be selected")
        let visible = picker.table.rows(in: picker.scroll.contentView.bounds)
        try require(NSLocationInRange(125, visible), "Opening the picker must reveal the current chapter")
        try require(visible.length <= 9, "Only about eight chapters may be visible at once")
        try require(picker.table.frame.height > picker.scroll.contentView.bounds.height, "Long chapter lists must scroll inside the bounded viewport")
        try snapshot(picker.view, to: outputDirectory.appendingPathComponent("05-chapters-bounded.png"))
        picker.table.scrollRowToVisible(2_000)
        try require(NSLocationInRange(2_000, picker.table.rows(in: picker.scroll.contentView.bounds)), "The final chapter must be reachable by internal scrolling")
        picker.table.selectRowIndexes(IndexSet(integer: 2_000), byExtendingSelection: false)
        picker.activateSelection()
        try require(picked == 200_000, "Selecting the final chapter must return its exact text offset")
        picker.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        picker.activateSelection()
        try require(picked == 0, "Beginning action must still work")
        let empty = ReaderChapterPicker(chapters: [], currentOffset: 0, palette: .named("night")) { _ in }
        _ = empty.view
        empty.revealCurrentChapter()
        try require(empty.table.numberOfRows == 1 && empty.view.frame.height == 76, "No headings must produce a short beginning-only picker")
    }

    private static func verifyGeometry(_ view: ReaderWindowView) throws {
        let bounds = view.surface.bounds
        try require(view.header.frame.maxY <= bounds.maxY + 1, "Header must fit inside window")
        try require(view.scroll.frame.height > 200, "Reading area must remain usable")
        try require(view.footer.frame.minY >= -1, "Footer must fit inside window")
        try require(view.progress.frame.width > 45, "Progress must have space at minimum window width")
        try require(view.font.frame.maxX < view.theme.frame.minX + 1, "Footer controls must not overlap")
    }

    private static func snapshot(_ view: ReaderWindowView, to url: URL) throws {
        view.surface.layoutSubtreeIfNeeded()
        try snapshot(view.surface, to: url)
    }

    private static func snapshot(_ content: NSView, to url: URL) throws {
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw Failure(description: "Could not allocate preview image")
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure(description: "Could not encode preview")
        }
        try data.write(to: url, options: .atomic)
    }
}
