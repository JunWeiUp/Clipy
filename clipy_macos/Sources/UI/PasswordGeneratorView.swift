import SwiftUI

final class PasswordViewModel: ObservableObject {
    @Published var password = ""
    @Published var copied = false
    @Published private(set) var options = PasswordOptions()

    init() {
        regenerate()
    }

    func regenerate() {
        password = PasswordGenerator.generate(options: options) ?? ""
    }

    /// 修改任一开关后立即重新生成
    func binding(_ keyPath: WritableKeyPath<PasswordOptions, Bool>) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.options[keyPath: keyPath] ?? false },
            set: { [weak self] newValue in
                guard let self else { return }
                options[keyPath: keyPath] = newValue
                regenerate()
            }
        )
    }

    func setLength(_ length: Int) {
        guard length != options.length else { return }
        options.length = length
        regenerate()
    }

    /// 写入系统剪贴板（不模拟粘贴）；历史入库与同步广播由 ClipboardManager 轮询链路完成
    func copyToClipboard() {
        guard !password.isEmpty else { return }
        ClipboardManager.shared.copyToPasteboard(.text(password), simulatePaste: false)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copied = false
        }
    }
}

/// V3 palette for the password window (UI/design-v3/tokens.css + mac.css).
private enum PasswordV3Style {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
    static let content = dynamic(.white, rgb(30, 30, 33))
    static let box = dynamic(rgb(247, 247, 249), rgb(22, 22, 24))
    static let line = dynamic(NSColor(white: 0, alpha: 0.08), NSColor(white: 1, alpha: 0.09))
    static let fill = dynamic(NSColor(white: 0, alpha: 0.045), NSColor(white: 1, alpha: 0.06))
    static let fill2 = dynamic(NSColor(white: 0, alpha: 0.07), NSColor(white: 1, alpha: 0.10))
    static let selection = dynamic(rgb(10, 108, 255, 0.11), rgb(61, 139, 255, 0.22))
    static let control = dynamic(.white, NSColor(white: 1, alpha: 0.08))
    static let controlLine = dynamic(NSColor(white: 0, alpha: 0.12), NSColor(white: 1, alpha: 0.10))
    static let text2 = dynamic(rgb(29, 29, 31, 0.66), rgb(242, 242, 245, 0.66))
    static let text3 = dynamic(rgb(29, 29, 31, 0.42), rgb(242, 242, 245, 0.40))
    static let symbol = dynamic(rgb(190, 24, 93), rgb(244, 114, 182))
    static let ok = dynamic(rgb(22, 163, 74), rgb(52, 211, 153))
    static let warn = dynamic(rgb(217, 119, 6), rgb(251, 191, 36))
    static let bad = dynamic(rgb(229, 56, 59), rgb(255, 107, 107))
}

