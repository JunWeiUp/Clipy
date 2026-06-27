use crate::repository::models::{ClipboardRecord, ContentType};

#[derive(Debug, Clone, Default)]
pub struct SearchOptions {
    pub case_sensitive: bool,
    pub whole_word: bool,
    pub regex: bool,
    pub pinned_only: bool,
    pub content_type: Option<ContentType>,
    pub source_app: Option<String>,
    pub path_contains: Option<String>,
    pub url_only: bool,
}

pub fn parse_query(query: &str) -> (String, SearchOptions) {
    let mut opts = SearchOptions::default();
    let mut text_parts = Vec::new();
    for token in query.split_whitespace() {
        if let Some(rest) = token.strip_prefix("type:") {
            opts.content_type = match rest.to_lowercase().as_str() {
                "text" => Some(ContentType::Text),
                "image" => Some(ContentType::Image),
                "file" | "files" => Some(ContentType::FilePath),
                "rich" | "richtext" => Some(ContentType::RichText),
                _ => None,
            };
        } else if let Some(rest) = token.strip_prefix("app:") {
            opts.source_app = Some(rest.to_string());
        } else if let Some(rest) = token.strip_prefix("path:") {
            opts.path_contains = Some(rest.to_string());
        } else if token == "pin" {
            opts.pinned_only = true;
        } else if token == "url" {
            opts.url_only = true;
        } else {
            text_parts.push(token);
        }
    }
    (text_parts.join(" "), opts)
}

pub fn filter_and_rank(records: &[ClipboardRecord], query: &str, opts: &SearchOptions) -> Vec<(usize, f32)> {
    let mut scored: Vec<(usize, f32)> = records
        .iter()
        .enumerate()
        .filter_map(|(idx, record)| {
            if opts.pinned_only && !record.pinned {
                return None;
            }
            if let Some(ref ct) = opts.content_type {
                if &record.content_type != ct {
                    return None;
                }
            }
            if let Some(ref app) = opts.source_app {
                let source = record.source_app.as_deref().unwrap_or("");
                if !source.to_lowercase().contains(&app.to_lowercase()) {
                    return None;
                }
            }
            if let Some(ref path) = opts.path_contains {
                if !record.content.to_lowercase().contains(&path.to_lowercase()) {
                    return None;
                }
            }
            if opts.url_only && !record.content.contains("://") {
                return None;
            }
            let score = fuzzy_score(&record.content, query, opts);
            if query.is_empty() || score > 0.0 {
                let mut final_score = score;
                if record.pinned {
                    final_score += 1000.0;
                }
                final_score += record.use_count as f32 * 2.0;
                if let Some(last) = record.last_used_at {
                    final_score += (last.timestamp() as f32) / 1_000_000.0;
                }
                Some((idx, final_score))
            } else {
                None
            }
        })
        .collect();
    scored.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    scored
}

fn fuzzy_score(content: &str, query: &str, opts: &SearchOptions) -> f32 {
    if query.is_empty() {
        return 1.0;
    }
    let content_cmp = if opts.case_sensitive {
        content.to_string()
    } else {
        content.to_lowercase()
    };
    let query_cmp = if opts.case_sensitive {
        query.to_string()
    } else {
        query.to_lowercase()
    };
    if opts.regex {
        if let Ok(re) = regex::RegexBuilder::new(query)
            .case_insensitive(!opts.case_sensitive)
            .build()
        {
            return if re.is_match(&content_cmp) { 50.0 } else { 0.0 };
        }
        return 0.0;
    }
    if opts.whole_word {
        return if content_cmp.split_whitespace().any(|w| w == query_cmp) {
            80.0
        } else {
            0.0
        };
    }
    if content_cmp.contains(&query_cmp) {
        60.0 + (query_cmp.len() as f32 / content_cmp.len().max(1) as f32) * 40.0
    } else {
        0.0
    }
}
