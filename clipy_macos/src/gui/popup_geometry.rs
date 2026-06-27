use gpui::{App, Bounds, Pixels, Window, point, px};

use super::constants::{
    MENU_BAR_FALLBACK_HEIGHT_PX, POPUP_EDGE_MARGIN_PX, POPUP_TRAY_GAP_PX, default_popup_size,
};
use super::tray_anchor::{TrayAnchorRect, last_tray_anchor};

#[cfg(target_os = "macos")]
use super::macos_window::set_window_frame;

use super::design_tokens::window_size;

pub fn popup_size_for_tab(tab: super::board::PanelTab, _single: bool) -> gpui::Size<Pixels> {
    match tab {
        super::board::PanelTab::History => window_size::search(),
        super::board::PanelTab::Snippets => window_size::editor(),
        super::board::PanelTab::Notifications => window_size::list(),
        super::board::PanelTab::Collector => window_size::list(),
        super::board::PanelTab::Settings => window_size::settings(),
        super::board::PanelTab::Logs => window_size::log(),
    }
}

/// 计算弹出窗口应出现的区域：紧贴菜单栏图标下方、右对齐（与旧版 NSMenu 一致）
pub fn popup_bounds_near_tray(window: &Window, cx: &App) -> Bounds<Pixels> {
    popup_bounds_near_tray_with_size(window, cx, default_popup_size())
}

pub fn popup_bounds_near_tray_with_size(
    window: &Window,
    cx: &App,
    size: gpui::Size<Pixels>,
) -> Bounds<Pixels> {
    let scale = window.scale_factor().max(1.0);
    let display = cx
        .primary_display()
        .expect("primary display");
    let screen = display.bounds();
    let margin = px(POPUP_EDGE_MARGIN_PX);
    let gap = px(POPUP_TRAY_GAP_PX);

    let (mut origin_x, mut origin_y) = if let Some(anchor) = last_tray_anchor() {
        anchor_origin(anchor, size, scale, gap)
    } else {
        fallback_origin(size, screen, margin)
    };

    origin_x = origin_x.max(screen.origin.x + margin);
    origin_y = origin_y.max(screen.origin.y + px(MENU_BAR_FALLBACK_HEIGHT_PX));
    if origin_x + size.width > screen.origin.x + screen.size.width - margin {
        origin_x = screen.origin.x + screen.size.width - size.width - margin;
    }
    if origin_y + size.height > screen.origin.y + screen.size.height - margin {
        origin_y = screen.origin.y + screen.size.height - size.height - margin;
    }

    Bounds::new(point(origin_x, origin_y), size)
}

fn anchor_origin(
    anchor: TrayAnchorRect,
    size: gpui::Size<Pixels>,
    scale: f32,
    gap: Pixels,
) -> (Pixels, Pixels) {
    let icon_x = px((anchor.x / f64::from(scale)) as f32);
    let icon_y = px((anchor.y / f64::from(scale)) as f32);
    let icon_w = px((anchor.width / f64::from(scale)) as f32);
    let icon_h = px((anchor.height / f64::from(scale)) as f32);

    let origin_x = icon_x + icon_w - size.width;
    let origin_y = icon_y + icon_h + gap;
    (origin_x, origin_y)
}

fn fallback_origin(
    size: gpui::Size<Pixels>,
    screen: Bounds<Pixels>,
    margin: Pixels,
) -> (Pixels, Pixels) {
    let origin_x = screen.origin.x + screen.size.width - size.width - margin;
    let origin_y = screen.origin.y + px(MENU_BAR_FALLBACK_HEIGHT_PX);
    (origin_x, origin_y)
}

#[cfg(target_os = "macos")]
pub fn reposition_popup_for_tab(window: &mut Window, cx: &App, tab: super::board::PanelTab, single: bool) {
    let size = popup_size_for_tab(tab, single);
    let bounds = popup_bounds_near_tray_with_size(window, cx, size);
    window.resize(bounds.size);
    set_window_frame(window, bounds, cx);
}

#[cfg(not(target_os = "macos"))]
pub fn reposition_popup_for_tab(window: &mut Window, cx: &App, tab: super::board::PanelTab, single: bool) {
    let size = popup_size_for_tab(tab, single);
    let bounds = popup_bounds_near_tray_with_size(window, cx, size);
    window.resize(bounds.size);
    let _ = (tab, single);
}

#[cfg(target_os = "macos")]
pub fn reposition_popup(window: &mut Window, cx: &App) {
    let bounds = popup_bounds_near_tray(window, cx);
    window.resize(bounds.size);
    set_window_frame(window, bounds, cx);
}

#[cfg(not(target_os = "macos"))]
pub fn reposition_popup(window: &mut Window, cx: &App) {
    let bounds = popup_bounds_near_tray(window, cx);
    window.resize(bounds.size);
}
