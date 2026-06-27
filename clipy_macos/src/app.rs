#![cfg_attr(test, allow(clippy::unwrap_used))]

use std::sync::{Arc, Mutex, RwLock};

use gpui::{App, AppContext, Global, ReadGlobal, WindowHandle};
use gpui_component::Root;

use crate::{
    clipboard::{self, ClipboardEvent, LastCopyState},
    config::Settings,
    constants::{CLIPBOARD_EVENT_CHANNEL_CAPACITY, UI_NOTIFY_CHANNEL_CAPACITY},
    gui::board::ClipyBoard,
    gui::hotkey,
    gui::window_manager::{self, WindowKindId, WindowManager, WindowShared},
    gui::{defer_on_main, tray::TrayState},
    i18n::I18n,
    repository::{ClipboardRecord, ClipboardRepository, GlobalRepository, SharedRecords},
    snippet::GlobalSnippetStore,
    sync,
    utils::migration,
};

pub struct AppWindows {
    pub manager: Arc<Mutex<WindowManager>>,
}

impl Clone for AppWindows {
    fn clone(&self) -> Self {
        Self {
            manager: self.manager.clone(),
        }
    }
}

impl AppWindows {
    pub fn global(cx: &App) -> Self {
        cx.read_global(|s: &Self, _| s.clone())
    }
}

impl Global for AppWindows {}

pub fn launch() {
    let _ = migration::migrate_from_swift_if_needed();

    gpui::Application::new()
        .with_assets(crate::gui::Assets)
        .run(|cx| {
            #[cfg(target_os = "macos")]
            crate::gui::set_activation_policy_accessory();

            gpui_component::init(cx);
            window_manager::init_app_theme(cx);
            window_manager::install_window_keys(cx);

            let settings = Settings::load().unwrap_or_default();
            let language = settings.language;
            cx.set_global(settings.clone());
            cx.set_global(I18n::new(language));
            crate::gui::tray::TrayState::register(cx);

            let repository = match ClipboardRepository::new() {
                Ok(r) => {
                    r.set_encryption_enabled(settings.history_encryption.enabled);
                    Some(Arc::new(r))
                }
                Err(e) => {
                    tracing::error!(error = %e, "repository init failed");
                    None
                }
            };

            let limit = settings.storage.history_load_count;
            let initial: Vec<ClipboardRecord> = repository
                .as_ref()
                .and_then(|r| r.get_display_records(limit).ok())
                .unwrap_or_default();
            let shared_records: SharedRecords = Arc::new(RwLock::new(initial));
            cx.set_global(GlobalRepository::new(repository));

            GlobalSnippetStore::install(cx);

            let last_copy = Arc::new(Mutex::new(LastCopyState::default()));
            let (clip_tx, clip_rx) =
                async_channel::bounded::<ClipboardEvent>(CLIPBOARD_EVENT_CHANNEL_CAPACITY);
            clipboard::start_clipboard_monitor(clip_tx, last_copy.clone());
            let copy_tx = clipboard::start_clipboard_writer(cx);

            let shared = WindowShared {
                records: shared_records.clone(),
                last_copy: last_copy.clone(),
                copy_tx: copy_tx.clone(),
            };
            let manager = Arc::new(Mutex::new(WindowManager::new(shared)));
            cx.set_global(AppWindows { manager: manager.clone() });

            start_clipboard_handler(clip_rx, cx);

            if settings.sync.enabled {
                cx.defer(|cx| sync::start_sync(cx));
            }

            let hotkey_str = settings.hotkey.activation_key.clone();
            let manager = manager.clone();
            let _hotkey_tx = hotkey::start_hotkey_listener(hotkey_str, cx, move |async_app| {
                defer_on_main(async_app, move |cx| {
                    let manager = cx.read_global(|s: &AppWindows, _| s.manager.clone());
                    let mut mgr = manager.lock().unwrap_or_else(|e| e.into_inner());
                    mgr.show(WindowKindId::Search, cx);
                });
            });

            let tray = crate::gui::tray::start_tray(
                cx,
                shared_records.clone(),
                copy_tx.clone(),
                last_copy.clone(),
            );
            crate::gui::tray::TrayState::install(
                cx,
                tray,
                shared_records.clone(),
                copy_tx,
                last_copy,
            );
        });
}

fn start_clipboard_handler(clip_rx: async_channel::Receiver<ClipboardEvent>, cx: &App) {
    let (notify_tx, notify_rx) = async_channel::bounded::<()>(UI_NOTIFY_CHANNEL_CAPACITY);
    let bg_repo = GlobalRepository::global(cx).cloned();
    let excluded = Settings::read(cx, |s| s.storage.excluded_apps.clone());
    let sync_enabled = Settings::read(cx, |s| s.sync.enabled);

    cx.background_spawn(async move {
        while let Ok(event) = clip_rx.recv().await {
            if let Some(ref repo) = bg_repo {
                if let Some(bundle) = event_source_bundle(&event) {
                    if excluded.contains(&bundle) {
                        continue;
                    }
                }
                let saved = match event {
                    ClipboardEvent::Text {
                        text,
                        source_app,
                        source_bundle_id,
                    } => {
                        let result = repo.save_text(text.clone(), source_app, source_bundle_id);
                        if sync_enabled {
                            if let Ok(ref record) = result {
                                if let Some(ref h) = record.content_hash_hex {
                                    sync::broadcast_text(&text, h);
                                }
                            }
                        }
                        result
                    }
                    ClipboardEvent::Image {
                        path,
                        hash,
                        source_app,
                        source_bundle_id,
                    } => repo.save_image_from_path(path, hash, source_app, source_bundle_id),
                    ClipboardEvent::Files {
                        paths,
                        source_app,
                        source_bundle_id,
                    } => repo.save_files(paths, source_app, source_bundle_id),
                    ClipboardEvent::RichText {
                        plain_text,
                        html,
                        rtf,
                        source_app,
                        source_bundle_id,
                    } => repo.save_rich_text(plain_text, html, rtf, source_app, source_bundle_id),
                };
                if saved.is_ok() {
                    let _ = repo.persist_current();
                    let _ = notify_tx.try_send(());
                    if let Some(ref r) = bg_repo {
                        let max = 2000usize;
                        let _ = r.cleanup_old_records(max);
                    }
                }
            }
        }
    })
    .detach();

    cx.spawn(async move |async_app| {
        while notify_rx.recv().await.is_ok() {
            while notify_rx.try_recv().is_ok() {}
            defer_on_main(&async_app, move |cx| {
                refresh_all_boards(cx);
                crate::gui::tray::TrayState::refresh_menu(cx);
            });
        }
    })
    .detach();
}

fn refresh_all_boards(cx: &mut App) {
    let manager = cx.read_global(|s: &AppWindows, _| s.manager.clone());
    let mgr = manager.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(handle) = mgr.search_handle() {
        let _ = handle.update(cx, |root, _, cx| {
            if let Ok(board) = root.view().clone().downcast::<ClipyBoard>() {
                board.update(cx, |board, cx| {
                    board.refresh_from_repo(cx);
                    cx.notify();
                });
            }
        });
    }
}

fn event_source_bundle(event: &ClipboardEvent) -> Option<String> {
    match event {
        ClipboardEvent::Text { source_bundle_id, .. }
        | ClipboardEvent::Image { source_bundle_id, .. }
        | ClipboardEvent::Files { source_bundle_id, .. }
        | ClipboardEvent::RichText { source_bundle_id, .. } => source_bundle_id.clone(),
    }
}
