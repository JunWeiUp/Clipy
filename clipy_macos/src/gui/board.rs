use std::sync::{Arc, Mutex};

use gpui::{
    Action, App, AppContext, Context, Entity, FocusHandle, InteractiveElement, IntoElement,
    ParentElement, Render, Styled, Subscription, Window, div, px, actions,
    prelude::{FluentBuilder, StatefulInteractiveElement},
};
use gpui_component::{
    h_flex, v_flex,
    button::{Button, ButtonVariants},
    input::{Input, InputEvent, InputState},
    ActiveTheme as _,
};

use crate::clipboard::{CopyRequest, LastCopyState};
use crate::config::{ConfirmMode, Settings};
use crate::i18n::Language;
use crate::gui::{active_window, hide_window};
use crate::i18n::I18n;
use crate::repository::{
    ClipboardRecord, ContentType, GlobalRepository, SharedRecords,
    search::{filter_and_rank, parse_query},
};
use crate::snippet::SnippetStore;

actions!(clipy_board, [Hide, Active, Quit, SelectNext, SelectPrev, ConfirmSelection, TogglePin, DeleteRecord]);

#[derive(Clone, Copy, PartialEq, Eq, Action)]
#[action(namespace = clipy_board, no_json)]
pub struct OpenPanel {
    pub tab: PanelTab,
    pub single: bool,
}

impl OpenPanel {
    pub const fn single(tab: PanelTab) -> Self {
        Self { tab, single: true }
    }

