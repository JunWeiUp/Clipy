use gpui::App;
use tray_icon::menu::{
    CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu,
    accelerator::{Accelerator, CMD_OR_CTRL, Code, Modifiers},
};

use crate::collector::CollectorStore;
use crate::i18n::I18n;
use crate::repository::{ClipboardRecord, ContentType, GlobalRepository, SharedRecords};
use crate::snippet::SnippetStore;
use crate::sync::discovery::discovered_devices;

const MENU_DIRECT_HISTORY_LIMIT: usize = 50;
const HISTORY_GROUP_SIZE: usize = 10;

pub const ACTION_SEARCH: &str = "action:search";
pub const ACTION_COLLECTOR: &str = "action:collector";
pub const ACTION_SNIPPETS: &str = "action:snippets";
pub const ACTION_PREFERENCES: &str = "action:preferences";
pub const ACTION_CLEAR: &str = "action:clear";
pub const ACTION_LOGS: &str = "action:logs";
pub const ACTION_QUIT: &str = "action:quit";

pub struct TrayMenuContext {
    pub shared_records: SharedRecords,
}

pub fn build_tray_menu(ctx: &TrayMenuContext, i18n: &I18n, cx: &App) -> Result<Menu, Box<dyn std::error::Error>> {
    let menu = Menu::new();
    let history = ctx
        .shared_records
        .read()
        .map(|records| records.clone())
        .unwrap_or_default();

    append_history_section(&menu, &history, i18n)?;
    menu.append(&PredefinedMenuItem::separator())?;
    append_snippets_section(&menu, i18n)?;
    menu.append(&PredefinedMenuItem::separator())?;
    append_file_history_section(&menu, i18n, cx)?;
    menu.append(&PredefinedMenuItem::separator())?;
    append_collector_item(&menu, i18n)?;
    menu.append(&PredefinedMenuItem::separator())?;
    append_devices_section(&menu, i18n)?;
    menu.append(&PredefinedMenuItem::separator())?;
    append_footer_actions(&menu, i18n)?;
    Ok(menu)
}

fn append_history_section(
    menu: &Menu,
    history: &[ClipboardRecord],
    i18n: &I18n,
) -> Result<(), Box<dyn std::error::Error>> {
    let header = format!("{} ({})", i18n.t("menu_history"), history.len());
    menu.append(&MenuItem::new(header, false, None))?;
    menu.append(&MenuItem::with_id(
        ACTION_SEARCH,
        i18n.t("menu_search_history"),
        true,
        Some(Accelerator::new(
            Some(CMD_OR_CTRL | Modifiers::SHIFT),
            Code::KeyF,
        )),
    ))?;
    menu.append(&PredefinedMenuItem::separator())?;

    if history.is_empty() {
        menu.append(&MenuItem::new(i18n.t("menu_no_history"), false, None))?;
        return Ok(());
    }

    let direct: Vec<_> = history.iter().take(MENU_DIRECT_HISTORY_LIMIT).collect();
    let overflow: Vec<_> = history.iter().skip(MENU_DIRECT_HISTORY_LIMIT).collect();

    append_history_groups_to_menu(menu, &direct, 0, i18n)?;

    if !overflow.is_empty() {
        let more_menu = Submenu::new(i18n.t("menu_more_history"), true);
        append_history_groups_to_submenu(&more_menu, &overflow, MENU_DIRECT_HISTORY_LIMIT, i18n)?;
        menu.append(&more_menu)?;
    }
    Ok(())
}

fn append_history_groups_to_menu(
    menu: &Menu,
    history: &[&ClipboardRecord],
    start_index: usize,
    i18n: &I18n,
) -> Result<(), Box<dyn std::error::Error>> {
    for group_start in (0..history.len()).step_by(HISTORY_GROUP_SIZE) {
        let group_end = (group_start + HISTORY_GROUP_SIZE).min(history.len());
        let group_title = format!("  {} - {}", start_index + group_start + 1, start_index + group_end);
        let group_menu = Submenu::new(group_title, true);

        for (offset, record) in history[group_start..group_end].iter().enumerate() {
            append_history_item(&group_menu, record, offset, start_index, i18n)?;
        }

        menu.append(&group_menu)?;
    }
    Ok(())
}

