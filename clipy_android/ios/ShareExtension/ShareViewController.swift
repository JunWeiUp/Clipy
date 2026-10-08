import UIKit
import UniformTypeIdentifiers

/// Extension-safe review → choose device → send; no main-app launch or listener.
final class ShareViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
  private struct FileRow {
    var name: String
    var file: ShareInboxStore.SharedFile?
    var error: String?
    var sent = false
    var fraction: Double?
  }
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let status = UILabel()
  private let sendButton = UIButton(type: .system)
  private let refreshButton = UIButton(type: .system)
  private let retryButton = UIButton(type: .system)
  private let worker = DispatchQueue(label: "clipy.share.files", qos: .userInitiated)
  private let scans: OperationQueue = { let value = OperationQueue(); value.maxConcurrentOperationCount = 12; return value }()
  private let lifetime = ShareCancellation()
  private var scanCancellation = ShareCancellation()
  private var sendCancellation = ShareCancellation()
  private var configuration = ShareSettings()
  private var client = ShareTransferClient(name: "iPhone · Share")
  private var providers: [NSItemProvider] = []
  private var files: [FileRow] = []
  private var peers: [SharePeer] = []
  private var selectedID: String?
  private var batchID: String?
  private var importing = true
  private var sending = false
  private var scanning = false
  private var providerProgress: Progress?
  private var zh: Bool { configuration.language.hasPrefix("zh") }
  private func t(_ chinese: String, _ english: String) -> String { zh ? chinese : english }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    let title = UILabel(); title.text = "Clipy"; title.font = .preferredFont(forTextStyle: .title2)
    let close = UIButton(type: .system); close.setImage(UIImage(systemName: "xmark"), for: .normal)
    close.accessibilityLabel = "Close / 关闭"; close.addTarget(self, action: #selector(closeShare), for: .touchUpInside)
    let header = UIStackView(arrangedSubviews: [title, UIView(), close]); header.spacing = 12
    status.font = .preferredFont(forTextStyle: .subheadline); status.textColor = .secondaryLabel; status.numberOfLines = 0
    status.text = t("正在读取文件…", "Reading files…")
    let top = UIStackView(arrangedSubviews: [header, status]); top.axis = .vertical; top.spacing = 12
    top.isLayoutMarginsRelativeArrangement = true; top.directionalLayoutMargins = .init(top: 20, leading: 20, bottom: 4, trailing: 20)
    table.dataSource = self; table.delegate = self; table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 64
    table.backgroundColor = .systemGroupedBackground
    refreshButton.addTarget(self, action: #selector(refreshPeers), for: .touchUpInside)
    let manual = UIButton(type: .system); manual.setTitle("IP +", for: .normal)
    manual.addTarget(self, action: #selector(addManualPeer), for: .touchUpInside)
    retryButton.addTarget(self, action: #selector(retryImport), for: .touchUpInside)
    let tools = UIStackView(arrangedSubviews: [refreshButton, manual, retryButton]); tools.distribution = .fillEqually
    var style = UIButton.Configuration.filled(); style.cornerStyle = .large; style.image = UIImage(systemName: "paperplane.fill"); style.imagePadding = 8
    sendButton.configuration = style; sendButton.addTarget(self, action: #selector(sendFiles), for: .touchUpInside)
    sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    let footer = UIStackView(arrangedSubviews: [tools, sendButton]); footer.axis = .vertical; footer.spacing = 12
    footer.isLayoutMarginsRelativeArrangement = true; footer.directionalLayoutMargins = .init(top: 8, leading: 20, bottom: 12, trailing: 20)
    let stack = UIStackView(arrangedSubviews: [top, table, footer]); stack.axis = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    guard !providers.isEmpty, providers.count <= 32 else {
      importing = false; status.text = t("每次请选择 1～32 个文件。", "Choose 1–32 files per share."); update(); return
    }
    files = providers.enumerated().map { FileRow(name: $0.element.suggestedName ?? t("文件 \($0.offset + 1)", "File \($0.offset + 1)")) }
    update()
    worker.async { [weak self] in
      guard let self else { return }
      let settings = ShareSettingsStore.read()
      do {
        let id = try ShareInboxStore.begin()
        DispatchQueue.main.async {
          guard !self.lifetime.isCancelled else { self.worker.async { try? ShareInboxStore.remove(id) }; return }
          self.configuration = settings
          self.client = ShareTransferClient(name: settings.name + " · " + self.t("分享", "Share"))
          self.peers = settings.peers
          self.batchID = id
          self.update()
          self.load(index: 0, id: id)
        }
      } catch { DispatchQueue.main.async { self.importing = false; self.status.text = self.message(error); self.update() } }
    }
  }

  private func update() {
    refreshButton.setTitle(scanning ? t("正在查找…", "Searching…") : t("刷新设备", "Refresh devices"), for: .normal)
    refreshButton.isEnabled = !scanning && !sending
    retryButton.setTitle(t("重新读取", "Read again"), for: .normal)
    retryButton.isEnabled = !importing && !sending && files.contains { $0.file == nil && $0.error != nil }
    sendButton.configuration?.title = sending ? t("发送中…", "Sending…") : t("发送", "Send")
    sendButton.isEnabled = !sending && !importing && selectedID != nil && files.contains { $0.file != nil && !$0.sent }
    table.reloadData()
  }

  func numberOfSections(in tableView: UITableView) -> Int { 2 }
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? files.count : max(peers.count, 1) }
  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    section == 0 ? t("文件 · 单个不超过 1 GiB", "Files · up to 1 GiB each") : t("选择接收设备", "Choose a receiving device")
  }
  func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.numberOfLines = 2; cell.detailTextLabel?.numberOfLines = 0
    cell.textLabel?.font = .preferredFont(forTextStyle: .body)
    cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
    cell.detailTextLabel?.textColor = .secondaryLabel
    if path.section == 0 {
      let item = files[path.row]
      cell.textLabel?.text = item.name
      cell.imageView?.image = UIImage(systemName: item.sent ? "checkmark.circle.fill" : "doc")
      cell.imageView?.tintColor = item.sent ? .systemGreen : .systemBlue
      if let error = item.error { cell.detailTextLabel?.text = error; cell.detailTextLabel?.textColor = .systemRed }
      else if item.sent { cell.detailTextLabel?.text = t("已发送", "Sent") }
      else if let fraction = item.fraction { cell.detailTextLabel?.text = t("正在发送", "Sending") + String(format: " · %.0f%%", fraction * 100) }
      else if let file = item.file { cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) }
      else { cell.detailTextLabel?.text = t("等待读取…", "Waiting to read…") }
      cell.selectionStyle = .none
    } else if peers.isEmpty {
      cell.textLabel?.text = t("未发现设备", "No devices found")
      cell.detailTextLabel?.text = t("点击刷新，或输入接收设备的 IP。请确保对方已开启 Clipy 同步并在同一网络。", "Refresh or enter the receiving device's IP. Enable Clipy sync on that device and use the same network.")
      cell.selectionStyle = .none
    } else {
      let peer = peers[path.row]
      cell.textLabel?.text = peer.name
      cell.detailTextLabel?.text = "\(peer.host):\(peer.port)"
      cell.imageView?.image = UIImage(systemName: selectedID == peer.peerId ? "checkmark.circle.fill" : "circle")
      cell.imageView?.tintColor = .systemBlue
      cell.accessibilityTraits = selectedID == peer.peerId ? [.button, .selected] : .button
    }
    return cell
  }
  func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
    guard path.section == 1, peers.indices.contains(path.row), !sending else { return }
    if selectedID != peers[path.row].peerId { for index in files.indices { files[index].sent = false } }
    selectedID = peers[path.row].peerId; update()
  }

  private func load(index: Int, id: String) {
    guard !lifetime.isCancelled else { return }
    guard index < providers.count else {
      importing = false
      status.text = t("确认文件并选择设备，点击发送即可。", "Review files, choose a device, then tap Send.")
      update(); return
    }
    if files[index].file != nil { load(index: index + 1, id: id); return }
    let provider = providers[index]
    let types = provider.registeredTypeIdentifiers
    let candidates = types.filter { $0 != UTType.fileURL.identifier && UTType($0)?.conforms(to: .data) == true }
      + types.filter { $0 == UTType.fileURL.identifier || UTType($0)?.conforms(to: .data) != true }
    loadRepresentation(provider, types: Array(candidates.prefix(4)), index: index, id: id)
  }
  private func loadRepresentation(_ provider: NSItemProvider, types: [String], index: Int, id: String) {
    guard !lifetime.isCancelled else { return }
    guard let type = types.first else {
      files[index].error = message(ShareInboxStore.Failure.invalid)
      load(index: index + 1, id: id); return
    }
    providerProgress = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
      guard let self else { return }
      var copied: ShareInboxStore.SharedFile?
      var failure: Error? = error
      if let url {
        var name = provider.suggestedName ?? url.lastPathComponent
        if (name as NSString).pathExtension.isEmpty, let suffix = UTType(type)?.preferredFilenameExtension { name += "." + suffix }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
          do { copied = try ShareInboxStore.copy(readable, name: name, batchID: id, index: index, cancelled: { self.lifetime.isCancelled }) }
          catch { failure = error }
        }
        if let coordinationError { failure = coordinationError }
      }
      let result = copied; let readError = failure
      DispatchQueue.main.async {
        guard !self.lifetime.isCancelled else { self.worker.async { try? ShareInboxStore.remove(id) }; return }
        if let result {
          self.files[index].file = result; self.files[index].name = result.name; self.files[index].error = nil
        } else if types.count > 1 && !(readError is ShareInboxStore.Failure) {
          self.loadRepresentation(provider, types: Array(types.dropFirst()), index: index, id: id); return
        } else { self.files[index].error = self.message(readError ?? ShareInboxStore.Failure.invalid) }
        self.update(); self.load(index: index + 1, id: id)
      }
    }
  }
  @objc private func retryImport() {
    guard !sending, !importing, let id = batchID else { return }
    importing = true; update(); load(index: 0, id: id)
  }

  @objc private func refreshPeers() { discover(manual: nil) }
  private func discover(manual: (String, UInt16)?) {
    guard !scanning, !sending, !lifetime.isCancelled else { return }
    scanning = true; scanCancellation = ShareCancellation(); let token = scanCancellation
    let scanClient = client
    var endpoints = configuration.peers.map { ($0.host, $0.port) }
    if let manual { endpoints = [manual] }
    else {
      let local = ShareSettingsStore.localIPv4()
      for ip in local.prefix(2) {
        let prefix = ip.split(separator: ".").dropLast().joined(separator: ".")
        for last in 1...254 {
          let host = "\(prefix).\(last)"
          if !local.contains(host) { endpoints.append((host, configuration.port)) }
        }
      }
    }
    var seen = Set<String>()
    endpoints = endpoints.filter { seen.insert("\($0.0):\($0.1)").inserted }
    let total = endpoints.count
    var completed = 0
    let group = DispatchGroup()
    status.text = t("正在查找设备…", "Searching for devices…"); update()
    for (host, port) in endpoints.prefix(640) {
      group.enter()
      scans.addOperation { [weak self] in
        defer { group.leave() }
        guard let self, !token.isCancelled else { return }
        let peer = try? scanClient.probe(host: host, port: port, cancellation: token)
        DispatchQueue.main.async {
          guard !self.lifetime.isCancelled, !token.isCancelled else { return }
          completed += 1
          if let peer {
            self.peers.removeAll { $0.peerId == peer.peerId }; self.peers.append(peer)
            self.peers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
          }
          self.status.text = self.t("查找设备", "Searching") + " \(completed)/\(total)"
          self.update()
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self, !self.lifetime.isCancelled, !token.isCancelled else { return }
      self.scanning = false
      self.status.text = self.t("选择设备后点击发送。", "Choose a device, then tap Send.")
      self.configuration.peers = Array(self.peers.prefix(128))
      let settings = self.configuration
      self.worker.async { try? ShareSettingsStore.write(settings) }
      self.update()
    }
  }
  @objc private func addManualPeer() {
    guard !sending, !scanning else { return }
    let alert = UIAlertController(title: t("添加设备", "Add device"), message: "IP / Port", preferredStyle: .alert)
    alert.addTextField { $0.placeholder = "192.168.1.10"; $0.keyboardType = .decimalPad }
    alert.addTextField { $0.text = String(self.configuration.port); $0.keyboardType = .numberPad }
    alert.addAction(UIAlertAction(title: t("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: t("连接", "Connect"), style: .default) { _ in
      let host = alert.textFields?[0].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard ShareSettingsStore.validIPv4(host), let port = UInt16(alert.textFields?[1].text ?? ""), port > 0 else {
        self.status.text = self.t("请输入有效 IPv4 和 1～65535 端口。", "Enter a valid IPv4 address and port 1–65535."); return
      }
      self.discover(manual: (host, port))
    })
    present(alert, animated: true)
  }

  @objc private func sendFiles() {
    guard !sending, !importing, let id = batchID, let peer = peers.first(where: { $0.peerId == selectedID }) else { return }
    scanCancellation.cancel(); scanning = false
    sending = true; sendCancellation = ShareCancellation(); let token = sendCancellation
    let sender = client
    let pending = files.enumerated().compactMap { index, row -> (Int, ShareInboxStore.SharedFile)? in
      guard let file = row.file, !row.sent else { return nil }; return (index, file)
    }
    for (index, _) in pending { files[index].error = nil; files[index].fraction = nil }
    status.text = t("正在校验文件并连接设备…", "Checking files and connecting…"); update()
    worker.async { [weak self] in
      guard let self else { return }
      var failure: Error?
      for (index, file) in pending {
        do {
          try token.check()
          let url = try ShareInboxStore.root().appendingPathComponent(id).appendingPathComponent(file.relativePath)
          try sender.send(file: url, to: peer, cancellation: token) { fraction in
            DispatchQueue.main.async {
              guard !self.lifetime.isCancelled else { return }
              self.files[index].fraction = fraction; self.update()
            }
          }
          DispatchQueue.main.async {
            guard !self.lifetime.isCancelled else { return }
            self.files[index].sent = true; self.files[index].error = nil; self.update()
          }
        } catch {
          failure = error
          DispatchQueue.main.async { if !self.lifetime.isCancelled { self.files[index].error = self.message(error) } }
          break
        }
      }
      let sendError = failure
      DispatchQueue.main.async {
        guard !self.lifetime.isCancelled else { return }
        self.sending = false
        self.status.text = sendError.map(self.message) ?? self.t("已发送至 \(peer.name)", "Sent to \(peer.name)")
        self.update()
      }
    }
  }

  private func message(_ error: Error) -> String {
    switch error {
    case ShareInboxStore.Failure.tooLarge, ShareTransferError.tooLarge:
      return t("该文件超过 1 GiB，请选择较小文件。", "This file exceeds 1 GiB. Choose a smaller file.")
    case ShareInboxStore.Failure.storageFull:
      return t("可用存储空间不足，请释放空间后重试。", "Not enough temporary storage. Free space and retry.")
    case ShareInboxStore.Failure.limit:
      return t("待处理分享过多，请先完成或关闭其它分享。", "Too many pending shares. Finish or close another share first.")
    case ShareTransferError.rejected(let reason):
      if reason == "tooLarge" { return t("接收端仍限制 512 MiB，请更新接收端 Clipy。", "The receiver still limits files to 512 MiB. Update Clipy on that device.") }
      return t("接收端拒绝文件，请检查对方存储空间后重试。", "The receiver rejected the file. Check its free space and retry.")
    case ShareTransferError.connection, ShareTransferError.timeout:
      return t("设备未连接或传输中断，请确认同一网络、对方同步已开启后重试。", "Connection failed or transfer interrupted. Check the network and receiver's sync, then retry.")
    case ShareTransferError.wrongDevice:
      return t("此地址的设备已变化，请刷新并重新选择设备。", "The device at this address changed. Refresh and select it again.")
    case ShareTransferError.cancelled, ShareInboxStore.Failure.cancelled:
      return t("已取消", "Cancelled")
    default:
      let ns = error as NSError
      if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return t("存储空间不足。", "Not enough free storage.") }
      return t("无法读取该文件。请先下载到本机，再从“文件”App重新分享。", "Cannot read this file. Download it locally, then share again from Files.")
    }
  }

  private func tearDown() {
    lifetime.cancel(); scanCancellation.cancel(); sendCancellation.cancel(); providerProgress?.cancel()
    if let id = batchID { worker.async { try? ShareInboxStore.remove(id) } }
  }
  @objc private func closeShare() { tearDown(); extensionContext?.completeRequest(returningItems: nil) }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true { tearDown() }
  }
  deinit { lifetime.cancel(); scanCancellation.cancel(); sendCancellation.cancel(); providerProgress?.cancel() }
}
