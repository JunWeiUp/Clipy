use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnippetFolder {
    pub id: String,
    pub name: String,
    pub snippets: Vec<Snippet>,
    #[serde(default)]
    pub hotkey: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snippet {
    pub id: String,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub hotkey: Option<String>,
    pub updated_at: DateTime<Local>,
}

impl SnippetFolder {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            snippets: Vec::new(),
            hotkey: None,
        }
    }
}

impl Snippet {
    pub fn new(title: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            title: title.into(),
            content: content.into(),
            hotkey: None,
            updated_at: Local::now(),
        }
    }
}
