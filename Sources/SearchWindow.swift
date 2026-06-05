import AppKit

class SearchWindow: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SearchWindow()

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var results: [HistoryEntry] = []
    private var debounceTimer: Timer?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = L10n.t(.searchHistory)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 400, height: 300)
        panel.isReleasedWhenClosed = false
        panel.center()

        super.init(window: panel)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Search field
        searchField.placeholderString = L10n.t(.searchHistoryPlaceholder)
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchField)

        // Table scroll view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked(_:))

        // Column 1: Content preview
        let contentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        contentColumn.title = L10n.t(.content)
        contentColumn.width = 340
        contentColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(contentColumn)

        // Column 2: Source
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = L10n.t(.source)
        sourceColumn.width = 80
        sourceColumn.minWidth = 60
        sourceColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(sourceColumn)

        // Column 3: Time
        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.title = L10n.t(.time)
        timeColumn.width = 90
        timeColumn.minWidth = 70
        timeColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(timeColumn)

        scrollView.documentView = tableView

        // Status label
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Layout
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    func showWindow() {
        results = ClipboardManager.shared.searchHistory(query: "")
        statusLabel.stringValue = "\(results.count) \(L10n.t(.history).lowercased())"
        tableView.reloadData()
        window?.makeKeyAndOrderFront(nil)
        searchField.stringValue = ""
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.searchField)
        }
    }

    // MARK: - Search

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.performSearch()
        }
    }

    private func performSearch() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        results = ClipboardManager.shared.searchHistory(query: query)

        if query.isEmpty {
            statusLabel.stringValue = "\(results.count) \(L10n.t(.history).lowercased())"
        } else if results.isEmpty {
            statusLabel.stringValue = L10n.t(.noSearchResults)
        } else {
            statusLabel.stringValue = "\(results.count) \(L10n.t(.history).lowercased())"
        }

        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            close()
        } else if event.keyCode == 13 && event.modifierFlags.contains(.command) { // Cmd+W
            close()
        } else if event.keyCode == 36 { // Enter
            selectCurrentRow()
        } else if event.keyCode == 126 { // Up arrow
            moveSelection(by: -1)
        } else if event.keyCode == 125 { // Down arrow
            moveSelection(by: 1)
        } else {
            super.keyDown(with: event)
        }
    }

    private func moveSelection(by offset: Int) {
        let current = tableView.selectedRow
        let new = max(0, min(current + offset, results.count - 1))
        if new != current {
            tableView.selectRowIndexes(IndexSet(integer: new), byExtendingSelection: false)
            tableView.scrollRowToVisible(new)
        }
    }

    private func selectCurrentRow() {
        let row = tableView.selectedRow
        guard row >= 0 && row < results.count else { return }
        selectEntry(results[row])
    }

    @objc private func tableViewDoubleClicked(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0 && row < results.count else { return }
        selectEntry(results[row])
    }

    private func selectEntry(_ entry: HistoryEntry) {
        let clipboard = ClipboardManager.shared
        clipboard.moveHistoryEntryToFront(entry)
        clipboard.copyToPasteboard(entry.item)
        close()
        paste()
    }

    private func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vKeyDown?.flags = .maskCommand
        let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vKeyUp?.flags = .maskCommand
        vKeyDown?.post(tap: .cghidEventTap)
        vKeyUp?.post(tap: .cghidEventTap)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return results.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let entry = results[row]
        let identifier = column.identifier

        let cellView: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cellView = existing
        } else {
            cellView = NSTableCellView()
            cellView.identifier = identifier
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(textField)
            cellView.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                textField.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        switch identifier.rawValue {
        case "content":
            cellView.textField?.stringValue = contentPreview(for: entry)
            cellView.textField?.font = NSFont.systemFont(ofSize: 13)
        case "source":
            cellView.textField?.stringValue = entry.sourceApp ?? "—"
            cellView.textField?.font = NSFont.systemFont(ofSize: 12)
            cellView.textField?.textColor = .secondaryLabelColor
        case "time":
            cellView.textField?.stringValue = relativeTime(entry.date)
            cellView.textField?.font = NSFont.systemFont(ofSize: 12)
            cellView.textField?.textColor = .secondaryLabelColor
        default:
            break
        }

        return cellView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return true
    }

    // MARK: - Helpers

    private func contentPreview(for entry: HistoryEntry) -> String {
        let title = entry.item.title
        let singleLine = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count > 80 {
            return String(singleLine.prefix(80)) + "..."
        }
        return singleLine
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = -date.timeIntervalSinceNow
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        if interval < 604800 { return "\(Int(interval / 86400))天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
