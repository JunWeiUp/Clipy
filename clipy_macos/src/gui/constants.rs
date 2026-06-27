use gpui::{px, size, Size, Pixels};

use super::design_tokens::window_size;

pub const POPUP_EDGE_MARGIN_PX: f32 = 8.0;
pub const POPUP_TRAY_GAP_PX: f32 = 4.0;
pub const MENU_BAR_FALLBACK_HEIGHT_PX: f32 = 28.0;

pub fn default_popup_size() -> Size<Pixels> {
    window_size::search()
}
