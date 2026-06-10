import AppKit

class NotificationWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var emptyLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var keyMonitor: Any?
    private let manager = NotificationManager.shared
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private var expandedApps = Set<String>()
    private var tableRows: [TableRow] = []

    private enum TableRow {
        case group(packageName: String, appName: String, count: Int)
        case detail(NotificationManager.NotificationEntry)
    }

    func showWindow() {
        if let window = window {
            reloadData()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        createWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let windowRect = NSRect(x: 0, y: 0, width: 760, height: 520)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let win = NSWindow(contentRect: windowRect, styleMask: styleMask, backing: .buffered, defer: false)
        win.title = L10n.t(.notificationSync)
        win.minSize = NSSize(width: 560, height: 360)
        win.isReleasedWhenClosed = false
        win.center()

        let contentView = NSView(frame: win.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]

        let toolbarHeight: CGFloat = 44
        let toolbar = NSView(frame: NSRect(x: 0, y: windowRect.height - toolbarHeight, width: windowRect.width, height: toolbarHeight))
        toolbar.autoresizingMask = [.width, .minYMargin]

        let clearLocalBtn = NSButton(title: L10n.t(.clearNotifications), target: self, action: #selector(clearLocalClicked))
        clearLocalBtn.bezelStyle = .rounded
        clearLocalBtn.frame = NSRect(x: 8, y: 8, width: 100, height: 28)
        toolbar.addSubview(clearLocalBtn)

        let clearPhoneBtn = NSButton(title: L10n.t(.clearAllOnPhone), target: self, action: #selector(clearPhoneClicked))
        clearPhoneBtn.bezelStyle = .rounded
        clearPhoneBtn.frame = NSRect(x: 116, y: 8, width: 150, height: 28)
        toolbar.addSubview(clearPhoneBtn)

        let copyBtn = NSButton(title: L10n.t(.copyContent), target: self, action: #selector(copySelectedClicked))
        copyBtn.bezelStyle = .rounded
        copyBtn.frame = NSRect(x: windowRect.width - 112, y: 8, width: 104, height: 28)
        copyBtn.autoresizingMask = [.minXMargin]
        toolbar.addSubview(copyBtn)

        contentView.addSubview(toolbar)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 24, width: windowRect.width, height: windowRect.height - toolbarHeight - 24))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        let table = GroupableTableView(frame: scroll.contentView.bounds)
        table.autoresizingMask = [.width, .height]
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 36

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = L10n.t(.source)
        appColumn.width = 160
        appColumn.minWidth = 100
        table.addTableColumn(appColumn)

        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = L10n.t(.title)
        titleColumn.width = 180
        titleColumn.minWidth = 120
        table.addTableColumn(titleColumn)

        let bodyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("body"))
        bodyColumn.title = L10n.t(.content)
        bodyColumn.width = 280
        bodyColumn.minWidth = 140
        table.addTableColumn(bodyColumn)

        let timeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeColumn.title = L10n.t(.time)
        timeColumn.width = 120
        timeColumn.minWidth = 100
        table.addTableColumn(timeColumn)

        table.menu = makeContextMenu()
        table.onGroupRowClicked = { [weak self] row in
            guard let self = self, row < self.tableRows.count,
                  case .group(let packageName, _, _) = self.tableRows[row] else { return }
            self.toggleGroup(packageName)
        }
        scroll.documentView = table
        contentView.addSubview(scroll)
        self.tableView = table

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 8, y: 4, width: windowRect.width - 16, height: 18)
        status.autoresizingMask = [.width, .maxYMargin]
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        contentView.addSubview(status)
        self.statusLabel = status

        let empty = NSTextField(labelWithString: L10n.t(.noNotifications))
        empty.alignment = .center
        empty.font = NSFont.systemFont(ofSize: 16)
        empty.textColor = .tertiaryLabelColor
        empty.frame = NSRect(x: 0, y: windowRect.height / 2 - 20, width: windowRect.width, height: 40)
        empty.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        empty.isHidden = true
        contentView.addSubview(empty)
        self.emptyLabel = empty

        win.contentView = contentView
        self.window = win

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                self?.closeWindow()
                return nil
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(phoneNotificationsDidChange),
            name: .phoneNotificationsDidChange,
            object: nil
        )

        reloadData()
    }

    private func closeWindow() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        window?.close()
    }

    @objc private func phoneNotificationsDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.reloadData()
        }
    }

    private func reloadData() {
        rebuildTableRows()
        tableView?.reloadData()
        let count = manager.notifications.count
        emptyLabel?.isHidden = count > 0
        statusLabel?.stringValue = count == 0 ? L10n.t(.noNotifications) : "\(L10n.t(.phoneNotifications)): \(count)"
    }

    private func rebuildTableRows() {
        var grouped = [(packageName: String, appName: String, items: [NotificationManager.NotificationEntry])]()
        var seen = [String: Int]()

        for n in manager.notifications {
            if let idx = seen[n.packageName] {
                grouped[idx].items.append(n)
            } else {
                seen[n.packageName] = grouped.count
                grouped.append((packageName: n.packageName, appName: n.appName, items: [n]))
            }
        }

        var rows: [TableRow] = []
        var groupIndices = Set<Int>()
        for g in grouped {
            groupIndices.insert(rows.count)
            rows.append(.group(packageName: g.packageName, appName: g.appName, count: g.items.count))
            if expandedApps.contains(g.packageName) {
                for item in g.items {
                    rows.append(.detail(item))
                }
            }
        }
        tableRows = rows
        (tableView as? GroupableTableView)?.groupRows = groupIndices
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableRows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < tableRows.count else { return 36 }
        switch tableRows[row] {
        case .group: return 40
        case .detail: return 36
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < tableRows.count, let tableColumn = tableColumn else { return nil }
        let identifier = tableColumn.identifier.rawValue

        switch tableRows[row] {
        case .group(let packageName, let appName, let count):
            guard identifier == "app" else {
                if identifier == "time" {
                    let latestTime = manager.notifications.first(where: { $0.packageName == packageName })
                    let timeStr = latestTime.map { dateFormatter.string(from: date(from: $0.postTime)) } ?? ""
                    return makeText(timeStr, bold: false, width: tableColumn.width, rowHeight: 40)
                }
                return makeText("", bold: false, width: tableColumn.width, rowHeight: 40)
            }
            return makeGroupCell(appName: appName, packageName: packageName, count: count, width: tableColumn.width)

        case .detail(let notification):
            let text: String
            switch identifier {
            case "app": text = ""
            case "title": text = notification.title
            case "body": text = notification.body
            case "time": text = dateFormatter.string(from: date(from: notification.postTime))
            default: text = ""
            }
            let field = makeText(text, bold: false, width: tableColumn.width, rowHeight: 36)
            field.toolTip = "\(notification.title)\n\(notification.body)\n\(dateFormatter.string(from: date(from: notification.postTime)))"
            return field
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // no-op, but required for selection highlight to work
    }

    // MARK: - Click handling

    private func toggleGroup(_ packageName: String) {
        if expandedApps.contains(packageName) {
            expandedApps.remove(packageName)
        } else {
            expandedApps.insert(packageName)
        }
        rebuildTableRows()
        tableView?.reloadData()
    }

    // MARK: - Cell builders

    private func makeGroupCell(appName: String, packageName: String, count: Int, width: CGFloat) -> NSView {
        let container = PassthroughView(frame: NSRect(x: 0, y: 0, width: width, height: 40))

        let isExpanded = expandedApps.contains(packageName)
        let arrow = NSTextField(labelWithString: isExpanded ? "▼" : "▶")
        arrow.frame = NSRect(x: 4, y: 8, width: 16, height: 24)
        arrow.font = NSFont.systemFont(ofSize: 11)
        arrow.textColor = .secondaryLabelColor
        container.addSubview(arrow)

        let name = NSTextField(labelWithString: appName)
        name.frame = NSRect(x: 22, y: 8, width: width - 80, height: 24)
        name.autoresizingMask = [.width]
        name.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        container.addSubview(name)

        let countBadge = NSTextField(labelWithString: "\(count)")
        countBadge.frame = NSRect(x: width - 50, y: 10, width: 42, height: 20)
        countBadge.autoresizingMask = [.minXMargin]
        countBadge.alignment = .center
        countBadge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        countBadge.textColor = .white
        countBadge.backgroundColor = .controlAccentColor
        countBadge.drawsBackground = true
        countBadge.isBordered = false
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 10
        container.addSubview(countBadge)

        container.autoresizingMask = [.width]
        return container
    }

    private func makeText(_ text: String, bold: Bool, width: CGFloat, rowHeight: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 4, y: 0, width: width - 8, height: rowHeight)
        field.autoresizingMask = [.width, .height]
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 2
        field.textColor = .labelColor
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = true
        field.font = bold
            ? NSFont.systemFont(ofSize: 12, weight: .semibold)
            : NSFont.systemFont(ofSize: 12)
        return field
    }

    // MARK: - Helpers

    private func date(from timestamp: TimeInterval) -> Date {
        timestamp > 10_000_000_000 ? Date(timeIntervalSince1970: timestamp / 1000) : Date(timeIntervalSince1970: timestamp)
    }

    private func notificationsForSelectedRows() -> [NotificationManager.NotificationEntry] {
        guard let tableView = tableView else { return [] }
        var result = [NotificationManager.NotificationEntry]()
        for index in tableView.selectedRowIndexes {
            guard index < tableRows.count else { continue }
            switch tableRows[index] {
            case .group(let packageName, _, _):
                result.append(contentsOf: manager.notifications.filter { $0.packageName == packageName })
            case .detail(let entry):
                result.append(entry)
            }
        }
        return result
    }

    private func detailText(for entry: NotificationManager.NotificationEntry) -> String {
        var lines = [
            "App: \(entry.appName)",
            "Package: \(entry.packageName)",
            "Title: \(entry.title)",
        ]
        if let subtitle = entry.subtitle, !subtitle.isEmpty {
            lines.append("Subtitle: \(subtitle)")
        }
        if !entry.body.isEmpty {
            lines.append("Body: \(entry.body)")
        }
        lines.append("Time: \(dateFormatter.string(from: date(from: entry.postTime)))")
        if let notificationKey = entry.notificationKey, !notificationKey.isEmpty {
            lines.append("Key: \(notificationKey)")
        }
        if let groupKey = entry.groupKey, !groupKey.isEmpty {
            lines.append("Group: \(groupKey)")
        }
        if let extras = entry.extras, !extras.isEmpty {
            lines.append("")
            lines.append("Extras:")
            for key in extras.keys.sorted() {
                if let value = extras[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("\(key): \(value)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L10n.t(.copyContent), action: #selector(copySelectedClicked), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let dismiss = NSMenuItem(title: L10n.t(.dismissOnPhone), action: #selector(dismissSelectedOnPhoneClicked), keyEquivalent: "")
        dismiss.target = self
        menu.addItem(dismiss)
        menu.addItem(NSMenuItem.separator())
        let delete = NSMenuItem(title: L10n.t(.delete), action: #selector(deleteSelectedClicked), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    @objc private func copySelectedClicked() {
        let text = notificationsForSelectedRows().map { detailText(for: $0) }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func dismissSelectedOnPhoneClicked() {
        for n in notificationsForSelectedRows() {
            manager.dismissOnRemote(n)
        }
    }

    @objc private func deleteSelectedClicked() {
        for n in notificationsForSelectedRows() {
            manager.removeNotification(n.id)
        }
    }

    @objc private func clearLocalClicked() {
        manager.clearAllLocal()
    }

    @objc private func clearPhoneClicked() {
        manager.clearAllOnRemote()
    }
}

private class GroupableTableView: NSTableView {
    var onGroupRowClicked: ((Int) -> Void)?
    var groupRows = Set<Int>()

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let row = row(at: location)
        if row >= 0 && groupRows.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            onGroupRowClicked?(row)
            return
        }
        super.mouseDown(with: event)
    }
}

private class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
