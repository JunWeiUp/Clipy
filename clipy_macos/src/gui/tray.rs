use gpui::{App, AppContext as _, Global};
use tray_icon::{
    Icon, TrayIcon, TrayIconBuilder, TrayIconEvent,
    menu::{MenuEvent, MenuId},
};

use crate::app::AppWindows;
use crate::gui::window_manager::WindowKindId;
use crate::clipboard::{CopyRequest, LastCopyState};
use crate::config::Settings;
use crate::constants::APP_NAME;
use crate::gui::board::PanelTab;
use crate::gui::tray_menu::{
    ACTION_CLEAR, ACTION_COLLECTOR, ACTION_LOGS, ACTION_PREFERENCES, ACTION_QUIT, ACTION_SEARCH,
    ACTION_SNIPPETS, build_tray_menu, tray_menu_context,
};
use crate::gui::{defer_on_main, spawn_event_forwarder, tray_anchor::set_tray_anchor_from_rect};
use crate::i18n::I18n;
use crate::repository::{ClipboardRecord, ContentType, GlobalRepository, SharedRecords};
use crate::snippet::SnippetStore;

const TRAY_ICON_SIZE: u32 = 22;

#[derive(Debug, Clone)]
enum TrayMenuAction {
    OpenPanel(PanelTab),
    CopyRecord(u64),
    CopyFileNames(u64),
    CopyFiles(u64),
    RevealFile(u64),
    CopySnippet(String),
    RevealFileHistory(String),
    SendFile(String),
    ClearHistory,
    Quit,
}

#[derive(Default)]
pub struct TrayState {
    tray_icon: Option<TrayIcon>,
    deps: Option<TrayDeps>,
}

struct TrayDeps {
    shared_records: SharedRecords,
    copy_tx: async_channel::Sender<CopyRequest>,
    last_copy: std::sync::Arc<std::sync::Mutex<LastCopyState>>,
}

impl Clone for TrayDeps {
    fn clone(&self) -> Self {
        Self {
            shared_records: self.shared_records.clone(),
            copy_tx: self.copy_tx.clone(),
            last_copy: self.last_copy.clone(),
        }
    }
}

impl Global for TrayState {}

impl TrayState {
    pub fn register(cx: &mut App) {
        cx.set_global(Self::default());
    }

    pub fn install(
        cx: &mut App,
        tray: Option<TrayIcon>,
        shared_records: SharedRecords,
        copy_tx: async_channel::Sender<CopyRequest>,
        last_copy: std::sync::Arc<std::sync::Mutex<LastCopyState>>,
    ) {
        cx.set_global(TrayState {
            tray_icon: tray,
            deps: Some(TrayDeps {
                shared_records,
                copy_tx,
                last_copy,
            }),
        });
    }

    pub fn refresh_menu(cx: &mut App) {
        let (tray, deps) = cx.read_global(|state: &TrayState, _| {
            (state.tray_icon.clone(), state.deps.clone())
        });
        let Some(tray) = tray else { return };
        let Some(deps) = deps else { return };

        let i18n = cx.read_global(|i: &I18n, _| i.clone());
        let ctx = tray_menu_context(cx, deps.shared_records.clone());
        match build_tray_menu(&ctx, &i18n, cx) {
            Ok(menu) => tray.set_menu(Some(Box::new(menu))),
            Err(e) => tracing::error!(error = %e, "failed to rebuild tray menu"),
        }
    }
}

pub fn start_tray(
    cx: &App,
    shared_records: SharedRecords,
    copy_tx: async_channel::Sender<CopyRequest>,
    last_copy: std::sync::Arc<std::sync::Mutex<LastCopyState>>,
) -> Option<TrayIcon> {
    let i18n = cx.read_global(|i: &I18n, _| i.clone());
    let ctx = tray_menu_context(cx, shared_records.clone());
    let menu = match build_tray_menu(&ctx, &i18n, cx) {
        Ok(m) => m,
        Err(e) => {
            tracing::error!(error = %e, "failed to build tray menu");
            return None;
        }
    };
    let icon = match create_icon() {
        Ok(i) => i,
        Err(e) => {
            tracing::error!(error = %e, "failed to create tray icon");
            return None;
        }
    };

    let tray = match TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip(APP_NAME)
        .with_icon(icon)
        .with_icon_as_template(true)
        .with_menu_on_left_click(true)
        .with_menu_on_right_click(true)
        .build()
    {
        Ok(t) => t,
        Err(e) => {
            tracing::error!(error = %e, "failed to build tray icon");
            return None;
        }
    };

    let (action_tx, action_rx) = async_channel::unbounded::<TrayMenuAction>();
    spawn_tray_menu_forwarder(action_tx);
    spawn_tray_anchor_tracker();

    let deps = TrayDeps {
        shared_records: shared_records.clone(),
        copy_tx: copy_tx.clone(),
        last_copy: last_copy.clone(),
    };

    cx.spawn(async move |async_app| {
        while let Ok(action) = action_rx.recv().await {
            let deps = deps.clone();
            defer_on_main(&async_app, move |cx| handle_menu_action(action, &deps, cx));
        }
    })
    .detach();

    tracing::info!("tray icon initialized");
    Some(tray)
}

