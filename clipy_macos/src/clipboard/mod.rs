pub mod listener;
pub mod writer;

use std::sync::{Arc, Mutex};

#[derive(Debug, Clone)]
pub enum ClipboardEvent {
    Text {
        text: String,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    },
    Image {
        path: String,
        hash: u64,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    },
    Files {
        paths: Vec<String>,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    },
    RichText {
        plain_text: String,
        html: Option<String>,
        rtf: Option<String>,
        source_app: Option<String>,
        source_bundle_id: Option<String>,
    },
}

#[derive(Debug, Clone)]
pub enum LastCopyState {
    Text(String),
    Image(u64),
    Files(u64),
    RichText(String),
}

impl Default for LastCopyState {
    fn default() -> Self {
        Self::Text(String::new())
    }
}

#[derive(Debug)]
pub enum CopyRequest {
    Text {
        text: String,
        paste: bool,
    },
    Image {
        path: String,
        paste: bool,
    },
    Files {
        paths: Vec<String>,
        paste: bool,
    },
    RichText {
        plain_text: String,
        html: Option<String>,
        rtf: Option<String>,
        paste: bool,
    },
}

pub type LastCopyHandle = Arc<Mutex<LastCopyState>>;

pub fn start_clipboard_monitor(
    tx: async_channel::Sender<ClipboardEvent>,
    last_copy: LastCopyHandle,
) {
    listener::start(tx, last_copy);
}

pub fn start_clipboard_writer(cx: &gpui::App) -> async_channel::Sender<CopyRequest> {
    writer::start(cx)
}
