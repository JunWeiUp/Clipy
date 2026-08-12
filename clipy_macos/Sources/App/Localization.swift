import Foundation

enum AppLanguage: String, CaseIterable {
    case zh
    case en

    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }

    static var systemDefault: AppLanguage {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("appLanguageDidChange")
}

enum L10nKey: String {
    case recordShortcut
    case recordingShortcut
    case preferences
    case screenshotPreferences
    case language
    case deviceNameForSync
    case enterDeviceName
    case save
    case success
    case deviceNameUpdated
    case ok
    case historyLimit
    case moreHistory
    case changesNextCopy
    case excludedBundleIds
    case enableLanSync
    case syncPort
    case authorizedDevicesComma
    case syncTargetsHint
    case syncClipboardToDevice
    case syncNotificationsToDevice
    case close
    case history
    case noHistory
    case snippets
    case noSnippets
    case source
    case lanDevices
    case authorizedDevices
    case noDevicesFound
    case refreshDevices
    case refreshingDevices
    case myIPAddress
    case staleAuthorizedDevicesWarning
    case syncLocalNameHint
    case authorized
    case sendFile
    case sendText
    case chooseTextToSend
    case sendTextHint
    case enterTextToSend
    case editSnippets
    case clearHistory
    case clearHistoryConfirm
    case showLogs
    case quit
    case chooseFileToSend
    case send
    case sendFailed
    case snippetEditorTitle
    case nameColumn
    case newFolder
    case newSnippet
    case selectFolderOrSnippet
    case folderName
    case shortcut
    case folderShortcutHint
    case snippetTitle
    case content
    case confirmDeleteFolder
    case deleteFolderWarning
    case delete
    case cancel
    case importFailed
    case exportSnippets
    case exportFailed
    case folderFallback
    case snippetFallback
    case addSnippet
    case addFolder
    case importAction
    case exportAction
    case searchLogs
    case copyAll
    case revealLogFile
    case clear
    case clipyLogs
    case quitClipy
    case editMenu
    case undo
    case redo
    case cut
    case copy
    case paste
    case selectAll
    case fileReceived
    case receivedFileFrom
    case transferStation
    case addText
    case addFile
    case addFolderTransfer
    case clearAll
    case title
    case type
    case dragOrAddToTransfer
    case enterTextContent
    case add
    case selectFiles
    case selectFolder
    case clearAllTransfer
    case clearAllTransferConfirm
    case copyContent
    case showInFinder
    case openFolder
    case openFile
    case saveAs
    case saveAsSuccess
    case setTemporary
    case setPermanent
    case searchHistory
    case searchHistoryPlaceholder
    case noSearchResults
    case time
    case pasteCount
    case phoneNotifications
    case noNotifications
    case enableNotificationSync
    case notificationSync
    case dismissOnPhone
    case clearAllOnPhone
    case notificationFilter
    case notificationSound
    case clearNotifications
    case bannerRules
    case bannerRulesHint
    case bannerKeywords
    case bannerKeywordsHint
    case blockedKeywords
    case blockedKeywordsHint
    case noReceivedApps
    case searchApps
    case notificationSettings
    case macNotificationPermission
    case macNotificationGranted
    case macNotificationDenied
    case notificationArchivedBadge
    case openNotificationSettings
    case launchAtLogin
    case launchAtLoginFailed
    case accessibilityPermission
    case accessibilityGranted
    case accessibilityNotGranted
    case accessibilityRequiredTitle
    case accessibilityRequiredMessage
    case openSystemSettings
    case relativeTimeJustNow
    case relativeTimeMinutes
    case relativeTimeHours
    case relativeTimeDays
    case transferStatusFormat
    case error
    case clearShortcut
    case searchResultCount
    case historyTotalCount
    case historyShownOfTotal
    case historyLoadMore
    case noSearchResultsWithTotal
    case historyCurrentCount
    case historyWithCount
    case location
    case pasteFileName
    case pasteFile
    case pinToTop
    case unpinFromTop
    case preview
    case selectHistoryToPreview
    case historyTypeText
    case historyTypeImage
    case historyTypeRTF
    case historyTypePDF
    case historyTypeFile
    case historyTypeHTML
    case historyTypeMarkdown
    case historyTypePlainText
    case historyTypeJSON
    case historyPreviewTruncated
    case historyPreviewLoadFailed
    case historyDataSize
    case historyFilterAll
    case historyFilterRichText
    case historyFilterSource
    case historyFilterAllSources
    case encryptHistoryAtRest
    case encryptHistoryAtRestDescription
    case historyEncryptionFailed
    case historyEncryptionInProgress
    case syncPairingSecret
    case syncPairingSecretHint
    case syncPairingSecretDefaultWarning
    case syncOfflineAuthorizedDevices
    case deviceOnline
    case deviceOffline
    case syncAddManualDevice
    case syncManualDeviceHost
    case syncManualDevicePort
    case syncManualDeviceHint
    case syncAdd
    case historyRegexSearch
    case historyDateFilter
    case historyDateFilterAll
    case historyDateFilterToday
    case historyDateFilterWeek
    case historyDateFilterMonth
    case historyCategoryURL
    case historyCategoryEmail
    case historyCategoryCode
    case historyCategoryJSON
    case pastePlainText
    case saveAsSnippet
    case searchGlobalShortcut
    case searchGlobalShortcutDescription
    case screenshot
    case screenshotRegion
    case screenshotWindow
    case screenshotFullscreen
    case screenshotShortcut
    case screenshotShortcutDescription
    case screenshotDefaultMode
    case screenshotEditorTitle
    case screenshotEdit
    case screenshotEditDone
    case screenshotCopy
    case screenshotPin
    case screenshotOCR
    case screenshotOCRResult
    case screenshotOCRNoText
    case screenshotCopyText
    case screenshotTextPrompt
    case screenshotTextPromptMessage
    case screenshotToolSelection
    case screenshotToolRectangle
    case screenshotToolArrow
    case screenshotToolEllipse
    case screenshotToolText
    case screenshotToolMosaic
    case screenshotLineWidth
    case screenshotFontSize
    case screenshotArrowSolid
    case screenshotArrowDashed
    case screenshotTextBackground
    case screenshotMosaicRect
    case screenshotMosaicBrushSmall
    case screenshotMosaicBrushMedium
    case screenshotMosaicBrushLarge
    case screenCaptureRequiredTitle
    case screenCaptureRequiredMessage
    case screenshotCaptureFailedTitle
    case screenshotCaptureFailedMessage
    case screenCapturePermission
    case requestScreenCaptureAccess
    case screenCapturePermissionHint
    case screenshotUndo
    case screenshotRedo
    case screenshotDone
    case screenshotHint
    case screenshotSelectionHint
    case screenshotCopied
    case screenshotMagnifier
    case screenshotElementSnap
    case screenshotToolPencil
    case screenshotToolHighlighter
    case screenshotToolEraser
    case screenshotPinOpacity
    case screenshotElementSnapAccessibilityHint
    case screenshotAutoSave
    case screenshotSavePath
    case screenshotChooseSavePath
    case screenshotSavedTo
    case screenshotResolution
    case screenshotResolutionAuto
    case screenshotResolutionNative
    case screenshotResolutionHint
    case screenshotPostAction
    case screenshotPostActionHint
    case screenshotPostActionCopy
    case screenshotPostActionPin
    case screenshotPostActionOCR
    case screenshotPostActionSaveAs
    case screenshotOCRLanguage
    case screenshotOCRLanguageHint
    case screenshotOCRLanguageEnglish
    case screenshotOCRLanguageChineseEnglish
    case screenshotOCRLanguageAuto
}

