use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use chrono::Local;
use parking_lot::Mutex;

use super::crypto::{decrypt, encrypt, load_or_create_key};
use super::models::{ClipboardRecord, ContentType, RichTextMeta};
use super::swift_models::{
    file_history_path, history_v2_path, HistoryEntry, HistoryItem, HistoryMediaStore, HistoryStorageEnvelope,
    MediaKind,
};
use crate::utils::{content_hash, hash_file_paths, images_dir, normalize_file_paths, rich_text_dir, sha256_hex};

#[derive(Debug, thiserror::Error)]
pub enum RepositoryError {
    #[error("data directory not found")]
    DataDirNotFound,
    #[error("database: {0}")]
    Database(String),
    #[error("deserialization: {0}")]
    Deserialization(String),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

pub struct ClipboardRepository {
    entries: Mutex<Vec<HistoryEntry>>,
    media: HistoryMediaStore,
    history_path: PathBuf,
    rich_text_dir: PathBuf,
    images_dir: PathBuf,
    encryption_enabled: AtomicBool,
}

impl ClipboardRepository {
    pub fn new() -> Result<Self, RepositoryError> {
        let history_path = history_v2_path().ok_or(RepositoryError::DataDirNotFound)?;
        let media = HistoryMediaStore::new().ok_or(RepositoryError::DataDirNotFound)?;
        let rich_text_dir = rich_text_dir().ok_or(RepositoryError::DataDirNotFound)?;
        let images_dir = images_dir().ok_or(RepositoryError::DataDirNotFound)?;
        if let Some(parent) = history_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let entries = Self::load_from_disk(&history_path)?;
        Ok(Self {
            entries: Mutex::new(entries),
            media,
            history_path,
            rich_text_dir,
            images_dir,
            encryption_enabled: AtomicBool::new(false),
        })
    }

    pub fn set_encryption_enabled(&self, enabled: bool) {
        self.encryption_enabled.store(enabled, Ordering::SeqCst);
    }

    pub fn encryption_enabled(&self) -> bool {
        self.encryption_enabled.load(Ordering::SeqCst)
    }

    pub fn persist_current(&self) -> Result<(), RepositoryError> {
        self.persist(self.encryption_enabled())
    }

    fn load_from_disk(path: &PathBuf) -> Result<Vec<HistoryEntry>, RepositoryError> {
        if !path.exists() {
            return Ok(Vec::new());
        }
        let data = std::fs::read(path)?;
        if data.is_empty() {
            return Ok(Vec::new());
        }
        if let Ok(envelope) = serde_json::from_slice::<HistoryStorageEnvelope>(&data) {
            if envelope.encrypted {
                let key = load_or_create_key().map_err(|e| RepositoryError::Database(e.to_string()))?;
                let encrypted = STANDARD
                    .decode(&envelope.payload)
                    .map_err(|e| RepositoryError::Deserialization(e.to_string()))?;
                let plain = decrypt(&encrypted, &key).map_err(|e| RepositoryError::Database(e.to_string()))?;
                return serde_json::from_slice(&plain)
                    .map_err(|e| RepositoryError::Deserialization(e.to_string()));
            }
        }
        serde_json::from_slice(&data).map_err(|e| RepositoryError::Deserialization(e.to_string()))
    }

    pub fn persist(&self, encryption_enabled: bool) -> Result<(), RepositoryError> {
        let entries = self.entries.lock().clone();
        let json = serde_json::to_vec(&entries).map_err(|e| RepositoryError::Deserialization(e.to_string()))?;
        let out = if encryption_enabled {
            let key = load_or_create_key().map_err(|e| RepositoryError::Database(e.to_string()))?;
            let encrypted = encrypt(&json, &key).map_err(|e| RepositoryError::Database(e.to_string()))?;
            serde_json::to_vec(&HistoryStorageEnvelope {
                version: 1,
                encrypted: true,
                payload: STANDARD.encode(encrypted),
            })
            .map_err(|e| RepositoryError::Deserialization(e.to_string()))?
        } else {
            json
        };
        std::fs::write(&self.history_path, out)?;
        let referenced = HistoryMediaStore::collect_referenced_paths(&entries);
        self.media.remove_unreferenced(&referenced);
        Ok(())
    }

    fn entry_id(entry: &HistoryEntry) -> u64 {
        match &entry.item {
            HistoryItem::Text { text } => content_hash(text, &ContentType::Text),
            HistoryItem::ImagePath { image_path } => {
                let mut h = seahash::SeaHasher::new();
                use std::hash::{Hash, Hasher};
                image_path.hash(&mut h);
                h.finish()
            }
            HistoryItem::FileUrl { file_url } => hash_file_paths(&[file_url.clone()]),
            HistoryItem::Files { files } => hash_file_paths(files),
            HistoryItem::RtfPath { rtf_path } => content_hash(rtf_path, &ContentType::Rtf),
            HistoryItem::PdfPath { pdf_path } => content_hash(pdf_path, &ContentType::Pdf),
            HistoryItem::HtmlPath { html_path } => content_hash(html_path, &ContentType::Html),
        }
    }

