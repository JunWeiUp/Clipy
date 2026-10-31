import SwiftUI

/// Presentation-only tool grouping. Actions still use the panel's existing focus handoff.
struct MenuBarPanelToolsView: View {
    @ObservedObject var model: MenuBarPanelModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.t(.menuTools)).font(AppFont.title)
                        Spacer()
                        Text(L10n.t(.panelToolsHint)).font(AppFont.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                    capture
                    group(.panelToolsLearning, tools: [.word, .wordBook], color: colorScheme == .dark ? Color(red: 0.53, green: 0.76, blue: 0.66) : Color(red: 0.16, green: 0.50, blue: 0.39))
                    group(.panelToolsEfficiency, tools: [.password], color: colorScheme == .dark ? Color(red: 0.69, green: 0.67, blue: 0.87) : Color(red: 0.41, green: 0.39, blue: 0.65))
                }.padding(.bottom, 12)
            }.onChange(of: model.selectedID) { id in if let id { proxy.scrollTo(id) } }
        }
    }

    private var capture: some View {
        VStack(spacing: 15) {
            Button { model.useTool(.capture) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "viewfinder").font(.system(size: 22))
                        .frame(width: 38, height: 38).foregroundStyle(.white)
                        .background(AppColor.accent, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t(.panelCaptureShortcut)).font(.system(size: 15, weight: .semibold))
                        Text(L10n.t(.panelCaptureSummary)).font(AppFont.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 32)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.t(.panelCaptureToolHint))
                .onHover { if $0 { model.selectedID = "t:capture" } }
            HStack(spacing: 8) {
                captureButton(.panelCaptureRegionShort, symbol: "viewfinder", action: .region, primary: true)
                captureButton(.panelCaptureWindowShort, symbol: "macwindow", action: .window)
                captureButton(.panelCaptureFullscreenShort, symbol: "display", action: .fullscreen)
            }
        }.padding(16)
            .background(AppColor.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
                AppColor.accent.opacity(model.selectedID == "t:capture" ? 0.6 : 0.14)))
            .id("t:capture")
    }

    private func captureButton(_ title: L10nKey, symbol: String,
                               action: MenuBarPanelModel.Action, primary: Bool = false) -> some View {
        Button { model.onAction?(action) } label: {
            Label(L10n.t(title), systemImage: symbol).font(AppFont.secondary).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 38).contentShape(Rectangle())
                .foregroundStyle(primary ? Color.white : Color.primary)
                .background(primary ? AppColor.accent : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private func group(_ title: L10nKey, tools: [MenuBarPanelModel.Tool], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t(title)).font(AppFont.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(tools, id: \.rawValue) { tool in
                    Button { model.useTool(tool) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: Self.cardSymbol(tool)).font(.system(size: 17, weight: .light))
                                .frame(width: 36, height: 36).foregroundStyle(color)
                                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t(tool.title))
                                    .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Text(L10n.t(tool.hint)).font(AppFont.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(model.selectedID == "t:" + tool.rawValue ? AppColor.accent.opacity(0.07) : Color(nsColor: .controlBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                                model.selectedID == "t:" + tool.rawValue ? AppColor.accent.opacity(0.6) : Color.primary.opacity(0.09)))
                    }.buttonStyle(.plain).help(L10n.t(tool.hint)).id("t:" + tool.rawValue)
                        .onHover { if $0 { model.selectedID = "t:" + tool.rawValue } }
                }
            }
        }
    }

    /// Line icons matching the V3 tool cards (book-open-text / book-marked / key-round).
    private static func cardSymbol(_ tool: MenuBarPanelModel.Tool) -> String {
        switch tool {
        case .word: return "book"
        case .wordBook: return "book.closed"
        case .password: return "key"
        default: return tool.symbol
        }
    }
}