struct L10n {
    static func t(_ key: L10nKey) -> String {
        table[PreferencesManager.shared.appLanguage]?[key] ?? table[.en]?[key] ?? key.rawValue
    }

    static func format(_ key: L10nKey, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    private static let table: [AppLanguage: [L10nKey: String]] = [
        .zh: [
            .recordShortcut: "点击录制快捷键",
            .recordingShortcut: "录制中...",
            .preferences: "偏好设置",
            .screenshotPreferences: "截图偏好设置",
            .language: "语言",
            .deviceNameForSync: "设备名称（用于同步）：",
            .enterDeviceName: "输入设备名称",
            .save: "保存",
            .success: "成功",
            .deviceNameUpdated: "设备名称已更新为“%@”，同步服务已重启。",
            .ok: "确定",
            .historyLimit: "历史数量：",
            .moreHistory: "  更多...",
            .changesNextCopy: "（修改后立即生效）",
            .excludedBundleIds: "排除的 Bundle ID（用逗号分隔）：",
            .enableLanSync: "启用局域网同步",
            .syncPort: "同步端口：",
            .authorizedDevicesComma: "授权设备（用逗号分隔）：",
            .syncTargetsHint: "分别勾选要向哪些设备同步剪贴板 / 通知。只需本机授权即可发送，对方无需勾选也能接收。设备列表「发送文本 / 发送文件」连本机授权也不需要。",
            .syncClipboardToDevice: "同步剪贴板",
            .syncNotificationsToDevice: "同步通知",
            .close: "关闭",
            .history: "历史记录",
            .noHistory: "暂无历史记录",
            .snippets: "片段",
            .noSnippets: "暂无片段",
            .source: "来源",
            .authorizedDevices: "授权设备",
            .lanDevices: "局域网设备",
            .noDevicesFound: "未发现设备",
            .refreshDevices: "刷新设备",
            .refreshingDevices: "正在刷新…",
            .myIPAddress: "本机 IP：%@",
            .staleAuthorizedDevicesWarning: "已授权但未在线：%@。请在下方列表勾选当前显示的设备名称（如 Android-redmi）。",
            .syncLocalNameHint: "本机名称：%@，设备 ID：%@…。勾选剪贴板/通知后向该设备推送，对方无需勾选即可接收。",
            .authorized: "已授权",
            .sendFile: "发送文件...",
            .sendText: "发送文本...",
            .chooseTextToSend: "发送文本到 %@",
            .sendTextHint: "文本将发送到对方设备并写入剪贴板。",
            .enterTextToSend: "输入要发送的文本",
            .editSnippets: "编辑片段...",
            .clearHistory: "清空历史记录",
            .clearHistoryConfirm: "将删除全部历史记录，此操作不可撤销。",
            .showLogs: "显示日志...",
            .quit: "退出",
            .chooseFileToSend: "选择要发送到 %@ 的文件",
            .send: "发送",
            .sendFailed: "发送失败。目标设备可能离线或网络连接异常。",
            .snippetEditorTitle: "Clipy - 片段编辑器",
            .nameColumn: "名称",
            .newFolder: "新文件夹",
            .newSnippet: "新片段",
            .selectFolderOrSnippet: "请在左侧选择一个文件夹或片段",
            .folderName: "文件夹名称",
            .shortcut: "快捷键",
            .folderShortcutHint: "设置后可通过快捷键直接弹出该文件夹菜单",
            .snippetTitle: "片段标题",
            .content: "内容",
            .confirmDeleteFolder: "确定要删除文件夹吗？",
            .deleteFolderWarning: "文件夹内的片段也会被删除，此操作不可撤销。",
            .delete: "删除",
            .cancel: "取消",
            .importFailed: "导入失败",
            .exportSnippets: "导出片段",
            .exportFailed: "导出失败",
            .folderFallback: "文件夹",
            .snippetFallback: "片段",
            .addSnippet: "添加片段",
            .addFolder: "添加文件夹",
            .importAction: "导入",
            .exportAction: "导出",
            .searchLogs: "搜索日志...",
            .copyAll: "复制全部",
            .revealLogFile: "日志文件",
            .clear: "清空",
            .clipyLogs: "Clipy 日志",
            .quitClipy: "退出 Clipy",
            .editMenu: "编辑",
            .undo: "撤销",
            .redo: "重做",
            .cut: "剪切",
            .copy: "复制",
            .paste: "粘贴",
            .selectAll: "全选",
            .fileReceived: "文件已接收",
            .receivedFileFrom: "已从 %@ 接收 %@",
            .transferStation: "超级中转站",
            .addText: "添加文本",
            .addFile: "添加文件",
            .addFolderTransfer: "添加文件夹",
            .clearAll: "清空",
            .title: "标题",
            .type: "类型",
            .dragOrAddToTransfer: "拖拽文件到此处，或点击上方按钮添加内容",
            .enterTextContent: "输入要添加到中转站的文本内容：",
            .add: "添加",
            .selectFiles: "选择要添加到中转站的文件",
            .selectFolder: "选择要添加到中转站的文件夹",
            .clearAllTransfer: "清空中转站",
            .clearAllTransferConfirm: "确定要清空所有中转站内容吗？此操作不可撤销。",
            .copyContent: "复制内容",
            .showInFinder: "在 Finder 中显示",
            .openFolder: "打开文件夹",
            .openFile: "打开文件",
            .saveAs: "另存为...",
            .saveAsSuccess: "文件已保存",
            .setTemporary: "设为临时",
            .setPermanent: "设为永久",
            .searchHistory: "搜索历史...",
            .searchHistoryPlaceholder: "搜索内容、路径或来源应用",
            .noSearchResults: "没有匹配的结果",
            .time: "时间",
            .pasteCount: "粘贴次数",
            .phoneNotifications: "手机通知",
            .noNotifications: "暂无通知",
            .enableNotificationSync: "启用通知同步",
            .notificationSync: "通知同步",
            .dismissOnPhone: "在手机上清除",
            .clearAllOnPhone: "清除所有手机通知",
            .notificationFilter: "通知过滤",
            .notificationSound: "通知声音",
            .clearNotifications: "清空通知",
            .bannerRules: "弹横幅规则",
            .bannerRulesHint: "未配置时不弹横幅；勾选应用或填写关键字后，命中才弹",
            .bannerKeywords: "关键字",
            .bannerKeywordsHint: "逗号分隔，匹配通知标题/副标题/正文",
            .blockedKeywords: "屏蔽关键字",
            .blockedKeywordsHint: "逗号分隔，命中则不弹横幅（优先于上方关键字）",
            .noReceivedApps: "暂无已接收应用，收到手机通知后会在此显示",
            .searchApps: "搜索应用或内容",
            .notificationSettings: "通知设置",
            .macNotificationPermission: "Mac 通知权限",
            .macNotificationGranted: "已授权",
            .macNotificationDenied: "已拒绝，请在系统设置中允许",
            .notificationArchivedBadge: "历史",
            .openNotificationSettings: "前往系统设置",
            .launchAtLogin: "登录时启动",
            .launchAtLoginFailed: "无法更新登录时启动设置，请重试。",
            .accessibilityPermission: "辅助功能权限（自动粘贴需要）：",
            .accessibilityGranted: "已授权",
            .accessibilityNotGranted: "未授权",
            .accessibilityRequiredTitle: "需要辅助功能权限",
            .accessibilityRequiredMessage: "Clipy 需要辅助功能权限才能模拟 ⌘V 自动粘贴。内容已复制到剪贴板，你也可以手动粘贴。请在系统设置中启用 ClipyClone。",
            .openSystemSettings: "打开系统设置",
            .relativeTimeJustNow: "刚刚",
            .relativeTimeMinutes: "%d分钟前",
            .relativeTimeHours: "%d小时前",
            .relativeTimeDays: "%d天前",
            .transferStatusFormat: "%d 项（%d 永久）",
            .error: "错误",
            .clearShortcut: "清除",
            .searchResultCount: "%d 条历史",
            .historyTotalCount: "共 %d 条历史",
            .historyShownOfTotal: "显示 %d / 共 %d 条",
            .historyLoadMore: "加载更多",
            .noSearchResultsWithTotal: "没有匹配的结果（共 %d 条）",
            .historyCurrentCount: "当前已保存 %d 条",
            .historyWithCount: "历史记录（%d）",
            .location: "位置",
            .pasteFileName: "粘贴文件名",
            .pasteFile: "粘贴文件",
            .pinToTop: "置顶",
            .unpinFromTop: "取消置顶",
            .preview: "预览",
            .selectHistoryToPreview: "选择一条历史记录以预览",
            .historyTypeText: "文本",
            .historyTypeImage: "图片",
            .historyTypeRTF: "富文本",
            .historyTypePDF: "PDF 文档",
            .historyTypeFile: "文件",
            .historyTypeHTML: "HTML",
            .historyTypeMarkdown: "Markdown",
            .historyTypePlainText: "纯文本",
            .historyTypeJSON: "JSON",
            .historyPreviewTruncated: "内容已截断（文件过大）",
            .historyPreviewLoadFailed: "无法加载预览",
            .historyDataSize: "大小：%@",
            .historyFilterAll: "全部",
            .historyFilterRichText: "富文本",
            .historyFilterSource: "来源",
            .historyFilterAllSources: "全部来源",
            .encryptHistoryAtRest: "加密本地历史",
            .encryptHistoryAtRestDescription: "使用本机专用密钥 AES-GCM 加密外置的历史文本与媒体文件，密钥仅保存在本机。",
            .historyEncryptionFailed: "无法更新历史加密设置，请重试。",
            .historyEncryptionInProgress: "正在重新加密历史文件…",
            .syncPairingSecret: "配对密钥：",
            .syncPairingSecretHint: "在同一组设备上填写完全相同的密钥。留空则使用内置默认密钥，同网段任何一份本应用都能解密同步内容。",
            .syncPairingSecretDefaultWarning: "当前使用内置默认密钥，建议设置自定义配对密钥。",
            .syncOfflineAuthorizedDevices: "离线已授权设备（可删除）",
            .deviceOnline: "在线",
            .deviceOffline: "离线",
            .syncAddManualDevice: "手动添加设备（跨频段/跨子网兜底）",
            .syncManualDeviceHost: "IP 地址（如 192.168.1.20）",
            .syncManualDevicePort: "端口",
            .syncManualDeviceHint: "当自动发现失效（如 2.4G/5G 隔离）时，在对端查看 IP 后在此手动添加。",
            .syncAdd: "添加",
            .historyRegexSearch: "正则",
            .historyDateFilter: "时间",
            .historyDateFilterAll: "全部",
            .historyDateFilterToday: "今天",
            .historyDateFilterWeek: "7 天",
            .historyDateFilterMonth: "30 天",
            .historyCategoryURL: "URL",
            .historyCategoryEmail: "邮箱",
            .historyCategoryCode: "代码",
            .historyCategoryJSON: "JSON",
            .pastePlainText: "粘贴为纯文本",
            .saveAsSnippet: "保存为片段",
            .searchGlobalShortcut: "全局搜索快捷键",
            .searchGlobalShortcutDescription: "在任何应用中按下此快捷键打开历史搜索窗口。",
            .screenshot: "截图",
            .screenshotRegion: "区域截图",
            .screenshotWindow: "窗口截图",
            .screenshotFullscreen: "全屏截图",
            .screenshotShortcut: "全局截图快捷键",
            .screenshotShortcutDescription: "按下此快捷键开始截图，默认使用偏好设置中的截图模式。",
            .screenshotDefaultMode: "默认截图模式",
            .screenshotEditorTitle: "截图标注",
            .screenshotEdit: "编辑贴图",
            .screenshotEditDone: "完成",
            .screenshotCopy: "复制",
            .screenshotPin: "贴图",
            .screenshotOCR: "OCR",
            .screenshotOCRResult: "识别结果",
            .screenshotOCRNoText: "未识别到文字",
            .screenshotCopyText: "复制文字",
            .screenshotTextPrompt: "添加文字",
            .screenshotTextPromptMessage: "输入要添加的标注文字",
            .screenshotToolRectangle: "矩形",
            .screenshotToolArrow: "箭头",
            .screenshotToolEllipse: "椭圆",
            .screenshotToolText: "文字",
            .screenshotToolMosaic: "马赛克",
            .screenshotLineWidth: "线宽 %d",
            .screenshotFontSize: "字号",
            .screenshotArrowSolid: "实线",
            .screenshotArrowDashed: "虚线",
            .screenshotTextBackground: "底色",
            .screenshotMosaicRect: "矩形",
            .screenshotMosaicBrushSmall: "笔·小",
            .screenshotMosaicBrushMedium: "笔·中",
            .screenshotMosaicBrushLarge: "笔·大",
            .screenCaptureRequiredTitle: "需要屏幕录制权限",
            .screenCaptureRequiredMessage: "Clipy 需要屏幕录制权限才能截图。请在系统设置中启用 ClipyClone 的屏幕录制权限。",
            .screenshotCaptureFailedTitle: "截图失败",
            .screenshotCaptureFailedMessage: "无法捕获屏幕内容。请确认已授予屏幕录制权限，然后重试。",
            .screenCapturePermission: "屏幕录制权限（截图需要）：",
            .requestScreenCaptureAccess: "请求系统授权",
            .screenCapturePermissionHint: "若重编译后截图失效，请在系统设置 > 隐私与安全性 > 屏幕录制中重新启用 ClipyClone。",
            .screenshotUndo: "撤销",
            .screenshotRedo: "重做",
            .screenshotDone: "完成",
            .screenshotHint: "移动鼠标吸附元素 · 拖拽画框 · Esc 取消",
            .screenshotSelectionHint: "拖拽/缩放选框 · 标注后点完成截图 · Esc 取消",
            .screenshotCopied: "已复制到剪贴板",
            .screenshotMagnifier: "截图放大镜",
            .screenshotElementSnap: "UI 元素吸附",
            .screenshotToolSelection: "调整选区",
            .screenshotToolPencil: "画笔",
            .screenshotToolHighlighter: "荧光笔",
            .screenshotToolEraser: "橡皮擦",
            .screenshotPinOpacity: "贴图透明度",
            .screenshotElementSnapAccessibilityHint: "精确吸附控件需要辅助功能权限，未授权时将降级为窗口吸附。",
            .screenshotAutoSave: "自动保存截图",
            .screenshotSavePath: "保存路径",
            .screenshotChooseSavePath: "选择文件夹",
            .screenshotSavedTo: "已保存：%@",
            .screenshotResolution: "截图分辨率",
            .screenshotResolutionAuto: "自动（跟随屏幕）",
            .screenshotResolutionNative: "原生像素",
            .screenshotResolutionHint: "始终以屏幕原生分辨率截图，保证清晰。两种模式效果相同，「原生」用于明确锁定不缩放。",
            .screenshotPostAction: "截图后默认动作",
            .screenshotPostActionHint: "选区确认或全屏截图完成后自动执行的动作。工具栏按钮会临时覆盖此项。",
            .screenshotPostActionCopy: "复制到剪贴板",
            .screenshotPostActionPin: "贴在屏幕上",
            .screenshotPostActionOCR: "识别文字 (OCR)",
            .screenshotPostActionSaveAs: "另存为…",
            .screenshotOCRLanguage: "OCR 识别语言",
            .screenshotOCRLanguageHint: "中文+英文适合大多数中文截图；自动会使用系统支持的全部语言，速度较慢。",
            .screenshotOCRLanguageEnglish: "仅英文",
            .screenshotOCRLanguageChineseEnglish: "中文 + 英文",
            .screenshotOCRLanguageAuto: "自动（全部语言）",
        ],
        .en: [
            .recordShortcut: "Click to record shortcut",
            .recordingShortcut: "Recording...",
            .preferences: "Preferences",
            .screenshotPreferences: "Screenshot Preferences",
            .language: "Language",
            .deviceNameForSync: "Device Name (for Sync):",
            .enterDeviceName: "Enter device name",
            .save: "Save",
            .success: "Success",
            .deviceNameUpdated: "Device name updated to \"%@\". Sync services restarted.",
            .ok: "OK",
            .historyLimit: "History Limit:",
            .moreHistory: "  More...",
            .changesNextCopy: "(Takes effect immediately)",
            .excludedBundleIds: "Excluded Bundle IDs (comma separated):",
            .enableLanSync: "Enable LAN Sync",
            .syncPort: "Sync Port:",
            .authorizedDevicesComma: "Authorized Devices (comma separated):",
            .syncTargetsHint: "Choose which devices receive clipboard and/or notifications. Authorization is one-sided: authorize on this device to send; the peer can receive without authorizing you. Device-list Send Text / Send File needs no authorization at all.",
            .syncClipboardToDevice: "Sync clipboard",
            .syncNotificationsToDevice: "Sync notifications",
            .close: "Close",
            .history: "History",
            .noHistory: "No History",
            .snippets: "Snippets",
            .noSnippets: "No Snippets",
            .source: "Source",
            .authorizedDevices: "Authorized Devices",
            .lanDevices: "Devices on Network",
            .noDevicesFound: "No Devices Found",
            .refreshDevices: "Refresh Devices",
            .refreshingDevices: "Refreshing…",
            .myIPAddress: "My IP: %@",
            .staleAuthorizedDevicesWarning: "Authorized but offline: %@. Select the name shown in the list below (e.g. Android-redmi).",
            .syncLocalNameHint: "This device: %@ (ID: %@…). Check clipboard/notifications to push; they can receive without checking you.",
            .authorized: "Authorized",
            .sendFile: "Send File...",
            .sendText: "Send Text...",
            .chooseTextToSend: "Send text to %@",
            .sendTextHint: "The text will be delivered to the other device and copied to its clipboard.",
            .enterTextToSend: "Enter text to send",
            .editSnippets: "Edit Snippets...",
            .clearHistory: "Clear History",
            .clearHistoryConfirm: "All history will be deleted. This cannot be undone.",
            .showLogs: "Show Logs...",
            .quit: "Quit",
            .chooseFileToSend: "Choose a file to send to %@",
            .send: "Send",
            .sendFailed: "Send failed. The target device may be offline or the network connection may be unstable.",
            .snippetEditorTitle: "Clipy - Snippet Editor",
            .nameColumn: "Name",
            .newFolder: "New Folder",
            .newSnippet: "New Snippet",
            .selectFolderOrSnippet: "Select a folder or snippet on the left",
            .folderName: "Folder Name",
            .shortcut: "Shortcut",
            .folderShortcutHint: "Set a shortcut to open this folder menu directly",
            .snippetTitle: "Snippet Title",
            .content: "Content",
            .confirmDeleteFolder: "Delete this folder?",
            .deleteFolderWarning: "Snippets in this folder will also be deleted. This cannot be undone.",
            .delete: "Delete",
            .cancel: "Cancel",
            .importFailed: "Import Failed",
            .exportSnippets: "Export Snippets",
            .exportFailed: "Export Failed",
            .folderFallback: "Folder",
            .snippetFallback: "Snippet",
            .addSnippet: "Add Snippet",
            .addFolder: "Add Folder",
            .importAction: "Import",
            .exportAction: "Export",
            .searchLogs: "Search logs...",
            .copyAll: "Copy All",
            .revealLogFile: "Log File",
            .clear: "Clear",
            .clipyLogs: "Clipy Logs",
            .quitClipy: "Quit Clipy",
            .editMenu: "Edit",
            .undo: "Undo",
            .redo: "Redo",
            .cut: "Cut",
            .copy: "Copy",
            .paste: "Paste",
            .selectAll: "Select All",
            .fileReceived: "File Received",
            .receivedFileFrom: "Received %@ from %@",
            .transferStation: "Transfer Station",
            .addText: "Add Text",
            .addFile: "Add File",
            .addFolderTransfer: "Add Folder",
            .clearAll: "Clear All",
            .title: "Title",
            .type: "Type",
            .dragOrAddToTransfer: "Drag files here, or click the buttons above to add content",
            .enterTextContent: "Enter text content to add to the transfer station:",
            .add: "Add",
            .selectFiles: "Select files to add to the transfer station",
            .selectFolder: "Select a folder to add to the transfer station",
            .clearAllTransfer: "Clear Transfer Station",
            .clearAllTransferConfirm: "Are you sure you want to clear all transfer station content? This cannot be undone.",
            .copyContent: "Copy Content",
            .showInFinder: "Show in Finder",
            .openFolder: "Open Folder",
            .openFile: "Open File",
            .saveAs: "Save As...",
            .saveAsSuccess: "File saved",
            .setTemporary: "Set Temporary",
            .setPermanent: "Set Permanent",
            .searchHistory: "Search History...",
            .searchHistoryPlaceholder: "Search content, path, or source app",
            .noSearchResults: "No matching results",
            .time: "Time",
            .pasteCount: "Paste Count",
            .phoneNotifications: "Phone Notifications",
            .noNotifications: "No Notifications",
            .enableNotificationSync: "Enable Notification Sync",
            .notificationSync: "Notification Sync",
            .dismissOnPhone: "Dismiss on Phone",
            .clearAllOnPhone: "Clear All on Phone",
            .notificationFilter: "Notification Filter",
            .notificationSound: "Notification Sound",
            .clearNotifications: "Clear Notifications",
            .bannerRules: "Banner Rules",
            .bannerRulesHint: "No banner without rules; tick apps or add keywords to show banners on match",
            .bannerKeywords: "Keywords",
            .bannerKeywordsHint: "Comma-separated; matches title/subtitle/body",
            .blockedKeywords: "Blocked Keywords",
            .blockedKeywordsHint: "Comma-separated; matched entries never show a banner (overrides above)",
            .noReceivedApps: "No received apps yet; they appear after phone notifications arrive",
            .searchApps: "Search apps or content",
            .notificationSettings: "Notification Settings",
            .macNotificationPermission: "Mac Notification Permission",
            .macNotificationGranted: "Granted",
            .macNotificationDenied: "Denied; please allow in System Settings",
            .notificationArchivedBadge: "History",
            .openNotificationSettings: "Open System Settings",
            .launchAtLogin: "Launch at Login",
            .launchAtLoginFailed: "Unable to update launch at login settings. Please try again.",
            .accessibilityPermission: "Accessibility Permission (required for auto-paste):",
            .accessibilityGranted: "Granted",
            .accessibilityNotGranted: "Not Granted",
            .accessibilityRequiredTitle: "Accessibility Permission Required",
            .accessibilityRequiredMessage: "Clipy needs Accessibility permission to simulate ⌘V for auto-paste. The content has been copied to your clipboard; you can paste manually. Enable ClipyClone in System Settings.",
            .openSystemSettings: "Open System Settings",
            .relativeTimeJustNow: "Just now",
            .relativeTimeMinutes: "%dm ago",
            .relativeTimeHours: "%dh ago",
            .relativeTimeDays: "%dd ago",
            .transferStatusFormat: "%d items (%d permanent)",
            .error: "Error",
            .clearShortcut: "Clear",
            .searchResultCount: "%d history items",
            .historyTotalCount: "%d items total",
            .historyShownOfTotal: "Showing %d / %d items",
            .historyLoadMore: "Load More",
            .noSearchResultsWithTotal: "No results (%d items total)",
            .historyCurrentCount: "%d items saved",
            .historyWithCount: "History (%d)",
            .location: "Location",
            .pasteFileName: "Paste File Name",
            .pasteFile: "Paste File",
            .pinToTop: "Pin to Top",
            .unpinFromTop: "Unpin",
            .preview: "Preview",
            .selectHistoryToPreview: "Select a history item to preview",
            .historyTypeText: "Text",
            .historyTypeImage: "Image",
            .historyTypeRTF: "Rich Text",
            .historyTypePDF: "PDF Document",
            .historyTypeFile: "File",
            .historyTypeHTML: "HTML",
            .historyTypeMarkdown: "Markdown",
            .historyTypePlainText: "Plain Text",
            .historyTypeJSON: "JSON",
            .historyPreviewTruncated: "Content truncated (file too large)",
            .historyPreviewLoadFailed: "Failed to load preview",
            .historyDataSize: "Size: %@",
            .historyFilterAll: "All",
            .historyFilterRichText: "Rich Text",
            .historyFilterSource: "Source",
            .historyFilterAllSources: "All Sources",
            .encryptHistoryAtRest: "Encrypt Local History",
            .encryptHistoryAtRestDescription: "Encrypt externalized history text and media files with a device-local AES-GCM key stored on this device only.",
            .historyEncryptionFailed: "Could not update history encryption. Please try again.",
            .historyEncryptionInProgress: "Re-encrypting history files…",
            .syncPairingSecret: "Pairing secret:",
            .syncPairingSecretHint: "Enter the exact same secret on every device in this sync group. Leave it empty to use the built-in default key, which any copy of this app on your network can decrypt.",
            .syncPairingSecretDefaultWarning: "Using the built-in default key. Set a custom pairing secret for real protection.",
            .syncOfflineAuthorizedDevices: "Authorized devices that are offline (removable)",
            .deviceOnline: "Online",
            .deviceOffline: "Offline",
            .syncAddManualDevice: "Add device manually (across bands / subnets)",
            .syncManualDeviceHost: "IP address (e.g. 192.168.1.20)",
            .syncManualDevicePort: "Port",
            .syncManualDeviceHint: "When automatic discovery fails (e.g. 2.4G/5G isolation), look up the other device's IP and add it here.",
            .syncAdd: "Add",
            .historyRegexSearch: "Regex",
            .historyDateFilter: "Time",
            .historyDateFilterAll: "All",
            .historyDateFilterToday: "Today",
            .historyDateFilterWeek: "7 Days",
            .historyDateFilterMonth: "30 Days",
            .historyCategoryURL: "URL",
            .historyCategoryEmail: "Email",
            .historyCategoryCode: "Code",
            .historyCategoryJSON: "JSON",
            .pastePlainText: "Paste as Plain Text",
            .saveAsSnippet: "Save as Snippet",
            .searchGlobalShortcut: "Global Search Shortcut",
            .searchGlobalShortcutDescription: "Press this shortcut from any app to open history search.",
            .screenshot: "Screenshot",
            .screenshotRegion: "Capture Region",
            .screenshotWindow: "Capture Window",
            .screenshotFullscreen: "Capture Full Screen",
            .screenshotShortcut: "Global Screenshot Shortcut",
            .screenshotShortcutDescription: "Press this shortcut to start a screenshot using the default mode below.",
            .screenshotDefaultMode: "Default Capture Mode",
            .screenshotEditorTitle: "Screenshot Editor",
            .screenshotEdit: "Edit Pin",
            .screenshotEditDone: "Done",
            .screenshotCopy: "Copy",
            .screenshotPin: "Pin to Screen",
            .screenshotOCR: "OCR",
            .screenshotOCRResult: "Recognized Text",
            .screenshotOCRNoText: "No text recognized",
            .screenshotCopyText: "Copy Text",
            .screenshotTextPrompt: "Add Text",
            .screenshotTextPromptMessage: "Enter annotation text",
            .screenshotToolRectangle: "Rectangle",
            .screenshotToolArrow: "Arrow",
            .screenshotToolEllipse: "Ellipse",
            .screenshotToolText: "Text",
            .screenshotToolMosaic: "Mosaic",
            .screenshotLineWidth: "Width %d",
            .screenshotFontSize: "Font Size",
            .screenshotArrowSolid: "Solid",
            .screenshotArrowDashed: "Dashed",
            .screenshotTextBackground: "Fill",
            .screenshotMosaicRect: "Rect",
            .screenshotMosaicBrushSmall: "Brush S",
            .screenshotMosaicBrushMedium: "Brush M",
            .screenshotMosaicBrushLarge: "Brush L",
            .screenCaptureRequiredTitle: "Screen Recording Permission Required",
            .screenCaptureRequiredMessage: "Clipy needs Screen Recording permission to capture screenshots. Enable ClipyClone in System Settings.",
            .screenshotCaptureFailedTitle: "Screenshot Failed",
            .screenshotCaptureFailedMessage: "Could not capture the screen. Check Screen Recording permission and try again.",
            .screenCapturePermission: "Screen Recording Permission (required for screenshots):",
            .requestScreenCaptureAccess: "Request System Permission",
            .screenCapturePermissionHint: "If screenshots stop working after a rebuild, re-enable ClipyClone under System Settings > Privacy & Security > Screen Recording.",
            .screenshotUndo: "Undo",
            .screenshotRedo: "Redo",
            .screenshotDone: "Done",
            .screenshotHint: "Hover to snap · Drag to select · Esc to cancel",
            .screenshotSelectionHint: "Drag/resize selection · Annotate then Done to capture · Esc to cancel",
            .screenshotCopied: "Copied to clipboard",
            .screenshotMagnifier: "Capture Magnifier",
            .screenshotElementSnap: "Snap to UI Elements",
            .screenshotToolSelection: "Adjust Selection",
            .screenshotToolPencil: "Pencil",
            .screenshotToolHighlighter: "Highlighter",
            .screenshotToolEraser: "Eraser",
            .screenshotPinOpacity: "Pin Opacity",
            .screenshotElementSnapAccessibilityHint: "Precise element snap needs Accessibility permission. Without it, window-level snap is used.",
            .screenshotAutoSave: "Auto-save Screenshots",
            .screenshotSavePath: "Save Location",
            .screenshotChooseSavePath: "Choose Folder",
            .screenshotSavedTo: "Saved: %@",
            .screenshotResolution: "Screenshot Resolution",
            .screenshotResolutionAuto: "Auto (Match Screen)",
            .screenshotResolutionNative: "Native Pixels",
            .screenshotResolutionHint: "Always captures at the screen's native resolution for sharp results. Both modes behave the same; Native explicitly locks to no scaling.",
            .screenshotPostAction: "After Capture",
            .screenshotPostActionHint: "Action to run automatically after a selection or fullscreen capture. Toolbar buttons override this temporarily.",
            .screenshotPostActionCopy: "Copy to Clipboard",
            .screenshotPostActionPin: "Pin on Screen",
            .screenshotPostActionOCR: "Recognize Text (OCR)",
            .screenshotPostActionSaveAs: "Save As…",
            .screenshotOCRLanguage: "OCR Language",
            .screenshotOCRLanguageHint: "Chinese + English works for most Chinese screenshots. Auto uses all system-supported languages and is slower.",
            .screenshotOCRLanguageEnglish: "English Only",
            .screenshotOCRLanguageChineseEnglish: "Chinese + English",
            .screenshotOCRLanguageAuto: "Auto (All Languages)",
        ]
    ]
}