fn append_history_groups_to_submenu(
    menu: &Submenu,
    history: &[&ClipboardRecord],
    start_index: usize,
    i18n: &I18n,
) -> Result<(), Box<dyn std::error::Error>> {
    for group_start in (0..history.len()).step_by(HISTORY_GROUP_SIZE) {
        let group_end = (group_start + HISTORY_GROUP_SIZE).min(history.len());
        let group_title = format!("  {} - {}", start_index + group_start + 1, start_index + group_end);
        let group_menu = Submenu::new(group_title, true);

        for (offset, record) in history[group_start..group_end].iter().enumerate() {
            append_history_item(&group_menu, record, offset, start_index, i18n)?;
        }

        menu.append(&group_menu)?;
    }
    Ok(())
}

fn append_history_item(
    menu: &Submenu,
    record: &ClipboardRecord,
    index_in_group: usize,
    start_index: usize,
    i18n: &I18n,
) -> Result<(), Box<dyn std::error::Error>> {
    let menu_index = (index_in_group + 1) % 10;
    let prefix = format!("{menu_index}. ");
    let title = truncate_title(&record_display_title(record), 50);
    let accel = if start_index >= MENU_DIRECT_HISTORY_LIMIT {
        None
    } else {
        digit_accelerator(menu_index)
    };

    if record.content_type == ContentType::FilePath {
        let file_menu = Submenu::with_id(
            format!("hist_file_group:{}", record.id),
            format!("{prefix}{title}"),
            true,
        );
        file_menu.append(&MenuItem::with_id(
            format!("hist_file:paste_names:{}", record.id),
            i18n.t("menu_paste_file_name"),
            true,
            None,
        ))?;
        file_menu.append(&MenuItem::with_id(
            format!("hist_file:paste:{}", record.id),
            i18n.t("menu_paste_file"),
            true,
            None,
        ))?;
        file_menu.append(&MenuItem::with_id(
            format!("hist_file:reveal:{}", record.id),
            i18n.t("reveal_in_finder"),
            true,
            None,
        ))?;
        menu.append(&file_menu)?;
        return Ok(());
    }

    menu.append(&MenuItem::with_id(
        format!("hist:{}", record.id),
        format!("{prefix}{title}"),
        true,
        accel,
    ))?;
    Ok(())
}

fn append_snippets_section(menu: &Menu, i18n: &I18n) -> Result<(), Box<dyn std::error::Error>> {
    menu.append(&MenuItem::new(i18n.t("menu_snippets"), false, None))?;
    for folder in SnippetStore::global().folders() {
        let folder_menu = Submenu::new(format!("  {}", folder.name), true);
        for (index, snippet) in folder.snippets.iter().enumerate() {
            let menu_index = (index + 1) % 10;
            let prefix = format!("{menu_index}. ");
            let key = if index < 10 {
                digit_accelerator(menu_index)
            } else {
                None
            };
            folder_menu.append(&MenuItem::with_id(
                format!("snippet:{}", snippet.id),
                format!("{prefix}{}", snippet.title),
                true,
                key,
            ))?;
        }
        menu.append(&folder_menu)?;
    }
    Ok(())
}

fn append_file_history_section(menu: &Menu, i18n: &I18n, cx: &App) -> Result<(), Box<dyn std::error::Error>> {
    let file_menu = Submenu::new(i18n.t("menu_file_history"), true);
    let files = GlobalRepository::read(cx, |repo| {
        repo.and_then(|r| r.load_file_history().ok())
    })
    .unwrap_or_default();
    if files.is_empty() {
        file_menu.append(&MenuItem::new(i18n.t("menu_no_files"), false, None))?;
    } else {
        for item in files {
            file_menu.append(&MenuItem::with_id(
                format!("file_hist:{}", item.id),
                format!("  {}", item.file_name),
                true,
                None,
            ))?;
        }
    }
    menu.append(&file_menu)?;
    Ok(())
}

