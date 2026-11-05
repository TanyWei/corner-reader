import AppKit
import QuartzCore

struct ReaderPalette {
    let paper: NSColor
    let ink: NSColor
    let secondary: NSColor
    let accent: NSColor
    let control: NSColor

    static func named(_ name: String) -> ReaderPalette {
        if name == "night" {
            return ReaderPalette(paper: color(0x242724), ink: color(0xD9DCCC), secondary: color(0x959B8E), accent: color(0xB5C2A0), control: color(0x30352E))
        }
        return ReaderPalette(paper: color(0xF7F3E8), ink: color(0x3B4035), secondary: color(0x8A8E7D), accent: color(0x65764F), control: color(0xEDEADD))
    }

    static func color(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

final class ReaderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum ReaderDrop {
    static func urls(from info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    static func accepts(_ info: NSDraggingInfo) -> Bool {
        let urls = urls(from: info)
        return urls.count == 1 && urls[0].pathExtension.lowercased() == "txt"
    }
}

final class ReaderSurface: NSView {
    var onDrop: ((URL) -> Void)?
    var palette = ReaderPalette.named("paper") { didSet { needsDisplay = true } }
    var dropHighlighted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        palette.paper.setFill()
        bounds.fill()
        if dropHighlighted {
            palette.accent.withAlphaComponent(0.12).setFill()
            bounds.fill()
            palette.accent.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 5), xRadius: 9, yRadius: 9)
            border.lineWidth = 2
            border.stroke()
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropHighlighted = ReaderDrop.accepts(sender)
        return dropHighlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { ReaderDrop.accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        guard ReaderDrop.accepts(sender), let url = ReaderDrop.urls(from: sender).first else { return false }
        onDrop?(url)
        return true
    }
}

final class ReaderTextView: NSTextView {
    var onDrop: ((URL) -> Void)?
    private(set) var isSelectingText = false
    override func mouseDown(with event: NSEvent) {
        isSelectingText = true
        defer {
            isSelectingText = false
        }
        super.mouseDown(with: event)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { ReaderDrop.accepts(sender) ? .copy : [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { ReaderDrop.accepts(sender) ? .copy : [] }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { ReaderDrop.accepts(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard ReaderDrop.accepts(sender), let url = ReaderDrop.urls(from: sender).first else { return false }
        onDrop?(url)
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "复制", action: #selector(copy(_:)), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = selectedRange().length > 0
        menu.addItem(copy)
        return menu
    }
}

final class DragHandle: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class ReaderWindowView {
    let panel: ReaderPanel
    let surface = ReaderSurface(frame: .zero)
    let header = DragHandle(frame: .zero)
    let title = NSTextField(labelWithString: "角落阅读")
    let pin = NSButton()
    let scroll = NSScrollView()
    let text = ReaderTextView(frame: NSRect(x: 0, y: 0, width: 280, height: 300))
    let empty = NSView()
    let emptyIcon = NSImageView()
    let emptyTitle = NSTextField(labelWithString: "把故事，放在手边")
    let emptySubtitle = NSTextField(wrappingLabelWithString: "拖入一本 TXT 小说\n在小小角落，读一会儿。")
    let openButton = NSButton(title: "打开 TXT", target: nil, action: nil)
    let hint = NSTextField(labelWithString: "⌘O 打开 · 顶部可拖动")
    let footer = NSView()
    let chapter = NSButton()
    let font = NSButton(title: "Aa", target: nil, action: nil)
    let theme = NSButton()
    let openIcon = NSButton()
    let progress = NSTextField(labelWithString: "随时读一会儿")
    let spinner = NSProgressIndicator()
    var palette = ReaderPalette.named("paper")

    init(restoreFrame: Bool = true) {
        panel = ReaderPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 420), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "角落阅读"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 240, height: 320)
        panel.maxSize = NSSize(width: 640, height: 1000)
        panel.contentView = surface
        panel.isMovableByWindowBackground = false
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 304, y: visible.maxY - 444))
        }
        if restoreFrame {
            panel.setFrameAutosaveName("CornerReaderWindow")
            // A removed monitor must not strand the reader outside the remaining screens.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersection(panel.frame).width > 80 && $0.visibleFrame.intersection(panel.frame).height > 80 }), let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 24, y: screen.visibleFrame.maxY - panel.frame.height - 24))
            }
        }
        configureLayout()
        applyTheme("paper", pinned: true)
    }