fn handle_menu_action(action: TrayMenuAction, deps: &TrayDeps, cx: &mut App) {
    match action {
        TrayMenuAction::OpenPanel(tab) => {
            let kind = panel_tab_to_window_kind(tab);
            let manager = cx.read_global(|s: &AppWindows, _| s.manager.clone());
            let mut mgr = manager.lock().unwrap_or_else(|e| e.into_inner());
            mgr.show(kind, cx);
        }
        TrayMenuAction::CopyRecord(id) => {
            if let Some(record) = load_record(id, cx) {
                send_copy_request(&deps.copy_tx, &record, false);
                touch_last_copy(&deps.last_copy, &record);
            }
        }
        TrayMenuAction::CopyFileNames(id) => {
            if let Some(record) = load_record(id, cx) {
                let names: Vec<_> = record
                    .content
                    .lines()
                    .filter_map(|line| {
                        std::path::Path::new(line)
                            .file_name()
                            .map(|n| n.to_string_lossy().into_owned())
                    })
                    .collect();
                let _ = deps.copy_tx.try_send(CopyRequest::Text {
                    text: names.join("\n"),
                    paste: false,
                });
            }
        }
        TrayMenuAction::CopyFiles(id) => {
            if let Some(record) = load_record(id, cx) {
                send_copy_request(&deps.copy_tx, &record, false);
            }
        }
        TrayMenuAction::RevealFile(id) => {
            if let Some(record) = load_record(id, cx) {
                if let Some(path) = record.content.lines().next() {
                    crate::gui::reveal_in_finder(path);
                }
            }
        }
        TrayMenuAction::RevealFileHistory(id) => {
            if let Some(path) = GlobalRepository::read(cx, |repo| {
                repo.and_then(|r| {
                    r.load_file_history().ok().and_then(|items| {
                        items.into_iter().find(|i| i.id == id).map(|i| i.file_path)
                    })
                })
            }) {
                crate::gui::reveal_in_finder(&path);
            }
        }
        TrayMenuAction::CopySnippet(snippet_id) => {
            for folder in SnippetStore::global().folders() {
                if let Some(snippet) = folder.snippets.iter().find(|s| s.id == snippet_id) {
                    let _ = deps.copy_tx.try_send(CopyRequest::Text {
                        text: snippet.content.clone(),
                        paste: false,
                    });
                    break;
                }
            }
        }
        TrayMenuAction::SendFile(_device) => {
            for path in crate::gui::macos_dialog::pick_files() {
                crate::sync::transport::send_file(std::path::Path::new(&path));
            }
        }
        TrayMenuAction::ClearHistory => clear_history(deps, cx),
        TrayMenuAction::Quit => cx.quit(),
    }
}

fn load_record(id: u64, cx: &App) -> Option<ClipboardRecord> {
    GlobalRepository::read(cx, |repo| {
        repo.and_then(|r| r.get_record(id).ok().flatten())
    })
}

fn send_copy_request(copy_tx: &async_channel::Sender<CopyRequest>, record: &ClipboardRecord, paste: bool) {
    let req = match record.content_type {
        ContentType::Image => CopyRequest::Image {
            path: record.content.clone(),
            paste,
        },
        ContentType::FilePath => CopyRequest::Files {
            paths: record.content.lines().map(str::to_string).collect(),
            paste,
        },
        ContentType::RichText => CopyRequest::RichText {
            plain_text: record.content.clone(),
            html: record.rich_text_meta.as_ref().and_then(|m| m.html_path.clone()),
            rtf: record.rich_text_meta.as_ref().and_then(|m| m.rtf_path.clone()),
            paste,
        },
        _ => CopyRequest::Text {
            text: record.content.clone(),
            paste,
        },
    };
    let _ = copy_tx.try_send(req);
}

fn touch_last_copy(last_copy: &std::sync::Arc<std::sync::Mutex<LastCopyState>>, record: &ClipboardRecord) {
    if let Ok(mut lc) = last_copy.lock() {
        *lc = match record.content_type {
            ContentType::Image => LastCopyState::Image(record.id),
            ContentType::FilePath => LastCopyState::Files(record.id),
            ContentType::RichText => LastCopyState::RichText(record.content.clone()),
            _ => LastCopyState::Text(record.content.clone()),
        };
    }
}

