use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

const MAX_ENTRIES: usize = 2000;

#[derive(Debug, Clone)]
pub struct LogEntry {
    pub timestamp: String,
    pub level: String,
    pub message: String,
}

static LOGS: OnceLock<Mutex<VecDeque<LogEntry>>> = OnceLock::new();

fn logs() -> &'static Mutex<VecDeque<LogEntry>> {
    LOGS.get_or_init(|| Mutex::new(VecDeque::with_capacity(MAX_ENTRIES)))
}

pub fn push(level: &str, message: impl Into<String>) {
    let entry = LogEntry {
        timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
        level: level.to_string(),
        message: message.into(),
    };
    if let Ok(mut buf) = logs().lock() {
        if buf.len() >= MAX_ENTRIES {
            buf.pop_front();
        }
        buf.push_back(entry);
    }
}

pub fn entries() -> Vec<LogEntry> {
    logs()
        .lock()
        .map(|buf| buf.iter().cloned().collect())
        .unwrap_or_default()
}

pub fn clear() {
    if let Ok(mut buf) = logs().lock() {
        buf.clear();
    }
}
