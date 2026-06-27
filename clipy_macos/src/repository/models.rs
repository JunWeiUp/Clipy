use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ClipboardRecord {
    pub id: u64,
    pub content: String,
    pub created_at: DateTime<Local>,
    pub content_type: ContentType,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub source_app: Option<String>,
    #[serde(default)]
    pub source_bundle_id: Option<String>,
    #[serde(default)]
    pub use_count: u32,
    #[serde(default)]
    pub last_used_at: Option<DateTime<Local>>,
    #[serde(default)]
    pub search_index: Option<String>,
    #[serde(default)]
    pub content_hash_hex: Option<String>,
    #[serde(default)]
    pub rich_text_meta: Option<RichTextMeta>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum ContentType {
    Text,
    Image,
    FilePath,
    RichText,
    Rtf,
    Html,
    Pdf,
}

impl ContentType {
    pub const fn as_tag(&self) -> u8 {
        match self {
            Self::Text => 0,
            Self::Image => 1,
            Self::FilePath => 2,
            Self::RichText => 3,
            Self::Rtf => 4,
            Self::Html => 5,
            Self::Pdf => 6,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RichTextMeta {
    pub html_path: Option<String>,
    pub rtf_path: Option<String>,
}
