use std::sync::{Arc, Mutex};

use gpui::{
    App, AppContext as _, Bounds, KeyBinding, WindowBackgroundAppearance, WindowBounds,
    WindowHandle, WindowKind, WindowOptions, point, px,
};
use gpui_component::Root;

use crate::clipboard::{CopyRequest, LastCopyState};
use crate::gui::board::{
    ClipyBoard, ConfirmSelection, DeleteRecord, Hide, OpenPanel, PanelTab, Quit, SelectNext,
    SelectPrev, TogglePin,
};
use crate::gui::design_tokens::window_size;
use crate::gui::system_theme::{apply_system_light_theme, init_global_light_theme};
use crate::repository::SharedRecords;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowKindId {
    Search,
    Settings,
    Snippets,
    Logs,
    Collector,
    Notifications,
}

pub struct WindowManager {
    search: Option<WindowHandle<Root>>,
    settings: Option<WindowHandle<Root>>,
    snippets: Option<WindowHandle<Root>>,
    logs: Option<WindowHandle<Root>>,
    collector: Option<WindowHandle<Root>>,
    notifications: Option<WindowHandle<Root>>,
    shared: WindowShared,
}

#[derive(Clone)]
pub struct WindowShared {
    pub records: SharedRecords,
    pub last_copy: Arc<Mutex<LastCopyState>>,
    pub copy_tx: async_channel::Sender<CopyRequest>,
}

impl WindowManager {
    pub fn new(shared: WindowShared) -> Self {
        Self {
            search: None,
            settings: None,
            snippets: None,
            logs: None,
            collector: None,
            notifications: None,
            shared,
        }
    }

    pub fn show(&mut self, kind: WindowKindId, cx: &mut App) {
        let shared = self.shared.clone();
        let handle = match kind {
            WindowKindId::Search => {
                if self.search.is_none() {
                    self.search = Some(open_window_for_kind(kind, shared, cx));
                }
                self.search.unwrap()
            }
            WindowKindId::Settings => {
                if self.settings.is_none() {
                    self.settings = Some(open_window_for_kind(kind, shared, cx));
                }
                self.settings.unwrap()
            }
            WindowKindId::Snippets => {
                if self.snippets.is_none() {
                    self.snippets = Some(open_window_for_kind(kind, shared, cx));
                }
                self.snippets.unwrap()
            }
            WindowKindId::Logs => {
                if self.logs.is_none() {
                    self.logs = Some(open_window_for_kind(kind, shared, cx));
                }
                self.logs.unwrap()
            }
            WindowKindId::Collector => {
                if self.collector.is_none() {
                    self.collector = Some(open_window_for_kind(kind, shared, cx));
                }
                self.collector.unwrap()
            }
            WindowKindId::Notifications => {
                if self.notifications.is_none() {
                    self.notifications = Some(open_window_for_kind(kind, shared, cx));
                }
                self.notifications.unwrap()
            }
        };
        let tab = kind_to_tab(kind);
        let _ = handle.update(cx, |root, window, cx| {
            if let Ok(board) = root.view().clone().downcast::<ClipyBoard>() {
                board.update(cx, |board, cx| {
                    board.open_panel(&OpenPanel::single(tab), window, cx);
                });
            }
        });
    }

    pub fn search_handle(&self) -> Option<WindowHandle<Root>> {
        self.search
    }
}

fn kind_to_tab(kind: WindowKindId) -> PanelTab {
    match kind {
        WindowKindId::Search => PanelTab::History,
        WindowKindId::Settings => PanelTab::Settings,
        WindowKindId::Snippets => PanelTab::Snippets,
        WindowKindId::Logs => PanelTab::Logs,
        WindowKindId::Collector => PanelTab::Collector,
        WindowKindId::Notifications => PanelTab::Notifications,
    }
}

fn window_title(kind: WindowKindId) -> &'static str {
    match kind {
        WindowKindId::Search => "Search History",
        WindowKindId::Settings => "Preferences",
        WindowKindId::Snippets => "Snippets",
        WindowKindId::Logs => "Logs",
        WindowKindId::Collector => "Phone Collector",
        WindowKindId::Notifications => "Notifications",
    }
}

fn window_bounds(kind: WindowKindId) -> Bounds<gpui::Pixels> {
    let size = match kind {
        WindowKindId::Search => window_size::search(),
        WindowKindId::Settings => window_size::settings(),
        WindowKindId::Snippets => window_size::editor(),
        WindowKindId::Logs => window_size::log(),
        WindowKindId::Collector | WindowKindId::Notifications => window_size::list(),
    };
    Bounds::new(point(px(0.0), px(0.0)), size)
}

fn open_window_for_kind(
    kind: WindowKindId,
    shared: WindowShared,
    cx: &mut App,
) -> WindowHandle<Root> {
    let bounds = window_bounds(kind);
    let _resizable = kind != WindowKindId::Settings;
    cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            kind: WindowKind::Normal,
            titlebar: Some(gpui::TitlebarOptions {
                title: Some(window_title(kind).into()),
                ..Default::default()
            }),
            show: false,
            window_background: WindowBackgroundAppearance::Opaque,
            ..Default::default()
        },
        move |window, cx| {
            apply_system_light_theme(window, cx);
            let view = cx.new(|cx| {
                ClipyBoard::new(
                    shared.records.clone(),
                    shared.last_copy.clone(),
                    shared.copy_tx.clone(),
                    window,
                    cx,
                )
            });
            cx.new(|cx| Root::new(view, window, cx))
        },
    )
    .unwrap_or_else(|e| {
        tracing::error!(error = %e, "failed to open window");
        std::process::exit(1);
    })
}

pub fn install_window_keys(cx: &mut App) {
    cx.bind_keys([
        KeyBinding::new("escape", Hide, None),
        KeyBinding::new("cmd-w", Hide, None),
        KeyBinding::new("cmd-q", Quit, None),
        KeyBinding::new("up", SelectPrev, None),
        KeyBinding::new("down", SelectNext, None),
        KeyBinding::new("enter", ConfirmSelection, None),
        KeyBinding::new("p", TogglePin, None),
        KeyBinding::new("backspace", DeleteRecord, None),
    ]);
}

pub fn init_app_theme(cx: &mut App) {
    init_global_light_theme(cx);
}
