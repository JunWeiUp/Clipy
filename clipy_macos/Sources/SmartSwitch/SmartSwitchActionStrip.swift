import AppKit
import SwiftUI

struct SmartSwitchActionStrip: View {
    @ObservedObject var model: SmartSwitchViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text(SmartActionL10n.t("滚轮循环选择 · 回车执行", "Wheel to cycle · Return to execute"))
                    .font(AppFont.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.sm), count: 3), spacing: AppSpacing.sm) {
                ForEach(model.availableActions) { action in
                    Button { select(action) } label: {
                        Label(action.title, systemImage: action.icon)
                            .lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(SmartActionButtonStyle(selected: model.selectedAction == action))
                    .help(action.title)
                    .accessibilityValue(model.selectedAction == action ? SmartActionL10n.t("已选择", "Selected") : "")
                }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .background(SmartSwitchWheelArea { model.cycleAction($0) })
    }

    private func select(_ action: SmartSwitchAction) {
        model.selectAction(action, execute: action.acceptsEmptyInput || !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private struct SmartActionButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(AppFont.caption)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(configuration.isPressed ? 0.22 : 0.12) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small))
            .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.small).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

private struct SmartSwitchWheelArea: NSViewRepresentable {
    var onCycle: (Int) -> Void
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ view: WheelView, context: Context) { view.onCycle = onCycle }

    final class WheelView: NSView {
        var onCycle: ((Int) -> Void)?
        private var monitor: Any?
        private var selection = SmartSwitchWheelSelection()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, window.isVisible, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                if let step = self.selection.step(delta: delta, precise: event.hasPreciseScrollingDeltas,
                                                 momentum: !event.momentumPhase.isEmpty, time: event.timestamp) {
                    self.onCycle?(step)
                }
                return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
