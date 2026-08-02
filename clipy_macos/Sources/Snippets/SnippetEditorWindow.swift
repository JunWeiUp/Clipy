import AppKit

final class SnippetEditorWindow {
    static let shared = SnippetEditorWindow()

    private let session = WindowSession<SnippetEditorView>()
    private var viewModel: SnippetEditorViewModel?

    private init() {}

    func makeKeyAndOrderFront(_ sender: Any?) {
        show()
    }

    func showWithPrefilledSnippet(title: String, content: String) {
        guard let snippet = SnippetManager.shared.addSnippetToDefaultFolder(title: title, content: content) else { return }
        show()
        DispatchQueue.main.async { [weak self] in
            self?.viewModel?.selectSnippet(snippet.id)
            self?.viewModel?.reloadSidebar()
        }
    }

    func show() {
        session.present(
            create: { [self] in
                let viewModel = SnippetEditorViewModel()
                self.viewModel = viewModel
                return HostingWindow(
                    title: L10n.t(.snippetEditorTitle),
                    size: AppWindowSize.editor,
                    minSize: AppWindowSize.editorMin,
                    frameAutosaveName: "SnippetEditorWindow"
                ) {
                    SnippetEditorView(viewModel: viewModel)
                }
            },
            onPrepareForClose: { [weak self] in
                self?.viewModel?.prepareForClose()
            },
            onTeardown: { [weak self] in
                self?.viewModel = nil
            },
            update: { window in
                window.title = L10n.t(.snippetEditorTitle)
            }
        )
    }
}
