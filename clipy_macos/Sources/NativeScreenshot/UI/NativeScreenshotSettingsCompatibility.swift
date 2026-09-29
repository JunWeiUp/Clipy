import CoreGraphics
import Foundation

/// Settings labels retained by ScreenshotSettingsView during the native screenshot rewrite.
/// This table is independent of the previous screenshot implementation.
enum NativeScreenshotSettingsCompatibility {
    static let chinese: [String: String] = [
        "Accessibility": "辅助功能",
        "After Recording": "录制结束后",
        "All Keystrokes": "所有按键",
        "Auto Scroll": "自动滚动",
        "Auto Scroll Speed": "自动滚动速度",
        "Beautify & Image Effects (Defaults)": "美化与图像特效（默认值）",
        "Beautify Mode": "美化模式",
        "Bottom Left": "左下角",
        "Bottom Right": "右下角",
        "Brightness": "亮度",
        "Camera": "摄像头",
        "Capture Mouse Cursor": "捕获鼠标指针",
        "Circle": "圆形",
        "Contrast": "对比度",
        "Copy to clipboard": "复制到剪贴板",
        "Detect Frozen Headers": "检测固定页眉",
        "Downscale Retina Screenshots to 1×": "将 Retina 截图缩小至 1×",
        "Enable Beautify Wrap by Default": "默认启用美化包裹",
        "Frame Rate (FPS)": "帧率（FPS）",
        "Hide Recording Controls": "隐藏录屏控件",
        "Huge": "超大",
        "Input Monitoring": "输入监控",
        "Keystroke Display": "按键显示",
        "Keystroke Mode": "按键显示模式",
        "Keystroke display and mouse click highlight": "显示按键和高亮鼠标点击",
        "Large": "大",
        "Margin": "边距",
        "Max Height: %d px": "最大高度：%d 像素",
        "Medium": "中",
        "Microphone": "麦克风",
        "Mouse Click Highlight": "鼠标点击高亮",
        "None": "无",
        "Open editor": "打开编辑器",
        "Output & Thumbnails": "输出与缩略图",
        "Paste simulation and element snap": "模拟粘贴和元素吸附",
        "Pencil Pressure (Apple Pencil)": "画笔压感（Apple Pencil）",
        "Pencil Smoothing": "画笔平滑",
        "Play Sound After Capture": "截图后播放提示音",
        "Quality": "画质",
        "Quick Capture Action": "快速捕获动作",
        "Record Microphone": "录制麦克风",
        "Record System Audio": "录制系统音频",
        "Record voice during screen recording": "录屏时录制人声",
        "Recording": "录屏",
        "Refined": "精细",
        "Remember Last Used Tool": "记住上次使用的工具",
        "Request Permission": "请求授权",
        "Required for screenshots and recording": "截图和录屏所需",
        "Rounded": "圆角",
        "Rounded Rectangle": "圆角矩形",
        "Saturation": "饱和度",
        "Save Format": "保存格式",
        "Save Only": "仅保存",
        "Save and Copy": "保存并复制",
        "Screen Recording": "屏幕录制",
        "Screenshot": "截图",
        "Scroll Capture": "滚动长截图",
        "Scroll Capture & Drawing Aids": "滚动截图与绘制辅助",
        "Shadow": "阴影",
        "Sharpness": "锐度",
        "Shortcuts Only": "仅快捷键",
        "Show Alignment Guides": "显示对齐参考线",
        "Show Floating Thumbnail After Capture": "截图后显示浮动缩略图",
        "Show Shortcuts in Tooltips": "在工具提示中显示快捷键",
        "Show in Finder": "在访达中显示",
        "Small": "小",
        "Smart Marker (Fit Text Line Height)": "智能荧光笔（适配文字行高）",
        "Smooth": "平滑",
        "Stack Thumbnails for Consecutive Captures": "连续截图时堆叠缩略图",
        "Thumbnail Only": "仅显示缩略图",
        "Thumbnail Position": "缩略图位置",
        "Thumbnail Size": "缩略图大小",
        "Top Left": "左上角",
        "Top Right": "右上角",
        "Webcam Overlay": "摄像头画中画",
        "Webcam Position": "摄像头位置",
        "Webcam Shape": "摄像头形状",
        "Webcam Size": "摄像头大小",
        "Webcam overlay during recording": "录屏时显示摄像头画中画",
        "Window (with Traffic Lights)": "窗口（带红绿灯按钮）",
    ]

    static func localized(_ english: String, languageCode: String? = nil) -> String {
        let raw = languageCode ?? UserDefaults.standard.string(forKey: "appLanguage")
        let usesChinese = raw == "zh"
            || (raw != "en" && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        return usesChinese ? chinese[english] ?? english : english
    }
}

/// Existing settings view call site. Unknown strings remain readable in English.
func L(_ english: String) -> String {
    NativeScreenshotSettingsCompatibility.localized(english)
}

/// Preview-only permission adapter used by the existing settings view.
/// Merely showing settings never requests access or starts an event tap.
enum KeystrokeOverlay {
    static var hasInputMonitoringPermission: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
    }
}
