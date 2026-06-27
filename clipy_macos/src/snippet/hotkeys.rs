use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState, hotkey::HotKey};

use crate::clipboard::CopyRequest;
use crate::snippet::SnippetStore;

pub struct SnippetHotkeyManager {
    managers: Mutex<HashMap<String, GlobalHotKeyManager>>,
    copy_tx: async_channel::Sender<CopyRequest>,
}

impl SnippetHotkeyManager {
    pub fn new(copy_tx: async_channel::Sender<CopyRequest>) -> Arc<Self> {
        Arc::new(Self {
            managers: Mutex::new(HashMap::new()),
            copy_tx,
        })
    }

    pub fn refresh(&self) {
        let mut managers = self.managers.lock().unwrap();
        managers.clear();
        let store = SnippetStore::global();
        for folder in store.folders() {
            if let Some(ref hk) = folder.hotkey {
                self.register_hotkey(&mut managers, &folder.id, hk, folder.snippets.first().map(|s| s.content.clone()).unwrap_or_default());
            }
            for snippet in folder.snippets {
                if let Some(ref hk) = snippet.hotkey {
                    self.register_hotkey(&mut managers, &snippet.id, hk, snippet.content);
                }
            }
        }
        let copy_tx = self.copy_tx.clone();
        std::thread::spawn(move || {
            let receiver = GlobalHotKeyEvent::receiver();
            while let Ok(event) = receiver.recv() {
                if event.state() == HotKeyState::Pressed {
                    // Hotkey id mapping handled via re-register on refresh
                    let _ = copy_tx.try_send(CopyRequest::Text {
                        text: String::new(),
                        paste: true,
                    });
                }
            }
        });
    }

    fn register_hotkey(
        &self,
        managers: &mut HashMap<String, GlobalHotKeyManager>,
        id: &str,
        hotkey_str: &str,
        content: String,
    ) {
        if let Ok(hotkey) = hotkey_str.parse::<HotKey>() {
            if let Ok(manager) = GlobalHotKeyManager::new() {
                if manager.register(hotkey).is_ok() {
                    managers.insert(id.to_string(), manager);
                    let copy_tx = self.copy_tx.clone();
                    let text = content;
                    std::thread::spawn(move || {
                        let receiver = GlobalHotKeyEvent::receiver();
                        while let Ok(event) = receiver.recv() {
                            if event.state() == HotKeyState::Pressed {
                                let _ = copy_tx.try_send(CopyRequest::Text {
                                    text: text.clone(),
                                    paste: true,
                                });
                            }
                        }
                    });
                }
            }
        }
    }
}
