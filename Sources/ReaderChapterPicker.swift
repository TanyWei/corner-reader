import AppKit

final class ChapterTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let action { _ = sendAction(action, to: target) }
        } else if event.keyCode == 53 {
            cancelOperation(self)
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A bounded, virtualized chapter list. Its size does not grow with the number of chapters.
final class ReaderChapterPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 28
    static let maximumVisibleRows = 8
    let table = ChapterTableView()
    let scroll = NSScrollView()
    private let chapters: [ReaderChapter]
    private let palette: ReaderPalette
    private let currentRow: Int
    private let onSelect: (Int) -> Void
    var onDismiss: (() -> Void)?

    init(chapters: [ReaderChapter], currentOffset: Int, palette: ReaderPalette, onSelect: @escaping (Int) -> Void) {
        self.chapters = chapters
        self.palette = palette
        self.currentRow = chapters.lastIndex(where: { $0.offset <= currentOffset }).map { $0 + 1 } ?? 0
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 240, height: 48 + CGFloat(min(chapters.count + 1, Self.maximumVisibleRows)) * Self.rowHeight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        view.wantsLayer = true
        view.layer?.backgroundColor = palette.paper.cgColor
        let title = NSTextField(labelWithString: "章节目录")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = palette.ink
        let count = NSTextField(labelWithString: chapters.isEmpty ? "未识别到章节" : "\(chapters.count) 章")
        count.font = .systemFont(ofSize: 10)
        count.textColor = palette.secondary
        for child in [title, count, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.hasHorizontalScroller = false
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = palette.paper
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("章节列表，可上下滚动")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chapter"))
        column.resizingMask = .autoresizingMask
        column.width = preferredContentSize.width - 16
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activateSelection)
        scroll.documentView = table
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 13),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            count.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 40),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: currentRow), byExtendingSelection: false)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        revealCurrentChapter()
    }

    func revealCurrentChapter() {
        view.layoutSubtreeIfNeeded()
        scroll.tile()
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: CGFloat(chapters.count + 1) * Self.rowHeight))
        let y = max(0, CGFloat(currentRow) * Self.rowHeight - (scroll.contentView.bounds.height - Self.rowHeight) / 2)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { chapters.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("chapterCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        let title = row == 0 ? "回到开头" : chapters[row - 1].title
        cell.textField?.stringValue = title
        cell.toolTip = title
        return cell
    }

    @objc func activateSelection() {
        let row = table.selectedRow
        guard row >= 0, row <= chapters.count else { return }
        onSelect(row == 0 ? 0 : chapters[row - 1].offset)
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
