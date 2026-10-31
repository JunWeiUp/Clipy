import SwiftUI

struct SnippetEditorView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: SnippetEditorViewModel
    @State private var showingFolderSettings = false

    var body: some View {
        let _ = languageObserver.revision
        HStack(spacing: 0) {
            folderSidebar.frame(width: MainWindowMetrics.sidebarWidth)
            SplitV3Hairline(vertical: true)
            VStack(spacing: 0) {
                SplitV3Toolbar(leading: 20, trailing: 14) {
                    HStack(spacing: 9) {
                        Image(systemName: "square.on.square")
                            .font(.system(size: 15)).foregroundStyle(SplitV3Color.text2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.t(.snippetLibrary)).font(.system(size: 15, weight: .semibold))
                            Text(L10n.t(.snippetEditorTitle)).font(.system(size: 11.5))
                                .foregroundStyle(SplitV3Color.text3)
                        }
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(action: viewModel.addSnippet) {
                        Label(L10n.t(.newSnippet), systemImage: "plus")
                    }
                    .buttonStyle(SplitV3ButtonStyle(kind: .primary))
                    .keyboardShortcut("n", modifiers: .command)
                    .help(L10n.t(.newSnippet) + " ⌘N")
                    Menu {
                        Button(L10n.t(.addFolder), action: viewModel.addFolder)
                        Divider()
                        Button(L10n.t(.importAction), action: viewModel.importSnippets)
                        Button(L10n.t(.exportAction), action: viewModel.exportSnippets)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 15))
                            .foregroundStyle(SplitV3Color.text2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 28, height: 28)
                    .help(L10n.t(.snippetLibraryActions))
                    .accessibilityLabel(L10n.t(.snippetLibraryActions))
                }
                HStack(spacing: 0) {
                    snippetList.frame(width: 260)
                    SplitV3Hairline(vertical: true)
                    editor.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(SplitV3Color.content)
        }
        .background(SplitV3Color.content)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: AppWindowSize.editorMin.width, minHeight: AppWindowSize.editorMin.height)
        .onAppear { viewModel.activate() }
        .onChange(of: viewModel.folderSettingsRequest) { _ in showingFolderSettings = true }
    }

    private var folderSidebar: some View {
        VStack(spacing: 0) {
            MainWindowSidebarHeader()
            HStack {
                Text(L10n.t(.snippetFolders)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SplitV3Color.text3)
                Spacer()
                Button(action: viewModel.addFolder) { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(SplitV3IconButtonStyle())
                    .frame(height: 24)
                    .help(L10n.t(.addFolder))
                    .accessibilityLabel(L10n.t(.addFolder))
            }
            .frame(height: 24)
            .padding(.leading, 10).padding(.trailing, 0)
            .padding(.bottom, 6)
            SnippetEditorSidebarRepresentable(viewModel: viewModel, pane: .folders)
                .help(L10n.t(.snippetMoveHint))
            SplitV3Hairline()
            Button { showingFolderSettings = true } label: {
                Label(L10n.t(.snippetFolderSettings), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(SnippetSidebarFooterButtonStyle(isOn: showingFolderSettings))
            .disabled(viewModel.selectedFolder == nil)
            .padding(.top, 8).padding(.horizontal, 2)
            .popover(isPresented: $showingFolderSettings, arrowEdge: .trailing) {
                if let folder = viewModel.selectedFolder {
                    SnippetFolderSettings(folder: folder, viewModel: viewModel).id(folder.id)
                }
            }
            MainWindowSidebarFooter()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .background(SplitV3Color.sidebar)
    }

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(viewModel.selectedFolder?.title ?? L10n.t(.snippets))
                    .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                SplitV3CountPill(count: viewModel.filteredSnippets.count)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            SplitV3SearchField(placeholder: L10n.t(.snippetSearch), text: $viewModel.searchQuery) {
                viewModel.filterChanged()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            SplitV3Hairline()
            if viewModel.filteredSnippets.isEmpty {
                VStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 26, weight: .light))
                    Text(L10n.t(viewModel.searchQuery.isEmpty ? .snippetEmptyFolder : .noSearchResults))
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(SplitV3Color.text3)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SnippetEditorSidebarRepresentable(viewModel: viewModel, pane: .snippets)
                    .padding(.top, 8).padding(.horizontal, 8)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = viewModel.selectedSnippetId,
           let snippet = SnippetEditorViewModel.latestSnippet(matching: id) {
            SnippetDocumentEditor(snippet: snippet, viewModel: viewModel).id(id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 38, weight: .light)).foregroundStyle(SplitV3Color.text3)
                Text(L10n.t(.snippetEmptyFolder)).font(.system(size: 17, weight: .semibold))
                Text(L10n.t(.snippetEmptyHint)).font(.system(size: 13)).foregroundStyle(SplitV3Color.text3)
                    .multilineTextAlignment(.center)
                Button(L10n.t(.newSnippet), action: viewModel.addSnippet)
                    .buttonStyle(SplitV3ButtonStyle(kind: .primary))
                    .padding(.top, 6)
            }
            .padding(32)
        }
    }
}

