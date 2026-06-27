pub mod crypto;
pub mod discovery;
pub mod handlers;
pub mod protocol;
pub mod transport;

use gpui::{App, Global};

use crate::config::Settings;
use crate::repository::GlobalRepository;

pub struct SyncManager {
    pub device_id: String,
    pub last_sync_hash: parking_lot::Mutex<Option<String>>,
}

impl SyncManager {
    pub fn new(device_id: String) -> Self {
        Self {
            device_id,
            last_sync_hash: parking_lot::Mutex::new(None),
        }
    }
}

impl Global for SyncManager {}

pub fn start_sync(cx: &mut App) {
    let settings = Settings::read(cx, |s| s.sync.clone());
    if !settings.enabled {
        return;
    }
    let device_id = settings.device_name.clone();
    cx.set_global(SyncManager::new(device_id.clone()));
    discovery::start(settings.clone());
    transport::start_listener(settings, cx);

    let repo = GlobalRepository::global(cx).cloned();
    cx.spawn(async move |_async_app| {
        loop {
            for (text, _hash) in handlers::drain_remote_text() {
                if let Some(ref r) = repo {
                    let _ = r.save_text(text, None, None);
                    let _ = r.persist_current();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
    })
    .detach();
}

pub fn broadcast_text(content: &str, hash: &str) {
    transport::broadcast_sync_message("text/plain", content, hash);
}
