import AppKit
import SwiftUI

@MainActor
final class SmartSwitchWindow {
    static let shared = SmartSwitchWindow()
    private let session = WindowSession<SmartSwitchView>()
    private let inputSource = SmartSwitchInputSourceSession()
    private let focusSession = SmartSwitchWindowFocusSession()
    private var model: SmartSwitchViewModel?
    private var voiceTicket: UUID?
    private var voiceReady: ((Bool) -> Void)?
    private var escapePasteText: String?
    private var handoffOriginPID: pid_t?
    var hasKeyboardFocus: Bool { session.keyWindow?.firstResponder is SmartSwitchCommandTextView }

    func show() {
        focusSession.begin(previousPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        voiceTicket = nil
        voiceReady = nil
        present()
    }

    func showForVoiceRouting(ticket: UUID, previousPID: pid_t, ready: @escaping (Bool) -> Void) {
        focusSession.begin(previousPID: previousPID)
        voiceTicket = ticket
        voiceReady = ready
        present()
    }

    func cancelVoiceRouting(ticket: UUID) {
        guard voiceTicket == ticket else { return }
        session.close()
    }

    func preserveVoiceRouting(ticket: UUID) {
        guard voiceTicket == ticket else { return }
        // Release the pending callback without closing, restoring focus, or
        // reactivating the app (which could retrigger a peripheral's profile).
        voiceTicket = nil
        voiceReady = nil
        model?.voiceRoutingInterrupted()
    }

    private func present() {
        inputSource.restore()
        session.present(create: { [self] in
            let model = SmartSwitchViewModel()
            self.model = model
            model.onWillActivate = { [weak self] in
                self?.handoffOriginPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                self?.inputSource.restore()
                self?.session.hideForHandoff()
            }
            model.onSuccess = { [weak self] in
                // Activation is asynchronous; the destination may not be frontmost yet.
                self?.focusSession.handOff()
                self?.session.close()
            }
            model.onActivationFailed = { [weak self, weak model] in
                let front = NSWorkspace.shared.frontmostApplication
                if front?.processIdentifier == self?.handoffOriginPID ||
                    front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || front?.bundleIdentifier == "dev.zcode.app" {
                    self?.session.revealExistingWindow()
                    model?.focusGeneration += 1
                }
            }
            model.onPaste = { [weak self] text in self?.escapePasteText = text; self?.session.close() }
            let window = SmartSwitchInputPanel(title: L10n.t(.smartSwitchTitle), size: CGSize(width: 720, height: 500),
                                 minSize: CGSize(width: 620, height: 440), frameAutosaveName: "SmartSwitchWindow") {
                SmartSwitchView(model: model, onFocus: { [weak self] in self?.selectInputSource() })
            }
            window.onEscape = { [weak self, weak window, weak model] in
                guard let self else { return }
                // Capture before close clears the view model. Read the native
                // editor when focused so even the latest dictation is included.
                self.escapePasteText = model?.output ?? (window?.firstResponder as? SmartSwitchCommandTextView)?.string ?? model?.query
                self.session.close()
            }
            return window
        }, onPrepareForClose: { [weak self] in
            let pasteText = self?.escapePasteText
            self?.escapePasteText = nil
            let ready = self?.voiceReady
            self?.voiceReady = nil
            self?.voiceTicket = nil
            self?.handoffOriginPID = nil
            ready?(false)
            self?.model?.close()
            self?.inputSource.restore()
            self?.focusSession.close(pasteText: pasteText)
        }, onTeardown: { [weak self] in
            self?.model = nil
        }, update: { [weak self] window in
            window.title = L10n.t(.smartSwitchTitle)
            self?.model?.present()
            window.setContentSize(NSSize(width: 720, height: 500))
        })
    }

    private func selectInputSource() {
        let selected = inputSource.selectDoubao()
        model?.inputSourceWarning = selected ? nil : L10n.t(.smartSwitchDoubaoUnavailable)
        guard let ready = voiceReady else { return }
        guard selected else { voiceReady = nil; ready(false); return }
        let ticket = voiceTicket
        // Give the new native text-input client/input source a run-loop settle
        // interval before forwarding the hold-to-talk modifier to Doubao.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.voiceTicket == ticket, self.voiceReady != nil else { return }
            self.voiceReady = nil
            ready(self.hasKeyboardFocus)
        }
    }

    func showSettings() {
        focusSession.handOff()
        session.close()
        SettingsWindow.shared.show()
        // Wait for newly-created settings anchors to be attached before scrolling.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appSettingsNavigate, object: "smartSwitch")
        }
    }

}

private struct SmartSwitchView: View {
    @ObservedObject var model: SmartSwitchViewModel
    let onFocus: () -> Void