private struct SnippetDocumentEditor: View {
    let snippet: Snippet
    @ObservedObject var viewModel: SnippetEditorViewModel
    @State private var title: String
    @State private var content: String
    @State private var isCopied = false
    @FocusState private var titleFocused: Bool

    init(snippet: Snippet, viewModel: SnippetEditorViewModel) {
        self.snippet = snippet
        self.viewModel = viewModel
        _title = State(initialValue: snippet.title)
        _content = State(initialValue: snippet.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(viewModel.selectedFolder?.title ?? L10n.t(.snippets)).lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    commitContent(content)
                    ClipboardManager.shared.copyToPasteboard(.text(content))
                    isCopied = true
                } label: {
                    Label(L10n.t(isCopied ? .snippetCopied : .copy),
                          systemImage: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12.5)).foregroundStyle(Color.primary)
                }
                .buttonStyle(SplitV3IconButtonStyle())
                .disabled(content.isEmpty)
                Button(role: .destructive) {
                    viewModel.deleteSelection()
                } label: {
                    Image(systemName: "trash").foregroundStyle(Color.primary)
                }
                .buttonStyle(SplitV3IconButtonStyle())
                .help(L10n.t(.delete)).accessibilityLabel(L10n.t(.delete))
            }
            .font(.system(size: 12)).foregroundStyle(SplitV3Color.text3)
            .padding(.top, 16).padding(.leading, 32).padding(.trailing, 24)
            TextField(L10n.t(.snippetTitle), text: $title)
                .font(.system(size: 24, weight: .bold))
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .onChange(of: title) { viewModel.persistTitle($0, for: snippet.id) }
                .padding(.top, 14).padding(.horizontal, 32)
            Text(L10n.t(.content)).font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
                .padding(.top, 14).padding(.bottom, 12).padding(.horizontal, 32)
            SplitV3Hairline().padding(.horizontal, 32)
            LeftAlignedTextEditor(text: $content, onCommit: commitContent)
                .padding(.horizontal, 8)
                .padding(.top, -2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
                Text(L10n.t(.snippetAutosave))
                Spacer()
                Text(L10n.format(.snippetCharacters, content.count)).monospacedDigit()
            }
            .font(.system(size: 11.5)).foregroundStyle(SplitV3Color.text3)
            .padding(.leading, 32).padding(.trailing, 20)
            .frame(height: 36)
            .background(SplitV3Color.sidebar)
            .overlay(alignment: .top) { SplitV3Hairline() }
        }
        .background(SplitV3Color.content)
        .onAppear {
            if viewModel.focusNewTitleID == snippet.id {
                titleFocused = true
                viewModel.focusNewTitleID = nil
            }
        }
        .onChange(of: content) { _ in isCopied = false }
        .onDisappear {
            // Save to the captured ID even if a new selection is already active.
            viewModel.persistTitle(title, for: snippet.id)
            commitContent(content)
        }
    }

    private func commitContent(_ value: String) { viewModel.persistContent(value, for: snippet.id) }
}

private struct SnippetFolderSettings: View {
    let folder: SnippetFolder
    @ObservedObject var viewModel: SnippetEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var shortcut: ShortcutCombo?
    @FocusState private var nameFocused: Bool

    init(folder: SnippetFolder, viewModel: SnippetEditorViewModel) {
        self.folder = folder
        self.viewModel = viewModel
        _title = State(initialValue: folder.title)
        _shortcut = State(initialValue: folder.shortcut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(L10n.t(.snippetFolderSettings)).font(AppFont.section)
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(L10n.t(.folderName)).font(AppFont.secondary).foregroundStyle(.secondary)
                TextField(L10n.t(.folderName), text: $title).textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onChange(of: title) { viewModel.renameFolder(folder.id, title: $0) }
            }
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(L10n.t(.shortcut)).font(AppFont.secondary).foregroundStyle(.secondary)
                ShortcutRecorderRepresentable(combo: $shortcut) {
                    viewModel.setFolderShortcut(folder.id, shortcut: $0)
                }
                .frame(height: 30)
                Text(L10n.t(.folderShortcutHint)).font(AppFont.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button(L10n.t(.delete), role: .destructive) {
                dismiss()
                viewModel.deleteFolder(folder.id)
            }
            .buttonStyle(.bordered)
        }
        .padding(AppSpacing.lg)
        .frame(width: 320)
        .onAppear { nameFocused = true }
    }
}

/// Full-width sidebar footer button (`.side-foot .tbtn`).
private struct SnippetSidebarFooterButtonStyle: ButtonStyle {
    var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(
                configuration.isPressed || isOn || (hovered && isEnabled) ? SplitV3Color.fill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}
