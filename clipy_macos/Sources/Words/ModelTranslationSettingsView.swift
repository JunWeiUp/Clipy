import SwiftUI

struct ModelTranslationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = ModelTranslationConfiguration.current
    @State private var key = ""
    @State private var replaceKey = false
    @State private var error: String?
    @StateObject private var modelList = ModelListViewModel()
    @State private var modelFilter = ""
    private func t(_ zh: String, _ en: String) -> String { ModelTranslationText.t(zh, en) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("模型翻译设置", "Model translation settings")).font(.title2)
            Text(t("支持 Chat Completions 兼容接口。填写基础地址或完整接口地址，再获取模型列表或手动填写。支持本地 HTTP，例如 http://127.0.0.1:3425。",
                   "Use a Chat Completions compatible base URL or full endpoint, then fetch models or enter one manually. Local HTTP is supported, e.g. http://127.0.0.1:3425."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(t("接口地址", "API endpoint"), text: $configuration.endpoint)
            Toggle(t("更新 API Key（留空则删除已存密钥）", "Update API key (empty removes the saved key)"), isOn: $replaceKey)
            if replaceKey { SecureField("API Key", text: $key) }
            HStack {
                TextField(t("模型名称（可手动填写）", "Model name (manual entry supported)"), text: $configuration.model)
                Button(t(modelList.isLoading ? "获取中…" : "获取模型", modelList.isLoading ? "Fetching…" : "Fetch models")) {
                    error = nil
                    modelFilter = ""
                    modelList.load(configuration: configuration,
                                   replacementKey: replaceKey ? key.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
                }.disabled(modelList.isLoading || configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if modelList.isLoading { ProgressView().controlSize(.small) }
            if !modelList.models.isEmpty {
                TextField(t("筛选模型", "Filter models"), text: $modelFilter)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(modelList.models.filter { modelFilter.isEmpty || $0.localizedCaseInsensitiveContains(modelFilter) }, id: \.self) { model in
                            Button { configuration.model = model } label: {
                                HStack {
                                    Text(model).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer()
                                    if configuration.model == model { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: 140)
                Text(t("点击模型即可选择；列表可能包含不支持对话翻译的模型。", "Click a model to select it. Some listed models may not support chat translation."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let listError = modelList.error {
                Text(listError).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Text(t("密钥保存在系统钥匙串。仅点击翻译时向此接口发送文本；译文不保存到单词本。",
                   "Keys are stored in Keychain. Text is sent to this endpoint only on submission; translations are not saved to vocabulary."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("保存", "Save")) {
                    do {
                        _ = try configuration.validatedURL()
                        if replaceKey { try ModelTranslationKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        try configuration.save()
                        key = ""
                        dismiss()
                    } catch {
                        self.error = (error as? ModelTranslationError)?.message ?? t("保存失败，请重试。", "Save failed. Please retry.")
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: configuration.endpoint) { _ in modelList.reset() }
        .onChange(of: key) { _ in modelList.reset() }
        .onChange(of: replaceKey) { _ in modelList.reset() }
        .onDisappear { modelList.reset() }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 460)
    }
}
