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

struct PasswordGeneratorView: View {
    @EnvironmentObject private var languageObserver: AppLanguageObserver
    @ObservedObject var viewModel: PasswordViewModel

    private var lengthBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.options.length) },
            set: { viewModel.setLength(Int($0.rounded())) }
        )
    }

    var body: some View {
        let _ = languageObserver.revision

        VStack(spacing: 0) {
            AppWindowHeader {
                HStack(spacing: AppSpacing.sm) {
                    if viewModel.copied {
                        Label(L10n.t(.passwordCopied), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button(action: { viewModel.regenerate() }) {
                        Label(L10n.t(.passwordRegenerate), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AppToolbarButtonStyle())
                    Button(action: { viewModel.copyToClipboard() }) {
                        Label(L10n.t(.passwordCopy), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.password.isEmpty)
                }
            }
            Divider()

            AppFormWindowLayout {
                Form {
                    Section {
                        VStack(spacing: AppSpacing.xs) {
                            Text(viewModel.password.isEmpty ? "—" : viewModel.password)
                                .font(.system(size: 22, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.5)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.md)
                            HStack(spacing: AppSpacing.sm) {
                                strengthBadge
                                Spacer()
                                Text(L10n.format(.passwordEntropy, String(format: "%.0f", viewModel.options.entropyBits())))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section(header: Text(L10n.t(.passwordCharacterSet))) {
                        HStack(spacing: AppSpacing.sm) {
                            Text(L10n.t(.passwordLengthLabel))
                            Slider(value: lengthBinding, in: 8...64, step: 1)
                            Text("\(viewModel.options.length)")
                                .monospacedDigit()
                                .frame(width: 26, alignment: .trailing)
                        }
                        Toggle(L10n.t(.passwordUppercase), isOn: viewModel.binding(\.useUppercase))
                        Toggle(L10n.t(.passwordLowercase), isOn: viewModel.binding(\.useLowercase))
                        Toggle(L10n.t(.passwordDigits), isOn: viewModel.binding(\.useDigits))
                        Toggle(L10n.t(.passwordSymbols), isOn: viewModel.binding(\.useSymbols))
                        Toggle(L10n.t(.passwordExcludeAmbiguous), isOn: viewModel.binding(\.excludeAmbiguous))
                    }
                }
            }
        }
        .frame(minWidth: AppWindowSize.passwordGeneratorMin.width,
               minHeight: AppWindowSize.passwordGeneratorMin.height)
    }

    private var strengthBadge: some View {
        let info = strengthInfo
        return Label(info.text, systemImage: info.icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(info.color)
    }

    private var strengthInfo: (text: String, color: Color, icon: String) {
        switch viewModel.options.strength {
        case .weak:
            return (L10n.t(.passwordStrengthWeak), .red, "exclamationmark.shield.fill")
        case .fair:
            return (L10n.t(.passwordStrengthFair), .orange, "shield.lefthalf.filled")
        case .strong:
            return (L10n.t(.passwordStrengthStrong), .green, "shield.fill")
        case .veryStrong:
            return (L10n.t(.passwordStrengthVeryStrong), .accentColor, "shield.lefthalf.filled.badge.checkmark")
        }
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
            }
        )
    }
}