    pub const fn tab(tab: PanelTab) -> Self {
        Self { tab, single: false }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PanelTab {
    #[default]
    History,
    Snippets,
    Notifications,
    Collector,
    Settings,
    Logs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HistoryTypeFilter {
    #[default]
    All,
    Text,
    Image,
    File,
    RichText,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HistoryDateFilter {
    #[default]
    All,
    Today,
    Week,
    Month,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryContentCategory {
    Url,
    Code,
    Email,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CollectorCategoryFilter {
    #[default]
    All,
    Notification,
    Sms,
    Call,
    Clipboard,
    Location,
    System,
}

impl CollectorCategoryFilter {
    pub fn matches(self, event_type: &str) -> bool {
        match self {
            Self::All => true,
            Self::Notification => event_type == "notification",
            Self::Sms => event_type == "sms",
            Self::Call => event_type == "call" || event_type == "callLog",
            Self::Clipboard => event_type == "clipboard",
            Self::Location => event_type == "location",
            Self::System => event_type == "system",
        }
    }
}

pub struct ClipyBoard {
    pub(crate) records: SharedRecords,
    pub(crate) filtered_indices: Vec<usize>,
    pub(crate) selected_index: usize,
    focus_handle: FocusHandle,
    last_copy: Arc<Mutex<LastCopyState>>,
    pub(crate) copy_tx: async_channel::Sender<CopyRequest>,
    active_tab: PanelTab,
    pub(crate) single_panel: bool,
    pub(crate) activated: bool,

    pub(crate) search_input: Entity<InputState>,
    pub(crate) snippet_title_input: Entity<InputState>,
    pub(crate) snippet_content_input: Entity<InputState>,
    pub(crate) collector_filter_input: Entity<InputState>,
    pub(crate) logs_filter_input: Entity<InputState>,
    pub(crate) settings_device_input: Entity<InputState>,
    pub(crate) settings_excluded_input: Entity<InputState>,
    pub(crate) settings_port_input: Entity<InputState>,
    pub(crate) settings_auth_devices_input: Entity<InputState>,

    pub(crate) selected_folder_id: Option<String>,
    pub(crate) selected_snippet_id: Option<String>,

    pub(crate) history_status: String,
    pub(crate) history_loaded_count: usize,
    pub(crate) history_total_count: usize,
    pub(crate) filter_records: Vec<ClipboardRecord>,
    pub(crate) history_use_regex: bool,
    pub(crate) history_type_filter: HistoryTypeFilter,
    pub(crate) history_date_filter: HistoryDateFilter,
    pub(crate) history_source_app: String,
    pub(crate) history_category: Option<HistoryContentCategory>,
    pub(crate) collector_filter: String,
    pub(crate) collector_category: CollectorCategoryFilter,
    pub(crate) logs_filter: String,
    pub(crate) settings_history_limit: usize,
    settings_excluded_apps: String,
    settings_sync_port: String,
    settings_auth_devices: String,

    _subscriptions: Vec<Subscription>,
}

impl ClipyBoard {
    pub fn new(
        records: SharedRecords,
        last_copy: Arc<Mutex<LastCopyState>>,
        copy_tx: async_channel::Sender<CopyRequest>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let device_name = Settings::read(cx, |s| s.sync.device_name.clone());
        let history_limit = Settings::read(cx, |s| s.storage.max_history_records);
        let history_load_count = Settings::read(cx, |s| s.storage.history_load_count);
        let excluded = Settings::read(cx, |s| s.storage.excluded_apps.join(", "));
        let sync_port = Settings::read(cx, |s| s.sync.port.to_string());
        let auth_devices = Settings::read(cx, |s| s.sync.authorized_devices.join(", "));
        let search_ph = cx.read_global(|i: &I18n, _| i.t("search_placeholder"));
        let collector_ph = cx.read_global(|i: &I18n, _| i.t("collector_search_placeholder"));
        let logs_ph = cx.read_global(|i: &I18n, _| i.t("search_logs"));

        let search_input = cx.new(|cx| InputState::new(window, cx).placeholder(search_ph));
        let snippet_title_input = cx.new(|cx| InputState::new(window, cx));
        let snippet_content_input =
            cx.new(|cx| InputState::new(window, cx).multi_line(true));
        let collector_filter_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(collector_ph)
        });
        let logs_filter_input =
            cx.new(|cx| InputState::new(window, cx).placeholder(logs_ph));
        let settings_device_input =
            cx.new(|cx| InputState::new(window, cx).default_value(device_name));
        let settings_excluded_input =
            cx.new(|cx| InputState::new(window, cx).default_value(excluded));
        let settings_port_input =
            cx.new(|cx| InputState::new(window, cx).default_value(sync_port));
        let settings_auth_devices_input =
            cx.new(|cx| InputState::new(window, cx).default_value(auth_devices));

        let mut board = Self {
            records,
            filtered_indices: Vec::new(),
            selected_index: 0,
            focus_handle: cx.focus_handle(),
            last_copy,
            copy_tx,
            active_tab: PanelTab::History,
            single_panel: false,
            activated: false,
            search_input: search_input.clone(),
            snippet_title_input,
            snippet_content_input,
            collector_filter_input: collector_filter_input.clone(),
            logs_filter_input: logs_filter_input.clone(),
            settings_device_input,
            settings_excluded_input,
            settings_port_input,
            settings_auth_devices_input,
            selected_folder_id: None,
            selected_snippet_id: None,
            history_status: String::new(),
            history_loaded_count: history_load_count,
            history_total_count: GlobalRepository::read(cx, |repo| {
                repo.and_then(|r| r.count_records().ok()).unwrap_or(0)
            }),
            filter_records: Vec::new(),
            history_use_regex: false,
            history_type_filter: HistoryTypeFilter::default(),
            history_date_filter: HistoryDateFilter::default(),
            history_source_app: String::new(),
            history_category: None,
            collector_filter: String::new(),
            collector_category: CollectorCategoryFilter::default(),
            logs_filter: String::new(),
            settings_history_limit: history_limit,
            settings_excluded_apps: String::new(),
            settings_sync_port: String::new(),
            settings_auth_devices: String::new(),
            _subscriptions: Vec::new(),
        };
        board.recompute_filter(cx);

        let sub_search = cx.subscribe(&search_input, |this, _, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.recompute_filter(cx);
                cx.notify();
            }
        });
        let sub_collector = cx.subscribe(&collector_filter_input, |this, input, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.collector_filter = input.read(cx).value().to_string();
                cx.notify();
            }
        });
        let sub_logs = cx.subscribe(&logs_filter_input, |this, input, event, cx| {
            if matches!(event, InputEvent::Change) {
                this.logs_filter = input.read(cx).value().to_string();
                cx.notify();
            }
        });
        board._subscriptions = vec![sub_search, sub_collector, sub_logs];
        board
    }

