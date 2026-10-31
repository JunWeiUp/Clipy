import Foundation
import Combine

/// Settings-sheet lifetime only: one request, bounded list, no persistent cache.
@MainActor
final class ModelListViewModel: ObservableObject {
    @Published private(set) var models: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        models = []
        error = nil
        isLoading = false
    }

    func load(configuration: ModelTranslationConfiguration, replacementKey: String?) {
        reset()
        let token = generation
        isLoading = true
        task = Task { @MainActor [weak self] in
            do {
                // Validate before accessing the saved credential.
                _ = try configuration.modelsURL()
                let key = try replacementKey ?? ModelTranslationKeychain.read()
                let models = try await ModelTranslationService().models(configuration: configuration, key: key)
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.models = models
                self.isLoading = false
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                if let failure = error as? ModelTranslationError, case .http(let status) = failure {
                    self.error = ModelTranslationText.t("获取模型失败（HTTP (status)），请检查地址和密钥，或手动填写模型名称。",
                                                       "Could not fetch models (HTTP (status)). Check endpoint/key or enter a model manually.")
                } else {
                    self.error = (error as? ModelTranslationError)?.message
                        ?? ModelTranslationText.t("获取模型失败，请重试或手动填写模型名称。", "Could not fetch models. Retry or enter a model manually.")
                }
                self.isLoading = false
                self.task = nil
            }
        }
    }

    deinit { task?.cancel() }
}
