import SwiftUI

struct ShortcutRecorderRepresentable: NSViewRepresentable {
    @Binding var combo: ShortcutCombo?
    var onChanged: ((ShortcutCombo?) -> Void)?

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.combo = combo
        view.onShortcutChanged = { newCombo in
            DispatchQueue.main.async {
                combo = newCombo
                onChanged?(newCombo)
            }
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        if nsView.combo?.keyCode != combo?.keyCode || nsView.combo?.modifierFlags != combo?.modifierFlags {
            nsView.combo = combo
        }
        nsView.refreshLocalizedStrings()
    }
}