fn append_collector_item(menu: &Menu, i18n: &I18n) -> Result<(), Box<dyn std::error::Error>> {
    let count = CollectorStore::global().event_count();
    let title = format!("{} ({count})...", i18n.t("menu_phone_collector"));
    menu.append(&MenuItem::with_id(
        ACTION_COLLECTOR,
        title,
        true,
        Some(Accelerator::new(Some(CMD_OR_CTRL), Code::KeyN)),
    ))?;
    Ok(())
}

fn append_devices_section(menu: &Menu, i18n: &I18n) -> Result<(), Box<dyn std::error::Error>> {
    menu.append(&MenuItem::new(i18n.t("menu_lan_devices"), false, None))?;
    let devices = discovered_devices();
    if devices.is_empty() {
        menu.append(&MenuItem::new(i18n.t("menu_no_devices"), false, None))?;
        return Ok(());
    }

    for device in devices {
        menu.append(&MenuItem::with_id(
            format!("device_send:{device}"),
            format!("  {device} — {}", i18n.t("menu_send_file")),
            true,
            None,
        ))?;
    }
    Ok(())
}

fn append_footer_actions(menu: &Menu, i18n: &I18n) -> Result<(), Box<dyn std::error::Error>> {
    menu.append(&MenuItem::with_id(
        ACTION_SNIPPETS,
        i18n.t("menu_edit_snippets"),
        true,
        Some(Accelerator::new(Some(CMD_OR_CTRL), Code::KeyS)),
    ))?;
    menu.append(&MenuItem::with_id(
        ACTION_PREFERENCES,
        format!("{}...", i18n.t("menu_preferences")),
        true,
        Some(Accelerator::new(Some(CMD_OR_CTRL), Code::Comma)),
    ))?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&MenuItem::with_id(
        ACTION_CLEAR,
        i18n.t("menu_clear_history"),
        true,
        None,
    ))?;
    menu.append(&MenuItem::with_id(
        ACTION_LOGS,
        i18n.t("menu_show_logs"),
        true,
        Some(Accelerator::new(Some(CMD_OR_CTRL), Code::KeyL)),
    ))?;
    menu.append(&MenuItem::with_id(
        ACTION_QUIT,
        i18n.t("tray_quit"),
        true,
        Some(Accelerator::new(Some(CMD_OR_CTRL), Code::KeyQ)),
    ))?;
    Ok(())
}

pub fn tray_menu_context(_cx: &App, shared_records: SharedRecords) -> TrayMenuContext {
    TrayMenuContext { shared_records }
}

fn record_display_title(record: &ClipboardRecord) -> String {
    match record.content_type {
        ContentType::Image => "[Image]".into(),
        ContentType::FilePath => {
            let first = record.content.lines().next().unwrap_or("");
            format!(
                "[File] {}",
                std::path::Path::new(first)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| first.to_string())
            )
        }
        _ => record
            .content
            .lines()
            .next()
            .unwrap_or("")
            .to_string(),
    }
}

fn truncate_title(title: &str, max: usize) -> String {
    if title.chars().count() <= max {
        title.to_string()
    } else {
        format!("{}...", title.chars().take(max).collect::<String>())
    }
}

fn digit_accelerator(menu_index: usize) -> Option<Accelerator> {
    let code = match menu_index {
        1 => Code::Digit1,
        2 => Code::Digit2,
        3 => Code::Digit3,
        4 => Code::Digit4,
        5 => Code::Digit5,
        6 => Code::Digit6,
        7 => Code::Digit7,
        8 => Code::Digit8,
        9 => Code::Digit9,
        0 => Code::Digit0,
        _ => return None,
    };
    Some(Accelerator::new(None, code))
}
