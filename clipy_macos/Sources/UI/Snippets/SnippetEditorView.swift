import SwiftUI

struct SnippetEditorView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: SnippetEditorViewModel

    var body: some View {
        let _ = languageObserver.revision

        VStack(spacing: 0) {
            AppToolbar(
                leading: [
                    AppToolbarButton(title: L10n.t(.addSnippet), systemImage: "doc.badge.plus", action: viewModel.addSnippet),
                    AppToolbarButton(title: L10n.t(.addFolder), systemImage: "folder.badge.plus", action: viewModel.addFolder),
                    AppToolbarButton(title: L10n.t(.delete), systemImage: "minus", action: viewModel.deleteSelection),
                ],
                trailing: [
                    AppToolbarButton(title: L10n.t(.importAction), systemImage: "square.and.arrow.down", action: viewModel.importSnippets),
                    AppToolbarButton(title: L10n.t(.exportAction), systemImage: "square.and.arrow.up", action: viewModel.exportSnippets),
                ]
            )

            Divider()

            NavigationSplitView {
                SnippetEditorSidebarRepresentable(viewModel: viewModel)
                    .frame(minWidth: 200, idealWidth: 250)
            } detail: {
                detailContent
                    .frame(minWidth: 280)
            }
        }
        .background(Color.clear)
        .frame(minWidth: AppWindowSize.editorMin.width, minHeight: AppWindowSize.editorMin.height)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let snippetId = viewModel.selectedSnippetId {
            snippetDetail(snippetId: snippetId)
        } else if viewModel.selectedFolderId != nil {
            folderDetail
        } else {
            EmptyStateView(message: L10n.t(.selectFolderOrSnippet))
        }
    }

    private var folderDetail: some View {
        Form {
            Section(L10n.t(.folderName)) {
                LeftAlignedTextField(text: $viewModel.draftTitle) {
                    viewModel.persistDraftTitle()
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }

            Section(L10n.t(.shortcut)) {
                ShortcutRecorderRepresentable(
                    combo: $viewModel.draftShortcut,
                    onChanged: { _ in viewModel.persistDraftShortcut() }
                )
                .frame(maxWidth: 240, minHeight: 30, maxHeight: 30)
                Text(L10n.t(.folderShortcutHint))
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(AppSpacing.sm)
        .id(viewModel.selectedFolderId)
    }

    private func snippetDetail(snippetId: UUID) -> some View {
        Form {
            Section(L10n.t(.snippetTitle)) {
                LeftAlignedTextField(text: $viewModel.draftTitle) {
                    viewModel.persistDraftTitle()
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }

            Section(L10n.t(.content)) {
                DebouncedSnippetContentEditor(snippetId: snippetId, viewModel: viewModel)
                    .frame(minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .formStyle(.grouped)
        .padding(AppSpacing.sm)
        .id(snippetId)
    }
}

/// Keeps keystrokes in local state so `@Published draftContent` / disk writes
/// only happen after debounce or when leaving the snippet (blur / selection change).
private struct DebouncedSnippetContentEditor: View {
    let snippetId: UUID
    @ObservedObject var viewModel: SnippetEditorViewModel
    @State private var localContent: String

    init(snippetId: UUID, viewModel: SnippetEditorViewModel) {
        self.snippetId = snippetId
        self.viewModel = viewModel
        _localContent = State(initialValue: viewModel.draftContent)
    }

    var body: some View {
        LeftAlignedTextEditor(text: $localContent, onCommit: commitToDisk)
            .onDisappear {
                // Selection change / window close tears this view down via `.id`;
                // flush here so pending edits are not lost before the next draft loads.
                commitToDisk(localContent)
            }
    }

    private func commitToDisk(_ content: String) {
        // Capture snippetId so a close that clears selectedSnippetId still saves.
        viewModel.persistContent(content, for: snippetId)
    }
}
