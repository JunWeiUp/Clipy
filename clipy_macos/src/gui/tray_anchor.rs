use once_cell::sync::Lazy;
use parking_lot::Mutex;
use tray_icon::Rect;

/// 托盘图标在屏幕上的物理像素区域（来自 tray-icon 事件）
#[derive(Clone, Copy, Debug, Default)]
pub struct TrayAnchorRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

static LAST_TRAY_ANCHOR: Lazy<Mutex<Option<TrayAnchorRect>>> =
    Lazy::new(|| Mutex::new(None));

pub fn set_tray_anchor_from_rect(rect: &Rect) {
    *LAST_TRAY_ANCHOR.lock() = Some(TrayAnchorRect {
        x: rect.position.x,
        y: rect.position.y,
        width: f64::from(rect.size.width),
        height: f64::from(rect.size.height),
    });
}

pub fn last_tray_anchor() -> Option<TrayAnchorRect> {
    LAST_TRAY_ANCHOR.lock().clone()
}
