use std::collections::HashMap;
use std::path::PathBuf;

const BUNDLE_ID: &str = "com.yourdomain.ClipyClone";

pub fn plist_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| {
        h.join("Library")
            .join("Preferences")
            .join(format!("{BUNDLE_ID}.plist"))
    })
}

pub fn read_string(key: &str) -> Option<String> {
    read_value(key).and_then(|v| match v {
        plist::Value::String(s) => Some(s),
        _ => None,
    })
}

pub fn read_bool(key: &str) -> Option<bool> {
    read_value(key).and_then(|v| match v {
        plist::Value::Boolean(b) => Some(b),
        _ => None,
    })
}

pub fn read_i64(key: &str) -> Option<i64> {
    read_value(key).and_then(|v| match v {
        plist::Value::Integer(i) => i.as_signed().map(|n| n as i64),
        _ => None,
    })
}

pub fn read_string_array(key: &str) -> Option<Vec<String>> {
    read_value(key).and_then(|v| match v {
        plist::Value::Array(arr) => Some(
            arr.into_iter()
                .filter_map(|v| match v {
                    plist::Value::String(s) => Some(s),
                    _ => None,
                })
                .collect(),
        ),
        _ => None,
    })
}

pub fn write_string(key: &str, value: &str) {
    write_value(key, plist::Value::String(value.to_string()));
}

pub fn write_bool(key: &str, value: bool) {
    write_value(key, plist::Value::Boolean(value));
}

pub fn write_i64(key: &str, value: i64) {
    write_value(key, plist::Value::Integer(value.into()));
}

pub fn write_string_array(key: &str, values: &[String]) {
    write_value(
        key,
        plist::Value::Array(
            values
                .iter()
                .map(|s| plist::Value::String(s.clone()))
                .collect(),
        ),
    );
}

fn read_value(key: &str) -> Option<plist::Value> {
    let path = plist_path()?;
    let file = std::fs::File::open(path).ok()?;
    let root: plist::Value = plist::from_reader(file).ok()?;
    match root {
        plist::Value::Dictionary(dict) => dict.get(key).cloned(),
        _ => None,
    }
}

fn write_value(key: &str, value: plist::Value) {
    let Some(path) = plist_path() else {
        return;
    };
    let mut dict: plist::Dictionary = if path.exists() {
        std::fs::File::open(&path)
            .ok()
            .and_then(|f| {
                let value: plist::Value = plist::from_reader(f).ok()?;
                match value {
                    plist::Value::Dictionary(d) => Some(d),
                    _ => None,
                }
            })
            .unwrap_or_default()
    } else {
        plist::Dictionary::new()
    };
    dict.insert(key.to_string(), value);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(mut file) = std::fs::File::create(path) {
        let _ = plist::to_writer_xml(&mut file, &plist::Value::Dictionary(dict));
    }
}

pub fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_else(|_| "Mac".to_string())
}