    pub fn refresh_from_repo(&mut self, cx: &App) {
        let batch = Settings::read(cx, |s| s.storage.history_load_count);
        if let Some((records, total)) = GlobalRepository::read(cx, |repo| {
            repo.and_then(|r| {
                let total = r.count_records().ok()?;
                let records = r.get_display_records(self.history_loaded_count.max(batch)).ok()?;
                Some((records, total))
            })
        }) {
            if let Ok(mut shared) = self.records.write() {
                *shared = records;
            }
            self.history_total_count = total;
        }
        self.recompute_filter(cx);
    }

    pub(crate) fn load_more_history(&mut self, cx: &App) {
        let batch = Settings::read(cx, |s| s.storage.history_load_count);
        self.history_loaded_count = (self.history_loaded_count + batch).min(self.history_total_count);
        self.refresh_from_repo(cx);
    }

    pub(crate) fn has_more_history(&self) -> bool {
        self.history_loaded_count < self.history_total_count
    }

    pub(crate) fn history_browse_loaded_only(&self, cx: &App) -> bool {
        let query = self.search_input.read(cx).value();
        query.trim().is_empty()
            && !self.history_use_regex
            && self.history_source_app.is_empty()
            && self.history_type_filter == HistoryTypeFilter::All
            && self.history_date_filter == HistoryDateFilter::All
            && self.history_category.is_none()
    }

    pub(crate) fn can_load_more_history(&self, cx: &App) -> bool {
        self.history_browse_loaded_only(cx) && self.has_more_history()
    }

    pub(crate) fn recompute_filter(&mut self, cx: &App) {
        let query = self.search_input.read(cx).value().to_string();
        let (text, mut opts) = parse_query(&query);
        opts.regex = self.history_use_regex;
        if !self.history_source_app.is_empty() {
            opts.source_app = Some(self.history_source_app.clone());
        }
        if let Some(ct) = type_filter_to_content_type(self.history_type_filter) {
            opts.content_type = Some(ct);
        }

        let browse_loaded_only = self.history_browse_loaded_only(cx);

        let records = if browse_loaded_only {
            self.records.read().map(|r| r.clone()).unwrap_or_default()
        } else {
            GlobalRepository::read(cx, |repo| {
                repo.and_then(|r| r.get_display_records(usize::MAX).ok())
            })
            .unwrap_or_else(|| self.records.read().map(|r| r.clone()).unwrap_or_default())
        };

        let mut indices: Vec<usize> = filter_and_rank(&records, &text, &opts)
            .into_iter()
            .map(|(idx, _)| idx)
            .filter(|&idx| {
                records.get(idx).is_some_and(|r| {
                    matches_date(r, self.history_date_filter)
                        && matches_category(&r.content, self.history_category)
                })
            })
            .collect();
        self.filter_records = records;
        self.filtered_indices = indices;
        if self.selected_index >= self.filtered_indices.len() {
            self.selected_index = self.filtered_indices.len().saturating_sub(1);
        }
        let total = if browse_loaded_only {
            self.history_total_count
        } else {
            self.filter_records.len()
        };
        let shown = self.filtered_indices.len();
        self.history_status = if total == 0 {
            cx.read_global(|i: &I18n, _| i.t("no_records").to_string())
        } else if shown == 0 {
            format!("0 / {total}")
        } else if browse_loaded_only && self.has_more_history() {
            format!("{shown} / {total}")
        } else if text.trim().is_empty()
            && self.history_type_filter == HistoryTypeFilter::All
            && self.history_date_filter == HistoryDateFilter::All
            && self.history_source_app.is_empty()
            && self.history_category.is_none()
            && shown == total
        {
            format!("{total}")
        } else {
            format!("{shown} / {total}")
        };
    }

    pub(crate) fn selected_record(&self, _cx: &App) -> Option<ClipboardRecord> {
        let idx = *self.filtered_indices.get(self.selected_index)?;
        self.filter_records.get(idx).cloned()
    }