    fn to_record(entry: &HistoryEntry) -> ClipboardRecord {
        let (content_type, content, rich_text_meta) = match &entry.item {
            HistoryItem::Text { text } => (ContentType::Text, text.clone(), None),
            HistoryItem::ImagePath { image_path } => (ContentType::Image, image_path.clone(), None),
            HistoryItem::RtfPath { rtf_path } => (
                ContentType::Rtf,
                rtf_path.clone(),
                None,
            ),
            HistoryItem::PdfPath { pdf_path } => (ContentType::Pdf, pdf_path.clone(), None),
            HistoryItem::HtmlPath { html_path } => (ContentType::Html, html_path.clone(), None),
            HistoryItem::FileUrl { file_url } => (ContentType::FilePath, file_url.clone(), None),
            HistoryItem::Files { files } => (ContentType::FilePath, files.join("\n"), None),
        };
        let id = Self::entry_id(entry);
        ClipboardRecord {
            id,
            content,
            created_at: entry.date,
            content_type,
            pinned: entry.is_pinned,
            source_app: entry.source_app.clone(),
            source_bundle_id: entry.source_bundle_id.clone(),
            use_count: entry.use_count.max(0) as u32,
            last_used_at: entry.last_used_at,
            search_index: entry.search_index.clone(),
            content_hash_hex: entry.content_hash.clone(),
            rich_text_meta,
        }
    }

    fn remove_by_id(&self, id: u64) -> Option<HistoryEntry> {
        let mut entries = self.entries.lock();
        if let Some(pos) = entries.iter().position(|e| Self::entry_id(e) == id) {
            Some(entries.remove(pos))
        } else {
            None
        }
    }

    fn insert_entry(&self, entry: HistoryEntry) -> Result<HistoryEntry, RepositoryError> {
        let id = Self::entry_id(&entry);
        if let Some(existing) = self.remove_by_id(id) {
            let mut entry = entry;
            entry.is_pinned = existing.is_pinned;
            entry.use_count = existing.use_count;
            entry.last_used_at = existing.last_used_at;
            self.entries.lock().insert(0, entry.clone());
            return Ok(entry);
        }
        self.entries.lock().insert(0, entry.clone());
        Ok(entry)
    }

    pub fn save_text(
        &self,
        content: String,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    ) -> Result<ClipboardRecord, RepositoryError> {
        let entry = HistoryEntry {
            item: HistoryItem::text(content.clone()),
            date: Local::now(),
            source_app,
            source_bundle_id,
            content_hash: Some(sha256_hex(content.as_bytes())),
            is_pinned: false,
            search_index: Some(content.chars().take(500).collect()),
            last_used_at: None,
            use_count: 0,
        };
        let saved = self.insert_entry(entry)?;
        Ok(Self::to_record(&saved))
    }

    pub fn save_files(
        &self,
        paths: Vec<String>,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    ) -> Result<ClipboardRecord, RepositoryError> {
        let normalized = normalize_file_paths(paths);
        let item = if normalized.len() == 1 {
            HistoryItem::FileUrl {
                file_url: normalized[0].clone(),
            }
        } else {
            HistoryItem::Files {
                files: normalized.clone(),
            }
        };
        let entry = HistoryEntry {
            item,
            date: Local::now(),
            source_app,
            source_bundle_id,
            content_hash: Some(sha256_hex(normalized.join("|").as_bytes())),
            is_pinned: false,
            search_index: None,
            last_used_at: None,
            use_count: 0,
        };
        let saved = self.insert_entry(entry)?;
        Ok(Self::to_record(&saved))
    }

    pub fn save_image_from_path(
        &self,
        file_path: String,
        image_hash: u64,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    ) -> Result<ClipboardRecord, RepositoryError> {
        let _ = image_hash;
        let entry = HistoryEntry {
            item: HistoryItem::ImagePath {
                image_path: file_path,
            },
            date: Local::now(),
            source_app,
            source_bundle_id,
            content_hash: None,
            is_pinned: false,
            search_index: None,
            last_used_at: None,
            use_count: 0,
        };
        let saved = self.insert_entry(entry)?;
        Ok(Self::to_record(&saved))
    }

