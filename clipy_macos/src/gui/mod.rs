pub mod board;
pub mod constants;
pub mod design_tokens;
pub mod system_theme;
pub mod window_manager;
pub mod hotkey;
pub mod layout;
#[cfg(target_os = "macos")]
pub mod macos_dialog;
#[cfg(target_os = "macos")]
pub mod macos_window;
pub mod panels;
pub mod popup_geometry;
pub mod tray;
pub mod tray_anchor;
pub mod tray_menu;
pub mod views;
pub mod window;

pub use window::{dispatch_active, open_panel};

use std::borrow::Cow;

use gpui::{Context, Window};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "assets"]
pub struct Assets;

impl gpui::AssetSource for Assets {
    fn load(&self, path: &str) -> gpui::Result<Option<Cow<'static, [u8]>>> {
        Ok(Self::get(path).map(|data| data.data))
    }

    fn list(&self, path: &str) -> gpui::Result<Vec<gpui::SharedString>> {
        Ok(Self::iter()
            .filter_map(|p| p.starts_with(path).then(|| p.into()))
            .collect())
    }
}

/// 显示并激活窗口（托盘/热键共用）
pub fn active_window<T>(window: &mut Window, cx: &Context<'_, T>) {
    window.activate_window();
    #[cfg(target_os = "macos")]
    cx.activate(true);
}

pub fn hide_window<T>(window: &mut Window, cx: &Context<'_, T>) {
    #[cfg(target_os = "macos")]
    macos_window::order_out_window(window);
    let _ = cx;
}

/// 将 OS 线程事件转发到 async channel（阻塞 recv + send_blocking）
pub(crate) fn spawn_event_forwarder<T, F>(thread_name: &str, sender: async_channel::Sender<T>, receive_loop: F)
where
    T: Send + 'static,
    F: FnOnce(&dyn Fn(Option<T>) -> bool) + Send + 'static,
{
    if std::thread::Builder::new()
        .name(thread_name.to_string())
        .spawn(move || {
            receive_loop(&|mapped| {
                let Some(value) = mapped else {
                    return true;
                };
                sender.send_blocking(value).is_ok()
            });
        })
        .is_err()
    {
        tracing::error!(thread = thread_name, "failed to spawn event forwarder thread");
    }
}

/// 在下一帧主线程执行 UI 更新，避免与当前 App 借用冲突
pub fn defer_on_main(async_app: &gpui::AsyncApp, f: impl FnOnce(&mut gpui::App) + Send + 'static) {
    if async_app
        .update(|cx| {
            cx.defer(f);
        })
        .is_err()
    {
        tracing::warn!("defer_on_main failed: app unavailable");
    }
}

#[cfg(target_os = "macos")]
pub fn set_activation_policy_accessory() {
    use objc2_app_kit::{NSApplication, NSApplicationActivationPolicy};
    use objc2_foundation::MainThreadMarker;
    unsafe {
        if let Some(mtm) = MainThreadMarker::new() {
            let app = NSApplication::sharedApplication(mtm);
            app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
        }
    }
}

#[cfg(not(target_os = "macos"))]
pub fn set_activation_policy_accessory() {}

pub fn reveal_in_finder(path: &str) {
    #[cfg(target_os = "macos")]
    {
        use std::process::Command;
        let _ = Command::new("open").arg("-R").arg(path).spawn();
    }
    let _ = path;
}
