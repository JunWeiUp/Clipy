import SwiftUI

struct SnippetEditorView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: SnippetEditorViewModel
    @State private var showingFolderSettings = false

    var body: some View {
        let _ = languageObserver.revision
        VStack(spacing: 0) {
            AppWindowHeader {
                HStack(spacing: AppSpacing.sm) {
                    Label(L10n.t(.snippetLibrary), systemImage: "square.on.square")
                        .font(AppFont.section)
                    Spacer()
                    Button(action: viewModel.addSnippet) {
                        Label(L10n.t(.newSnippet), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("n", modifiers: .command)
                    Menu {
                        Button(L10n.t(.addFolder), action: viewModel.addFolder)
                        Divider()
                        Button(L10n.t(.importAction), action: viewModel.importSnippets)
                        Button(L10n.t(.exportAction), action: viewModel.exportSnippets)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.t(.snippetLibraryActions))
                    .accessibilityLabel(L10n.t(.snippetLibraryActions))
                }
            }
            Divider()
            HStack(spacing: 0) {
                folderSidebar.frame(width: 180)
                Divider()
                snippetList.frame(width: 260)
                Divider()
                editor.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppColor.windowBackground)
        .frame(minWidth: AppWindowSize.editorMin.width, minHeight: AppWindowSize.editorMin.height)
        .onAppear { viewModel.activate() }
        .onChange(of: viewModel.folderSettingsRequest) { _ in showingFolderSettings = true }
    }

    private var folderSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.t(.snippetFolders)).font(AppFont.secondary.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: viewModel.addFolder) { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(AppToolbarButtonStyle())
                    .help(L10n.t(.addFolder))
                    .accessibilityLabel(L10n.t(.addFolder))
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.top, AppSpacing.xs)
            SnippetEditorSidebarRepresentable(viewModel: viewModel, pane: .folders)
                .help(L10n.t(.snippetMoveHint))
            Divider()
            Button { showingFolderSettings = true } label: {
                Label(L10n.t(.snippetFolderSettings), systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(AppToolbarButtonStyle())
            .disabled(viewModel.selectedFolder == nil)
            .padding(AppSpacing.xs)
            .popover(isPresented: $showingFolderSettings) {
                if let folder = viewModel.selectedFolder {
                    SnippetFolderSettings(folder: folder, viewModel: viewModel).id(folder.id)
                }
            }
        }
        .background(AppColor.groupedBackground)
    }

    private var snippetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.selectedFolder?.title ?? L10n.t(.snippets))
                    .font(AppFont.section).lineLimit(1)
                Spacer()
                CountBadge(count: viewModel.filteredSnippets.count)
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.sm)
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.t(.snippetSearch), text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: viewModel.searchQuery) { _ in viewModel.filterChanged() }
                if !viewModel.searchQuery.isEmpty {
                    Button { viewModel.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(L10n.t(.clear)).accessibilityLabel(L10n.t(.clear))
                }
            }
            .modifier(AppInputSurface())
            .padding(.horizontal, AppSpacing.sm)
            .padding(.bottom, AppSpacing.sm)
            Divider()
            if viewModel.filteredSnippets.isEmpty {
                VStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 24, weight: .light))
                    Text(L10n.t(viewModel.searchQuery.isEmpty ? .snippetEmptyFolder : .noSearchResults))
                        .font(AppFont.secondary).multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(AppSpacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SnippetEditorSidebarRepresentable(viewModel: viewModel, pane: .snippets)
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let id = viewModel.selectedSnippetId,
           let snippet = SnippetEditorViewModel.latestSnippet(matching: id) {
            SnippetDocumentEditor(snippet: snippet, viewModel: viewModel).id(id)
        } else {
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                Text(L10n.t(.snippetEmptyFolder)).font(AppFont.title)
                Text(L10n.t(.snippetEmptyHint)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(L10n.t(.newSnippet), action: viewModel.addSnippet).buttonStyle(.borderedProminent)
            }
            .padding(AppSpacing.xl)
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
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                HStack {
                    Label(viewModel.selectedFolder?.title ?? L10n.t(.snippets), systemImage: "folder")
                        .font(AppFont.secondary).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button {
                        commitContent(content)
                        ClipboardManager.shared.copyToPasteboard(.text(content))
                        isCopied = true
                    } label: {
                        Label(L10n.t(isCopied ? .snippetCopied : .copy),
                              systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(AppToolbarButtonStyle())
                    .disabled(content.isEmpty)
                    Menu {
                        Button(L10n.t(.delete), role: .destructive) { viewModel.deleteSelection() }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(L10n.t(.snippetActions)).accessibilityLabel(L10n.t(.snippetActions))
                }
                TextField(L10n.t(.snippetTitle), text: $title)
                    .font(.system(size: 24, weight: .semibold))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onChange(of: title) { viewModel.persistTitle($0, for: snippet.id) }
                Text(L10n.t(.content)).font(AppFont.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.md)
            Divider().padding(.horizontal, AppSpacing.xl)
            LeftAlignedTextEditor(text: $content, onCommit: commitContent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Label(L10n.t(.snippetAutosave), systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Text(L10n.format(.snippetCharacters, content.count)).monospacedDigit()
            }
            .font(AppFont.caption).foregroundStyle(.secondary)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .background(AppColor.groupedBackground)
        }
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
