import AppKit
import AVFoundation
import CoreGraphics

#if !NATIVE_SCREENSHOT_RECORDING_TESTS

/// Snapshot of the choices shown beside the selected area. Preferences are
/// written only when the user starts, so Cancel leaves the previous defaults.
struct NativeScreenshotRecordingSetupSelection {
    var framesPerSecond: Int
    var includesSystemAudio: Bool
    var includesMicrophone: Bool
    var highlightsMouseClicks: Bool
    var includesWebcam: Bool
    var keystrokeMode: NativeScreenshotRecordingOptions.KeystrokeMode
    var delaySeconds: Int
    var hidesHUD: Bool
    var postAction: String
    var webcamPosition: String
    var webcamSize: String
    var webcamShape: String
    var microphoneDeviceID: String?
    var webcamDeviceID: String?

    init(preferences: PreferencesManager) {
        framesPerSecond = [15, 24, 30, 60].contains(preferences.recordingFPS)
            ? preferences.recordingFPS : 30
        includesSystemAudio = preferences.recordSystemAudio
        includesMicrophone = preferences.recordMicAudio
        highlightsMouseClicks = preferences.recordMouseHighlight
        includesWebcam = preferences.recordWebcam
        keystrokeMode = !preferences.recordKeystroke ? .off
            : (preferences.keystrokeShowAll ? .allKeys : .shortcutsOnly)
        delaySeconds = [0, 3, 5, 10].contains(UserDefaults.standard.integer(
            forKey: "nativeScreenshot.recordingDelaySeconds"))
            ? UserDefaults.standard.integer(forKey: "nativeScreenshot.recordingDelaySeconds") : 0
        hidesHUD = preferences.hideRecordingHUD
        postAction = preferences.recordingOnStop
        webcamPosition = preferences.webcamPosition
        webcamSize = preferences.webcamSize
        webcamShape = preferences.webcamShape
        microphoneDeviceID = UserDefaults.standard.string(
            forKey: "nativeScreenshot.recordingMicrophoneDeviceID")
        webcamDeviceID = UserDefaults.standard.string(
            forKey: "nativeScreenshot.recordingWebcamDeviceID")
    }

    func persist(to preferences: PreferencesManager) {
        preferences.recordingFPS = framesPerSecond
        preferences.recordSystemAudio = includesSystemAudio
        preferences.recordMicAudio = includesMicrophone
        preferences.recordMouseHighlight = highlightsMouseClicks
        preferences.recordWebcam = includesWebcam
        preferences.recordKeystroke = keystrokeMode != .off
        preferences.keystrokeShowAll = keystrokeMode == .allKeys
        preferences.hideRecordingHUD = hidesHUD
        preferences.recordingOnStop = postAction
        preferences.webcamPosition = webcamPosition
        preferences.webcamSize = webcamSize
        preferences.webcamShape = webcamShape
        UserDefaults.standard.set(microphoneDeviceID,
                                  forKey: "nativeScreenshot.recordingMicrophoneDeviceID")
        UserDefaults.standard.set(webcamDeviceID,
                                  forKey: "nativeScreenshot.recordingWebcamDeviceID")
        UserDefaults.standard.set(delaySeconds, forKey: "nativeScreenshot.recordingDelaySeconds")
    }
}

@MainActor
private final class NativeScreenshotRecordingSetupWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onEscape?()
        case 36, 76: onReturn?()
        default: super.keyDown(with: event)
        }
    }
}

/// The recording state uses the same vertical strip position and dark chrome
/// as the selection actions. Extra camera/output options live in its gear
/// popover, leaving the selected screen region visible until Start or Cancel.
@MainActor
final class NativeScreenshotRecordingSetupPanel: NSObject, NSMenuDelegate {
    let window: NSPanel
    var onStart: ((NativeScreenshotRecordingSetupSelection) -> Void)?
    var onCancel: (() -> Void)?
    var onMove: (() -> Void)?