    pub(crate) fn confirm_selection(&mut self, cx: &App, paste: bool) {
        let Some(record) = self.selected_record(cx) else {
            return;
        };
        copy_record(&self.copy_tx, &record, paste, cx);
        touch_last_copy(&self.last_copy, &record);
    }

    pub(crate) fn on_active(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.activated = true;
        self.single_panel = true;
        window.focus(&self.focus_handle);
        crate::gui::active_window(window, cx);
        cx.notify();
    }

    pub(crate) fn open_panel(&mut self, action: &OpenPanel, window: &mut Window, cx: &mut Context<Self>) {
        self.active_tab = action.tab;
        self.single_panel = true;
        self.on_active(window, cx);
    }

    fn on_hide(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        hide_window(window, cx);
        self.activated = false;
    }

    pub(crate) fn t(&self, cx: &App, key: &str) -> gpui::SharedString {
        cx.read_global(|i: &I18n, _| i.t(key))
    }

    pub(crate) fn load_snippet_draft(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(snippet_id) = self.selected_snippet_id.clone() {
            if let Some((_, snippet)) = SnippetStore::global().find_snippet(&snippet_id) {
                self.snippet_title_input.update(cx, |input, cx| {
                    input.set_value(snippet.title, window, cx);
                });
                self.snippet_content_input.update(cx, |input, cx| {
                    input.set_value(snippet.content, window, cx);
                });
            }
        } else if let Some(folder_id) = self.selected_folder_id.clone() {
            let name = SnippetStore::global()
                .folders()
                .into_iter()
                .find(|f| f.id == folder_id)
                .map(|f| f.name)
                .unwrap_or_default();
            self.snippet_title_input.update(cx, |input, cx| {
                input.set_value(name, window, cx);
            });
            self.snippet_content_input.update(cx, |input, cx| {
                input.set_value("", window, cx);
            });
        }
    }

    pub(crate) fn save_snippet_draft(&mut self, cx: &mut Context<Self>) {
        if let Some(snippet_id) = self.selected_snippet_id.clone() {
            let title = self.snippet_title_input.read(cx).value().to_string();
            let content = self.snippet_content_input.read(cx).value().to_string();
            SnippetStore::global().update_snippet(&snippet_id, &title, &content);
        } else if let Some(folder_id) = self.selected_folder_id.clone() {
            let name = self.snippet_title_input.read(cx).value().to_string();
            SnippetStore::global().update_folder_name(&folder_id, &name);
        }
        crate::gui::tray::TrayState::refresh_menu(cx);
        cx.notify();
    }

    pub(crate) fn save_settings(&mut self, cx: &mut Context<Self>) {
        let device = self.settings_device_input.read(cx).value().to_string();
        let limit = self.settings_history_limit;
        let excluded = self.settings_excluded_input.read(cx).value().to_string();
        let port_str = self.settings_port_input.read(cx).value().to_string();
        let auth = self.settings_auth_devices_input.read(cx).value().to_string();
        let mut settings = Settings::read(cx, |s| s.clone());
        settings.sync.device_name = device;
        settings.storage.max_history_records = limit;
        settings.storage.excluded_apps = excluded
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        if let Ok(port) = port_str.parse() {
            settings.sync.port = port;
        }
        settings.sync.authorized_devices = auth
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect();
        let _ = settings.save();
        cx.set_global(settings);
        self.refresh_from_repo(cx);
        cx.notify();
    }
}

fn copy_record(
    copy_tx: &async_channel::Sender<CopyRequest>,
    record: &ClipboardRecord,
    paste: bool,
    cx: &App,
) {
    let paste = paste || Settings::read(cx, |s| s.confirm.mode == ConfirmMode::PasteImmediately);
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
    GlobalRepository::read(cx, |repo| {
        if let Some(r) = repo {
            let _ = r.touch_usage(record.id);
        }
    });
    let _ = copy_tx.try_send(req);
}

