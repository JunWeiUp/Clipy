import AppKit
import SwiftUI

enum WordGlobalHotKeyManager {
    private static let hotKeyID: UInt32 = 0x574F_5244 // 'WORD'

    @discardableResult
    static func register() -> Bool {
        let prefs = PreferencesManager.shared
        guard prefs.isWordShortcutEnabled, let combo = prefs.wordLookupShortcut else {
            HotKeyManager.shared.unregister(id: hotKeyID)
            return true
        }
        return HotKeyManager.shared.register(keyCode: combo.keyCode, modifiers: combo.modifierFlags, id: hotKeyID) {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                MainWindow.shared.showTools(.lookup)
            }
        }
    }
}

/// 工具模块的页面：单词查询 / 单词表 / 生成密码与保持唤醒。
enum WordWorkspacePage: Equatable { case lookup, book, utilities }

final class WordWorkspaceNavigation: ObservableObject {
    @Published var page: WordWorkspacePage = .lookup
    @Published var showsModelSettings = false

    var showBook: Bool {
        get { page == .book }
        set { page = newValue ? .book : .lookup }
    }
}

/// V3 word workspace palette (UI/design-v3/mac.css), resolved per appearance.
enum WordsV3Style {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func white(_ value: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(white: value, alpha: alpha) }
    static let side = dynamic(NSColor(srgbRed: 240/255, green: 241/255, blue: 245/255, alpha: 1), NSColor(srgbRed: 40/255, green: 40/255, blue: 46/255, alpha: 1))
    static let content = dynamic(.white, NSColor(srgbRed: 30/255, green: 30/255, blue: 33/255, alpha: 1))
    static let secondaryContent = dynamic(NSColor(srgbRed: 247/255, green: 247/255, blue: 249/255, alpha: 1), NSColor(srgbRed: 26/255, green: 26/255, blue: 29/255, alpha: 1))
    static let card = dynamic(.white, NSColor(srgbRed: 35/255, green: 35/255, blue: 38/255, alpha: 1))
    static let line = dynamic(white(0, 0.08), white(1, 0.09))
    static let fill = dynamic(white(0, 0.045), white(1, 0.06))
    static let fill2 = dynamic(white(0, 0.07), white(1, 0.10))
    static let selection = dynamic(NSColor(srgbRed: 10/255, green: 108/255, blue: 1, alpha: 0.11), NSColor(srgbRed: 61/255, green: 139/255, blue: 1, alpha: 0.22))
    static let text2 = dynamic(NSColor(srgbRed: 29/255, green: 29/255, blue: 31/255, alpha: 0.66), white(0.95, 0.66))
    static let text3 = dynamic(NSColor(srgbRed: 29/255, green: 29/255, blue: 31/255, alpha: 0.42), white(0.95, 0.40))
    static let ok = dynamic(NSColor(srgbRed: 22/255, green: 163/255, blue: 74/255, alpha: 1), NSColor(srgbRed: 52/255, green: 211/255, blue: 153/255, alpha: 1))
    static let warn = dynamic(NSColor(srgbRed: 217/255, green: 119/255, blue: 6/255, alpha: 1), NSColor(srgbRed: 251/255, green: 191/255, blue: 36/255, alpha: 1))
}

