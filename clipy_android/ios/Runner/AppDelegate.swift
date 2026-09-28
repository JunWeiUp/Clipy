import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var documentController: UIDocumentInteractionController?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "ClipyPlatform") {
      let storage = FlutterMethodChannel(
        name: "com.clipyclone.clipy_android/storage",
        binaryMessenger: registrar.messenger()
      )
      storage.setMethodCallHandler { call, result in
        let manager = FileManager.default
        switch call.method {
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
        guard let controller = self?.window?.rootViewController else {
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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
