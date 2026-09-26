import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Excluded-app list: icon + name rows, "+" menu to pick an installed or
/// running app. Bundle IDs are what `ClipboardManager` matches against.
struct ExcludedAppsEditor: View {
  @State private var bundleIDs: [String] = PreferencesManager.shared.excludedApps

  /// Common password managers offered as one-click presets.
  private static let passwordManagers: [(name: String, bundleID: String)] = [
    ("1Password", "com.1password.1password"),
    ("1Password 7", "com.agilebits.onepassword7"),
    ("Bitwarden", "com.bitwarden.desktop"),
    ("KeePassXC", "org.keepassxc.keepassxc"),
    ("Enpass", "in.sinew.Enpass-Desktop"),
    (L10n.t(.excludedAppsPasswordsApp), "com.apple.Passwords"),
    (L10n.t(.excludedAppsKeychainAccess), "com.apple.keychainaccess"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: AppSpacing.xs) {
      HStack {
        Text(L10n.t(.excludedApps))
        Spacer()
        Menu {
          Button(L10n.t(.excludedAppsChooseApp)) { chooseApplication() }
          let running = runningApps
          if !running.isEmpty {
            Menu(L10n.t(.excludedAppsRunning)) {
              ForEach(running, id: \.bundleID) { app in
                Button(app.name) { add(app.bundleID) }
              }
            }
          }
          Divider()
          Button(L10n.t(.excludedAppsAddPasswordManagers)) {
            Self.passwordManagers.forEach { add($0.bundleID) }
          }
        } label: {
          Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t(.excludedAppsAdd))
      }

      if bundleIDs.isEmpty {
        Text(L10n.t(.excludedAppsEmpty))
          .font(AppFont.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(bundleIDs, id: \.self) { bundleID in
          HStack(spacing: AppSpacing.sm) {
            Image(nsImage: Self.icon(for: bundleID))
              .resizable()
              .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
              Text(Self.displayName(for: bundleID)).lineLimit(1)
              Text(bundleID)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            Button {
              remove(bundleID)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help(L10n.t(.delete))
          }
        }
      }

      Text(L10n.t(.excludedAppsHint))
        .font(AppFont.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var runningApps: [(name: String, bundleID: String)] {
    let own = Bundle.main.bundleIdentifier
    return NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
      .compactMap { app -> (String, String)? in
        guard let id = app.bundleIdentifier, id != own, !bundleIDs.contains(id) else { return nil }
        return (app.localizedName ?? id, id)
      }
      .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
      .map { (name: $0.0, bundleID: $0.1) }
  }

  private func chooseApplication() {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    panel.allowedContentTypes = [.application]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
    }
  }

  private func add(_ bundleID: String) {
    guard !bundleIDs.contains(bundleID) else { return }
    bundleIDs.append(bundleID)
    PreferencesManager.shared.excludedApps = bundleIDs
  }

  private func remove(_ bundleID: String) {
    bundleIDs.removeAll { $0 == bundleID }
    PreferencesManager.shared.excludedApps = bundleIDs
  }

  private static func icon(for bundleID: String) -> NSImage {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSWorkspace.shared.icon(for: .application)
  }

  private static func displayName(for bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return FileManager.default.displayName(atPath: url.path)
        .replacingOccurrences(of: ".app", with: "")
    }
    return passwordManagers.first { $0.bundleID == bundleID }?.name ?? bundleID
  }
}
