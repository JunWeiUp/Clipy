import AppKit

final class SnippetEditorWindow {
    static let shared = SnippetEditorWindow()
    private var window: HostingWindow<SnippetEditorView>?

    private init() {}

    func makeKeyAndOrderFront(_ sender: Any?) {
        show()
    }

    func showWithPrefilledSnippet(title: String, content: String) {
        guard let snippet = SnippetManager.shared.addSnippetToDefaultFolder(title: title, content: content) else { return }
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .snippetEditorSelectSnippet, object: snippet.id)
        }
    }

    func show() {
        if window == nil {
            window = HostingWindow(
                title: L10n.t(.snippetEditorTitle),
                size: AppWindowSize.editor,
                minSize: AppWindowSize.editorMin,
                frameAutosaveName: "SnippetEditorWindow"
            ) {
                SnippetEditorView()
            }
        }
        window?.title = L10n.t(.snippetEditorTitle)
        window?.show()
    }
}
