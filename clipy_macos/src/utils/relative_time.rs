use chrono::{DateTime, Local, Utc};

/// 对齐 Swift RelativeTimeFormatter
pub fn format_relative_time(date: DateTime<Local>) -> String {
    let now = Local::now();
    let secs = (now - date).num_seconds();
    if secs < 60 {
        return if secs <= 1 {
            "just now".into()
        } else {
            format!("{secs}s ago")
        };
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("{mins}m ago");
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{hours}h ago");
    }
    let days = hours / 24;
    if days < 7 {
        return format!("{days}d ago");
    }
    date.format("%Y-%m-%d %H:%M").to_string()
}

pub fn format_relative_time_zh(date: DateTime<Local>) -> String {
    let now = Local::now();
    let secs = (now - date).num_seconds();
    if secs < 60 {
        return if secs <= 1 {
            "刚刚".into()
        } else {
            format!("{secs} 秒前")
        };
    }
    let mins = secs / 60;
    if mins < 60 {
        return format!("{mins} 分钟前");
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{hours} 小时前");
    }
    let days = hours / 24;
    if days < 7 {
        return format!("{days} 天前");
    }
    date.format("%Y-%m-%d %H:%M").to_string()
}

pub fn format_for_language(date: DateTime<Local>, zh: bool) -> String {
    if zh {
        format_relative_time_zh(date)
    } else {
        format_relative_time(date)
    }
}

#[allow(dead_code)]
pub fn utc_to_local(utc: DateTime<Utc>) -> DateTime<Local> {
    utc.with_timezone(&Local)
}