struct WordWorkspaceView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var model: WordLookupViewModel
    @ObservedObject var navigation: WordWorkspaceNavigation
    @ObservedObject private var store: WordBookStore
    @ObservedObject private var keepAwake = KeepAwakeManager.shared
    @Environment(\.mainWindowNavigator) private var mainWindowNavigator
    @State private var modelName = ModelTranslationConfiguration.current.model
    /// 主窗口传入（切走即释放）；单独预览时退回本地实例。
    private let passwordModel: PasswordViewModel?

    init(model: WordLookupViewModel, navigation: WordWorkspaceNavigation, passwordModel: PasswordViewModel? = nil) {
        self.model = model
        self.navigation = navigation
        self.store = model.wordBook
        self.passwordModel = passwordModel
    }

    private func t(_ zh: String, _ en: String) -> String { ModelTranslationText.t(zh, en) }

    /// Most recent saved lookups (lastLookedUpAt descending), opened offline.
    private var recentWords: [SavedWord] {
        Array(store.words.sorted { $0.lastLookedUpAt > $1.lastLookedUpAt }.prefix(7))
    }

    var body: some View {
        let _ = languageObserver.revision
        HStack(spacing: 0) {
            sidebar
            Group {
                switch navigation.page {
                case .book:
                    WordBookView(store: model.wordBook, model: model)
                case .lookup:
                    WordLookupView(viewModel: model)
                case .utilities:
                    ToolsUtilitiesView(passwordModel: passwordModel ?? PasswordViewModel())
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $navigation.showsModelSettings, onDismiss: {
            modelName = ModelTranslationConfiguration.current.model
        }) { ModelTranslationSettingsView() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Traffic lights + module switcher when hosted in the main window.
            MainWindowSidebarHeader()
            navigationRow(L10n.t(.wordLookup), symbol: "character.book.closed", selected: navigation.page == .lookup) {
                MainWindow.shared.showTools(.lookup)
            }
            navigationRow(L10n.t(.wordBook), symbol: "books.vertical", selected: navigation.page == .book,
                          count: store.words.count) {
                MainWindow.shared.showTools(.book)
            }
            navigationRow(t("API 设置", "API settings"), symbol: "gearshape", selected: false) {
                navigation.showsModelSettings = true
            }
            .accessibilityIdentifier("wordAPISettings")
            // 工具（对齐菜单栏面板「工具」标签）：生成密码 / 保持唤醒在本模块打开，截图为全屏覆盖层。
            Text(t("工具", "Tools"))
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(WordsV3Style.text3)
                .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
            navigationRow(L10n.t(.generatePassword), symbol: "key", selected: navigation.page == .utilities) {
                navigation.page = .utilities
            }
            navigationRow(L10n.t(.keepAwakeTitle), symbol: keepAwake.isActive ? "sun.max" : "moon",
                          selected: false, trailing: L10n.t(keepAwake.isActive ? .keepAwakeOn : .keepAwakeOff)) {
                navigation.page = .utilities
            }
            navigationRow(t("截图与录屏", "Screenshot & recording"), symbol: "camera", selected: false) {
                ScreenshotSessionCoordinator.shared.startCapture(mode: .region, fromMenu: true)
            }
            if !recentWords.isEmpty {
                Text(t("最近查询", "Recent lookups"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(WordsV3Style.text3)
                    .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(recentWords) { word in recentRow(word) }
                    }
                }
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 10).padding(.top, mainWindowNavigator == nil ? 50 : 0).padding(.bottom, 0)
        .frame(width: mainWindowNavigator == nil ? 219 : MainWindowMetrics.sidebarWidth - 1).frame(maxHeight: .infinity)
        .background(WordsV3Style.side)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1).offset(x: 1)
        }
        .padding(.trailing, 1)
    }

    private func navigationRow(_ title: String, symbol: String, selected: Bool, count: Int? = nil,
                               trailing: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 14))
                    .foregroundStyle(selected ? AppColor.accent : WordsV3Style.text2)
                    .frame(width: 18)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(WordsV3Style.text3)
                }
                if let trailing {
                    Text(trailing).font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? WordsV3Style.fill2 : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ word: SavedWord) -> some View {
        let current = navigation.page == .lookup && model.entry?.word.lowercased() == word.id
        return Button {
            navigation.page = .lookup
            model.showSaved(word.entry)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(word.entry.word).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
                    .layoutPriority(1)
                Text(word.entry.meanings.first?.definition ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text3).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(current ? WordsV3Style.fill2 : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 0) {
            Rectangle().fill(WordsV3Style.line).frame(height: 0.5)
            HStack(spacing: 8) {
                Circle().fill(name.isEmpty ? WordsV3Style.text3 : WordsV3Style.ok).frame(width: 7, height: 7)
                Text(t("有道词典 · ", "Youdao · ") + (name.isEmpty ? t("模型未配置", "No model configured") : t("模型 ", "Model ") + name))
                    .font(.system(size: 11.5)).foregroundStyle(WordsV3Style.text2).lineLimit(1).truncationMode(.tail)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
