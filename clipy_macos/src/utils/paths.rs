use std::path::PathBuf;

use crate::constants::DATA_DIR_NAME;

pub fn app_support_dir() -> Option<PathBuf> {
    dirs::data_local_dir().map(|d| d.join(DATA_DIR_NAME))
}

pub fn app_data_dir() -> Option<PathBuf> {
    app_support_dir()
}

pub fn config_dir() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join(DATA_DIR_NAME))
}

pub fn downloads_clipy_dir() -> Option<PathBuf> {
    dirs::download_dir().map(|d| d.join("Clipy"))
}

pub fn images_dir() -> Option<PathBuf> {
    app_support_dir().map(|d| d.join("images"))
}

pub fn rich_text_dir() -> Option<PathBuf> {
    app_support_dir().map(|d| d.join("rich_text"))
}

pub fn history_json_path() -> Option<PathBuf> {
    app_support_dir().map(|d| d.join("history_v2.json"))
}