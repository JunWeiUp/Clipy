use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;

use once_cell::sync::Lazy;

use base64::{Engine as _, engine::general_purpose::STANDARD};

use crate::utils::downloads_clipy_dir;

static PENDING_FILES: Lazy<Mutex<HashMap<String, PendingFile>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

struct PendingFile {
    file_name: String,
    file_size: i64,
    data: Vec<u8>,
}

pub fn handle_remote_text(text: &str, hash: &str) {
    tracing::info!(hash = %hash, len = text.len(), "received remote text sync");
    REMOTE_TEXT_QUEUE.lock().unwrap().push((text.to_string(), hash.to_string()));
}

static REMOTE_TEXT_QUEUE: once_cell::sync::Lazy<std::sync::Mutex<Vec<(String, String)>>> =
    once_cell::sync::Lazy::new(|| std::sync::Mutex::new(Vec::new()));

pub fn drain_remote_text() -> Vec<(String, String)> {
    std::mem::take(&mut *REMOTE_TEXT_QUEUE.lock().unwrap())
}

pub fn handle_file_header(json: &str, _sender: &str) {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
        let file_id = v["fileId"].as_str().unwrap_or("").to_string();
        let file_name = v["fileName"].as_str().unwrap_or("file").to_string();
        let file_size = v["fileSize"].as_i64().unwrap_or(0);
        if let Ok(mut pending) = PENDING_FILES.lock() {
            pending.insert(
                file_id,
                PendingFile {
                    file_name,
                    file_size,
                    data: Vec::new(),
                },
            );
        }
    }
}

pub fn handle_file_chunk(json: &str) {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
        let file_id = v["fileId"].as_str().unwrap_or("").to_string();
        let is_last = v["isLast"].as_bool().unwrap_or(false);
        if let Some(data_b64) = v["data"].as_str() {
            if let Ok(chunk) = STANDARD.decode(data_b64) {
                let mut should_write = None;
                if let Ok(mut pending) = PENDING_FILES.lock() {
                    if let Some(pf) = pending.get_mut(&file_id) {
                        pf.data.extend_from_slice(&chunk);
                        if is_last {
                            should_write = Some((pf.file_name.clone(), pf.data.clone()));
                            pending.remove(&file_id);
                        }
                    }
                }
                if let Some((name, data)) = should_write {
                    write_received_file(&name, &data);
                }
            }
        }
    }
}

fn write_received_file(name: &str, data: &[u8]) {
    if let Some(dir) = downloads_clipy_dir() {
        let _ = std::fs::create_dir_all(&dir);
        let path: PathBuf = dir.join(name);
        if let Ok(mut f) = std::fs::File::create(&path) {
            let _ = f.write_all(data);
            tracing::info!(path = %path.display(), "file received via sync");
        }
    }
}
