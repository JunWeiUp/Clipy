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
    case smartVoiceTitle
    case smartVoiceEnabled
    case smartVoiceTrigger
    case smartVoiceRightCommand
    case smartVoiceRightOption
    case smartVoiceHint
    case smartVoiceInputMonitoring
    case smartVoiceRecheck
    case smartVoiceDisabled
    case smartVoiceNeedsSetup
    case smartVoiceNeedsPermission
    case smartVoiceActive
    case smartVoiceUnavailable
    case smartVoiceInterrupted
    case smartSwitchTitle
    case smartSwitchSettingsTitle
    case smartSwitchInputLabel
    case smartSwitchInputHint
    case smartSwitchExecute
    case smartSwitchWorking
    case smartSwitchSetupHint
    case smartSwitchShortcut
    case smartSwitchShortcutConflict
    case smartSwitchDoubaoUnavailable
    case smartSwitchAPI
    case smartSwitchModel
    case smartSwitchAPIHint
    case smartSwitchSaveAPI
    case smartSwitchTest
    case smartSwitchTestSuccess
    case smartSwitchSaved
    case smartSwitchPrivacy
    case smartSwitchApplications
    case smartSwitchAddApplication
    case smartSwitchLocate
    case smartSwitchAppName
    case smartSwitchAliases
    case smartSwitchDescription
    case smartSwitchNoTargets
    case smartSwitchNoMatch
    case smartSwitchAmbiguous
    case smartSwitchConfigurationError
    case smartSwitchInputError
    case smartSwitchResponseError
    case smartSwitchInvalidApplication
    case smartSwitchApplicationMissing
    case smartSwitchActivationFailed
    case smartSwitchKeychainError
    case smartSwitchAuthenticationError
    case smartSwitchHTTPError
    case smartSwitchTimeout
    case smartSwitchNetworkError
    case wordHideChinese
    case wordShowChinese
    case wordChineseVisible
    case wordChineseHidden
    case wordBook
    case wordFamiliar
    case wordUnfamiliar
    case wordBookStatus
    case wordBookFilter
    case wordBookCheckHelp
    case wordBookEmpty
    case wordBookSelect
    case wordBookHint
    case wordBookLookups
    case wordBookLastLookup
    case wordBookReadError
    case wordBookWriteError
    case wordLookup
    case wordOriginal
    case wordEnglishTranslation
    case wordChineseTranslation
    case wordMachineTranslation
    case wordCopyTranslation
    case wordReadEnglish
    case wordPlaceholder
    case wordCandidates
    case wordSearch
    case wordLoading
    case wordInvalidQuery
    case wordNotFound
    case wordNetworkError
    case wordTryAgain
    case wordMeanings
    case wordInflections
    case wordPhrases
    case wordExamples
    case wordNoPhrases
    case wordNoExamples
    case wordLookupPhrase
    case wordSource
    case wordWelcome
    case wordWelcomeDetail
    case wordPrivacy
    case wordAmerican
    case wordNoIPA
    case wordPlayAudio
    case wordStopAudio
    case wordAudioLoading
    case wordRecordedAudio
    case wordSystemAudio
    case wordAudioUnavailable
    case wordShortcut
    case wordShortcutDescription
    case wordShortcutConflict
    case menuRecentHistory
    case designDeviceName
    case designGeneral
    case designPermissions
    case designOutput
    case designDrawing
    case designEffects
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
    case folderSendPreparationFailed
    case snippetFolders
    case snippetLibrary
    case snippetSearch
    case snippetFolderSettings
    case snippetAutosave
    case snippetCopied
    case snippetEmptyFolder
    case snippetEmptyHint
    case snippetCharacters
    case snippetActions
    case snippetLibraryActions
    case snippetFolderCount
    case snippetMoveHint
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
    case historyImageOCRIndexing
    case historyImageOCRIndexingDescription
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
    case fileReceivedTitle
    case fileReceivedBody
    case generatePassword
    case passwordRegenerate
    case passwordCopy
    case passwordCopied
    case passwordEntropy
    case passwordLengthLabel
    case passwordCharacterSet
    case passwordUppercase
    case passwordLowercase
    case passwordDigits
    case passwordSymbols
    case passwordExcludeAmbiguous
    case passwordStrengthWeak
    case passwordStrengthFair
    case passwordStrengthStrong
    case passwordStrengthVeryStrong
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
            .smartVoiceTitle: "语音自动入口",
            .smartVoiceEnabled: "确认非输入控件时，接入智能切换",
            .smartVoiceTrigger: "豆包的长按语音键",
            .smartVoiceRightCommand: "右侧 Command（⌘）",
            .smartVoiceRightOption: "右侧 Option（⌥）",
            .smartVoiceHint: "与豆包「长按模式」使用同一按键。所有应用统一判断：输入框或焦点不明确时保留普通语音；确认非输入控件并复核同一目标后才呼出窗口，文字落入后按回车。部分自绘界面无法确认，可用智能切换快捷键手动呼出。短按和组合键照常；不接管免按模式或语音按钮。",
            .smartVoiceInputMonitoring: "打开输入监控设置",
            .smartVoiceRecheck: "重新检查",
            .smartVoiceDisabled: "自动入口已关闭，原有智能切换快捷键仍可使用。",
            .smartVoiceNeedsSetup: "请先保存 API 配置，并添加和启用至少一个应用。",
            .smartVoiceNeedsPermission: "请在系统设置中为 ClipyClone 开启「辅助功能」和「输入监控」，然后重新启动应用。仅识别触发手势和焦点类型，不记录按键内容或前台文字。",
            .smartVoiceActive: "自动入口已就绪：沿用豆包长按语音键，无需另按智能切换快捷键。",
            .smartVoiceUnavailable: "无法建立按键监听。请检查权限并重新启动 ClipyClone；普通语音输入保持可用。",
            .smartVoiceInterrupted: "本次语音准备已中断，窗口已保留。请再次长按语音键，或直接输入。",
            .smartSwitchTitle: "智能切换应用",
            .smartSwitchSettingsTitle: "智能切换",
            .smartSwitchInputLabel: "输入文字或应用指令",
            .smartSwitchInputHint: "直接说“打开软件名”优先切换；回车执行所选功能，Esc 粘贴回原应用。",
            .smartSwitchExecute: "切换",
            .smartSwitchWorking: "正在处理…",
            .smartSwitchSetupHint: "呼出后自动切到豆包，语音落字后按回车。明确的打开应用指令优先本地匹配；其他功能可点击按钮，或用滚轮循环选择。",
            .smartSwitchShortcut: "启用智能切换快捷键",
            .smartSwitchShortcutConflict: "快捷键注册失败，可能已被占用。请换一个组合；仍可使用菜单栏入口。",
            .smartSwitchDoubaoUnavailable: "豆包输入法不可用，请在系统设置中启用；现在仍可打字输入。",
            .smartSwitchAPI: "大模型 API",
            .smartSwitchModel: "模型名称",
            .smartSwitchAPIHint: "使用兼容 Chat Completions 的接口。Base URL 包含版本路径（如 /v1），不要包含 /chat/completions。清空三项后保存可移除配置。",
            .smartSwitchSaveAPI: "保存 API 配置",
            .smartSwitchTest: "测试连接",
            .smartSwitchTestSuccess: "连接成功，模型已返回有效应用选择。测试不会打开应用；请保存配置后使用。",
            .smartSwitchSaved: "API 配置已保存。",
            .smartSwitchPrivacy: "本地应用匹配、打开 Codex 和 ZCode 新对话不调用模型。模型判断仅发送本次输入、可用动作和已配置应用的信息，不发送路径或历史库；翻译发送你选择处理的文字。API Key 保存在钥匙串。",
            .smartSwitchApplications: "应用与别名（自动保存）",
            .smartSwitchAddApplication: "添加应用…",
            .smartSwitchLocate: "重新选择…",
            .smartSwitchAppName: "应用名称",
            .smartSwitchAliases: "别名（例如：浏览器、查资料）",
            .smartSwitchDescription: "用途描述（例如：日常写代码使用的编辑器）",
            .smartSwitchNoTargets: "请在「偏好设置 → 智能切换」添加并启用至少一个应用。",
            .smartSwitchNoMatch: "没有找到对应应用或动作。可换一种说法、选择功能按钮，或在设置中补充应用别名。",
            .smartSwitchAmbiguous: "有多个可能的应用，请用上下方向键选择并回车，或点击目标应用。",
            .smartSwitchConfigurationError: "请检查并保存 Base URL、模型名称和 API Key。地址须为 HTTPS（本机服务可用 HTTP），包含版本路径但不含 /chat/completions。",
            .smartSwitchInputError: "请输入需要处理的文字（最多 8000 个字符），或选择可直接执行的功能。",
            .smartSwitchResponseError: "模型返回了无效的应用选择。请重试，或检查接口与模型是否支持此格式。",
            .smartSwitchInvalidApplication: "请选择有效的 macOS .app 应用。",
            .smartSwitchApplicationMissing: "找不到该应用，请在设置中重新选择应用位置。",
            .smartSwitchActivationFailed: "无法将应用切到前台，请重试或检查应用是否能正常启动。",
            .smartSwitchKeychainError: "无法访问 API Key 钥匙串项目（%d）。请检查钥匙串访问权限后重新打开设置。",
            .smartSwitchAuthenticationError: "API 鉴权失败。请检查密钥、地址及模型访问权限。",
            .smartSwitchHTTPError: "服务返回 HTTP %d。请检查配置或稍后重试。",
            .smartSwitchTimeout: "请求超时（15 秒），请检查网络或换用响应更快的模型。",
            .smartSwitchNetworkError: "无法连接模型服务，请检查网络和 API 地址后重试。",
            .menuRecentHistory: "最近复制",
            .designDeviceName: "设备名称",
            .designGeneral: "通用",
            .designPermissions: "权限",
            .designOutput: "输出与预览",
            .designDrawing: "滚动与标注",
            .designEffects: "美化与特效",
            .wordHideChinese: "隐藏中文释义",
            .wordShowChinese: "显示中文释义",
            .wordChineseVisible: "中文释义已显示",
            .wordChineseHidden: "中文释义已隐藏",
            .wordBook: "单词表",
            .wordFamiliar: "熟悉",
            .wordUnfamiliar: "不熟悉",
            .wordBookStatus: "熟悉程度",
            .wordBookFilter: "中英文模糊搜索",
            .wordBookCheckHelp: "勾选表示熟悉，取消勾选移回不熟悉。",
            .wordBookEmpty: "此列表暂无匹配的单词。",
            .wordBookSelect: "选择一个单词开始复习",
            .wordBookHint: "查询成功后自动加入「不熟悉」。已保存的释义可离线查看，播放词典发音需要联网。",
            .wordBookLookups: "查询次数",
            .wordBookLastLookup: "最近查询",
            .wordBookReadError: "无法读取单词表，已保留原文件。请检查文件权限或备份后重新打开应用。",
            .wordBookWriteError: "单词表保存失败，本次改动未保存。请检查磁盘空间和权限后重试。",
            .wordLookup: "单词查询",
            .wordOriginal: "原文",
            .wordEnglishTranslation: "英文翻译",
            .wordChineseTranslation: "中文翻译",
            .wordMachineTranslation: "有道机器翻译 · 译文供参考，可结合上下文调整",
            .wordCopyTranslation: "复制译文",
            .wordReadEnglish: "朗读英文",
            .wordPlaceholder: "输入中文或英文单词、短语、句子",
            .wordCandidates: "匹配词条 · 点击查看详情",
            .wordSearch: "查询",
            .wordLoading: "正在查询与翻译…",
            .wordInvalidQuery: "请输入 500 个字符以内的中文或英文，可包含数字和标点",
            .wordNotFound: "未找到词条或翻译",
            .wordNetworkError: "暂时无法连接词典或读取结果",
            .wordTryAgain: "检查拼写或网络后，按回车重新查询。",
            .wordMeanings: "词性与释义",
            .wordInflections: "词形变化",
            .wordPhrases: "相关短语",
            .wordExamples: "双语例句",
            .wordNoPhrases: "词典暂未提供相关短语。",
            .wordNoExamples: "词典暂未提供例句。",
            .wordLookupPhrase: "查询这个短语",
            .wordSource: "来源：有道词典 · 查看完整词条",
            .wordWelcome: "查单词，也能翻译句子",
            .wordWelcomeDetail: "输入单词、短语或完整句子后点击查询。支持中文译英文、英文译中文，以及模糊查词。⌘ 回车也可提交。",
            .wordPrivacy: "剪贴板单词自动预填 · 提交后将输入发送至有道 · 词条保存到单词表，句子翻译不保存",
            .wordAmerican: "美",
            .wordNoIPA: "词典暂未提供美式音标",
            .wordPlayAudio: "美式发音",
            .wordStopAudio: "停止播放",
            .wordAudioLoading: "正在加载美式发音…",
            .wordRecordedAudio: "有道美式发音",
            .wordSystemAudio: "词典音频不可用，正在使用系统美式英语朗读",
            .wordAudioUnavailable: "发音暂不可用，请重试或在系统设置中下载美式英语语音。",
            .wordShortcut: "单词查询快捷键",
            .wordShortcutDescription: "在任何应用中打开单词窗口，默认 ⌃⌥D；也可从菜单栏进入。",
            .wordShortcutConflict: "快捷键注册失败，可能已被占用，请换一个组合。",
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
            .moreHistory: "更多历史",
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
            .sendFile: "发送文件或文件夹...",
            .sendText: "发送文本...",
            .chooseTextToSend: "发送文本到 %@",
            .sendTextHint: "文本将发送到对方设备并写入剪贴板。",
            .enterTextToSend: "输入要发送的文本",
            .editSnippets: "编辑片段...",
            .clearHistory: "清空历史记录",
            .clearHistoryConfirm: "将删除全部历史记录，此操作不可撤销。",
            .showLogs: "显示日志...",
            .quit: "退出",
            .chooseFileToSend: "选择要发送到 %@ 的文件或文件夹",
            .fileReceivedTitle: "已接收文件",
            .fileReceivedBody: "来自 %@：%@（已存入“下载/Clipy”）",
            .send: "发送",
            .sendFailed: "发送失败。目标设备可能离线或网络连接异常。",
            .folderSendPreparationFailed: "无法准备发送内容。请检查读取权限；文件夹含打包开销不能超过 512 MiB、10,000 个项目，且不能包含符号链接或特殊文件。",
            .snippetFolders: "文件夹",
            .snippetLibrary: "片段库",
            .snippetSearch: "搜索此文件夹",
            .snippetFolderSettings: "文件夹设置",
            .snippetAutosave: "更改自动保存",
            .snippetCopied: "已复制",
            .snippetEmptyFolder: "这个文件夹还没有片段",
            .snippetEmptyHint: "新建一个片段，把常用内容留在手边。",
            .snippetCharacters: "%d 个字符",
            .snippetActions: "更多片段操作",
            .snippetLibraryActions: "片段库操作",
            .snippetFolderCount: "%d 个片段",
            .snippetMoveHint: "拖动以调整顺序",
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
            .historyImageOCRIndexing: "历史图片文字识别（OCR 索引）",
            .historyImageOCRIndexingDescription: "自动识别截图与图片中的文字，让历史搜索能搜到图片内容。首次识别会加载系统 Vision 模型并常驻约 100MB 内存；关闭可显著降低常驻内存，已索引的条目不受影响。",
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
            .generatePassword: "生成密码",
            .passwordRegenerate: "重新生成",
            .passwordCopy: "复制密码",
            .passwordCopied: "已复制到剪贴板",
            .passwordEntropy: "熵：%@ 位",
            .passwordLengthLabel: "长度：",
            .passwordCharacterSet: "字符集",
            .passwordUppercase: "大写字母 A-Z",
            .passwordLowercase: "小写字母 a-z",
            .passwordDigits: "数字 0-9",
            .passwordSymbols: "符号",
            .passwordExcludeAmbiguous: "排除易混淆字符（Il1|O0o）",
            .passwordStrengthWeak: "弱",
            .passwordStrengthFair: "中",
            .passwordStrengthStrong: "强",
            .passwordStrengthVeryStrong: "极强",
        ],
        .en: [
            .smartVoiceTitle: "Automatic voice entry",
            .smartVoiceEnabled: "Open Smart Switch only for confirmed non-text focus",
            .smartVoiceTrigger: "Doubao hold-to-talk key",
            .smartVoiceRightCommand: "Right Command (⌘)",
            .smartVoiceRightOption: "Right Option (⌥)",
            .smartVoiceHint: "Match Doubao’s hold-to-talk key. All apps keep normal dictation for text inputs or unresolved focus. Only confirmed non-text focus on the same rechecked target opens the window; press Return after dictation. Custom interfaces with incomplete focus information may need the regular Smart Switch shortcut. Short taps and shortcuts pass through; hands-free mode and voice buttons are not intercepted.",
            .smartVoiceInputMonitoring: "Open Input Monitoring settings",
            .smartVoiceRecheck: "Check again",
            .smartVoiceDisabled: "Automatic entry is off. The regular Smart Switch shortcut remains available.",
            .smartVoiceNeedsSetup: "Save API settings and add at least one enabled application first.",
            .smartVoiceNeedsPermission: "Allow ClipyClone in Accessibility and Input Monitoring, then restart it. Only trigger gestures and focus types are inspected; keystrokes and foreground text are not recorded.",
            .smartVoiceActive: "Automatic entry is ready. Use Doubao’s hold-to-talk key; no extra Smart Switch shortcut is needed.",
            .smartVoiceUnavailable: "Could not start key monitoring. Check permissions and restart ClipyClone. Normal voice input remains available.",
            .smartVoiceInterrupted: "Voice preparation was interrupted. The window stays open; hold the voice key again or type.",
            .smartSwitchTitle: "Smart App Switch",
            .smartSwitchSettingsTitle: "Smart Switch",
            .smartSwitchInputLabel: "Enter text or an application command",
            .smartSwitchInputHint: "Explicit app launches come first. Return executes the selected action; Esc pastes back.",
            .smartSwitchExecute: "Switch",
            .smartSwitchWorking: "Working…",
            .smartSwitchSetupHint: "The input window selects Doubao; dictate and press Return. Explicit app-launch commands match locally first. Click action buttons or scroll over them to cycle.",
            .smartSwitchShortcut: "Enable Smart Switch shortcut",
            .smartSwitchShortcutConflict: "The shortcut could not be registered. Choose another combination, or use the menu bar.",
            .smartSwitchDoubaoUnavailable: "Doubao is unavailable. Enable it in System Settings, or continue typing.",
            .smartSwitchAPI: "Model API",
            .smartSwitchModel: "Model name",
            .smartSwitchAPIHint: "Use a Chat Completions-compatible service. Include the version path (such as /v1) in Base URL, without /chat/completions. Clear all three fields and save to remove the configuration.",
            .smartSwitchSaveAPI: "Save API configuration",
            .smartSwitchTest: "Test connection",
            .smartSwitchTestSuccess: "Connected and received a valid app selection. No app was opened. Save the configuration to use it.",
            .smartSwitchSaved: "API configuration saved.",
            .smartSwitchPrivacy: "Local app matching, Open Codex and New ZCode chat do not use the model. Intent requests send current input, allowed actions and configured app information, not paths or history. Translation sends the selected text. Keys stay in Keychain.",
            .smartSwitchApplications: "Applications & aliases (saved automatically)",
            .smartSwitchAddApplication: "Add applications…",
            .smartSwitchLocate: "Locate…",
            .smartSwitchAppName: "App name",
            .smartSwitchAliases: "Aliases (for example: browser, research)",
            .smartSwitchDescription: "Description (for example: my everyday code editor)",
            .smartSwitchNoTargets: "Add and enable an application in Preferences → Smart Switch.",
            .smartSwitchNoMatch: "No matching app or action. Try another request, select an action button, or add app aliases in settings.",
            .smartSwitchAmbiguous: "Several apps match. Select with Up/Down and Return, or click an app.",
            .smartSwitchConfigurationError: "Check and save Base URL, model and API key. Use HTTPS (HTTP is allowed for localhost), including the version path but without /chat/completions.",
            .smartSwitchInputError: "Enter text to process (up to 8000 characters), or select an action that runs without text.",
            .smartSwitchResponseError: "The model returned an invalid app selection. Retry, or check the service and model compatibility.",
            .smartSwitchInvalidApplication: "Select a valid macOS .app application.",
            .smartSwitchApplicationMissing: "App not found. Locate it again in settings.",
            .smartSwitchActivationFailed: "Could not activate the app. Retry or check that the app can launch normally.",
            .smartSwitchKeychainError: "Could not access the API key in Keychain (%d). Check Keychain permissions and reopen settings.",
            .smartSwitchAuthenticationError: "API authentication failed. Check the key, endpoint and model access.",
            .smartSwitchHTTPError: "The service returned HTTP %d. Check the configuration or retry later.",
            .smartSwitchTimeout: "Request timed out (15 seconds). Check the network or use a faster model.",
            .smartSwitchNetworkError: "Could not connect to the model service. Check the network and API URL, then retry.",
            .menuRecentHistory: "Recently Copied",
            .designDeviceName: "Device Name",
            .designGeneral: "General",
            .designPermissions: "Permissions",
            .designOutput: "Output & Preview",
            .designDrawing: "Scroll & Annotate",
            .designEffects: "Image Effects",
            .wordHideChinese: "Hide Chinese meanings",
            .wordShowChinese: "Show Chinese meanings",
            .wordChineseVisible: "Chinese meanings are shown",
            .wordChineseHidden: "Chinese meanings are hidden",
            .wordBook: "Vocabulary",
            .wordFamiliar: "Familiar",
            .wordUnfamiliar: "Unfamiliar",
            .wordBookStatus: "Familiarity",
            .wordBookFilter: "Fuzzy search in Chinese or English",
            .wordBookCheckHelp: "Check to mark familiar; uncheck to move back.",
            .wordBookEmpty: "No matching words in this list.",
            .wordBookSelect: "Select a word to review",
            .wordBookHint: "Successful lookups are saved as unfamiliar. Saved definitions work offline; dictionary audio requires a connection.",
            .wordBookLookups: "Lookups",
            .wordBookLastLookup: "Last lookup",
            .wordBookReadError: "Cannot read vocabulary. The original file was preserved. Check permissions or restore a backup, then reopen the app.",
            .wordBookWriteError: "Vocabulary could not be saved. Check disk space and permissions, then retry.",
            .wordLookup: "Word Lookup",
            .wordOriginal: "Original",
            .wordEnglishTranslation: "English translation",
            .wordChineseTranslation: "Chinese translation",
            .wordMachineTranslation: "Youdao machine translation · Wording may need adjustment for context",
            .wordCopyTranslation: "Copy translation",
            .wordReadEnglish: "Read English",
            .wordPlaceholder: "Chinese or English words, phrases or sentences",
            .wordCandidates: "Matching words · Select for details",
            .wordSearch: "Look up",
            .wordLoading: "Looking up and translating…",
            .wordInvalidQuery: "Enter up to 500 Chinese or English characters, including numbers and punctuation",
            .wordNotFound: "No entry or translation found",
            .wordNetworkError: "The dictionary is unavailable or returned an unreadable response",
            .wordTryAgain: "Check your spelling or connection, then press Return to retry.",
            .wordMeanings: "Parts of speech & meanings",
            .wordInflections: "Word forms",
            .wordPhrases: "Related phrases",
            .wordExamples: "Bilingual examples",
            .wordNoPhrases: "No related phrases provided by the dictionary.",
            .wordNoExamples: "No examples provided by the dictionary.",
            .wordLookupPhrase: "Look up this phrase",
            .wordSource: "Source: Youdao Dictionary · View full entry",
            .wordWelcome: "Look up words and translate sentences",
            .wordWelcomeDetail: "Enter a word, phrase or sentence, then click Look up or press ⌘ Return. Translate between Chinese and English, or find words with fuzzy search.",
            .wordPrivacy: "Prefills a clipboard word · Submission sends input to Youdao · Dictionary entries are saved; sentence translations are not",
            .wordAmerican: "US",
            .wordNoIPA: "American IPA is not available for this entry",
            .wordPlayAudio: "American pronunciation",
            .wordStopAudio: "Stop",
            .wordAudioLoading: "Loading American pronunciation…",
            .wordRecordedAudio: "Youdao American pronunciation",
            .wordSystemAudio: "Dictionary audio unavailable; using the system American English voice",
            .wordAudioUnavailable: "Audio unavailable. Retry or download an American English voice in System Settings.",
            .wordShortcut: "Word Lookup Shortcut",
            .wordShortcutDescription: "Open Word Lookup from any app (default: ⌃⌥D), or from the menu bar.",
            .wordShortcutConflict: "The shortcut could not be registered. It may be in use; choose another combination.",
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
            .moreHistory: "Earlier History",
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
            .sendFile: "Send File or Folder...",
            .sendText: "Send Text...",
            .chooseTextToSend: "Send text to %@",
            .sendTextHint: "The text will be delivered to the other device and copied to its clipboard.",
            .enterTextToSend: "Enter text to send",
            .editSnippets: "Edit Snippets...",
            .clearHistory: "Clear History",
            .clearHistoryConfirm: "All history will be deleted. This cannot be undone.",
            .showLogs: "Show Logs...",
            .quit: "Quit",
            .chooseFileToSend: "Choose a file or folder to send to %@",
            .fileReceivedTitle: "File Received",
            .fileReceivedBody: "From %@: %@ (saved to Downloads/Clipy)",
            .send: "Send",
            .sendFailed: "Send failed. The target device may be offline or the network connection may be unstable.",
            .folderSendPreparationFailed: "Could not prepare the transfer. Check read permissions. Folders including archive overhead must fit within 512 MiB and 10,000 entries, without symbolic links or special files.",
            .snippetFolders: "Folders",
            .snippetLibrary: "Snippet Library",
            .snippetSearch: "Search this folder",
            .snippetFolderSettings: "Folder Settings",
            .snippetAutosave: "Changes save automatically",
            .snippetCopied: "Copied",
            .snippetEmptyFolder: "No snippets in this folder",
            .snippetEmptyHint: "Create a snippet to keep useful text close at hand.",
            .snippetCharacters: "%d characters",
            .snippetActions: "More Snippet Actions",
            .snippetLibraryActions: "Library Actions",
            .snippetFolderCount: "%d snippets",
            .snippetMoveHint: "Drag to reorder",
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
            .historyImageOCRIndexing: "OCR Indexing for Image History",
            .historyImageOCRIndexingDescription: "Recognize text in captured images so history search can find it. The first recognition loads the system Vision models (~100MB resident) that cannot be released; disabling it lowers the standing footprint. Already-indexed entries are unaffected.",
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
            .generatePassword: "Generate Password",
            .passwordRegenerate: "Regenerate",
            .passwordCopy: "Copy Password",
            .passwordCopied: "Copied to clipboard",
            .passwordEntropy: "Entropy: %@ bits",
            .passwordLengthLabel: "Length:",
            .passwordCharacterSet: "Character Set",
            .passwordUppercase: "Uppercase (A-Z)",
            .passwordLowercase: "Lowercase (a-z)",
            .passwordDigits: "Digits (0-9)",
            .passwordSymbols: "Symbols",
            .passwordExcludeAmbiguous: "Exclude ambiguous characters (Il1|O0o)",
            .passwordStrengthWeak: "Weak",
            .passwordStrengthFair: "Fair",
            .passwordStrengthStrong: "Strong",
            .passwordStrengthVeryStrong: "Very Strong",
        ]
    ]
}
