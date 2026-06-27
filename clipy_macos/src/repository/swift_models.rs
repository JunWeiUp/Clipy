use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::utils::{app_support_dir, sha256_hex};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaKind {
    Image,
    Rtf,
    Pdf,
    Html,
}

/// 对齐 Swift `HistoryMediaStore`
pub struct HistoryMediaStore {
    pub images_dir: PathBuf,
    pub rich_text_dir: PathBuf,
    pub documents_dir: PathBuf,
}

impl HistoryMediaStore {
    pub fn new() -> Option<Self> {
        let base = app_support_dir()?;
        let images_dir = base.join("images");
        let rich_text_dir = base.join("rich_text");
        let documents_dir = base.join("documents");
        for dir in [&images_dir, &rich_text_dir, &documents_dir] {
            let _ = std::fs::create_dir_all(dir);
        }
        Some(Self {
            images_dir,
            rich_text_dir,
            documents_dir,
        })
    }

    pub fn store(&self, data: &[u8], kind: MediaKind, preferred_hash: Option<&str>) -> String {
        let hash = preferred_hash.map(str::to_string).unwrap_or_else(|| sha256_hex(data));
        let path = self.file_path(kind, &hash);
        if !path.exists() {
            if kind == MediaKind::Image {
                let _ = self.write_png(data, &path);
            } else {
                let _ = std::fs::write(&path, data);
            }
        }
        path.to_string_lossy().into_owned()
    }

    fn write_png(&self, data: &[u8], path: &Path) -> std::io::Result<()> {
        if let Ok(img) = image::load_from_memory(data) {
            img.save(path).map_err(|e| std::io::Error::other(e.to_string()))?;
            return Ok(());
        }
        std::fs::write(path, data)
    }

    pub fn file_path(&self, kind: MediaKind, hash: &str) -> PathBuf {
        let dir = match kind {
            MediaKind::Image => &self.images_dir,
            MediaKind::Rtf | MediaKind::Html => &self.rich_text_dir,
            MediaKind::Pdf => &self.documents_dir,
        };
        let ext = match kind {
            MediaKind::Image => "png",
            MediaKind::Rtf => "rtf",
            MediaKind::Html => "html",
            MediaKind::Pdf => "pdf",
        };
        dir.join(format!("{hash}.{ext}"))
    }

    pub fn collect_referenced_paths(entries: &[HistoryEntry]) -> std::collections::HashSet<String> {
        let mut paths = std::collections::HashSet::new();
        for entry in entries {
            if let Some(path) = entry.item.stored_media_path() {
                paths.insert(path);
            }
        }
        paths
    }

    pub fn remove_unreferenced(&self, referenced: &std::collections::HashSet<String>) {
        for dir in [&self.images_dir, &self.rich_text_dir, &self.documents_dir] {
            if let Ok(read) = std::fs::read_dir(dir) {
                for entry in read.flatten() {
                    let path = entry.path();
                    if path.is_file() {
                        let s = path.to_string_lossy().into_owned();
                        if !referenced.contains(&s) {
                            let _ = std::fs::remove_file(path);
                        }
                    }
                }
            }
        }
    }
}

/// Swift `HistoryItem` JSON 格式
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(untagged)]
pub enum HistoryItem {
    Text {
        text: String,
    },
    ImagePath {
        #[serde(rename = "imagePath")]
        image_path: String,
    },
    RtfPath {
        #[serde(rename = "rtfPath")]
        rtf_path: String,
    },
    PdfPath {
        #[serde(rename = "pdfPath")]
        pdf_path: String,
    },
    HtmlPath {
        #[serde(rename = "htmlPath")]
        html_path: String,
    },
    FileUrl {
        #[serde(rename = "fileURL")]
        file_url: String,
    },
    Files {
        files: Vec<String>,
    },
}

impl HistoryItem {
    pub fn text(s: String) -> Self {
        Self::Text { text: s }
    }

    pub fn stored_media_path(&self) -> Option<String> {
        match self {
            Self::ImagePath { image_path } => Some(image_path.clone()),
            Self::RtfPath { rtf_path } => Some(rtf_path.clone()),
            Self::PdfPath { pdf_path } => Some(pdf_path.clone()),
            Self::HtmlPath { html_path } => Some(html_path.clone()),
            _ => None,
        }
    }

    pub fn title(&self) -> String {
        match self {
            Self::Text { text } => text
                .trim()
                .replace('\n', " ")
                .chars()
                .take(120)
                .collect(),
            Self::ImagePath { .. } => "[Image]".into(),
            Self::RtfPath { .. } => "[Rich Text]".into(),
            Self::PdfPath { .. } => "[PDF Document]".into(),
            Self::HtmlPath { .. } => "[HTML]".into(),
            Self::FileUrl { file_url } => Path::new(file_url)
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("[File]")
                .into(),
            Self::Files { files } => {
                if files.is_empty() {
                    return "[File]".into();
                }
                if files.len() == 1 {
                    return Path::new(&files[0])
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or("[File]")
                        .into();
                }
                format!("[{} Files]", files.len())
            }
        }
    }
}

/// Swift `HistoryEntry`
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HistoryEntry {
    pub item: HistoryItem,
    pub date: chrono::DateTime<chrono::Local>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_app: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_bundle_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_hash: Option<String>,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search_index: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_used_at: Option<chrono::DateTime<chrono::Local>>,
    #[serde(default)]
    pub use_count: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HistoryStorageEnvelope {
    pub version: i32,
    pub encrypted: bool,
    pub payload: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FileHistoryItem {
    pub id: String,
    pub file_name: String,
    pub file_path: String,
    pub file_size: i64,
    pub timestamp: chrono::DateTime<chrono::Local>,
    pub sender_name: String,
}

pub fn history_v2_path() -> Option<PathBuf> {
    app_support_dir().map(|d| d.join("history_v2.json"))
}

pub fn file_history_path() -> Option<PathBuf> {
    app_support_dir().map(|d| d.join("file_history.json"))
}
