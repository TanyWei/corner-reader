import AppKit
import UniformTypeIdentifiers

final class ReaderController: NSObject, NSWindowDelegate {
    let view: ReaderWindowView
    let store: ReaderStore
    private(set) var book: ReaderBook?
    private(set) var preferences = ReaderPreferences()
    private(set) var isImporting = false
    private var isRestoring = false
    private var progressOffset = 0
    private var saveTask: DispatchWorkItem?
    private var scrollObserver: NSObjectProtocol?
    private var pendingQuit = false
    private var statusItem: NSStatusItem?
    private var pinMenuItem: NSMenuItem?
    private var chapterPopover: NSPopover?
    var onImportFinished: (() -> Void)?

    init(store: ReaderStore = ReaderStore(), testing: Bool = false) {
        self.store = store
        self.view = ReaderWindowView(restoreFrame: !testing)
        super.init()
        view.panel.delegate = self
        wire(view.openButton, #selector(openFile))
        wire(view.openIcon, #selector(openFile))
        wire(view.pin, #selector(togglePin))
        wire(view.theme, #selector(toggleTheme))
        wire(view.chapter, #selector(showChapters))
        wire(view.font, #selector(showFontMenu))
        view.surface.onDrop = { [weak self] in self?.importURL($0) }
        view.text.onDrop = { [weak self] in self?.importURL($0) }
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: view.scroll.contentView, queue: .main) { [weak self] _ in self?.didScroll() }
        do {
            let state = try store.load()
            preferences = state.preferences
            display(state.book, at: state.progress)
        } catch {
            view.hint.stringValue = "上次记录无法读取，可重新打开 TXT"
            view.hint.toolTip = error.localizedDescription
        }
        applyPreferences()
        if !testing { installMenus() }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        saveTask?.cancel()
    }

    private func wire(_ button: NSButton, _ action: Selector) { button.target = self; button.action = action }

    @objc func showWindow() {
        view.panel.deminiaturize(nil)
        view.panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openFile() {
        guard !isImporting else { return }
        showWindow()
        let picker = NSOpenPanel()
        picker.title = "打开 TXT 小说"
        picker.prompt = "开始阅读"
        picker.allowedContentTypes = [UTType(filenameExtension: "txt") ?? .plainText]
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.beginSheetModal(for: view.panel) { [weak self] response in
            if response == .OK, let url = picker.url { self?.importURL(url) }
        }
    }

    func importURL(_ url: URL) {
        guard !isImporting else { return }
        if book != nil && !saveNow(reportError: true) { return }
        saveTask?.cancel()
        setImporting(true)
        let savedPreferences = preferences
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.store.importBook(from: url, preferences: savedPreferences) }
            DispatchQueue.main.async {
                self.setImporting(false)
                switch result {
                case .success(let state):
                    self.preferences = state.preferences
                    self.display(state.book, at: state.progress)
                    self.applyPreferences()
                case .failure(let error):
                    self.updateProgressLabel()
                    if !self.pendingQuit { self.showError("无法打开小说", error: error) }
                }
                self.onImportFinished?()
                if self.pendingQuit {
                    _ = self.saveNow(reportError: false)
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
        }
    }

    private func setImporting(_ loading: Bool) {
        if loading { chapterPopover?.performClose(nil) }
        isImporting = loading
        [view.openButton, view.openIcon, view.pin, view.theme, view.font].forEach { $0.isEnabled = !loading }
        view.chapter.isEnabled = !loading && book != nil
        view.progress.isHidden = loading
        if loading { view.spinner.startAnimation(nil) } else { view.spinner.stopAnimation(nil) }
    }

    func display(_ newBook: ReaderBook?, at offset: Int) {
        isRestoring = true
        book = newBook
        progressOffset = newBook?.clampedOffset(offset) ?? 0
        view.showBook(newBook != nil)
        view.title.stringValue = newBook?.title ?? "角落阅读"
        view.title.toolTip = newBook?.title ?? "拖动顶部，把阅读放在任意角落"
        view.title.setAccessibilityValue(view.title.stringValue)
        view.panel.title = newBook.map { "\($0.title) · 角落阅读" } ?? "角落阅读"
        view.text.string = newBook?.text ?? ""
        applyTextStyle()
        view.surface.layoutSubtreeIfNeeded()
        scrollTo(progressOffset)
        updateProgressLabel()
        isRestoring = false
    }

    private func applyTextStyle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(preferences.fontSize) * 0.32
        paragraph.paragraphSpacing = 2
        paragraph.lineBreakMode = .byWordWrapping
        let font = NSFont(name: "SongtiSC-Regular", size: CGFloat(preferences.fontSize)) ?? .systemFont(ofSize: CGFloat(preferences.fontSize))
        let style: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: view.palette.ink, .paragraphStyle: paragraph]
        view.text.textStorage?.setAttributes(style, range: NSRange(location: 0, length: view.text.string.utf16.count))
        view.text.typingAttributes = style
        // NSTextView can otherwise keep a partial document height until the next visible draw.
        // Resolve the layout before a chapter jump or a font change constrains the scroll origin.
        view.surface.layoutSubtreeIfNeeded()
        view.scroll.tile()
        if let container = view.text.textContainer {
            view.text.layoutManager?.ensureLayout(for: container)
            view.text.sizeToFit()
        }
    }

    func applyPreferences() {
        isRestoring = true
        view.panel.level = preferences.pinned ? .floating : .normal
        view.applyTheme(preferences.theme, pinned: preferences.pinned)
        applyTextStyle()
        view.surface.layoutSubtreeIfNeeded()
        scrollTo(progressOffset)
        pinMenuItem?.state = preferences.pinned ? .on : .off
        updateProgressLabel()
        isRestoring = false
    }

    @objc func togglePin() {
        guard !isImporting else { return }
        preferences.pinned.toggle()
        applyPreferences()
        _ = saveNow(reportError: true)
    }

    @objc func toggleTheme() {
        guard !isImporting else { return }
        preferences.theme = preferences.theme == "night" ? "paper" : "night"
        applyPreferences()
        _ = saveNow(reportError: true)
    }

    func setFontSize(_ size: Double) {
        guard !isImporting else { return }
        preferences.fontSize = min(max(size, 12), 30)
        applyPreferences()
        _ = saveNow(reportError: true)
    }

    @objc func increaseFont() { setFontSize(preferences.fontSize + 1) }
    @objc func decreaseFont() { setFontSize(preferences.fontSize - 1) }
    @objc func resetFont() { setFontSize(17) }
    @objc private func chooseFont(_ sender: NSMenuItem) { setFontSize(Double(sender.tag)) }

    @objc func showFontMenu() {
        let menu = NSMenu()
        let label = NSMenuItem(title: "阅读字号", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        for size in [12, 14, 16, 17, 18, 20, 22, 24, 28, 30] {
            let item = NSMenuItem(title: "\(size) 号", action: #selector(chooseFont(_:)), keyEquivalent: "")
            item.target = self
            item.tag = size
            item.state = Int(preferences.fontSize) == size ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.font.bounds.maxY + 6), in: view.font)
    }

    @objc func showChapters() {
        guard !isImporting else { return }
        if chapterPopover?.isShown == true { chapterPopover?.performClose(nil); return }
        guard let picker = makeChapterPicker() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.contentSize = picker.preferredContentSize
        popover.appearance = view.panel.appearance
        chapterPopover = popover
        picker.onDismiss = { [weak popover] in popover?.performClose(nil) }
        popover.show(relativeTo: view.chapter.bounds, of: view.chapter, preferredEdge: .maxY)
    }

    func makeChapterPicker() -> ReaderChapterPicker? {
        guard let book else { return nil }
        return ReaderChapterPicker(chapters: book.chapters, currentOffset: progressOffset, palette: view.palette) { [weak self] offset in
            self?.chapterPopover?.performClose(nil)
            self?.jump(to: offset)
        }
    }

    func jump(to offset: Int) {
        guard let book else { return }
        isRestoring = true
        progressOffset = book.clampedOffset(offset)
        scrollTo(progressOffset)
        updateProgressLabel()
        isRestoring = false
        _ = saveNow(reportError: true)
    }

    private func scrollTo(_ offset: Int) {
        guard let book, book.utf16Count > 0, let layout = view.text.layoutManager, let container = view.text.textContainer else { return }
        let index = min(book.clampedOffset(offset), book.utf16Count - 1)
        let characterRange = NSRange(location: index, length: 1)
        layout.ensureLayout(forCharacterRange: characterRange)
        let glyphs = layout.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let y = max(0, rect.minY + view.text.textContainerInset.height - 12)
        view.scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        view.scroll.reflectScrolledClipView(view.scroll.contentView)
    }

    private func visibleOffset() -> Int {
        guard let book, let layout = view.text.layoutManager, let container = view.text.textContainer else { return 0 }
        let point = NSPoint(x: 0, y: max(0, view.scroll.contentView.bounds.minY - view.text.textContainerOrigin.y + 1))
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs else { return book.utf16Count }
        return book.clampedOffset(layout.characterIndexForGlyph(at: glyph))
    }

    private func didScroll() {
        guard !isRestoring, !isImporting, book != nil else { return }
        progressOffset = visibleOffset()
        updateProgressLabel()
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in _ = self?.saveNow(reportError: false) }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: task)
    }

    private func updateProgressLabel() {
        guard let book else { view.progress.stringValue = "随时读一会儿"; return }
        let documentHeight = view.text.frame.height
        let viewport = view.scroll.contentView.bounds
        let complete = (view.text.layoutManager?.firstUnlaidCharacterIndex() ?? 0) >= book.utf16Count
        let atEnd = complete && documentHeight > 0 && viewport.maxY >= documentHeight - 2
        let fraction = atEnd ? 1.0 : Double(progressOffset) / Double(max(1, book.utf16Count))
        view.progress.stringValue = String(format: "%.1f%%", min(max(fraction, 0), 1) * 100)
        let current = book.chapters.last(where: { $0.offset <= progressOffset })
        view.progress.toolTip = current?.title ?? "阅读进度自动保存"
        view.progress.setAccessibilityValue(view.progress.stringValue)
    }

    @discardableResult
    func saveNow(reportError: Bool = false) -> Bool {
        guard !isImporting else { return false }
        saveTask?.cancel()
        do {
            try store.saveProgress(progressOffset, preferences: preferences)
            return true
        } catch {
            view.progress.stringValue = "未保存"
            view.progress.toolTip = error.localizedDescription
            if reportError { showError("无法保存阅读进度", error: error) }
            return false
        }
    }

    private func showError(_ title: String, error: Error) {
        showWindow()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: view.panel)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isImporting { _ = saveNow(reportError: false) }
        sender.orderOut(nil)
        return false
    }

    func prepareToQuit() -> NSApplication.TerminateReply {
        if isImporting { pendingQuit = true; return .terminateLater }
        _ = saveNow(reportError: false)
        return .terminateNow
    }

    @objc private func hideWindow() { view.panel.performClose(nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func installMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("显示角落阅读", #selector(showWindow)))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("退出角落阅读", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "文件")
        file.addItem(menuItem("打开 TXT…", #selector(openFile), key: "o"))
        file.addItem(menuItem("隐藏阅读窗口", #selector(hideWindow), key: "w"))
        fileItem.submenu = file
        main.addItem(fileItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        edit.addItem(NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)
        let readingItem = NSMenuItem(title: "阅读", action: nil, keyEquivalent: "")
        let reading = NSMenu(title: "阅读")
        pinMenuItem = menuItem("窗口置顶", #selector(togglePin), key: "p", modifiers: [.command, .shift])
        pinMenuItem?.state = preferences.pinned ? .on : .off
        reading.addItem(pinMenuItem!)
        reading.addItem(menuItem("切换纸张 / 夜间", #selector(toggleTheme)))
        reading.addItem(.separator())
        reading.addItem(menuItem("放大文字", #selector(increaseFont), key: "+"))
        // '=' is convenient on keyboards where '+' needs Shift.
        reading.addItem(menuItem("放大文字", #selector(increaseFont), key: "="))
        reading.addItem(menuItem("缩小文字", #selector(decreaseFont), key: "-"))
        reading.addItem(menuItem("默认字号", #selector(resetFont), key: "0"))
        readingItem.submenu = reading
        main.addItem(readingItem)
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "角落阅读")
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.toolTip = "角落阅读"
        let statusMenu = NSMenu()
        statusMenu.addItem(menuItem("显示阅读窗口", #selector(showWindow)))
        statusMenu.addItem(menuItem("打开 TXT…", #selector(openFile)))
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuItem("退出角落阅读", #selector(quit)))
        statusItem?.menu = statusMenu
    }
}
