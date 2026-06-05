import AppKit

class SettingsWindow: NSWindow {
    static let shared = SettingsWindow()
    private var deviceNameField: NSTextField?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
            close()
        } else {
            super.keyDown(with: event)
        }
    }

    init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 450),
                   styleMask: styleMask,
                   backing: .buffered,
                   defer: false)
        self.isReleasedWhenClosed = false
        
        self.title = L10n.t(.preferences)
        self.center()
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
    }
    
    private func setupUI() {
        self.title = L10n.t(.preferences)
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 450))
        self.contentView = contentView
        
        let languageLabel = NSTextField(labelWithString: L10n.t(.language))
        languageLabel.frame = NSRect(x: 20, y: 410, width: 100, height: 20)
        contentView.addSubview(languageLabel)

        let languagePopup = NSPopUpButton(frame: NSRect(x: 130, y: 405, width: 160, height: 28))
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(withTitle: PreferencesManager.shared.appLanguage.displayName)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        contentView.addSubview(languagePopup)

        // Device Name Section
        let nameLabel = NSTextField(labelWithString: L10n.t(.deviceNameForSync))
        nameLabel.frame = NSRect(x: 20, y: 365, width: 220, height: 20)
        contentView.addSubview(nameLabel)
        
        let nameField = NSTextField(frame: NSRect(x: 20, y: 335, width: 280, height: 24))
        nameField.stringValue = PreferencesManager.shared.deviceName
        nameField.placeholderString = L10n.t(.enterDeviceName)
        contentView.addSubview(nameField)
        self.deviceNameField = nameField
        
        let saveNameButton = NSButton(title: L10n.t(.save), target: self, action: #selector(saveDeviceNameClicked(_:)))
        saveNameButton.frame = NSRect(x: 310, y: 331, width: 70, height: 32)
        contentView.addSubview(saveNameButton)
        
        let label = NSTextField(labelWithString: L10n.t(.historyLimit))
        label.frame = NSRect(x: 20, y: 295, width: 110, height: 20)
        contentView.addSubview(label)
        
        let stepper = NSStepper(frame: NSRect(x: 130, y: 295, width: 20, height: 24))
        stepper.minValue = 1
        stepper.maxValue = 100
        stepper.integerValue = PreferencesManager.shared.historyLimit
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        contentView.addSubview(stepper)
        
        let valueLabel = NSTextField(labelWithString: "\(stepper.integerValue)")
        valueLabel.frame = NSRect(x: 160, y: 295, width: 40, height: 20)
        valueLabel.tag = 101
        contentView.addSubview(valueLabel)
        
        let infoLabel = NSTextField(labelWithString: L10n.t(.changesNextCopy))
        infoLabel.font = NSFont.systemFont(ofSize: 10)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.frame = NSRect(x: 20, y: 270, width: 300, height: 15)
        contentView.addSubview(infoLabel)
        
        let excludedLabel = NSTextField(labelWithString: L10n.t(.excludedBundleIds))
        excludedLabel.frame = NSRect(x: 20, y: 235, width: 320, height: 20)
        contentView.addSubview(excludedLabel)
        
        let textField = NSTextField(frame: NSRect(x: 20, y: 205, width: 360, height: 24))
        textField.stringValue = PreferencesManager.shared.excludedApps.joined(separator: ", ")
        textField.target = self
        textField.action = #selector(excludedAppsChanged(_:))
        contentView.addSubview(textField)
        
        // Sync Section
        let separator = NSBox(frame: NSRect(x: 20, y: 185, width: 360, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)
        
        let syncEnabledCheckbox = NSButton(checkboxWithTitle: L10n.t(.enableLanSync), target: self, action: #selector(syncEnabledToggled(_:)))
        syncEnabledCheckbox.frame = NSRect(x: 20, y: 155, width: 200, height: 20)
        syncEnabledCheckbox.state = PreferencesManager.shared.isSyncEnabled ? .on : .off
        contentView.addSubview(syncEnabledCheckbox)
        
        let portLabel = NSTextField(labelWithString: L10n.t(.syncPort))
        portLabel.frame = NSRect(x: 20, y: 125, width: 90, height: 20)
        contentView.addSubview(portLabel)
        
        let portField = NSTextField(frame: NSRect(x: 100, y: 123, width: 60, height: 24))
        portField.stringValue = "\(PreferencesManager.shared.syncPort)"
        portField.target = self
        portField.action = #selector(portChanged(_:))
        contentView.addSubview(portField)
        
        let devicesLabel = NSTextField(labelWithString: L10n.t(.authorizedDevicesComma))
        devicesLabel.frame = NSRect(x: 20, y: 95, width: 320, height: 20)
        contentView.addSubview(devicesLabel)
        
        let devicesField = NSTextField(frame: NSRect(x: 20, y: 65, width: 360, height: 24))
        devicesField.stringValue = PreferencesManager.shared.authorizedDevices.joined(separator: ", ")
        devicesField.target = self
        devicesField.action = #selector(authorizedDevicesChanged(_:))
        contentView.addSubview(devicesField)
        
        let closeButton = NSButton(title: L10n.t(.close), target: self, action: #selector(closeWindow))
        closeButton.frame = NSRect(x: 300, y: 20, width: 80, height: 32)
        contentView.addSubview(closeButton)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        PreferencesManager.shared.appLanguage = language
    }

    @objc private func languageDidChange() {
        setupUI()
    }
    
    @objc private func stepperChanged(_ sender: NSStepper) {
        PreferencesManager.shared.historyLimit = sender.integerValue
        if let label = self.contentView?.viewWithTag(101) as? NSTextField {
            label.stringValue = "\(sender.integerValue)"
        }
    }
    
    @objc private func saveDeviceNameClicked(_ sender: NSButton) {
        guard let nameField = self.deviceNameField else { return }
        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty {
            PreferencesManager.shared.deviceName = newName
            // Notify SyncManager to update mDNS advertisement
            SyncManager.shared.restartService()
            
            // Visual feedback
            let alert = NSAlert()
            alert.messageText = L10n.t(.success)
            alert.informativeText = L10n.format(.deviceNameUpdated, newName)
            alert.alertStyle = .informational
            alert.addButton(withTitle: L10n.t(.ok))
            alert.beginSheetModal(for: self, completionHandler: nil)
        } else {
            nameField.stringValue = PreferencesManager.shared.deviceName
        }
    }
    
    @objc private func excludedAppsChanged(_ sender: NSTextField) {
        let apps = sender.stringValue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        PreferencesManager.shared.excludedApps = apps
    }

    @objc private func syncEnabledToggled(_ sender: NSButton) {
        PreferencesManager.shared.isSyncEnabled = (sender.state == .on)
        if sender.state == .on {
            SyncManager.shared.start()
        } else {
            SyncManager.shared.stop()
        }
    }

    @objc private func portChanged(_ sender: NSTextField) {
        if let port = Int(sender.stringValue) {
            PreferencesManager.shared.syncPort = port
        }
    }

    @objc private func authorizedDevicesChanged(_ sender: NSTextField) {
        let devices = sender.stringValue.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        PreferencesManager.shared.authorizedDevices = devices
    }

    @objc private func secretChanged(_ sender: NSTextField) {
        let secret = String(sender.stringValue.prefix(10))
        sender.stringValue = secret
        PreferencesManager.shared.syncSecret = secret
    }
    
    @objc private func closeWindow() {
        self.orderOut(nil)
    }
}
