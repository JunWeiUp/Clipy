import Combine
import Foundation

final class AppLanguageObserver: ObservableObject {
    static let shared = AppLanguageObserver()

    @Published private(set) var revision = 0

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
    }

    @objc private func languageDidChange() {
        revision += 1
    }
}
