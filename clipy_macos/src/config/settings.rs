use std::path::PathBuf;

use gpui::{App, AppContext as _, Global, ReadGlobal};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::{
    constants::{DEFAULT_HISTORY_LOAD_COUNT, DEFAULT_SYNC_PORT},
    i18n::Language,
    utils::config_dir,
};

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("config directory not found")]
    ConfigDirectoryNotFound,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("toml error: {0}")]
    TomlDe(#[from] toml::de::Error),
    #[error("toml serialize error: {0}")]
    TomlSer(#[from] toml::ser::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub hotkey: HotkeySettings,
    pub storage: StorageSettings,
    pub sync: SyncSettings,
    pub general: GeneralSettings,
    pub collector: CollectorSettings,
    pub notification: NotificationSettings,
    pub confirm: ConfirmSettings,
    pub language: Language,
    pub autostart: AutostartSettings,
    pub history_encryption: HistoryEncryptionSettings,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            hotkey: HotkeySettings::default(),
            storage: StorageSettings::default(),
            sync: SyncSettings::default(),
            general: GeneralSettings::default(),
            collector: CollectorSettings::default(),
            notification: NotificationSettings::default(),
            confirm: ConfirmSettings::default(),
            language: Language::System,
            autostart: AutostartSettings::default(),
            history_encryption: HistoryEncryptionSettings::default(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct HotkeySettings {
    pub activation_key: String,
}

impl Default for HotkeySettings {
    fn default() -> Self {
        Self {
            activation_key: "cmd+shift+f".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct StorageSettings {
    pub max_history_records: usize,
    pub max_storage_records: usize,
    pub history_load_count: usize,
    pub excluded_apps: Vec<String>,
}

impl Default for StorageSettings {
    fn default() -> Self {
        Self {
            max_history_records: 1000,
            max_storage_records: 2000,
            history_load_count: DEFAULT_HISTORY_LOAD_COUNT,
            excluded_apps: vec![
                "com.1password.1password".to_string(),
                "com.apple.keychainaccess".to_string(),
            ],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct SyncSettings {
    pub enabled: bool,
    pub port: u16,
    pub device_name: String,
    pub authorized_devices: Vec<String>,
}

impl Default for SyncSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            port: DEFAULT_SYNC_PORT,
            device_name: std::env::var("HOSTNAME")
                .or_else(|_| std::env::var("COMPUTERNAME"))
                .unwrap_or_else(|_| "Mac".to_string()),
            authorized_devices: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct GeneralSettings {
    pub layout_mode: LayoutMode,
    pub window_opacity_percent: u8,
}

impl Default for GeneralSettings {
    fn default() -> Self {
        Self {
            layout_mode: LayoutMode::List,
            window_opacity_percent: 100,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum LayoutMode {
    #[default]
    List,
    Grid,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct CollectorSettings {
    pub enabled: bool,
    pub notifications: bool,
    pub sms: bool,
    pub calls: bool,
    pub clipboard: bool,
    pub location: bool,
    pub system: bool,
}

impl Default for CollectorSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            notifications: true,
            sms: true,
            calls: true,
            clipboard: true,
            location: false,
            system: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct NotificationSettings {
    pub enabled: bool,
    pub sound: bool,
    pub allowed_packages: Vec<String>,
}

impl Default for NotificationSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            sound: true,
            allowed_packages: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct ConfirmSettings {
    pub mode: ConfirmMode,
}

impl Default for ConfirmSettings {
    fn default() -> Self {
        Self { mode: ConfirmMode::CopyToClipboard }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum ConfirmMode {
    #[default]
    CopyToClipboard,
    PasteImmediately,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AutostartSettings {
    pub enabled: bool,
}

impl Default for AutostartSettings {
    fn default() -> Self {
        Self { enabled: false }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct HistoryEncryptionSettings {
    pub enabled: bool,
}

impl Default for HistoryEncryptionSettings {
    fn default() -> Self {
        Self { enabled: false }
    }
}

impl Settings {
    pub fn config_file() -> Result<PathBuf, SettingsError> {
        config_dir()
            .map(|d| d.join("config.toml"))
            .ok_or(SettingsError::ConfigDirectoryNotFound)
    }

    pub fn load() -> Result<Self, SettingsError> {
        #[cfg(target_os = "macos")]
        {
            if let Some(from_plist) = Self::load_from_user_defaults() {
                return Ok(from_plist);
            }
        }
        let config_file = Self::config_file()?;
        if let Some(parent) = config_file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        if !config_file.exists() {
            let defaults = Self::default();
            defaults.save()?;
            return Ok(defaults);
        }
        let content = std::fs::read_to_string(&config_file)?;
        let mut settings: Self = toml::from_str(&content)?;
        settings.validate();
        Ok(settings)
    }

    #[cfg(target_os = "macos")]
    fn load_from_user_defaults() -> Option<Self> {
        use super::user_defaults::{self, hostname};
        let mut s = Self::default();
        if let Some(lang) = user_defaults::read_string("appLanguage") {
            s.language = match lang.as_str() {
                "zh" => crate::i18n::Language::Zh,
                "en" => crate::i18n::Language::En,
                _ => crate::i18n::Language::System,
            };
        }
        s.autostart.enabled = user_defaults::read_bool("launchAtLogin").unwrap_or(false);
        s.sync.device_name = user_defaults::read_string("deviceName").unwrap_or_else(hostname);
        s.storage.max_history_records = user_defaults::read_i64("historyLimit").unwrap_or(1000) as usize;
        s.storage.history_load_count =
            user_defaults::read_i64("historyLoadCount").unwrap_or(100) as usize;
        s.storage.excluded_apps = user_defaults::read_string_array("excludedApps").unwrap_or_else(|| {
            vec![
                "com.agilebits.onepassword7".into(),
                "com.apple.keychainaccess".into(),
            ]
        });
        s.history_encryption.enabled =
            user_defaults::read_bool("historyEncryptionEnabled").unwrap_or(false);
        s.hotkey.activation_key = user_defaults::read_string("searchHistoryShortcut")
            .map(|_| "cmd+shift+f".into())
            .unwrap_or_else(|| "cmd+shift+f".into());
        s.sync.enabled = user_defaults::read_bool("syncEnabled").unwrap_or(false);
        s.sync.port = user_defaults::read_i64("syncPort").unwrap_or(5566) as u16;
        s.sync.authorized_devices =
            user_defaults::read_string_array("authorizedDevices").unwrap_or_default();
        s.collector.enabled = user_defaults::read_bool("collectorSyncEnabled").unwrap_or(true);
        s.notification.enabled = user_defaults::read_bool("notificationSyncEnabled").unwrap_or(true);
        s.notification.sound = user_defaults::read_bool("notificationSound").unwrap_or(true);
        Some(s)
    }

    pub fn save(&self) -> Result<(), SettingsError> {
        #[cfg(target_os = "macos")]
        self.save_to_user_defaults();
        let config_file = Self::config_file()?;
        if let Some(parent) = config_file.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(config_file, toml::to_string_pretty(self)?)?;
        Ok(())
    }

    pub fn validate(&mut self) {
        self.storage.max_history_records = self.storage.max_history_records.clamp(1, 10000);
        self.storage.history_load_count = self.storage.history_load_count.clamp(1, 1000);
        self.storage.max_storage_records = self
            .storage
            .max_storage_records
            .max(self.storage.max_history_records);
        self.general.window_opacity_percent = self.general.window_opacity_percent.clamp(40, 100);
        if self.sync.port == 0 {
            self.sync.port = DEFAULT_SYNC_PORT;
        }
    }

    #[cfg(target_os = "macos")]
    fn save_to_user_defaults(&self) {
        use super::user_defaults;
        let lang = match self.language {
            crate::i18n::Language::Zh => "zh",
            crate::i18n::Language::En => "en",
            crate::i18n::Language::System => "system",
        };
        user_defaults::write_string("appLanguage", lang);
        user_defaults::write_bool("launchAtLogin", self.autostart.enabled);
        user_defaults::write_string("deviceName", &self.sync.device_name);
        user_defaults::write_i64("historyLimit", self.storage.max_history_records as i64);
        user_defaults::write_i64("historyLoadCount", self.storage.history_load_count as i64);
        user_defaults::write_string_array("excludedApps", &self.storage.excluded_apps);
        user_defaults::write_bool("historyEncryptionEnabled", self.history_encryption.enabled);
        user_defaults::write_bool("syncEnabled", self.sync.enabled);
        user_defaults::write_i64("syncPort", self.sync.port as i64);
        user_defaults::write_string_array("authorizedDevices", &self.sync.authorized_devices);
        user_defaults::write_bool("collectorSyncEnabled", self.collector.enabled);
        user_defaults::write_bool("notificationSyncEnabled", self.notification.enabled);
        user_defaults::write_bool("notificationSound", self.notification.sound);
    }

    pub fn read<F, R>(cx: &App, f: F) -> R
    where
        F: FnOnce(&Self) -> R,
    {
        cx.read_global(|s: &Self, _| f(s))
    }
}

impl Global for Settings {}
