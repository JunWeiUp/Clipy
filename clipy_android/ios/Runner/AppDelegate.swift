import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pendingNotificationPath: String?
  private var documentController: UIDocumentInteractionController?
  private let shareQueue = DispatchQueue(label: "clipy.share.inbox", qos: .userInitiated)
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    NotificationCenter.default.addObserver(self, selector: #selector(openPendingReceivedFile),
      name: UIScene.didActivateNotification, object: nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ClipyPlatform") {
      let receipts = FlutterMethodChannel(name: "com.clipyclone.clipy_android/transfer_notifications", binaryMessenger: registrar.messenger())
      receipts.setMethodCallHandler { call, result in
        let center = UNUserNotificationCenter.current()
        if call.method == "initialize" {
          center.requestAuthorization(options: [.alert, .sound]) { _, error in
            DispatchQueue.main.async {
              if let error { result(FlutterError(code: "NOTIFICATION", message: error.localizedDescription, details: nil)) }
              else { result(nil) }
            }
          }
          return
        }
        guard call.method == "received", let args = call.arguments as? [String: Any],
              let path = args["path"] as? String, FileManager.default.fileExists(atPath: path) else {
          result(FlutterMethodNotImplemented); return
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let sender = args["sender"] as? String ?? ""
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let content = UNMutableNotificationContent()
        content.title = chinese ? "已接收：\(name)" : "Received: \(name)"
        content.body = chinese ? "来自 \(sender) · 点击打开文件" : "From \(sender) · Tap to open file"
        content.sound = .default
        // Store a Documents-relative path: the sandbox prefix can change on update.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(documents.path + "/") else { result(nil); return }
        content.userInfo = ["receivedFile": String(url.path.dropFirst(documents.path.count + 1))]
        center.add(UNNotificationRequest(identifier: "clipy.file." + UUID().uuidString, content: content, trigger: nil)) { error in
          DispatchQueue.main.async {
            if let error { result(FlutterError(code: "NOTIFICATION", message: error.localizedDescription, details: nil)) }
            else { result(nil) }
          }
        }
      }
      let shares = FlutterMethodChannel(name: "com.clipyclone.clipy_android/incoming_share", binaryMessenger: registrar.messenger())
      shares.setMethodCallHandler { [weak self] call, result in
        guard ["next", "complete", "configure"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
        self?.shareQueue.async {
          do {
            let value: [String: Any]?
            if call.method == "configure" {
              guard let args = call.arguments as? [String: Any] else { throw ShareInboxStore.Failure.invalid }
              try ShareSettingsStore.configure(args)
              value = nil
            } else if call.method == "next" { value = try ShareInboxStore.next() }
            else {
              guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else { throw ShareInboxStore.Failure.invalid }
              try ShareInboxStore.remove(id)
              value = nil
            }
            DispatchQueue.main.async { result(value) }
          } catch { DispatchQueue.main.async { result(FlutterError(code: "SHARE_INBOX", message: "Shared files are unavailable", details: nil)) } }
        }
      }
      let storage = FlutterMethodChannel(
        name: "com.clipyclone.clipy_android/storage",
        binaryMessenger: registrar.messenger()
      )
      storage.setMethodCallHandler { call, result in
        let manager = FileManager.default
        switch call.method {
        case "getAppVersion":
          result([
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
          ])
        case "getAppStorageDirectory":
          guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            result(FlutterError(code: "NO_STORAGE", message: "Application Support is unavailable", details: nil))
            return
          }
          result(base.appendingPathComponent("Clipy", isDirectory: true).path)
        case "getDownloadsDirectory":
          // Documents is visible through Files when UIFileSharingEnabled is set.
          guard let base = manager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            result(FlutterError(code: "NO_STORAGE", message: "Documents is unavailable", details: nil))
            return
          }
          result(base.path)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      let openFile = FlutterMethodChannel(
        name: "com.clipyclone.clipy_android/open_folder",
        binaryMessenger: registrar.messenger()
      )
      openFile.setMethodCallHandler { [weak self] call, result in
        guard call.method == "openFolder",
              let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "FILE_NOT_FOUND", message: path, details: nil))
          return
        }
        // UIScene owns the window; AppDelegate.window is no longer populated.
        guard let controller = self?.activeViewController else {
          result(FlutterError(code: "NO_ACTIVITY", message: nil, details: nil))
          return
        }
        let preview = UIDocumentInteractionController(url: URL(fileURLWithPath: path))
        self?.documentController = preview
        let shown = preview.presentOptionsMenu(from: controller.view.bounds, in: controller.view, animated: true)
        result(shown)
      }
      let pasteChannel = FlutterMethodChannel(
        name: "com.clipyclone.clipy_android/ios_paste",
        binaryMessenger: registrar.messenger()
      )
      registrar.register(ClipyPasteControlFactory(channel: pasteChannel), withId: "clipy/iosPasteControl")
    }
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if notification.request.identifier.hasPrefix("clipy.file.") { completionHandler([.banner, .list, .sound]) }
    else { super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler) }
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    guard response.notification.request.identifier.hasPrefix("clipy.file.") else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler); return
    }
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
       let relative = response.notification.request.content.userInfo["receivedFile"] as? String {
      DispatchQueue.main.async { [weak self] in
        self?.pendingNotificationPath = relative
        self?.openPendingReceivedFile()
      }
    }
    completionHandler()
  }

  @objc private func openPendingReceivedFile() {
    guard let relative = pendingNotificationPath, let controller = activeViewController else { return }
    pendingNotificationPath = nil
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
    let url = root.appendingPathComponent(relative).standardizedFileURL
    guard url.path.hasPrefix(root.path + "/") else { return }
    let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    guard FileManager.default.fileExists(atPath: url.path) else {
      let alert = UIAlertController(title: chinese ? "文件已移动或删除" : "File moved or deleted",
        message: url.lastPathComponent, preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: chinese ? "好" : "OK", style: .default))
      controller.present(alert, animated: true); return
    }
    let preview = UIDocumentInteractionController(url: url)
    documentController = preview
    preview.delegate = self
    if !preview.presentPreview(animated: true) {
      _ = preview.presentOptionsMenu(from: controller.view.bounds, in: controller.view, animated: true)
    }
  }

  private var activeViewController: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }),
          var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
      return nil
    }
    while let presented = controller.presentedViewController {
      controller = presented
    }
    return controller
  }
}

