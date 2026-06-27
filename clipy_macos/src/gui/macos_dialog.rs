#[cfg(target_os = "macos")]
pub fn pick_files() -> Vec<String> {
    let script = r#"
        set theFiles to choose file with prompt "Select files" with multiple selections allowed
        set output to ""
        repeat with f in theFiles
            set output to output & (POSIX path of f) & linefeed
        end repeat
        return output
    "#;
    run_osascript(script)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

#[cfg(target_os = "macos")]
pub fn pick_folder() -> Option<String> {
    let script = r#"
        return POSIX path of (choose folder with prompt "Select folder")
    "#;
    let result = run_osascript(script);
    if result.trim().is_empty() {
        None
    } else {
        Some(result.trim().to_string())
    }
}

#[cfg(target_os = "macos")]
pub fn prompt_text(title: &str, message: &str, default: &str) -> Option<String> {
    let script = format!(
        r#"display dialog "{message}" default answer "{default}" with title "{title}" buttons {{"Cancel", "OK"}} default button "OK"
        if button returned of result is "OK" then return text returned of result"#,
        message = escape_applescript(message),
        default = escape_applescript(default),
        title = escape_applescript(title),
    );
    let result = run_osascript(&script);
    if result.is_empty() { None } else { Some(result) }
}

#[cfg(target_os = "macos")]
fn escape_applescript(value: &str) -> String {
    value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(target_os = "macos")]
fn run_osascript(script: &str) -> String {
    use std::process::Command;
    Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .ok()
        .and_then(|output| {
            if output.status.success() {
                Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default()
}

#[cfg(not(target_os = "macos"))]
pub fn pick_files() -> Vec<String> {
    Vec::new()
}

#[cfg(not(target_os = "macos"))]
pub fn pick_folder() -> Option<String> {
    None
}

#[cfg(not(target_os = "macos"))]
pub fn prompt_text(_title: &str, _message: &str, _default: &str) -> Option<String> {
    None
}
