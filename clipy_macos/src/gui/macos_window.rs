#[cfg(target_os = "macos")]
use gpui::{App, Bounds, Pixels, Window};
#[cfg(target_os = "macos")]
use objc2_app_kit::NSView;
#[cfg(target_os = "macos")]
use objc2_foundation::{MainThreadMarker, NSPoint, NSRect, NSSize};
#[cfg(target_os = "macos")]
use raw_window_handle::{HasWindowHandle, RawWindowHandle};

/// 将 GPUI 逻辑坐标下的窗口 bounds 应用到 NSWindow（菜单栏下方定位依赖此函数）
#[cfg(target_os = "macos")]
pub fn set_window_frame(window: &Window, bounds: Bounds<Pixels>, _cx: &App) {
    let Some(_mtm) = MainThreadMarker::new() else {
        tracing::warn!("set_window_frame: not on main thread");
        return;
    };

    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        tracing::warn!("set_window_frame: no window handle");
        return;
    };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        tracing::warn!("set_window_frame: not an AppKit window");
        return;
    };

    unsafe {
        let view_ptr = appkit.ns_view.as_ptr() as *const NSView;
        if view_ptr.is_null() {
            return;
        }
        let view = &*view_ptr;
        let Some(ns_window) = view.window() else {
            tracing::warn!("set_window_frame: NSView has no window");
            return;
        };
        let Some(ns_screen) = ns_window.screen() else {
            tracing::warn!("set_window_frame: window has no screen");
            return;
        };

        let screen_frame = ns_screen.frame();
        let width = bounds.size.width.to_f64();
        let height = bounds.size.height.to_f64();
        let x = screen_frame.origin.x + bounds.origin.x.to_f64();
        let y = screen_frame.origin.y + screen_frame.size.height
            - bounds.origin.y.to_f64()
            - height;

        let frame = NSRect::new(NSPoint::new(x, y), NSSize::new(width, height));
        ns_window.setFrame_display(frame, true);
    }
}

/// 隐藏弹出窗口（不隐藏整个 NSApplication，便于再次从菜单栏唤起）
#[cfg(target_os = "macos")]
pub fn order_out_window(window: &Window) {
    let Some(_mtm) = MainThreadMarker::new() else {
        return;
    };
    let Ok(handle) = HasWindowHandle::window_handle(window) else {
        return;
    };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return;
    };
    unsafe {
        let view_ptr = appkit.ns_view.as_ptr() as *const NSView;
        if view_ptr.is_null() {
            return;
        }
        let view = &*view_ptr;
        if let Some(ns_window) = view.window() {
            ns_window.orderOut(None);
        }
    }
}
