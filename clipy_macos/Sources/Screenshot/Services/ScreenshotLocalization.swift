import Foundation

/// Chinese (zh-Hans) translations for the screenshot module.
///
/// macshot's source calls `L("English Text")` everywhere. This table maps those
/// exact English keys to Simplified Chinese so the screenshot UI is fully
/// localized. Any key not listed here falls back to the English string verbatim
/// (see `L(_:​)` in `L.swift`).
enum ScreenshotLocalization {

    /// English key → Simplified Chinese value. Lookup is exact-string, O(1).
    static let zhHans: [String: String] = [
        // MARK: - Hints & status
        "(Tab to toggle)": "(按 Tab 切换)",
        "(No text detected in the selected area)": "(所选区域未检测到文字)",
        "%d chars · %d words": "%d 字符 · %d 词",
        "%d seconds": "%d 秒",
        "%@ selected": "已选 %@",
        "Click a window  ·  Drag for custom area  ·  F for full screen": "点击窗口 · 拖拽自定义区域 · F 全屏",
        "Drag to select  ·  Click for full screen": "拖拽选择 · 点击全屏",
        "Hold 1 auto-vertical  ·  Hold 2 auto-horizontal": "按住 1 自动竖向 · 按住 2 自动横向",
        "Hold Space to move. Release to annotate and edit": "按住空格移动,松开开始标注编辑",
        "Hold Space to move. Release to finish": "按住空格移动,松开完成",
        "Right-click to copy": "右键复制",
        "Scrolling...": "正在滚动...",
        "Some English Text": "示例文字",
        "Custom · %@": "自定义 · %@",
        "Auto:": "自动:",
        "Cam pos:": "摄像头位置:",
        "Cam shape:": "摄像头形状:",
        "Cam size:": "摄像头尺寸:",
        "Draw:": "绘制:",
        "Delay:": "延迟:",
        "FPS:": "帧率:",
        "Start:": "开始:",
        "When done:": "完成后:",
        "Window snap: ": "窗口吸附:",
        "Not enough room here": "此处空间不足",
        "Copied to clipboard!": "已复制到剪贴板!",
        "Copied %@": "已复制 %@",
        "Path copied!": "路径已复制!",
        "Saved to %@": "已保存到 %@",
        "Set color %@": "设置颜色 %@",

        // MARK: - Generic actions
        "Cancel": "取消",
        "Done": "完成",
        "Save": "保存",
        "Save All": "全部保存",
        "Save As...": "另存为...",
        "Save & Close": "保存并关闭",
        "Save changes?": "保存更改?",
        "Save to default folder": "保存到默认文件夹",
        "Save to": "保存到",
        "Discard": "放弃",
        "Reset": "重置",
        "Undo": "撤销",
        "Redo": "重做",
        "Copy": "复制",
        "Copy Path": "复制路径",
        "Copy to clipboard": "复制到剪贴板",
        "Close All": "全部关闭",
        "Delete": "删除",
        "Pause": "暂停",
        "Resume": "继续",
        "Stop": "停止",
        "Open Settings": "打开设置",
        "Open in Finder": "在 Finder 中显示",
        "Open With": "打开方式",
        "Open Link": "打开链接",
        "Quick Look": "快速预览",
        "Show in Finder": "在 Finder 中显示",
        "Adjust": "调整",
        "Flip": "翻转",
        "Crop": "裁剪",

        // MARK: - Capture modes
        "Capture Area": "区域截图",
        "Capture Screen": "屏幕截图",
        "Capture Last Area": "截取上次区域",
        "Capture OCR & QR": "截图 OCR 与二维码",
        "Open from Clipboard": "从剪贴板打开",
        "Quick Capture": "快速截图",
        "Pin from Clipboard": "从剪贴板贴图",
        "Record Area": "录制区域",
        "Record Screen": "录制屏幕",
        "Record screen": "录制屏幕",
        "Scroll Capture": "滚动截图",
        "Full Screen": "全屏",

        // MARK: - Tools (annotation)
        "Pencil (Draw)": "画笔(自由绘制)",
        "Pencil": "画笔",
        "Line": "直线",
        "Arrow": "箭头",
        "Rectangle": "矩形",
        "Ellipse": "椭圆",
        "Marker": "荧光笔",
        "Text": "文字",
        "Number": "编号",
        "Stamp / Emoji": "图章 / 表情",
        "Stamp": "图章",
        "Pixelate": "马赛克",
        "Blur": "模糊",
        "Solid": "纯色遮罩",
        "Censor (Pixelate / Blur / Solid)": "遮挡(马赛克 / 模糊 / 纯色)",
        "Censor": "遮挡",
        "Highlight (Spotlight)": "聚光灯",
        "Highlight": "聚光灯",
        "Magnify (Loupe)": "放大镜",
        "Loupe": "放大镜",
        "Measure (px)": "测距(像素)",
        "Measure": "测距",
        "Color Picker": "取色器",
        "Move Selection": "移动选区",
        "Select": "选择",

        // MARK: - Styles / options
        "Fill": "填充",
        "Stroke": "描边",
        "Outline": "描边轮廓",
        "Rounded": "圆角",
        "Smooth": "平滑",
        "Refined": "精细",
        "Smart": "智能",
        "Pressure": "压感",
        "Freeform": "自由",
        "Alignment": "对齐",
        "Bold": "加粗",
        "Italic": "斜体",
        "Underline": "下划线",
        "Strikethrough": "删除线",
        "Left": "左对齐",
        "Right": "右对齐",
        "Center": "居中",
        "On": "开",
        "OFF": "关",
        "ON": "开",
        "None": "无",
        "All": "全部",
        "Size": "尺寸",
        "Small": "小",
        "Medium": "中",
        "Large": "大",
        "Huge": "特大",
        "Color": "颜色",
        "Background": "背景",
        "Background Color": "背景颜色",
        "Text Color": "文字颜色",
        "Radius": "半径",
        "Padding": "内边距",
        "Shadow": "阴影",
        "Aspect ratio": "宽高比",
        "Aspect ratio & resolution presets": "宽高比与分辨率预设",
        "Resolution": "分辨率",
        "Presets": "预设",
        "Custom…": "自定义...",
        "Limit to selection": "限制在选区内",
        "Keep ratio for next captures": "下次截图保持宽高比",
        "Same as screenshots": "与截图一致",
        "Units": "单位",
        "Invert Colors": "反色",
        "Fit Canvas": "适应画布",
        "Flip Horizontal": "水平翻转",
        "Flip Vertical": "垂直翻转",
        "Rotate Left": "向左旋转",
        "Rotate Right": "向右旋转",
        "Zoom In": "放大",
        "Zoom Out": "缩小",
        "Zoom": "缩放",
        "Show Original": "显示原图",
        "Hide controls": "隐藏控件",
        "Add Capture": "添加截图",
        "Open editor": "打开编辑器",
        "Open in Editor": "在编辑器中打开",
        "Open in Editor Window": "在编辑窗口中打开",
        "Edit Text…": "编辑文字...",
        "More Emojis": "更多表情",

        // MARK: - Colors
        "Black": "黑",
        "White": "白",
        "Red": "红",
        "Green": "绿",
        "Blue": "蓝",
        "Yellow": "黄",
        "Transparent": "透明",
        "Dim": "变暗",

        // MARK: - Beautify / Effects
        "Beautify": "美化",
        "Gradient Style": "渐变样式",
        "Adjust (Image Effects)": "调整(图像特效)",
        "Adjustments": "调整",
        "Image Effects": "图像特效",
        "Brightness": "亮度",
        "Contrast": "对比度",
        "Saturation": "饱和度",
        "Sharpness": "锐度",
        "Click to add effects": "点击添加特效",
        "Add effect": "添加特效",
        "High": "高",
        "Low": "低",
        "Fade": "淡入淡出",

        // MARK: - Toolbar / actions
        "Pin": "贴图",
        "Pin (floating window)": "贴图(悬浮窗)",
        "Pin to Screen": "贴到屏幕",
        "OCR & QR": "OCR 与二维码",
        "Run OCR & QR": "运行 OCR 与二维码",
        "Share": "分享",
        "Upload": "上传",
        "Remove Background": "移除背景",
        "Translate": "翻译",
        "Translation": "翻译",
        "Translate to:": "翻译为:",
        "Translation Failed": "翻译失败",
        "Start Recording": "开始录制",
        "Stop Recording": "停止录制",
        "Cancel Recording": "取消录制",
        "Recording Settings": "录制设置",
        "Record System Audio": "录制系统音频",
        "Record Microphone": "录制麦克风",
        "Show Keystrokes": "显示按键",
        "Highlight Mouse Clicks": "高亮鼠标点击",
        "Webcam Overlay": "摄像头悬浮窗",
        "Auto Scroll": "自动滚动",
        "Auto-Redact sensitive data": "自动遮挡敏感信息",
        "Auto-Redact": "自动遮挡",
        "PII": "隐私信息",
        "Faces": "人脸",
        "People": "人物",
        "Ask where to save": "询问保存位置",
        "Choose a folder": "选择文件夹",
        "Clear History": "清空历史",
        "History": "历史",
        "Confirm before upload": "上传前确认",
        "Configure S3 in Settings": "在设置中配置 S3",
        "Sign in to Google Drive in Settings": "在设置中登录 Google Drive",
        "No Apps Available": "没有可用的应用",
        "No Share Services": "没有可用的分享服务",
        "Shortcuts Only": "仅快捷键",
        "All Keystrokes": "全部按键",

        // MARK: - OCR / recognition
        "Text Recognition": "文字识别",
        "Text & QR Recognition": "文字与二维码识别",
        "Text Only": "仅文字",
        "QR Code": "二维码",
        "QR Codes": "二维码",

        // MARK: - Recognition results / errors
        "Export failed": "导出失败",
        "Exporting...": "导出中...",
        "Processing GIF…": "正在生成 GIF...",
        "Converting to GIF…": "正在转换为 GIF...",
        "GIF conversion failed": "GIF 转换失败",
        "Save failed": "保存失败",
        "No video track found": "未找到视频轨道",
        "Upload failed: %@": "上传失败:%@",
        "Upload to Google Drive?": "上传到 Google Drive?",
        "Upload to S3?": "上传到 S3?",
        "Upload to imgbb.com?": "上传到 imgbb.com?",
        "Uploaded! Link copied.": "已上传!链接已复制。",
        "Uploading to %@... %d%%": "正在上传到 %@... %d%%",
        "Video upload requires Google Drive or S3": "视频上传需要 Google Drive 或 S3",

        // MARK: - Video editor segments
        "Add Censor": "添加遮挡",
        "Add Cut": "添加剪切",
        "Add Freeze": "添加定格",
        "Add Speed": "添加变速",
        "Add Text": "添加文字",
        "Add Zoom": "添加缩放",
        "Delete Censor": "删除遮挡",
        "Delete Cut": "删除剪切",
        "Delete Freeze": "删除定格",
        "Delete Speed": "删除变速",
        "Delete Text": "删除文字",
        "Delete Zoom": "删除缩放",
        "macshot Video Editor": "视频编辑器",

        // MARK: - Permissions / dialogs
        "Camera Access Required": "需要摄像头权限",
        "Microphone Access Required": "需要麦克风权限",
        "macshot needs camera permission for the webcam overlay. Open System Settings to grant access.": "摄像头悬浮窗需要摄像头权限。请打开系统设置授权。",
        "macshot needs microphone permission to record voice audio. Open System Settings to grant access.": "录制人声需要麦克风权限。请打开系统设置授权。",
        "Your screenshot will be uploaded.": "您的截图将被上传。",
        "Your annotations will be lost if you close without saving.": "不保存直接关闭将丢失标注。",

        // MARK: - Misc / AI
        "AI Search": "AI 搜索",
        "Space": "空格",
        "Record": "录制",
        "Release to finish": "松开完成",
        "Load Image": "载入图片",
        "All Text": "全部文字",
        "  (Tab to toggle)": "  (按 Tab 切换)",
        "Save All to Folder…": "全部保存到文件夹...",

        // MARK: - Scroll capture / accessibility
        "Accessibility Access Required": "需要辅助功能权限",
        "macshot needs Accessibility permission for scroll capture. Please grant access in System Settings, then try again.": "滚动截图需要辅助功能权限。请在系统设置中授权后再试。",
        "macshot needs Accessibility permission to show keystrokes during recording. Please grant access in System Settings, then try again.": "录屏时显示按键需要辅助功能权限。请在系统设置中授权后再试。",
        "Input Monitoring Required": "需要输入监控权限",
        "macshot needs Input Monitoring permission to show keystrokes during recording. Please grant access in System Settings, then try again.": "录屏时显示按键需要输入监控权限。请在系统设置中授权后再试。",
    ]

    /// Active table based on the current system language.
    /// Matches clipy1's `Localization.swift` zh-Hans detection (language code
    /// prefix "zh"). Returns the English-pass-through (empty) table otherwise.
    /// The result is cached for the session and invalidated when clipy1's
    /// `appLanguageDidChange` notification fires (runtime language switch).
    static var active: [String: String] {
        ensureObserverInstalled()
        if let cached = cachedActive { return cached }
        let preferred = Locale.preferredLanguages.first ?? "en"
        let table = preferred.hasPrefix("zh") ? zhHans : [:]
        cachedActive = table
        return table
    }

    private static var cachedActive: [String: String]?
    private static var observerInstalled = false

    /// Install the language-change observer once. clipy1 posts
    /// `.appLanguageDidChange` when the user switches language at runtime.
    private static func ensureObserverInstalled() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: Notification.Name("appLanguageDidChange"),
            object: nil, queue: .main
        ) { _ in reload() }
    }

    /// Invalidate the cache (re-run on language change).
    static func reload() {
        cachedActive = nil
    }
}
