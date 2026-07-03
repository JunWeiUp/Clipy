import SwiftUI

struct ScreenshotToolbarView: View {
    @ObservedObject var viewModel: ScreenshotEditorViewModel
    var barWidth: CGFloat
    var onDone: () -> Void
    var onPin: () -> Void
    var onDismiss: () -> Void

    @EnvironmentObject private var languageObserver: AppLanguageObserver

    var body: some View {
        let _ = languageObserver.revision

        HStack(spacing: 6) {
            toolGroup
            Divider().frame(height: 18).opacity(0.35)
            colorGroup
            Divider().frame(height: 18).opacity(0.35)
            lineWidthControl
            Divider().frame(height: 18).opacity(0.35)
            historyGroup
            Spacer(minLength: 4)
            actionGroup
        }
        .padding(.horizontal, AppSpacing.sm)
        .frame(width: barWidth, height: ScreenshotChrome.barHeight)
        .background(
            ZStack {
                Color.black.opacity(0.55)
                Rectangle().fill(.regularMaterial)
            }
        )
        .clipShape(TopRoundedRectangle(radius: 8))
        .overlay {
            TopRoundedRectangle(radius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        }
        .contentShape(Rectangle())
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            ForEach(ScreenshotAnnotationTool.allCases) { tool in
                Button {
                    viewModel.annotationModel.selectedTool = tool
                    viewModel.annotationModel.lineWidth = tool.defaultLineWidth
                } label: {
                    Image(systemName: tool.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(viewModel.annotationModel.selectedTool == tool ? Color.accentColor : Color.primary)
                        .frame(width: 26, height: 26)
                        .background(
                            viewModel.annotationModel.selectedTool == tool
                                ? Color.accentColor.opacity(0.22)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: AppCornerRadius.small)
                        )
                }
                .buttonStyle(.plain)
                .help(toolLabel(tool))
            }
        }
    }

    private var colorGroup: some View {
        HStack(spacing: 5) {
            ForEach(Array(ScreenshotChrome.presetColors.enumerated()), id: \.offset) { _, color in
                let swiftColor = Color(nsColor: color)
                let isSelected = viewModel.annotationModel.strokeColor == color
                Button {
                    viewModel.annotationModel.strokeColor = color
                } label: {
                    Circle()
                        .fill(swiftColor)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
                                .padding(-2)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var lineWidthControl: some View {
        Stepper(value: Binding(
            get: { viewModel.annotationModel.lineWidth },
            set: { viewModel.annotationModel.lineWidth = $0 }
        ), in: 1...16) {
            Text(L10n.format(.screenshotLineWidth, Int(viewModel.annotationModel.lineWidth)))
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
        }
        .controlSize(.small)
    }

    private var historyGroup: some View {
        HStack(spacing: 2) {
            Button {
                viewModel.annotationModel.undo()
                viewModel.canvasView?.needsDisplay = true
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.annotationModel.canUndo)

            Button {
                viewModel.annotationModel.redo()
                viewModel.canvasView?.needsDisplay = true
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.annotationModel.canRedo)
        }
    }

    private var actionGroup: some View {
        HStack(spacing: 6) {
            Button(L10n.t(.screenshotDone), action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)

            Button(action: onPin) {
                Image(systemName: "pin.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(L10n.t(.screenshotPin))

            Button {
                viewModel.runOCR()
            } label: {
                if viewModel.isRecognizing {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "text.viewfinder")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.isRecognizing)
            .help(L10n.t(.screenshotOCR))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
            .help(L10n.t(.close))
        }
    }

    private func toolLabel(_ tool: ScreenshotAnnotationTool) -> String {
        switch tool {
        case .rectangle: return L10n.t(.screenshotToolRectangle)
        case .arrow: return L10n.t(.screenshotToolArrow)
        case .ellipse: return L10n.t(.screenshotToolEllipse)
        case .text: return L10n.t(.screenshotToolText)
        case .pencil: return L10n.t(.screenshotToolPencil)
        case .highlighter: return L10n.t(.screenshotToolHighlighter)
        case .eraser: return L10n.t(.screenshotToolEraser)
        case .mosaic: return L10n.t(.screenshotToolMosaic)
        }
    }
}

private struct TopRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