    private func place(_ child: NSView, in parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
    }

    private func configureLayout() {
        [header, scroll, empty, footer].forEach { place($0, in: surface) }
        [title, pin].forEach { place($0, in: header) }
        title.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.isSelectable = false
        title.setAccessibilityLabel("当前书名")
        title.setAccessibilityValue("角落阅读")
        configureIcon(pin, symbol: "pin.fill", label: "取消置顶", size: 12)
        configureIcon(chapter, symbol: "list.bullet", label: "章节目录")
        configureIcon(theme, symbol: "moon", label: "切换到夜间主题")
        configureIcon(openIcon, symbol: "folder", label: "打开 TXT（⌘O）")
        font.isBordered = false
        font.font = NSFont(name: "Georgia", size: 15) ?? .systemFont(ofSize: 15)
        font.toolTip = "阅读字号"
        font.setAccessibilityLabel("调整阅读字号")
        [chapter, font, theme, progress, openIcon, spinner].forEach { place($0, in: footer) }
        progress.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        progress.alignment = .center
        progress.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.setAccessibilityLabel("阅读进度")
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // Keep the narrow reading column stable across macOS scrollbar preferences.
        // Trackpad, mouse wheel, arrow keys and Page Up/Down still scroll normally.
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = NSSize(width: 22, height: 12)
        text.registerForDraggedTypes([.fileURL])
        text.setAccessibilityLabel("小说正文")
        scroll.documentView = text
        [emptyIcon, emptyTitle, emptySubtitle, openButton, hint].forEach { place($0, in: empty) }
        emptyIcon.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "书本")
        emptyIcon.imageScaling = .scaleProportionallyUpOrDown
        emptyIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 30, weight: .ultraLight)
        emptyTitle.font = NSFont(name: "SongtiSC-Regular", size: 19) ?? .systemFont(ofSize: 19)
        emptyTitle.alignment = .center
        emptySubtitle.font = .systemFont(ofSize: 11)
        emptySubtitle.alignment = .center
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 6
        emptySubtitle.attributedStringValue = NSAttributedString(string: emptySubtitle.stringValue, attributes: [.paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 11)])
        openButton.bezelStyle = .rounded
        openButton.isBordered = false
        openButton.wantsLayer = true
        openButton.layer?.cornerRadius = 8
        openButton.font = .systemFont(ofSize: 12, weight: .medium)
        hint.font = .systemFont(ofSize: 10)
        hint.alignment = .center
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: surface.topAnchor), header.leadingAnchor.constraint(equalTo: surface.leadingAnchor), header.trailingAnchor.constraint(equalTo: surface.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 44),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 76), title.centerYAnchor.constraint(equalTo: header.topAnchor, constant: 20), title.trailingAnchor.constraint(lessThanOrEqualTo: pin.leadingAnchor, constant: -8),
            pin.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10), pin.topAnchor.constraint(equalTo: header.topAnchor, constant: 6), pin.widthAnchor.constraint(equalToConstant: 28), pin.heightAnchor.constraint(equalToConstant: 28),
            footer.leadingAnchor.constraint(equalTo: surface.leadingAnchor), footer.trailingAnchor.constraint(equalTo: surface.trailingAnchor), footer.bottomAnchor.constraint(equalTo: surface.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 38),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            empty.topAnchor.constraint(equalTo: header.bottomAnchor), empty.bottomAnchor.constraint(equalTo: footer.topAnchor), empty.leadingAnchor.constraint(equalTo: surface.leadingAnchor), empty.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            emptyIcon.centerXAnchor.constraint(equalTo: empty.centerXAnchor), emptyIcon.centerYAnchor.constraint(equalTo: empty.centerYAnchor, constant: -82), emptyIcon.widthAnchor.constraint(equalToConstant: 36), emptyIcon.heightAnchor.constraint(equalToConstant: 40),
            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 22), emptyTitle.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptySubtitle.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 12), emptySubtitle.centerXAnchor.constraint(equalTo: empty.centerXAnchor), emptySubtitle.widthAnchor.constraint(equalTo: empty.widthAnchor, constant: -32),
            openButton.topAnchor.constraint(equalTo: emptySubtitle.bottomAnchor, constant: 24), openButton.centerXAnchor.constraint(equalTo: empty.centerXAnchor), openButton.widthAnchor.constraint(equalToConstant: 112), openButton.heightAnchor.constraint(equalToConstant: 34),
            hint.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 14), hint.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            chapter.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 10), chapter.centerYAnchor.constraint(equalTo: footer.centerYAnchor), chapter.widthAnchor.constraint(equalToConstant: 28), chapter.heightAnchor.constraint(equalToConstant: 28),
            font.leadingAnchor.constraint(equalTo: chapter.trailingAnchor, constant: 2), font.centerYAnchor.constraint(equalTo: footer.centerYAnchor), font.widthAnchor.constraint(equalToConstant: 30), font.heightAnchor.constraint(equalToConstant: 28),
            theme.leadingAnchor.constraint(equalTo: font.trailingAnchor, constant: 2), theme.centerYAnchor.constraint(equalTo: footer.centerYAnchor), theme.widthAnchor.constraint(equalToConstant: 28), theme.heightAnchor.constraint(equalToConstant: 28),
            openIcon.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10), openIcon.centerYAnchor.constraint(equalTo: footer.centerYAnchor), openIcon.widthAnchor.constraint(equalToConstant: 28), openIcon.heightAnchor.constraint(equalToConstant: 28),
            progress.leadingAnchor.constraint(equalTo: theme.trailingAnchor, constant: 2), progress.trailingAnchor.constraint(equalTo: openIcon.leadingAnchor, constant: -3), progress.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: progress.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: progress.centerYAnchor)
        ])
        showBook(false)
    }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, size: CGFloat = 13) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    func showBook(_ present: Bool) {
        scroll.isHidden = !present
        empty.isHidden = present
        chapter.isEnabled = present
        progress.stringValue = present ? "0.0%" : "随时读一会儿"
    }

    func applyTheme(_ name: String, pinned: Bool) {
        palette = ReaderPalette.named(name)
        surface.palette = palette
        panel.backgroundColor = palette.paper
        panel.appearance = NSAppearance(named: name == "night" ? .darkAqua : .aqua)
        title.textColor = palette.secondary
        emptyTitle.textColor = palette.ink
        emptySubtitle.textColor = palette.secondary
        hint.textColor = palette.secondary
        progress.textColor = palette.secondary
        emptyIcon.contentTintColor = palette.accent
        openButton.layer?.backgroundColor = palette.control.cgColor
        openButton.contentTintColor = palette.accent
        [chapter, font, theme, openIcon].forEach { $0.contentTintColor = palette.secondary }
        pin.contentTintColor = pinned ? palette.accent : palette.secondary
        pin.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: pinned ? "取消置顶" : "保持置顶")
        pin.toolTip = pinned ? "已置顶（⌘⇧P 取消）" : "保持置顶（⌘⇧P）"
        pin.setAccessibilityLabel(pinned ? "取消置顶" : "保持置顶")
        theme.image = NSImage(systemSymbolName: name == "night" ? "sun.max" : "moon", accessibilityDescription: "切换阅读主题")
        theme.toolTip = name == "night" ? "切换到纸张主题" : "切换到夜间主题"
        theme.setAccessibilityLabel(theme.toolTip)
        text.textColor = palette.ink
        text.selectedTextAttributes = [.backgroundColor: palette.accent.withAlphaComponent(0.2), .foregroundColor: palette.ink]
    }
}
