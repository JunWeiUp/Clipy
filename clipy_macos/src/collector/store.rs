use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use crate::utils::app_support_dir;

const MAX_EVENTS: usize = 5000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CollectorEvent {
    pub id: String,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub received_at: DateTime<Local>,
    pub device_id: String,
}

pub struct CollectorStore {
    path: PathBuf,
    count: RwLock<usize>,
}

impl CollectorStore {
    pub fn new() -> Self {
        let path = app_support_dir()
            .map(|d| d.join("device_collector_events.jsonl"))
            .unwrap_or_else(|| PathBuf::from("device_collector_events.jsonl"));
        let count = std::fs::read_to_string(&path)
            .map(|s| s.lines().count())
            .unwrap_or(0);
        Self {
            path,
            count: RwLock::new(count),
        }
    }

    pub fn global() -> Arc<CollectorStore> {
        GLOBAL_COLLECTOR.clone()
    }

    pub fn events(&self) -> Vec<CollectorEvent> {
        std::fs::read_to_string(&self.path)
            .ok()
            .map(|content| {
                content
                    .lines()
                    .filter_map(|line| serde_json::from_str(line).ok())
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn event_count(&self) -> usize {
        self.count.read().map(|c| *c).unwrap_or(0)
    }

    pub fn apply_remote_event(&self, json: &str) {
        if let Ok(event) = serde_json::from_str::<CollectorEvent>(json) {
            if let Ok(mut file) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.path)
            {
                use std::io::Write;
                if let Ok(line) = serde_json::to_string(&event) {
                    let _ = writeln!(file, "{line}");
                }
            }
            if let Ok(mut count) = self.count.write() {
                *count += 1;
            }
            self.trim_if_needed();
        }
    }

    fn trim_if_needed(&self) {
        if self.event_count() <= MAX_EVENTS {
            return;
        }
        if let Ok(content) = std::fs::read_to_string(&self.path) {
            let lines: Vec<_> = content.lines().collect();
            if lines.len() > MAX_EVENTS {
                let trimmed = lines[lines.len() - MAX_EVENTS..].join("\n");
                let _ = std::fs::write(&self.path, format!("{trimmed}\n"));
                if let Ok(mut count) = self.count.write() {
                    *count = MAX_EVENTS;
                }
            }
        }
    }

    pub fn clear_all(&self) {
        let _ = std::fs::write(&self.path, "");
        if let Ok(mut count) = self.count.write() {
            *count = 0;
        }
    }
}

static GLOBAL_COLLECTOR: once_cell::sync::Lazy<Arc<CollectorStore>> =
    once_cell::sync::Lazy::new(|| Arc::new(CollectorStore::new()));