    pub fn save_rich_text(
        &self,
        plain_text: String,
        html: Option<String>,
        rtf: Option<String>,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    ) -> Result<ClipboardRecord, RepositoryError> {
        let html_path = html.as_ref().map(|h| {
            self.media
                .store(h.as_bytes(), MediaKind::Html, None)
        });
        let rtf_path = rtf.as_ref().map(|r| self.media.store(r.as_bytes(), MediaKind::Rtf, None));
        let item = if let Some(ref path) = html_path {
            HistoryItem::HtmlPath {
                html_path: path.clone(),
            }
        } else if let Some(ref path) = rtf_path {
            HistoryItem::RtfPath {
                rtf_path: path.clone(),
            }
        } else {
            HistoryItem::text(plain_text.clone())
        };
        let entry = HistoryEntry {
            item,
            date: Local::now(),
            source_app,
            source_bundle_id,
            content_hash: Some(sha256_hex(plain_text.as_bytes())),
            is_pinned: false,
            search_index: Some(plain_text.chars().take(500).collect()),
            last_used_at: None,
            use_count: 0,
        };
        let saved = self.insert_entry(entry)?;
        let mut record = Self::to_record(&saved);
        record.content = plain_text;
        record.content_type = ContentType::RichText;
        record.rich_text_meta = Some(RichTextMeta { html_path, rtf_path });
        Ok(record)
    }

    pub fn get_record(&self, id: u64) -> Result<Option<ClipboardRecord>, RepositoryError> {
        let entries = self.entries.lock();
        Ok(entries
            .iter()
            .find(|e| Self::entry_id(e) == id)
            .map(Self::to_record))
    }

    pub fn get_display_records(&self, limit: usize) -> Result<Vec<ClipboardRecord>, RepositoryError> {
        let entries = self.entries.lock();
        let mut records: Vec<ClipboardRecord> = entries.iter().map(Self::to_record).collect();
        records.sort_by(|a, b| match (a.pinned, b.pinned) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => b.created_at.cmp(&a.created_at),
        });
        records.truncate(limit);
        Ok(records)
    }

    pub fn count_records(&self) -> Result<usize, RepositoryError> {
        Ok(self.entries.lock().len())
    }

    pub fn delete_record(&self, id: u64) -> Result<(), RepositoryError> {
        self.remove_by_id(id);
        self.persist_current()
    }

    pub fn toggle_pin(&self, id: u64) -> Result<Option<ClipboardRecord>, RepositoryError> {
        let mut entries = self.entries.lock();
        if let Some(entry) = entries.iter_mut().find(|e| Self::entry_id(e) == id) {
            entry.is_pinned = !entry.is_pinned;
            let record = Self::to_record(entry);
            drop(entries);
            self.persist_current()?;
            Ok(Some(record))
        } else {
            Ok(None)
        }
    }

    pub fn clear_history(&self) -> Result<usize, RepositoryError> {
        let mut entries = self.entries.lock();
        let count = entries.len();
        entries.clear();
        drop(entries);
        self.persist_current()?;
        Ok(count)
    }

    pub fn cleanup_old_records(&self, max_storage: usize) -> Result<usize, RepositoryError> {
        let mut entries = self.entries.lock();
        if entries.len() <= max_storage {
            return Ok(0);
        }
        let mut removed = 0usize;
        while entries.len() > max_storage {
            if let Some(pos) = entries.iter().rposition(|e| !e.is_pinned) {
                entries.remove(pos);
                removed += 1;
            } else {
                break;
            }
        }
        drop(entries);
        if removed > 0 {
            self.persist_current()?;
        }
        Ok(removed)
    }

    pub fn touch_usage(&self, id: u64) -> Result<(), RepositoryError> {
        let mut entries = self.entries.lock();
        if let Some(entry) = entries.iter_mut().find(|e| Self::entry_id(e) == id) {
            entry.use_count += 1;
            entry.last_used_at = Some(Local::now());
            drop(entries);
            self.persist_current()?;
        }
        Ok(())
    }

    pub fn all_entries(&self) -> Vec<HistoryEntry> {
        self.entries.lock().clone()
    }

    pub fn load_file_history(&self) -> Result<Vec<super::swift_models::FileHistoryItem>, RepositoryError> {
        let path = file_history_path().ok_or(RepositoryError::DataDirNotFound)?;
        if !path.exists() {
            return Ok(Vec::new());
        }
        let data = std::fs::read_to_string(path)?;
        serde_json::from_str(&data).map_err(|e| RepositoryError::Deserialization(e.to_string()))
    }

    pub fn add_file_history(
        &self,
        file_name: String,
        file_path: String,
        file_size: i64,
        sender_name: String,
    ) -> Result<(), RepositoryError> {
        use super::swift_models::FileHistoryItem;
        let path = file_history_path().ok_or(RepositoryError::DataDirNotFound)?;
        let mut items = self.load_file_history()?;
        items.insert(
            0,
            FileHistoryItem {
                id: uuid::Uuid::new_v4().to_string(),
                file_name,
                file_path,
                file_size,
                timestamp: Local::now(),
                sender_name,
            },
        );
        if items.len() > 20 {
            items.truncate(20);
        }
        std::fs::write(path, serde_json::to_string_pretty(&items).unwrap_or_default())?;
        Ok(())
    }

    pub fn images_directory(&self) -> &std::path::Path {
        &self.images_dir
    }
}

pub type SharedRepository = Arc<ClipboardRepository>;