    var body: some View {
        AppListWindowLayout {
            AppWindowHeader {
                HStack {
                    Label(L10n.t(.smartSwitchTitle), systemImage: "arrow.triangle.swap")
                    Spacer()
                    Button(L10n.t(.preferences)) { SmartSwitchWindow.shared.showSettings() }
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                SmartSwitchActionStrip(model: model)
                SmartSwitchTextInput(text: $model.query, focusGeneration: model.focusGeneration,
                                     hasCandidates: !model.candidates.isEmpty, onFocus: onFocus,
                                     onSubmit: model.submit, onMove: model.moveSelection)
                    .frame(height: 76)
                    .modifier(AppInputSurface())
                HStack {
                    Text(L10n.t(.smartSwitchInputHint)).font(AppFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.isBusy { ProgressView().controlSize(.small) }
                    Button(model.selectedAction == .automatic ? L10n.t(.smartSwitchExecute) : model.selectedAction.title) { model.submit() }
                        .disabled(!model.canSubmit)
                }
                if let warning = model.inputSourceWarning {
                    Text(warning).font(AppFont.caption).foregroundStyle(.orange)
                }
                if let message = model.message {
                    Text(message).font(AppFont.body).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if model.isBusy {
                    Text(L10n.t(.smartSwitchWorking)).font(AppFont.caption).foregroundStyle(.secondary)
                }
                if let output = model.output {
                    ScrollView { Text(output).font(AppFont.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(minHeight: 70, maxHeight: 180)
                    HStack {
                        Button(SmartActionL10n.t("复制结果", "Copy result")) { ClipboardManager.shared.writeToPasteboard(.text(output)) }
                        Button(SmartActionL10n.t("继续处理", "Use as input")) { model.useOutputAsInput() }
                        Spacer()
                        Button(SmartActionL10n.t("粘贴回原应用", "Paste back")) { model.pasteBack() }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: AppSpacing.xs) {
                            ForEach(model.candidates) { target in
                                Button { model.choose(target.id) } label: {
                                    HStack {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: target.applicationPath))
                                            .resizable().frame(width: 24, height: 24)
                                        Text(target.name)
                                        Spacer()
                                        if model.selectedID == target.id { Image(systemName: "return") }
                                    }
                                    .padding(AppSpacing.sm)
                                    .background(model.selectedID == target.id ? AppColor.accent.opacity(0.15) : Color.clear)
                                    .cornerRadius(AppCornerRadius.small)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(model.isBusy).id(target.id)
                            }
                        }
                    }
                    .onChange(of: model.selectedID) { id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            .padding(AppSpacing.md)
        }
    }
}

struct SmartSwitchTextInput: NSViewRepresentable {
    @Binding var text: String
    var focusGeneration: Int
    var hasCandidates: Bool
    var onFocus: () -> Void
    var onSubmit: () -> Void
    var onMove: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let editor = SmartSwitchCommandTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.font = AppFont.resolveFont(size: 20, weight: .regular)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 2, height: 4)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(L10n.t(.smartSwitchInputLabel))
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? SmartSwitchCommandTextView else { return }
        context.coordinator.text = $text
        if editor.focusGeneration != focusGeneration {
            // Cached windows must discard unfinished composition on close/reopen.
            editor.unmarkText()
            editor.string = text
        } else if !editor.hasMarkedText(), editor.string != text {
            editor.string = text
        }
        editor.onSubmit = onSubmit
        editor.onMove = onMove
        editor.onFocus = onFocus
        editor.hasCandidates = hasCandidates
        editor.focusGeneration = focusGeneration
        editor.focusIfNeeded()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}

final class SmartSwitchCommandTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onFocus: (() -> Void)?
    var hasCandidates = false
    var focusGeneration = 0
    private var appliedFocus: Int?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    func focusIfNeeded() {
        guard window != nil, appliedFocus != focusGeneration else { return }
        let ticket = focusGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusGeneration == ticket, self.appliedFocus != ticket,
                  let window = self.window, window.isVisible,
                  window.makeFirstResponder(self) else { return }
            self.appliedFocus = ticket
            self.onFocus?()
        }
    }

    override func keyDown(with event: NSEvent) {
        // Check BEFORE interpretKeyEvents can commit marked text. That same Return
        // must never both accept an IME candidate and submit an application command.
        let composing = hasMarkedText()
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !composing, modifiers.isEmpty {
            if event.keyCode == 36 || event.keyCode == 76 {
                if !event.isARepeat { onSubmit?() }
                return
            }
            if hasCandidates, event.keyCode == 125 || event.keyCode == 126 {
                onMove?(event.keyCode == 125 ? 1 : -1)
                return
            }
        }
        super.keyDown(with: event)
    }
}
