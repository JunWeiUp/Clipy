use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use uuid::Uuid;

use crate::utils::app_support_dir;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NotificationEntry {
    pub id: String,
    pub package_name: String,
    pub title: String,
    pub body: String,
    pub received_at: DateTime<Local>,
    pub dismissed: bool,
}

pub struct NotificationStore {
    entries: RwLock<Vec<NotificationEntry>>,
    path: PathBuf,
}

impl NotificationStore {
    pub fn new() -> Self {
        let path = app_support_dir()
            .map(|d| d.join("notifications.json"))
            .unwrap_or_else(|| PathBuf::from("notifications.json"));
        let entries = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Self { entries: RwLock::new(entries), path }
    }

    pub fn global() -> Arc<NotificationStore> {
        GLOBAL_NOTIFICATIONS.clone()
    }

    pub fn entries(&self) -> Vec<NotificationEntry> {
        self.entries.read().map(|e| e.clone()).unwrap_or_default()
    }

    pub fn apply_remote_post(&self, json: &str) {
        if let Ok(mut entry) = serde_json::from_str::<NotificationEntry>(json) {
            if entry.id.is_empty() {
                entry.id = Uuid::new_v4().to_string();
            }
            if let Ok(mut entries) = self.entries.write() {
                entries.insert(0, entry.clone());
            }
            self.save();
            show_macos_notification(&entry);
        }
    }

    pub fn dismiss_all(&self) {
        if let Ok(mut entries) = self.entries.write() {
            for e in entries.iter_mut() {
                e.dismissed = true;
            }
        }
        self.save();
    }

    pub fn active_entries(&self) -> Vec<NotificationEntry> {
        self.entries()
            .into_iter()
            .filter(|e| !e.dismissed)
            .collect()
    }

    pub fn dismiss(&self, id: &str) {
        if let Ok(mut entries) = self.entries.write() {
            for e in entries.iter_mut() {
                if e.id == id {
                    e.dismissed = true;
                }
            }
        }
        self.save();
    }

    fn save(&self) {
        if let Ok(entries) = self.entries.read() {
            if let Ok(json) = serde_json::to_string_pretty(&*entries) {
                let _ = std::fs::write(&self.path, json);
            }
        }
    }
}

fn show_macos_notification(entry: &NotificationEntry) {
    tracing::info!(title = %entry.title, body = %entry.body, "notification received");
}

static GLOBAL_NOTIFICATIONS: once_cell::sync::Lazy<Arc<NotificationStore>> =
    once_cell::sync::Lazy::new(|| Arc::new(NotificationStore::new()));