struct PasswordGeneratorView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: PasswordViewModel

    private var chinese: Bool { PreferencesManager.shared.appLanguage == .zh }
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }

    private var lengthBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.options.length) },
            set: { viewModel.setLength(Int($0.rounded())) }
        )
    }

    var body: some View {
        let _ = languageObserver.revision

        VStack(spacing: 0) {
            Rectangle().fill(PasswordV3Style.line).frame(height: 0.5)
            VStack(alignment: .leading, spacing: 16) {
                passwordBox
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(L10n.t(.passwordLengthLabel))
                    HStack(spacing: 12) {
                        Slider(value: lengthBinding, in: 8...64)
                            .controlSize(.small)
                            .accessibilityLabel(L10n.t(.passwordLengthLabel))
                        Text("\(viewModel.options.length)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .frame(width: 40, height: 26)
                            .background(PasswordV3Style.control, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(PasswordV3Style.controlLine, lineWidth: 0.5))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel(L10n.t(.passwordCharacterSet))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        charsetCard(text("大写字母", "Uppercase"), sample: "A-Z", keyPath: \.useUppercase)
                        charsetCard(text("小写字母", "Lowercase"), sample: "a-z", keyPath: \.useLowercase)
                        charsetCard(text("数字", "Digits"), sample: "0-9", keyPath: \.useDigits)
                        charsetCard(text("符号", "Symbols"), sample: "!@#$%", keyPath: \.useSymbols)
                    }
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text("排除易混淆字符", "Exclude ambiguous characters"))
                            .font(.system(size: 13, weight: .medium))
                        Text(text("不使用 I l 1 | O 0 o", "Avoids I l 1 | O 0 o"))
                            .font(.system(size: 11.5)).foregroundStyle(PasswordV3Style.text3)
                    }
                    Spacer()
                    Toggle(L10n.t(.passwordExcludeAmbiguous), isOn: viewModel.binding(\.excludeAmbiguous))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(PasswordV3Style.content, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PasswordV3Style.line, lineWidth: 0.5))
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            Spacer(minLength: 0)
            Rectangle().fill(PasswordV3Style.line).frame(height: 0.5)
            HStack(spacing: 8) {
                Button(action: { viewModel.regenerate() }) {
                    Label(L10n.t(.passwordRegenerate), systemImage: "arrow.clockwise")
                }
                .buttonStyle(PasswordV3ButtonStyle(primary: false))
                Spacer()
                if viewModel.copied {
                    Label(L10n.t(.passwordCopied), systemImage: "checkmark.circle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PasswordV3Style.ok)
                        .transition(.opacity)
                }
                Button(action: { viewModel.copyToClipboard() }) {
                    Label(L10n.t(.passwordCopy), systemImage: "doc.on.doc")
                }
                .buttonStyle(PasswordV3ButtonStyle(primary: true))
                .disabled(viewModel.password.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(PasswordV3Style.content)
        .frame(minWidth: AppWindowSize.passwordGeneratorMin.width,
               minHeight: AppWindowSize.passwordGeneratorMin.height)
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(PasswordV3Style.text2)
    }

    private var passwordBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            coloredPassword
                .font(.system(size: 21, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .textSelection(.enabled)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < strengthLevel ? strengthInfo.color : PasswordV3Style.fill2)
                        .frame(height: 4)
                }
            }
            .padding(.top, 14)
            HStack(spacing: AppSpacing.sm) {
                if strengthLevel > 0 {
                    Label(strengthInfo.text, systemImage: strengthInfo.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(strengthInfo.color)
                }
                Spacer()
                Text(L10n.format(.passwordEntropy, String(format: "%.0f", viewModel.password.isEmpty ? 0 : viewModel.options.entropyBits())))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(PasswordV3Style.text3)
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 14)
        .background(PasswordV3Style.box, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PasswordV3Style.line, lineWidth: 0.5))
    }

    private func charsetCard(_ title: String, sample: String, keyPath: WritableKeyPath<PasswordOptions, Bool>) -> some View {
        let binding = viewModel.binding(keyPath)
        let on = binding.wrappedValue
        return Button { binding.wrappedValue.toggle() } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on ? AppColor.accent : PasswordV3Style.control)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(on ? Color.clear : PasswordV3Style.controlLine, lineWidth: 1)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                Spacer(minLength: 4)
                Text(sample).font(.system(size: 12, design: .monospaced)).foregroundStyle(PasswordV3Style.text3)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(on ? PasswordV3Style.selection : PasswordV3Style.fill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AppColor.accent.opacity(on ? 0.35 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var coloredPassword: Text {
        let value = viewModel.password
        guard !value.isEmpty else { return Text("—").foregroundColor(PasswordV3Style.text3) }
        return value.reduce(Text("")) { result, character in
            let color: Color = character.isNumber ? AppColor.accent : (character.isLetter ? .primary : PasswordV3Style.symbol)
            return result + Text(String(character)).foregroundColor(color)
        }
    }

    private var strengthLevel: Int {
        guard !viewModel.password.isEmpty else { return 0 }
        switch viewModel.options.strength {
        case .weak: return 1
        case .fair: return 2
        case .strong: return 3
        case .veryStrong: return 4
        }
    }

    private var strengthInfo: (text: String, color: Color, icon: String) {
        switch viewModel.options.strength {
        case .weak:
            return (L10n.t(.passwordStrengthWeak), PasswordV3Style.bad, "exclamationmark.shield")
        case .fair:
            return (L10n.t(.passwordStrengthFair), PasswordV3Style.warn, "shield.lefthalf.filled")
        case .strong:
            return (L10n.t(.passwordStrengthStrong), PasswordV3Style.ok, "shield")
        case .veryStrong:
            return (L10n.t(.passwordStrengthVeryStrong), AppColor.accent, "checkmark.shield")
        }
    }
}

/// 34pt V3 footer buttons: secondary (control surface) and primary (accent fill).
private struct PasswordV3ButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(primary ? AppColor.accent : PasswordV3Style.control, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(primary ? Color.clear : PasswordV3Style.controlLine, lineWidth: 0.5))
            .shadow(color: primary ? AppColor.accent.opacity(0.35) : .black.opacity(0.06), radius: 1, y: 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

final class PasswordGeneratorWindow {
    private static var shared: PasswordGeneratorWindow?

    private let session = WindowSession<PasswordGeneratorView>()
    private var viewModel: PasswordViewModel?

    static func show() {
        if shared == nil {
            shared = PasswordGeneratorWindow()
        }
        shared?.showWindow()
    }

    private func showWindow() {
        session.present(
            create: { [self] in
                let viewModel = PasswordViewModel()
                self.viewModel = viewModel
                return HostingWindow(
                    title: L10n.t(.generatePassword),
                    size: AppWindowSize.passwordGenerator,
                    minSize: AppWindowSize.passwordGeneratorMin,
                    frameAutosaveName: "PasswordGeneratorWindow"
                ) {
                    PasswordGeneratorView(viewModel: viewModel)
                }
            },
            onPrepareForClose: {},
            onTeardown: { [weak self] in
                self?.viewModel = nil
                PasswordGeneratorWindow.shared = nil
            },
            update: { window in
                window.title = L10n.t(.generatePassword)
                // Keep passwords visible while the user switches to the destination app.
                window.level = .floating
                window.hidesOnDeactivate = false
                window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            }
        )
    }
}
