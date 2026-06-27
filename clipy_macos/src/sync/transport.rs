use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use gpui::App;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use parking_lot::Mutex;

use super::crypto::{decrypt, encrypt};
use super::protocol::{SyncMessage, decode_frames, encode_frame};
use crate::config::SyncSettings;
use crate::constants::FILE_CHUNK_SIZE;
use crate::notification::NotificationStore;
use crate::utils::{downloads_clipy_dir, sha256_hex};

static SETTINGS: once_cell::sync::Lazy<Arc<Mutex<Option<SyncSettings>>>> =
    once_cell::sync::Lazy::new(|| Arc::new(Mutex::new(None)));

static OUTBOUND: once_cell::sync::Lazy<Arc<Mutex<Vec<(String, u16)>>>> =
    once_cell::sync::Lazy::new(|| Arc::new(Mutex::new(Vec::new())));

pub fn start_listener(settings: SyncSettings, _cx: &App) {
    *SETTINGS.lock() = Some(settings.clone());
    std::thread::spawn(move || {
        let addr = format!("0.0.0.0:{}", settings.port);
        let listener = match TcpListener::bind(&addr) {
            Ok(l) => l,
            Err(e) => {
                tracing::error!(error = %e, "sync listener bind failed");
                return;
            }
        };
        tracing::info!(port = settings.port, "sync listener started");
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || handle_connection(stream));
        }
    });
}

fn handle_connection(mut stream: TcpStream) {
    let mut buffer = Vec::new();
    let mut tmp = [0u8; 8192];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => buffer.extend_from_slice(&tmp[..n]),
            Err(_) => break,
        }
        for msg in decode_frames(&mut buffer) {
            handle_message(&msg);
        }
    }
}

fn handle_message(msg: &SyncMessage) {
    let settings = SETTINGS.lock().clone();
    let Some(settings) = settings else { return };
    let is_file_message = msg.message_type == "file/header" || msg.message_type == "file/chunk";
    if !is_file_message && !settings.authorized_devices.contains(&msg.device_id) {
        tracing::debug!(device = %msg.device_id, "unauthorized sync message");
        return;
    }
    match msg.message_type.as_str() {
        "text/plain" => {
            if let Ok(bytes) = decrypt(&msg.content) {
                if let Ok(text) = String::from_utf8(bytes) {
                    crate::sync::handlers::handle_remote_text(&text, &msg.hash);
                }
            }
        }
        "file/header" => {
            if let Ok(bytes) = decrypt(&msg.content) {
                if let Ok(json) = String::from_utf8(bytes) {
                    crate::sync::handlers::handle_file_header(&json, &msg.device_id);
                }
            }
        }
        "file/chunk" => {
            if let Ok(bytes) = decrypt(&msg.content) {
                if let Ok(json) = String::from_utf8(bytes) {
                    crate::sync::handlers::handle_file_chunk(&json);
                }
            }
        }
        "notification/post" => {
            if let Ok(bytes) = decrypt(&msg.content) {
                if let Ok(json) = String::from_utf8(bytes) {
                    NotificationStore::global().apply_remote_post(&json);
                }
            }
        }
        "notification/dismiss" | "notification/clear_all" | "notification/config" => {
            tracing::debug!(msg_type = %msg.message_type, "notification sync");
        }
        "collector/event" => {
            if let Ok(bytes) = decrypt(&msg.content) {
                if let Ok(json) = String::from_utf8(bytes) {
                    crate::collector::CollectorStore::global().apply_remote_event(&json);
                }
            }
        }
        _ => tracing::debug!(msg_type = %msg.message_type, "unknown sync type"),
    }
}

pub fn broadcast_sync_message(message_type: &str, plaintext: &str, hash: &str) {
    let settings = SETTINGS.lock().clone();
    let Some(settings) = settings else { return };
    let encrypted = match encrypt(plaintext.as_bytes()) {
        Ok(e) => e,
        Err(e) => {
            tracing::warn!(error = %e, "encrypt failed");
            return;
        }
    };
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let msg = SyncMessage {
        device_id: settings.device_name.clone(),
        timestamp: ts,
        message_type: message_type.to_string(),
        content: encrypted,
        hash: hash.to_string(),
    };
    let frame = match encode_frame(&msg) {
        Ok(f) => f,
        Err(e) => {
            tracing::warn!(error = %e, "encode frame failed");
            return;
        }
    };
    for device in super::discovery::discovered_devices() {
        if let Some((host, port)) = parse_device_endpoint(&device, settings.port) {
            if let Ok(mut stream) = TcpStream::connect((host.as_str(), port)) {
                let _ = stream.write_all(&frame);
            }
        }
    }
}

fn parse_device_endpoint(device: &str, default_port: u16) -> Option<(String, u16)> {
    if device.contains(':') {
        let parts: Vec<_> = device.split(':').collect();
        if parts.len() == 2 {
            return Some((parts[0].to_string(), parts[1].parse().unwrap_or(default_port)));
        }
    }
    Some((device.to_string(), default_port))
}

pub fn send_file(path: &std::path::Path) {
    let settings = SETTINGS.lock().clone();
    let Some(settings) = settings else { return };
    let file_id = uuid::Uuid::new_v4().to_string();
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".into());
    let data = std::fs::read(path).unwrap_or_default();
    let file_size = data.len() as i64;
    let header = serde_json::json!({
        "fileId": file_id,
        "fileName": file_name,
        "fileSize": file_size,
    });
    broadcast_sync_message("file/header", &header.to_string(), &file_id);
    for (idx, chunk) in data.chunks(FILE_CHUNK_SIZE).enumerate() {
        let is_last = idx * FILE_CHUNK_SIZE + chunk.len() >= data.len();
        let chunk_json = serde_json::json!({
            "fileId": file_id,
            "chunkIndex": idx,
            "data": STANDARD.encode(chunk),
            "isLast": is_last,
            "isCompressed": false,
        });
        broadcast_sync_message("file/chunk", &chunk_json.to_string(), &file_id);
    }
    let _ = settings;
    let _ = sha256_hex;
    let _ = downloads_clipy_dir;
}
