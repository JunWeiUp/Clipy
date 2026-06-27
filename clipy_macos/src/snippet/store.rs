use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use gpui::{App, Global};

use chrono::Local;
use super::models::{Snippet, SnippetFolder};
use crate::utils::app_support_dir;

pub struct SnippetStore {
    folders: RwLock<Vec<SnippetFolder>>,
    path: PathBuf,
}

impl SnippetStore {
    pub fn new() -> Self {
        let path = app_support_dir()
            .map(|d| d.join("snippets.json"))
            .unwrap_or_else(|| PathBuf::from("snippets.json"));
        let folders = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(default_folders);
        Self {
            folders: RwLock::new(folders),
            path,
        }
    }

    pub fn global() -> Arc<SnippetStore> {
        GLOBAL_SNIPPETS.clone()
    }

    pub fn folders(&self) -> Vec<SnippetFolder> {
        self.folders.read().map(|f| f.clone()).unwrap_or_default()
    }

    pub fn save(&self) {
        if let Ok(data) = self.folders.read() {
            if let Ok(json) = serde_json::to_string_pretty(&*data) {
                let _ = std::fs::write(&self.path, json);
            }
        }
    }

    pub fn upsert_folder(&self, folder: SnippetFolder) {
        if let Ok(mut folders) = self.folders.write() {
            if let Some(idx) = folders.iter().position(|f| f.id == folder.id) {
                folders[idx] = folder;
            } else {
                folders.push(folder);
            }
        }
        self.save();
    }

    pub fn delete_folder(&self, id: &str) {
        if let Ok(mut folders) = self.folders.write() {
            folders.retain(|f| f.id != id);
        }
        self.save();
    }

    pub fn add_folder(&self, name: impl Into<String>) -> SnippetFolder {
        let folder = SnippetFolder::new(name);
        if let Ok(mut folders) = self.folders.write() {
            folders.push(folder.clone());
        }
        self.save();
        folder
    }

    pub fn add_snippet(&self, folder_id: &str, title: impl Into<String>, content: impl Into<String>) -> Option<Snippet> {
        let snippet = Snippet::new(title, content);
        if let Ok(mut folders) = self.folders.write() {
            if let Some(folder) = folders.iter_mut().find(|f| f.id == folder_id) {
                folder.snippets.push(snippet.clone());
                self.save();
                return Some(snippet);
            }
        }
        None
    }

    pub fn delete_snippet(&self, snippet_id: &str) -> bool {
        let mut removed = false;
        if let Ok(mut folders) = self.folders.write() {
            for folder in folders.iter_mut() {
                let before = folder.snippets.len();
                folder.snippets.retain(|s| s.id != snippet_id);
                if folder.snippets.len() != before {
                    removed = true;
                }
            }
        }
        if removed {
            self.save();
        }
        removed
    }

    pub fn update_snippet(&self, snippet_id: &str, title: &str, content: &str) -> bool {
        let mut updated = false;
        if let Ok(mut folders) = self.folders.write() {
            for folder in folders.iter_mut() {
                if let Some(snippet) = folder.snippets.iter_mut().find(|s| s.id == snippet_id) {
                    snippet.title = title.to_string();
                    snippet.content = content.to_string();
                    snippet.updated_at = Local::now();
                    updated = true;
                }
            }
        }
        if updated {
            self.save();
        }
        updated
    }

    pub fn update_folder_name(&self, folder_id: &str, name: &str) -> bool {
        if let Ok(mut folders) = self.folders.write() {
            if let Some(folder) = folders.iter_mut().find(|f| f.id == folder_id) {
                folder.name = name.to_string();
                self.save();
                return true;
            }
        }
        false
    }

    pub fn find_snippet(&self, snippet_id: &str) -> Option<(SnippetFolder, Snippet)> {
        for folder in self.folders() {
            if let Some(snippet) = folder.snippets.iter().find(|s| s.id == snippet_id).cloned() {
                return Some((folder, snippet));
            }
        }
        None
    }

    pub fn export_json(&self) -> Option<String> {
        self.folders.read().ok().and_then(|f| serde_json::to_string_pretty(&*f).ok())
    }

    pub fn import_json(&self, json: &str) -> bool {
        if let Ok(folders) = serde_json::from_str::<Vec<SnippetFolder>>(json) {
            if let Ok(mut data) = self.folders.write() {
                *data = folders;
            }
            self.save();
            true
        } else {
            false
        }
    }
}

fn default_folders() -> Vec<SnippetFolder> {
    let mut greetings = SnippetFolder::new("Greetings");
    greetings.snippets.push(super::models::Snippet::new(
        "Hello",
        "Hello, World!",
    ));
    vec![greetings]
}

static GLOBAL_SNIPPETS: once_cell::sync::Lazy<Arc<SnippetStore>> =
    once_cell::sync::Lazy::new(|| Arc::new(SnippetStore::new()));

pub struct GlobalSnippetStore(pub Arc<SnippetStore>);

impl Global for GlobalSnippetStore {}

impl GlobalSnippetStore {
    pub fn install(cx: &mut App) {
        cx.set_global(Self(SnippetStore::global()));
    }
}
