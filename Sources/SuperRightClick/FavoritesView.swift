import AppKit

/// 主界面里的一块可配置列表（常用目录 / 常用 App 共用）。
/// 列表 + 添加 / 删除 / 上移 / 下移，改动直接写回 `Favorites`（从而通知菜单刷新）。
final class FavoritesListView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private let titleLabel: NSTextField
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")

    private let load: () -> [URL]
    private let chooseApplication: Bool
    private let onAdd: (URL) -> Void
    private let onRemove: (Int) -> Void
    private let onMove: (Int, Int) -> Void

    init(title: String,
         chooseApplication: Bool,
         emptyHint: String,
         load: @escaping () -> [URL],
         onAdd: @escaping (URL) -> Void,
         onRemove: @escaping (Int) -> Void,
         onMove: @escaping (Int, Int) -> Void) {
        self.load = load
        self.chooseApplication = chooseApplication
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onMove = onMove
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.emptyHint = emptyHint
        build()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var emptyHint = ""

    // MARK: - 构建

    private func build() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.title = ""
        column.width = 420
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.style = .inset

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor

        let addButton = NSButton(title: chooseApplication ? "添加 App…" : "添加目录…",
                                 target: self, action: #selector(addTapped))
        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeTapped))
        let upButton = NSButton(title: "↑", target: self, action: #selector(moveUpTapped))
        let downButton = NSButton(title: "↓", target: self, action: #selector(moveDownTapped))
        for button in [removeButton, upButton, downButton] { button.bezelStyle = .rounded }

        let buttonRow = NSStackView(views: [addButton, removeButton, upButton, downButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, emptyLabel, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - 刷新

    func reload() {
        tableView.reloadData()
        let isEmpty = load().isEmpty
        emptyLabel.stringValue = isEmpty ? emptyHint : ""
        emptyLabel.isHidden = !isEmpty
    }

    // MARK: - 按钮

    @objc private func addTapped() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = chooseApplication
        panel.canChooseDirectories = !chooseApplication
        panel.prompt = "添加"
        if chooseApplication {
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { onAdd(url) }
        reload()
    }

    @objc private func removeTapped() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        onRemove(row)
        reload()
    }

    @objc private func moveUpTapped() {
        let row = tableView.selectedRow
        guard row > 0 else { return }
        onMove(row, -1)
        reload()
        tableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveDownTapped() {
        let row = tableView.selectedRow
        guard row >= 0, row < load().count - 1 else { return }
        onMove(row, 1)
        reload()
        tableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { load().count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = load()
        guard items.indices.contains(row) else { return nil }
        let url = items[row]

        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = NSWorkspace.shared.icon(forFile: url.path)
        image.translatesAutoresizingMaskIntoConstraints = false
        let text = NSTextField(labelWithString: url.lastPathComponent)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        let detail = NSTextField(labelWithString: url.deletingLastPathComponent().path)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image); cell.addSubview(text); cell.addSubview(detail)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detail.topAnchor.constraint(equalTo: text.bottomAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
        ])
        return cell
    }
}