    private let preferences: PreferencesManager
    private var selection: NativeScreenshotRecordingSetupSelection
    private let popover = NSPopover()
    private let clickButton: NSButton
    private let keysButton: NSButton
    private let systemButton: NSButton
    private let micButton: NSButton
    private let cameraButton: NSButton
    private let gearButton: NSButton
    private let keysMenu = NSMenu()
    private let microphoneMenu = NSMenu()
    private let cameraMenu = NSMenu()
    private var fpsPicker: NSPopUpButton?
    private var deliveryPicker: NSPopUpButton?
    private var delayPicker: NSPopUpButton?
    private var hideHUDButton: NSButton?
    private var webcamPositionControl: NSSegmentedControl?
    private var webcamSizeControl: NSSegmentedControl?
    private var webcamShapeControl: NSSegmentedControl?
    private var selectedArea: CGRect?
    private var cameraPreview: NativeScreenshotRecordingCameraPreview?
    private var cameraPreviewGeneration = 0
    private var starting = false

    init(preferences: PreferencesManager = .shared) {
        self.preferences = preferences
        selection = NativeScreenshotRecordingSetupSelection(preferences: preferences)
        window = NativeScreenshotRecordingSetupWindow(
            contentRect: CGRect(x: 0, y: 0, width: 50, height: 354),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        clickButton = Self.icon("cursorarrow.click.2", "鼠标点击高亮", "Highlight clicks")
        keysButton = Self.icon("keyboard", "按键显示", "Show keystrokes")
        systemButton = Self.icon("speaker.wave.2", "系统声音", "System audio")
        micButton = Self.icon("mic", "麦克风", "Microphone")
        cameraButton = Self.icon("web.camera", "摄像头", "Webcam")
        gearButton = Self.icon("gearshape", "录屏设置", "Recording settings")
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        let chrome = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 50, height: 354))
        chrome.material = .hudWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 11
        chrome.layer?.masksToBounds = true
        let controls: [(NSButton, Selector)] = [
            (Self.icon("record.circle", "开始录制", "Start recording"), #selector(startPressed)),
            (Self.icon("xmark", "取消录制", "Cancel recording"), #selector(cancelPressed)),
            (clickButton, #selector(toggleClick)),
            (keysButton, #selector(toggleKeystrokes)),
            (systemButton, #selector(toggleSystemAudio)),
            (micButton, #selector(toggleMicrophone)),
            (cameraButton, #selector(toggleCamera)),
            (gearButton, #selector(showSettings(_:))),
            (Self.icon("arrow.up.left.and.arrow.down.right", "移动选区", "Move selection"),
             #selector(movePressed))
        ]
        for (index, item) in controls.enumerated() {
            let button = item.0
            button.target = self
            button.action = item.1
            button.frame = CGRect(x: 7, y: 354 - 7 - CGFloat(index + 1) * 38,
                                  width: 36, height: 36)
            if index == 0 { button.contentTintColor = .systemRed }
            chrome.addSubview(button)
        }
        window.contentView = chrome
        for (button, menu) in [(keysButton, keysMenu),
                               (micButton, microphoneMenu), (cameraButton, cameraMenu)] {
            menu.delegate = self
            menu.autoenablesItems = false
            button.menu = menu
        }
        popover.behavior = .transient
        popover.animates = false
        makeSettingsPopover()
        refreshToggleColors()
        if let panel = window as? NativeScreenshotRecordingSetupWindow {
            panel.onEscape = { [weak self] in self?.cancelPressed() }
            panel.onReturn = { [weak self] in self?.startPressed() }
        }
    }

    func show(near region: CGRect, displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) ?? NSScreen.main else { return }
        let display = CGDisplayBounds(displayID)
        let visible = screen.visibleFrame
        let selected = CGRect(x: screen.frame.minX + region.minX - display.minX,
                              y: screen.frame.maxY - (region.maxY - display.minY),
                              width: region.width, height: region.height)
        selectedArea = selected
        let right = selected.maxX + 6
        let x = right + window.frame.width <= visible.maxX ? right : selected.minX - window.frame.width - 6
        let y = selected.midY - window.frame.height / 2
        window.setFrameOrigin(NSPoint(
            x: max(visible.minX + 6, min(x, visible.maxX - window.frame.width - 6)),
            y: max(visible.minY + 6, min(y, visible.maxY - window.frame.height - 6))))
        window.makeKeyAndOrderFront(nil)
        refreshCameraPreview()
    }

    func close() {
        popover.performClose(nil)
        cameraPreviewGeneration &+= 1
        cameraPreview?.close()
        cameraPreview = nil
        window.orderOut(nil)
        if let panel = window as? NativeScreenshotRecordingSetupWindow {
            panel.onEscape = nil
            panel.onReturn = nil
        }
        window.contentView = nil
        onStart = nil
        onCancel = nil
        onMove = nil
    }

    private static func icon(_ symbol: String, _ chinese: String, _ english: String) -> NSButton {
        let title = NativeScreenshotUserText.string(chinese, english)
        let button = NSButton(title: "", target: nil, action: nil)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.toolTip = title
        button.setAccessibilityLabel(title)
        return button
    }

    private func refreshToggleColors() {
        for (button, enabled) in [
            (clickButton, selection.highlightsMouseClicks),
            (keysButton, selection.keystrokeMode != .off),
            (systemButton, selection.includesSystemAudio),
            (micButton, selection.includesMicrophone),
            (cameraButton, selection.includesWebcam)
        ] {
            button.layer?.backgroundColor = enabled ? NSColor.systemBlue.cgColor : NSColor.clear.cgColor
            button.contentTintColor = enabled ? .white : .labelColor
        }
        keysButton.toolTip = selection.keystrokeMode == .allKeys
            ? NativeScreenshotUserText.string("按键显示：所有按键", "Keystrokes: all keys")
            : selection.keystrokeMode == .shortcutsOnly
                ? NativeScreenshotUserText.string("按键显示：仅快捷键", "Keystrokes: shortcuts only")
                : NativeScreenshotUserText.string("按键显示：关闭", "Keystrokes: off")
        micButton.toolTip = NativeScreenshotUserText.string(
            "麦克风（右键选择设备）", "Microphone (right-click to choose device)")
        cameraButton.toolTip = NativeScreenshotUserText.string(
            "摄像头（右键选择设备）", "Webcam (right-click to choose device)")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === keysMenu {
            let choices: [(NativeScreenshotRecordingOptions.KeystrokeMode, String, String)] = [
                (.off, "关闭", "Off"),
                (.shortcutsOnly, "仅快捷键", "Shortcuts only"),
                (.allKeys, "所有按键", "All keys")
            ]
            for (index, choice) in choices.enumerated() {
                let item = NSMenuItem(title: NativeScreenshotUserText.string(choice.1, choice.2),
                                      action: #selector(selectKeystrokeMode(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = selection.keystrokeMode == choice.0 ? .on : .off
                menu.addItem(item)
            }
            return
        }
        let microphone = menu === microphoneMenu
        let selectedID = microphone ? selection.microphoneDeviceID : selection.webcamDeviceID
        let defaultItem = NSMenuItem(
            title: NativeScreenshotUserText.string("系统默认设备", "System default device"),
            action: microphone ? #selector(selectMicrophoneDevice(_:))
                               : #selector(selectCameraDevice(_:)), keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = ""
        defaultItem.state = selectedID == nil ? .on : .off
        menu.addItem(defaultItem)
        let devices = AVCaptureDevice.devices(for: microphone ? .audio : .video)
        for device in devices {
            let item = NSMenuItem(title: device.localizedName,
                                  action: microphone ? #selector(selectMicrophoneDevice(_:))
                                                     : #selector(selectCameraDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = selectedID == device.uniqueID ? .on : .off
            menu.addItem(item)
        }
        if devices.isEmpty {
            let unavailable = NSMenuItem(title: NativeScreenshotUserText.string(
                "没有可用设备", "No devices available"), action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }
    }

    @objc private func selectKeystrokeMode(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: selection.keystrokeMode = .off
        case 1: selection.keystrokeMode = .shortcutsOnly
        default: selection.keystrokeMode = .allKeys
        }
        refreshToggleColors()
    }

    @objc private func selectMicrophoneDevice(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        selection.microphoneDeviceID = id?.isEmpty == false ? id : nil
        selection.includesMicrophone = true
        refreshToggleColors()
    }

    @objc private func selectCameraDevice(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        selection.webcamDeviceID = id?.isEmpty == false ? id : nil
        selection.includesWebcam = true
        refreshToggleColors()
        refreshCameraPreview()
    }

    @objc private func toggleClick() {
        selection.highlightsMouseClicks.toggle()
        refreshToggleColors()
    }
    @objc private func toggleKeystrokes() {
        switch selection.keystrokeMode {
        case .off: selection.keystrokeMode = .shortcutsOnly
        case .shortcutsOnly: selection.keystrokeMode = .allKeys
        case .allKeys: selection.keystrokeMode = .off
        }
        refreshToggleColors()
    }
    @objc private func toggleSystemAudio() {
        selection.includesSystemAudio.toggle()
        refreshToggleColors()
    }
    @objc private func toggleMicrophone() {
        selection.includesMicrophone.toggle()
        refreshToggleColors()
    }
    @objc private func toggleCamera() {
        selection.includesWebcam.toggle()
        refreshToggleColors()
        refreshCameraPreview()
    }

    @objc private func startPressed() {
        guard !starting else { return }
        starting = true
        readSettingsControls()
        selection.persist(to: preferences)
        let callback = onStart
        let choices = selection
        cameraPreviewGeneration &+= 1
        let preview = cameraPreview
        cameraPreview = nil
        popover.performClose(nil)
        window.orderOut(nil)
        Task { @MainActor in
            await preview?.stopAndWait()
            close()
            callback?(choices)
        }
    }

    @objc private func cancelPressed() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let callback = onCancel
        close()
        callback?()
    }

    @objc private func movePressed() {
        popover.performClose(nil)
        cameraPreviewGeneration &+= 1
        let preview = cameraPreview
        cameraPreview = nil
        window.orderOut(nil)
        let callback = onMove
        Task { @MainActor in
            await preview?.stopAndWait()
            callback?()
        }
    }

    @objc private func showSettings(_ sender: NSButton) {
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX) }
    }

    private func makeSettingsPopover() {
        let controller = NSViewController()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 292, height: 336))
        root.wantsLayer = true
        var y: CGFloat = 298
        func row(_ chinese: String, _ english: String, control: NSView) {
            let label = NSTextField(labelWithString: NativeScreenshotUserText.string(chinese, english))
            label.frame = CGRect(x: 12, y: y + 4, width: 102, height: 20)
            root.addSubview(label)
            control.frame = CGRect(x: 120, y: y, width: 158, height: 28)
            root.addSubview(control)
            y -= 38
        }
        let shape = NSSegmentedControl(labels: ["●", "▢"], trackingMode: .selectOne,
                                       target: self, action: #selector(cameraAppearanceChanged))
        shape.setSelected(selection.webcamShape != "roundedRect", forSegment: 0)
        shape.setSelected(selection.webcamShape == "roundedRect", forSegment: 1)
        webcamShapeControl = shape
        row("摄像头形状", "Camera shape", control: shape)
        let size = NSSegmentedControl(labels: ["S", "M", "L", "XL"], trackingMode: .selectOne,
                                      target: self, action: #selector(cameraAppearanceChanged))
        size.selectedSegment = ["small", "medium", "large", "xlarge"]
            .firstIndex(of: selection.webcamSize) ?? 1
        webcamSizeControl = size
        row("摄像头尺寸", "Camera size", control: size)
        let position = NSSegmentedControl(labels: ["↙", "↘", "↖", "↗"], trackingMode: .selectOne,
                                          target: self, action: #selector(cameraAppearanceChanged))
        position.selectedSegment = ["bottomLeft", "bottomRight", "topLeft", "topRight"]
            .firstIndex(of: selection.webcamPosition) ?? 1
        webcamPositionControl = position
        row("摄像头位置", "Camera position", control: position)
        let hideHUD = NSButton(checkboxWithTitle: NativeScreenshotUserText.string(
            "隐藏控件", "Hide recording controls"), target: nil, action: nil)
        hideHUD.state = selection.hidesHUD ? .on : .off
        hideHUDButton = hideHUD
        hideHUD.frame = CGRect(x: 120, y: y + 3, width: 158, height: 24)
        root.addSubview(hideHUD)
        y -= 37
        let delay = NSPopUpButton(frame: .zero, pullsDown: false)
        delay.addItems(withTitles: [NativeScreenshotUserText.string("无", "None"), "3 s", "5 s", "10 s"])
        delay.selectItem(at: [0, 3, 5, 10].firstIndex(of: selection.delaySeconds) ?? 0)
        delayPicker = delay
        row("延迟", "Delay", control: delay)
        let post = NSPopUpButton(frame: .zero, pullsDown: false)
        post.addItems(withTitles: [
            NativeScreenshotUserText.string("打开编辑器", "Open editor"),
            NativeScreenshotUserText.string("在 Finder 显示", "Show in Finder"),
            NativeScreenshotUserText.string("复制文件", "Copy file")])
        post.selectItem(at: ["editor", "finder", "clipboard"].firstIndex(of: selection.postAction) ?? 0)
        deliveryPicker = post
        row("完成后", "After recording", control: post)
        let fps = NSPopUpButton(frame: .zero, pullsDown: false)
        fps.addItems(withTitles: ["15", "24", "30", "60"])
        fps.selectItem(at: [15, 24, 30, 60].firstIndex(of: selection.framesPerSecond) ?? 2)
        fpsPicker = fps
        row("帧率", "Frame rate", control: fps)
        controller.view = root
        popover.contentViewController = controller
        popover.contentSize = root.frame.size
    }

    private func readSettingsControls() {
        selection.webcamShape = webcamShapeControl?.selectedSegment == 1 ? "roundedRect" : "circle"
        selection.webcamSize = ["small", "medium", "large", "xlarge"][max(0, webcamSizeControl?.selectedSegment ?? 1)]
        selection.webcamPosition = ["bottomLeft", "bottomRight", "topLeft", "topRight"][
            max(0, webcamPositionControl?.selectedSegment ?? 1)]
        selection.hidesHUD = hideHUDButton?.state == .on
        selection.delaySeconds = [0, 3, 5, 10][max(0, delayPicker?.indexOfSelectedItem ?? 0)]
        selection.postAction = ["editor", "finder", "clipboard"][max(0, deliveryPicker?.indexOfSelectedItem ?? 0)]
        selection.framesPerSecond = [15, 24, 30, 60][max(0, fpsPicker?.indexOfSelectedItem ?? 2)]
    }

    @objc private func cameraAppearanceChanged() {
        readSettingsControls()
        refreshCameraPreview()
    }

    private func refreshCameraPreview() {
        if selection.includesWebcam, let selectedArea,
           (selectedArea.width < 72 || selectedArea.height < 72) {
            selection.includesWebcam = false
            refreshToggleColors()
            cameraButton.toolTip = NativeScreenshotUserText.string(
                "选区过小，无法显示摄像头", "Selection is too small for webcam")
        }
        if selection.includesWebcam, let selectedArea, let cameraPreview {
            let wantedID = selection.webcamDeviceID
                ?? AVCaptureDevice.default(for: .video)?.uniqueID
            if cameraPreview.deviceID == wantedID {
                cameraPreview.show(in: selectedArea,
                                   position: selection.webcamPosition,
                                   size: selection.webcamSize,
                                   shape: selection.webcamShape)
                return
            }
        }
        cameraPreviewGeneration &+= 1
        let generation = cameraPreviewGeneration
        cameraPreview?.close()
        cameraPreview = nil
        guard selection.includesWebcam, let selectedArea else { return }
        Task { @MainActor [weak self] in
            guard await AVCaptureDevice.requestAccess(for: .video),
                  let self, self.cameraPreviewGeneration == generation else {
                if let self, self.cameraPreviewGeneration == generation {
                    self.selection.includesWebcam = false
                    self.refreshToggleColors()
                }
                return
            }
            let devices = AVCaptureDevice.devices(for: .video)
            let device = self.selection.webcamDeviceID.flatMap { selected in
                devices.first(where: { $0.uniqueID == selected })
            } ?? AVCaptureDevice.default(for: .video)
            guard let device,
                  let preview = try? NativeScreenshotRecordingCameraPreview(device: device) else {
                self.selection.includesWebcam = false
                self.refreshToggleColors()
                return
            }
            self.cameraPreview = preview
            preview.show(in: selectedArea,
                         position: self.selection.webcamPosition,
                         size: self.selection.webcamSize,
                         shape: self.selection.webcamShape)
        }
    }
}
#endif
