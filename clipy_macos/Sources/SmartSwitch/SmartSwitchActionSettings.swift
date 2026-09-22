import AppKit
import SwiftUI

struct SmartSwitchActionSettings: View {
    @ObservedObject var store: SmartSwitchStore
    var body: some View {
        Section(SmartActionL10n.t("功能按钮与语音动作", "Action buttons and voice commands")) {
            Text(SmartActionL10n.t("智能模式优先识别“打开某个软件”，明确匹配时直接切换。六个功能按钮全部显示；在按钮区域滚动可循环选择，回车执行。", "Smart mode prioritizes explicit app-launch commands and opens exact matches immediately. All six action buttons stay visible; scroll over them to cycle, then press Return."))
                .font(AppFont.caption).foregroundStyle(.secondary)
            ForEach(store.configuration.orderedActions) { action in
                HStack {
                    Image(systemName: action.icon).frame(width: 20)
                    Text(action.title)
                    Spacer()
                    Button { move(action, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(store.configuration.orderedActions.first == action)
                        .help(SmartActionL10n.t("上移", "Move up"))
                    Button { move(action, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(store.configuration.orderedActions.last == action)
                        .help(SmartActionL10n.t("下移", "Move down"))
                }
            }
            Picker(SmartActionL10n.t("网页搜索", "Web search"), selection: $store.configuration.searchEngine) {
                ForEach(SmartSwitchSearchEngine.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField(SmartActionL10n.t("默认翻译语言", "Default translation language"), text: $store.configuration.translationLanguage)
            Text(SmartActionL10n.t("ZCode 动作始终新建无项目对话；输入框有文字时自动预填，不自动发送。“ZCode 新对话”也支持空白对话。", "ZCode actions always prepare a projectless chat and prefill the input text without sending. New ZCode chat also accepts empty input."))
                .font(AppFont.caption).foregroundStyle(.secondary)
        }
    }
    private func move(_ action: SmartSwitchAction, by delta: Int) {
        var order = store.configuration.orderedActions
        guard let index = order.firstIndex(of: action), order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        store.configuration.actionOrder = order
    }
}