fn touch_last_copy(last_copy: &Arc<Mutex<LastCopyState>>, record: &ClipboardRecord) {
    if let Ok(mut lc) = last_copy.lock() {
        *lc = match record.content_type {
            ContentType::Image => LastCopyState::Image(record.id),
            ContentType::FilePath => LastCopyState::Files(record.id),
            ContentType::RichText => LastCopyState::RichText(record.content.clone()),
            _ => LastCopyState::Text(record.content.clone()),
        };
    }
}

impl Render for ClipyBoard {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let surface_bg = cx.theme().background;

        let base = v_flex()
            .track_focus(&self.focus_handle)
            .on_action(cx.listener(|this, _: &Hide, window, cx| this.on_hide(window, cx)))
            .on_action(cx.listener(|this, _: &Active, window, cx| this.on_active(window, cx)))
            .on_action(cx.listener(|this, action: &OpenPanel, window, cx| {
                this.open_panel(action, window, cx);
            }))
            .on_action(cx.listener(|this, _: &SelectNext, _, cx| {
                if !this.filtered_indices.is_empty() {
                    this.selected_index =
                        (this.selected_index + 1).min(this.filtered_indices.len() - 1);
                    cx.notify();
                }
            }))
            .on_action(cx.listener(|this, _: &SelectPrev, _, cx| {
                this.selected_index = this.selected_index.saturating_sub(1);
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &ConfirmSelection, _, cx| {
                this.confirm_selection(cx, false);
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &TogglePin, _, cx| {
                if let Some(record) = this.selected_record(cx) {
                    GlobalRepository::read(cx, |repo| {
                        if let Some(r) = repo {
                            let _ = r.toggle_pin(record.id);
                        }
                    });
                    this.refresh_from_repo(cx);
                    cx.notify();
                }
            }))
            .on_action(cx.listener(|this, _: &DeleteRecord, _, cx| {
                if let Some(record) = this.selected_record(cx) {
                    GlobalRepository::read(cx, |repo| {
                        if let Some(r) = repo {
                            let _ = r.delete_record(record.id);
                        }
                    });
                    this.refresh_from_repo(cx);
                    cx.notify();
                }
            }))
            .on_action(cx.listener(|_, _: &Quit, _, cx| {
                cx.quit();
            }))
            .size_full()
            .text_color(cx.theme().foreground)
            .bg(surface_bg);

        if !self.activated {
            return div().size_full().child(base).into_any_element();
        }

        let body = match self.active_tab {
            PanelTab::History => self.render_history(window, cx),
            PanelTab::Snippets => self.render_snippets(window, cx),
            PanelTab::Notifications => self.render_notifications(cx),
            PanelTab::Collector => self.render_collector(cx),
            PanelTab::Settings => self.render_settings(window, cx),
            PanelTab::Logs => self.render_logs(cx),
        };

        v_flex()
            .child(base.child(body))
            .into_any_element()
    }
}

fn type_filter_to_content_type(filter: HistoryTypeFilter) -> Option<ContentType> {
    match filter {
        HistoryTypeFilter::All => None,
        HistoryTypeFilter::Text => Some(ContentType::Text),
        HistoryTypeFilter::Image => Some(ContentType::Image),
        HistoryTypeFilter::File => Some(ContentType::FilePath),
        HistoryTypeFilter::RichText => Some(ContentType::RichText),
    }
}

fn matches_date(record: &ClipboardRecord, filter: HistoryDateFilter) -> bool {
    use chrono::Local;
    let now = Local::now();
    match filter {
        HistoryDateFilter::All => true,
        HistoryDateFilter::Today => record.created_at.date_naive() == now.date_naive(),
        HistoryDateFilter::Week => (now - record.created_at).num_days() <= 7,
        HistoryDateFilter::Month => (now - record.created_at).num_days() <= 30,
    }
}

fn matches_category(content: &str, category: Option<HistoryContentCategory>) -> bool {
    match category {
        None => true,
        Some(HistoryContentCategory::Url) => content.contains("://"),
        Some(HistoryContentCategory::Email) => content.contains('@'),
        Some(HistoryContentCategory::Code) => {
            content.contains("fn ")
                || content.contains("function ")
                || content.contains("class ")
                || content.contains('{')
        }
    }
}
