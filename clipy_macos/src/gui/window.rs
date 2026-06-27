use gpui::{App, WindowHandle};
use gpui_component::Root;

use super::board::{ClipyBoard, OpenPanel, PanelTab};

fn with_board(
    window_handle: WindowHandle<Root>,
    cx: &mut App,
    label: &str,
    f: impl FnOnce(&mut ClipyBoard, &mut gpui::Window, &mut gpui::Context<ClipyBoard>),
) {
    if window_handle
        .update(cx, |root, window, cx| {
            let Ok(board) = root.view().clone().downcast::<ClipyBoard>() else {
                tracing::warn!("{label}: ClipyBoard downcast failed");
                return;
            };
            board.update(cx, |board, cx| f(board, window, cx));
        })
        .is_err()
    {
        tracing::warn!("{label}: window update failed");
    }
}

/// 热键触发：直接激活面板（不依赖 window.dispatch_action）
pub fn dispatch_active(window_handle: WindowHandle<Root>, cx: &mut App) {
    with_board(window_handle, cx, "dispatch_active", |board, window, cx| {
        board.on_active(window, cx);
    });
}

/// 打开指定 Tab（托盘菜单项，单页大窗口模式）
pub fn open_panel(window_handle: WindowHandle<Root>, tab: PanelTab, cx: &mut App) {
    dispatch_open_panel(window_handle, OpenPanel::single(tab), cx);
}

pub fn dispatch_open_panel(window_handle: WindowHandle<Root>, action: OpenPanel, cx: &mut App) {
    with_board(window_handle, cx, "dispatch_open_panel", |board, window, cx| {
        board.open_panel(&action, window, cx);
    });
}
