# 截图相关控制全部纳入截图偏好

## 目标
把分散在 UserDefaults 的截图/录屏/输出/滚动/绘制辅助/美化特效控制,统一纳入 `PreferencesManager` 门面 + `ScreenshotSettingsView` 偏好面板。

## 已确认范围(用户全选)
- **录屏控制**:完成动作(编辑器/Finder/剪贴板)、帧率、隐藏HUD、系统音频/麦克风/摄像头/鼠标高亮/按键默认开关、按键模式(全部/仅快捷键)、摄像头位置/尺寸/形状
- **输出与缩略图**:显示浮动缩略图、堆叠、尺寸/位置、快速捕获动作、捕获鼠标光标、保存格式+质量、缩小Retina、提示音
- **滚动与绘制辅助**:滚动最大高度/自动滚动/速度/冻结检测;吸附对齐线、记住上次工具、单键快捷键提示、压感/平滑/智能荧光笔
- **美化与特效默认值**:渐变样式/模式/边距/圆角/阴影、特效预设/亮度/对比度/饱和度/锐度

## 改动文件(2 个)
1. **`Sources/App/PreferencesManager.swift`** — 新增 ~40 个计算属性(包装对应 UserDefaults 键,默认值与 macshot 一致),集中管理
2. **`Sources/UI/ScreenshotSettingsView.swift`** — 新增 4 个分区(录屏/输出缩略图/滚动绘制辅助/美化特效),用中文直显(应用中文优先,与 macshot 模块的 L() 风格一致)

## 不改的
- macshot 代码里的 `UserDefaults.standard.bool(forKey:)` 读取点不改(键名一致,PreferencesManager 只是门面,运行时读同一处);后续可逐步替换为 PreferencesManager.shared.xxx
- 不新增 L10nKey(约 40 个新字符串用中文直显,避免膨胀)

## 验证
`bash build_macos_app.sh` EXIT 0 + App 启动 + 打开截图偏好面板冒烟(4 个新分区可见、可改)