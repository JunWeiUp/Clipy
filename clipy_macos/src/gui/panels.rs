use chrono::{DateTime, Local};

use crate::repository::{ClipboardRecord, ContentType};

pub fn record_title(record: &ClipboardRecord) -> String {
    match record.content_type {
        ContentType::Image => "[Image]".into(),
        ContentType::FilePath => {
            let first = record.content.lines().next().unwrap_or("");
            format!(
                "[File] {}",
                std::path::Path::new(first)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| first.to_string())
            )
        }
        _ => record
            .content
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(120)
            .collect(),
    }
}

pub fn record_preview(record: &ClipboardRecord) -> String {
    match record.content_type {
        ContentType::FilePath => record.content.lines().take(5).collect::<Vec<_>>().join("\n"),
        _ => record.content.chars().take(500).collect(),
    }
}

pub fn record_location(record: &ClipboardRecord) -> String {
    match record.content_type {
        ContentType::FilePath => record
            .content
            .lines()
            .next()
            .map(|p| {
                std::path::Path::new(p)
                    .parent()
                    .map(|d| d.to_string_lossy().into_owned())
                    .unwrap_or_else(|| p.to_string())
            })
            .unwrap_or_default(),
        _ => String::new(),
    }
}

pub fn record_time(record: &ClipboardRecord) -> String {
    format_record_time(&record.created_at)
}

pub fn format_record_time(dt: &DateTime<Local>) -> String {
    crate::utils::relative_time::format_relative_time(*dt)
}

pub fn type_label(ct: ContentType) -> &'static str {
    match ct {
        ContentType::Text => "Text",
        ContentType::Image => "Image",
        ContentType::FilePath => "File",
        ContentType::RichText => "Rich",
        ContentType::Rtf => "RTF",
        ContentType::Html => "HTML",
        ContentType::Pdf => "PDF",
    }
}

pub fn type_icon(ct: ContentType) -> &'static str {
    match ct {
        ContentType::Text => "T",
        ContentType::Image => "I",
        ContentType::FilePath => "F",
        ContentType::RichText => "R",
        ContentType::Rtf => "R",
        ContentType::Html => "H",
        ContentType::Pdf => "P",
    }
}
