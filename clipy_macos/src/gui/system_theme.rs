use gpui::{App, Window};
use gpui_component::{Theme, theme::ThemeMode};

/// 应用 macOS 系统浅色主题（对齐 Swift AppKit windowBackgroundColor）
pub fn apply_system_light_theme(window: &mut Window, cx: &mut App) {
    Theme::change(ThemeMode::Light, Some(window), cx);
}

/// 启动时全局浅色主题
pub fn init_global_light_theme(cx: &mut App) {
    Theme::change(ThemeMode::Light, None, cx);
}
