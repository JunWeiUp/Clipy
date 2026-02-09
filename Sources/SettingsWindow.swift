import AppKit

class SettingsWindow: NSWindow {
    static let shared = SettingsWindow()
    
    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
                   styleMask: styleMask,
                   backing: .buffered,
                   defer: false)
        self.isReleasedWhenClosed = false
        
        self.title = "Preferences"
        self.center()
        setupUI()
    }
    
    private func setupUI() {
        let contentView = NSView(frame: self.frame)
        self.contentView = contentView
        
        let label = NSTextField(labelWithString: "History Limit:")
        label.frame = NSRect(x: 20, y: 300, width: 100, height: 20)
        contentView.addSubview(label)
        
        let stepper = NSStepper(frame: NSRect(x: 130, y: 300, width: 20, height: 24))
        stepper.minValue = 1
        stepper.maxValue = 100
        stepper.integerValue = PreferencesManager.shared.historyLimit
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        contentView.addSubview(stepper)
        
        let valueLabel = NSTextField(labelWithString: "\(stepper.integerValue)")
        valueLabel.frame = NSRect(x: 160, y: 300, width: 40, height: 20)
        valueLabel.tag = 101
        contentView.addSubview(valueLabel)
        
        let infoLabel = NSTextField(labelWithString: "(Changes take effect on next copy)")
        infoLabel.font = NSFont.systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 275, width: 300, height: 15)
        contentView.addSubview(infoLabel)
        
        let excludedLabel = NSTextField(labelWithString: "Excluded Bundle IDs (comma separated):")
        excludedLabel.frame = NSRect(x: 20, y: 230, width: 300, height: 20)
        contentView.addSubview(excludedLabel)
        
        let textField = NSTextField(frame: NSRect(x: 20, y: 200, width: 360, height: 24))
        textField.stringValue = PreferencesManager.shared.excludedApps.joined(separator: ", ")
        textField.target = self
        textField.action = #selector(excludedAppsChanged(_:))
        contentView.addSubview(textField)

        // Sync Settings
        let separator = NSBox(frame: NSRect(x: 20, y: 185, width: 360, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        let syncCheckbox = NSButton(checkboxWithTitle: "Enable LAN Synchronization", target: self, action: #selector(syncToggled(_:)))
        syncCheckbox.frame = NSRect(x: 20, y: 155, width: 300, height: 20)
        syncCheckbox.state = PreferencesManager.shared.isSyncEnabled ? .on : .off
        contentView.addSubview(syncCheckbox)

        let deviceNameLabel = NSTextField(labelWithString: "Device Name:")
        deviceNameLabel.frame = NSRect(x: 20, y: 125, width: 100, height: 20)
        contentView.addSubview(deviceNameLabel)

        let deviceNameField = NSTextField(frame: NSRect(x: 120, y: 122, width: 260, height: 24))
        deviceNameField.stringValue = PreferencesManager.shared.syncDeviceName
        deviceNameField.target = self
        deviceNameField.action = #selector(deviceNameChanged(_:))
        contentView.addSubview(deviceNameField)

        let syncKeyLabel = NSTextField(labelWithString: "Sync Key:")
        syncKeyLabel.frame = NSRect(x: 20, y: 90, width: 100, height: 20)
        contentView.addSubview(syncKeyLabel)

        let syncKeyField = NSSecureTextField(frame: NSRect(x: 120, y: 87, width: 260, height: 24))
        syncKeyField.stringValue = PreferencesManager.shared.syncKey
        syncKeyField.target = self
        syncKeyField.action = #selector(syncKeyChanged(_:))
        contentView.addSubview(syncKeyField)
        
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.frame = NSRect(x: 300, y: 20, width: 80, height: 32)
        contentView.addSubview(closeButton)
    }
    
    @objc private func syncKeyChanged(_ sender: NSSecureTextField) {
        PreferencesManager.shared.syncKey = sender.stringValue
        // No need to restart SyncManager as it's computed on demand, 
        // but existing connections might fail decryption until they also update their key.
    }

    @objc private func syncToggled(_ sender: NSButton) {
        let isEnabled = sender.state == .on
        PreferencesManager.shared.isSyncEnabled = isEnabled
        if isEnabled {
            SyncManager.shared.start()
        } else {
            SyncManager.shared.stop()
        }
    }

    @objc private func deviceNameChanged(_ sender: NSTextField) {
        PreferencesManager.shared.syncDeviceName = sender.stringValue
        if PreferencesManager.shared.isSyncEnabled {
            SyncManager.shared.stop()
            SyncManager.shared.start()
        }
    }
    
    @objc private func stepperChanged(_ sender: NSStepper) {
        PreferencesManager.shared.historyLimit = sender.integerValue
        if let label = self.contentView?.viewWithTag(101) as? NSTextField {
            label.stringValue = "\(sender.integerValue)"
        }
    }
    
    @objc private func excludedAppsChanged(_ sender: NSTextField) {
        let apps = sender.stringValue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        PreferencesManager.shared.excludedApps = apps
    }
    
    @objc private func closeWindow() {
        self.orderOut(nil)
    }
}