fn clear_history(deps: &TrayDeps, cx: &mut App) {
    if let Some(repo) = GlobalRepository::read(cx, |repo| repo.cloned()) {
        let _ = repo.clear_history();
    }
    if let Ok(mut records) = deps.shared_records.write() {
        records.clear();
    }
    let manager = cx.read_global(|s: &AppWindows, _| s.manager.clone());
    let mut mgr = manager.lock().unwrap_or_else(|e| e.into_inner());
    mgr.show(WindowKindId::Search, cx);
    TrayState::refresh_menu(cx);
}

fn panel_tab_to_window_kind(tab: PanelTab) -> WindowKindId {
    match tab {
        PanelTab::History => WindowKindId::Search,
        PanelTab::Snippets => WindowKindId::Snippets,
        PanelTab::Notifications => WindowKindId::Notifications,
        PanelTab::Collector => WindowKindId::Collector,
        PanelTab::Settings => WindowKindId::Settings,
        PanelTab::Logs => WindowKindId::Logs,
    }
}

fn spawn_tray_menu_forwarder(action_tx: async_channel::Sender<TrayMenuAction>) {
    let receiver = MenuEvent::receiver().clone();
    spawn_event_forwarder("tray-menu-forwarder", action_tx, move |forward| {
        while let Ok(event) = receiver.recv() {
            if let Some(action) = parse_menu_action(&event.id) {
                if !forward(Some(action)) {
                    break;
                }
            }
        }
    });
}

fn spawn_tray_anchor_tracker() {
    let receiver = TrayIconEvent::receiver().clone();
    if std::thread::Builder::new()
        .name("tray-anchor".into())
        .spawn(move || {
            while let Ok(event) = receiver.recv() {
                if let TrayIconEvent::Click { rect, .. } = event {
                    set_tray_anchor_from_rect(&rect);
                }
            }
        })
        .is_err()
    {
        tracing::error!("failed to spawn tray anchor tracker");
    }
}

fn parse_menu_action(id: &MenuId) -> Option<TrayMenuAction> {
    let id = id.0.as_str();
    match id {
        ACTION_SEARCH => Some(TrayMenuAction::OpenPanel(PanelTab::History)),
        ACTION_COLLECTOR => Some(TrayMenuAction::OpenPanel(PanelTab::Collector)),
        ACTION_SNIPPETS => Some(TrayMenuAction::OpenPanel(PanelTab::Snippets)),
        ACTION_PREFERENCES => Some(TrayMenuAction::OpenPanel(PanelTab::Settings)),
        ACTION_CLEAR => Some(TrayMenuAction::ClearHistory),
        ACTION_LOGS => Some(TrayMenuAction::OpenPanel(PanelTab::Logs)),
        ACTION_QUIT => Some(TrayMenuAction::Quit),
        _ if id.starts_with("hist:") => id
            .strip_prefix("hist:")
            .and_then(|s| s.parse().ok())
            .map(TrayMenuAction::CopyRecord),
        _ if id.starts_with("hist_file:paste_names:") => id
            .strip_prefix("hist_file:paste_names:")
            .and_then(|s| s.parse().ok())
            .map(TrayMenuAction::CopyFileNames),
        _ if id.starts_with("hist_file:paste:") => id
            .strip_prefix("hist_file:paste:")
            .and_then(|s| s.parse().ok())
            .map(TrayMenuAction::CopyFiles),
        _ if id.starts_with("hist_file:reveal:") => id
            .strip_prefix("hist_file:reveal:")
            .and_then(|s| s.parse().ok())
            .map(TrayMenuAction::RevealFile),
        _ if id.starts_with("file_hist:") => id
            .strip_prefix("file_hist:")
            .map(str::to_string)
            .map(TrayMenuAction::RevealFileHistory),
        _ if id.starts_with("snippet:") => id
            .strip_prefix("snippet:")
            .map(str::to_string)
            .map(TrayMenuAction::CopySnippet),
        _ if id.starts_with("device_send:") => id
            .strip_prefix("device_send:")
            .map(str::to_string)
            .map(TrayMenuAction::SendFile),
        _ => None,
    }
}

fn create_icon() -> Result<Icon, Box<dyn std::error::Error>> {
    let asset = super::Assets::get("logo.png").ok_or("logo.png missing")?;
    let img = image::load_from_memory(&asset.data)?;
    let resized = img
        .resize(
            TRAY_ICON_SIZE,
            TRAY_ICON_SIZE,
            image::imageops::FilterType::Lanczos3,
        )
        .to_rgba8();
    Ok(Icon::from_rgba(
        resized.into_raw(),
        TRAY_ICON_SIZE,
        TRAY_ICON_SIZE,
    )?)
}