private final class ClipyPasteControlFactory: NSObject, FlutterPlatformViewFactory {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    ClipyPasteControl(frame: frame, channel: channel)
  }
}

private final class ClipyPasteControl: NSObject, FlutterPlatformView {
  private let container: UIView
  private let receiver: PasteReceiver

  init(frame: CGRect, channel: FlutterMethodChannel) {
    receiver = PasteReceiver(frame: frame)
    container = receiver
    super.init()
    receiver.onText = { text in
      channel.invokeMethod("pasteText", arguments: text)
    }
    if #available(iOS 16.0, *) {
      let configuration = UIPasteControl.Configuration()
      configuration.displayMode = .iconAndLabel
      let control = UIPasteControl(configuration: configuration)
      control.target = receiver
      control.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(control)
      NSLayoutConstraint.activate([
        control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        control.topAnchor.constraint(equalTo: container.topAnchor),
        control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
    } else {
      let button = UIButton(type: .system)
      button.setTitle("Paste / 粘贴", for: .normal)
      button.addTarget(self, action: #selector(pasteWithPrompt), for: .touchUpInside)
      button.frame = container.bounds
      button.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.addSubview(button)
    }
  }

  func view() -> UIView { container }

  @objc private func pasteWithPrompt() {
    if let text = UIPasteboard.general.string { receiver.onText?(text) }
  }
}

private final class PasteReceiver: UIView {
  var onText: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
  }

  override func paste(itemProviders: [NSItemProvider]) {
    guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
    _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
      guard let text = object as? String else { return }
      DispatchQueue.main.async { self?.onText?(text) }
    }
  }
}

extension AppDelegate: UIDocumentInteractionControllerDelegate {
  func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
    activeViewController ?? UIViewController()
  }
  func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
    documentController = nil
  }
}
